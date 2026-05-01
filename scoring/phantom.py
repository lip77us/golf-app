"""
scoring/phantom.py
------------------
Pluggable phantom-player scoring framework.

A phantom player's scores are derived on-the-fly from the real players in
their foursome — no extra DB writes required.  The algorithm used is stored
on FoursomeMembership.phantom_algorithm; its per-run config (e.g. the random
rotation order) is stored in FoursomeMembership.phantom_config so it is
stable across recalculations.

Algorithm contract
~~~~~~~~~~~~~~~~~~
    algorithm_id   : str  — stable key stored in DB
    algorithm_label: str  — human-readable name
    initial_config(real_player_ids: list[int]) -> dict
        Called once when the phantom membership is first initialised.
        Returns a JSON-serialisable config dict that will be persisted on
        FoursomeMembership.phantom_config.
    compute_gross_score(hole: int, config: dict,
                        real_gross: dict[int, int]) -> int | None
        Given a hole number (1-18), the stored config, and a dict mapping
        {player_id: gross_score} for real players who have scored that hole,
        return the phantom's gross score for that hole (or None if not yet
        scoreable).
    compute_playing_handicap(config: dict,
                             real_hcaps: list[int]) -> int
        Return the phantom's playing handicap given the list of real players'
        playing handicaps.
    get_source_player_id(hole: int, config: dict) -> int | None
        Return the real player whose gross score is used on this hole
        (for display purposes only).
"""

import random
from abc import ABC, abstractmethod


# ---------------------------------------------------------------------------
# Abstract base
# ---------------------------------------------------------------------------

class PhantomAlgorithm(ABC):
    @property
    @abstractmethod
    def algorithm_id(self) -> str: ...

    @property
    @abstractmethod
    def algorithm_label(self) -> str: ...

    @abstractmethod
    def initial_config(self, real_player_ids: list) -> dict: ...

    @abstractmethod
    def compute_gross_score(self, hole: int, config: dict,
                            real_gross: dict) -> 'int | None': ...

    @abstractmethod
    def compute_playing_handicap(self, config: dict,
                                 real_hcaps: list) -> int: ...

    @abstractmethod
    def get_source_player_id(self, hole: int, config: dict) -> 'int | None': ...


# ---------------------------------------------------------------------------
# Concrete algorithm: Rotating Player Scores
# ---------------------------------------------------------------------------

class RotatingPlayerScores(PhantomAlgorithm):
    """
    On each hole the phantom copies the gross score of one real player,
    rotating through a fixed random order.

    config schema:
        {"rotation": [player_id, player_id, player_id]}   # 1..3 real players

    Hole assignment: rotation[(hole - 1) % len(rotation)]
    Handicap: round(average of real playing handicaps)
    """

    algorithm_id    = 'rotating_player_scores'
    algorithm_label = 'Rotating Player Scores'

    def initial_config(self, real_player_ids: list) -> dict:
        order = list(real_player_ids)
        random.shuffle(order)
        return {'rotation': order}

    def compute_gross_score(self, hole: int, config: dict,
                            real_gross: dict) -> 'int | None':
        rotation = config.get('rotation', [])
        if not rotation:
            return None
        pid = rotation[(hole - 1) % len(rotation)]
        return real_gross.get(pid)

    def compute_playing_handicap(self, config: dict,
                                 real_hcaps: list) -> int:
        if not real_hcaps:
            return 0
        return round(sum(real_hcaps) / len(real_hcaps))

    def get_source_player_id(self, hole: int,
                             config: dict) -> 'int | None':
        rotation = config.get('rotation', [])
        if not rotation:
            return None
        return rotation[(hole - 1) % len(rotation)]


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

_ALGORITHMS: list = [RotatingPlayerScores()]
REGISTRY: dict = {a.algorithm_id: a for a in _ALGORITHMS}
DEFAULT_ALGORITHM_ID = 'rotating_player_scores'


def get_algorithm(algorithm_id: str) -> PhantomAlgorithm:
    if algorithm_id not in REGISTRY:
        raise KeyError(f"Unknown phantom algorithm: {algorithm_id!r}")
    return REGISTRY[algorithm_id]


# ---------------------------------------------------------------------------
# PhantomScoreProvider — high-level helper used by game services
# ---------------------------------------------------------------------------

class PhantomScoreProvider:
    """
    Wraps a Foursome and provides on-the-fly phantom scores.

    Usage:
        provider = PhantomScoreProvider(foursome)
        if provider.has_phantom:
            gross_by_hole = provider.phantom_gross_scores()
            playing_hcp   = provider.phantom_playing_handicap()
    """

    def __init__(self, foursome):
        self._foursome = foursome
        self._phantom_membership = None
        self._real_memberships   = []
        self._algorithm          = None
        self._config             = {}
        self._loaded             = False

    def _load(self):
        if self._loaded:
            return
        self._loaded = True
        for m in self._foursome.memberships.all():
            if m.player.is_phantom:
                self._phantom_membership = m
                algo_id = getattr(m, 'phantom_algorithm', DEFAULT_ALGORITHM_ID) or DEFAULT_ALGORITHM_ID
                self._algorithm = get_algorithm(algo_id)
                self._config    = getattr(m, 'phantom_config', {}) or {}
            else:
                self._real_memberships.append(m)

    @property
    def has_phantom(self) -> bool:
        self._load()
        return self._phantom_membership is not None

    def phantom_playing_handicap(self) -> int:
        self._load()
        real_hcaps = [m.playing_handicap for m in self._real_memberships]
        return self._algorithm.compute_playing_handicap(self._config, real_hcaps)

    def phantom_gross_scores(self) -> dict:
        """
        Return {hole_number: gross_score} for every hole where all required
        real-player scores exist.
        """
        from scoring.models import HoleScore
        self._load()
        if not self._phantom_membership:
            return {}

        real_ids = [m.player_id for m in self._real_memberships]

        # Fetch real players' gross scores for this foursome
        qs = (
            HoleScore.objects
            .filter(
                foursome=self._foursome,
                player_id__in=real_ids,
            )
            .exclude(gross_score=None)
            .values('player_id', 'hole_number', 'gross_score')
        )
        # Build {hole: {player_id: gross}}
        by_hole: dict = {}
        for row in qs:
            by_hole.setdefault(row['hole_number'], {})[row['player_id']] = row['gross_score']

        result = {}
        for hole, real_gross in by_hole.items():
            score = self._algorithm.compute_gross_score(hole, self._config, real_gross)
            if score is not None:
                result[hole] = score

        return result

    def get_source_player_id(self, hole: int) -> 'int | None':
        self._load()
        return self._algorithm.get_source_player_id(hole, self._config)

    def source_by_hole(self) -> dict:
        """Return {hole_number: player_id} for holes 1-18."""
        self._load()
        return {
            h: self._algorithm.get_source_player_id(h, self._config)
            for h in range(1, 19)
        }
