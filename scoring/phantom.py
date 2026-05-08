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

Algorithms
~~~~~~~~~~
rotating_player_scores     — intra-foursome rotation (default, for 3-player groups)
cross_foursome_rotation    — rotation over donor players from OTHER foursomes on the
                             same cup team; used for Four Ball phantom in Ryder Cup.
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
# Concrete algorithm: Rotating Player Scores (intra-foursome, default)
# ---------------------------------------------------------------------------

class RotatingPlayerScores(PhantomAlgorithm):
    """
    On each hole the phantom copies the gross score of one real player,
    rotating through a fixed random order.

    Used when a threesome is padded to a foursome (e.g. Irish Rumble).
    The rotation is over the real players IN THE SAME foursome.

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
# Concrete algorithm: Cross-Foursome Rotation (Four Ball phantom)
# ---------------------------------------------------------------------------

class CrossFoursomeRotation(PhantomAlgorithm):
    """
    For Ryder Cup Four Ball (Nassau) when one team has only 3 players across
    all foursomes in the round.

    The phantom's gross score on each hole = the assigned donor's gross score
    pulled from THEIR OWN foursome (not the phantom's foursome).  Donors are
    the real players on the SAME cup team from other foursomes.

    The rotation is shuffled once and then fixed for the round so every donor
    gets approximately the same number of phantom holes, cycling in a
    deterministic order once all donors have been used once.

    config schema:
        {
          "rotation": [player_id, player_id, ...],   # donor player IDs
          "donor_names": {str(player_id): name, ...} # cached for display
        }

    Hole assignment: rotation[(hole - 1) % len(rotation)]
    Handicap: round(average of donor playing handicaps, supplied at init time)
    """

    algorithm_id    = 'cross_foursome_rotation'
    algorithm_label = 'Cross-Foursome Rotation'

    def initial_config(self, real_player_ids: list) -> dict:
        """
        real_player_ids here are the DONOR player IDs from other foursomes.
        donor_names is populated separately via init_config_with_names().
        """
        order = list(real_player_ids)
        random.shuffle(order)
        return {'rotation': order, 'donor_names': {}}

    def initial_config_with_names(self, donor_id_name_pairs: list) -> dict:
        """
        Build config from [(player_id, name), ...] pairs so the rotation
        and the name cache are set in a single step.
        """
        pairs = list(donor_id_name_pairs)
        random.shuffle(pairs)
        return {
            'rotation'    : [pid for pid, _ in pairs],
            'donor_names' : {str(pid): name for pid, name in pairs},
        }

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

    def get_source_player_name(self, hole: int, config: dict) -> 'str | None':
        pid = self.get_source_player_id(hole, config)
        if pid is None:
            return None
        return config.get('donor_names', {}).get(str(pid))


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

_ALGORITHMS: list = [RotatingPlayerScores(), CrossFoursomeRotation()]
REGISTRY: dict = {a.algorithm_id: a for a in _ALGORITHMS}
DEFAULT_ALGORITHM_ID = 'rotating_player_scores'
CROSS_FOURSOME_ALGORITHM_ID = 'cross_foursome_rotation'


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

    For 'rotating_player_scores': reads HoleScores from the SAME foursome.
    For 'cross_foursome_rotation': reads HoleScores from OTHER foursomes
        (by round) for the donor players listed in phantom_config.

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

    @property
    def is_cross_foursome(self) -> bool:
        self._load()
        return (
            self._algorithm is not None
            and self._algorithm.algorithm_id == CROSS_FOURSOME_ALGORITHM_ID
        )

    def phantom_playing_handicap(self) -> int:
        self._load()
        real_hcaps = [m.playing_handicap for m in self._real_memberships]
        return self._algorithm.compute_playing_handicap(self._config, real_hcaps)

    def phantom_gross_scores(self) -> dict:
        """
        Return {hole_number: gross_score} for every hole where the donor
        has scored.

        For rotating_player_scores: queries same-foursome HoleScores.
        For cross_foursome_rotation: queries across the whole round for
            the donor player IDs stored in phantom_config['rotation'].
        """
        from scoring.models import HoleScore
        self._load()
        if not self._phantom_membership:
            return {}

        if self.is_cross_foursome:
            # Donor players are in OTHER foursomes of the same round
            donor_ids = self._config.get('rotation', [])
            if not donor_ids:
                return {}
            qs = (
                HoleScore.objects
                .filter(
                    foursome__round_id=self._foursome.round_id,
                    player_id__in=donor_ids,
                )
                .exclude(gross_score=None)
                .values('player_id', 'hole_number', 'gross_score')
            )
        else:
            # Intra-foursome rotation
            real_ids = [m.player_id for m in self._real_memberships]
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

    def donor_status_by_hole(self) -> dict:
        """
        For cross_foursome_rotation only.
        Return {hole_number: {'player_id': int, 'player_name': str, 'has_score': bool}}
        for holes 1-18.  Returns {} for intra-foursome phantoms.
        """
        self._load()
        if not self.is_cross_foursome or not self._phantom_membership:
            return {}

        from scoring.models import HoleScore
        donor_ids = self._config.get('rotation', [])
        donor_names = self._config.get('donor_names', {})

        # Fetch which (donor, hole) pairs have scores
        scored_pairs = set(
            HoleScore.objects
            .filter(
                foursome__round_id=self._foursome.round_id,
                player_id__in=donor_ids,
            )
            .exclude(gross_score=None)
            .values_list('player_id', 'hole_number')
        )
        scored_pairs = {(pid, h) for pid, h in scored_pairs}

        status = {}
        for hole in range(1, 19):
            pid = self._algorithm.get_source_player_id(hole, self._config)
            if pid is None:
                continue
            name = donor_names.get(str(pid), f'Player {pid}')
            status[hole] = {
                'player_id'  : pid,
                'player_name': name,
                'has_score'  : (pid, hole) in scored_pairs,
            }
        return status


# ---------------------------------------------------------------------------
# Cross-foursome score propagation
# ---------------------------------------------------------------------------

def propagate_phantom_score(round_obj, hole_number: int,
                            donor_player_id: int, gross_score: int) -> None:
    """
    Called after a real player (donor) saves a HoleScore.

    Finds any phantom membership in the same round that uses
    cross_foursome_rotation AND lists donor_player_id in its rotation.
    For each found, creates or updates the phantom's HoleScore for
    hole_number using the same gross_score and the phantom's own handicap.

    This keeps the phantom's HoleScore table current so that
    build_score_index (used by Nassau) can read it without modification.
    """
    from scoring.models import HoleScore
    from tournament.models import FoursomeMembership

    # Find phantom memberships in this round with cross_foursome_rotation
    phantom_memberships = (
        FoursomeMembership.objects
        .filter(
            foursome__round=round_obj,
            player__is_phantom=True,
            phantom_algorithm=CROSS_FOURSOME_ALGORITHM_ID,
        )
        .select_related('player', 'tee', 'foursome')
    )

    for pm in phantom_memberships:
        config = pm.phantom_config or {}
        rotation = config.get('rotation', [])
        if donor_player_id not in rotation:
            continue  # this phantom doesn't use this donor

        # Check whether this donor is assigned to this hole
        if not rotation:
            continue
        assigned_donor = rotation[(hole_number - 1) % len(rotation)]
        if assigned_donor != donor_player_id:
            continue  # another donor handles this hole

        # Compute phantom's handicap strokes on this hole
        if pm.tee_id is None:
            continue
        hole_info = pm.tee.hole(hole_number)
        stroke_index = hole_info.get('stroke_index', 18)
        hcp_strokes = pm.handicap_strokes_on_hole(stroke_index)

        # Upsert the phantom's HoleScore
        hs, _ = HoleScore.objects.get_or_create(
            foursome    = pm.foursome,
            player      = pm.player,
            hole_number = hole_number,
            defaults    = {'handicap_strokes': hcp_strokes},
        )
        hs.gross_score      = gross_score
        hs.handicap_strokes = hcp_strokes
        hs.save()


def setup_cross_foursome_phantom(foursome, phantom_team, round_obj) -> bool:
    """
    Configure a cross-foursome phantom for any cup game type (Nassau, Quota Nassau, …).

    Called from RyderCupRoundSetupView after ALL foursome memberships are committed.

    phantom_team: the TournamentTeam whose player the phantom represents.
    round_obj:    the Round being configured.

    Returns True if setup succeeded, False if no donors were found.
    """
    from tournament.models import FoursomeMembership

    phantom_m = foursome.memberships.filter(player__is_phantom=True).first()
    if not phantom_m:
        print(f'[phantom setup] foursome {foursome.id}: no phantom membership found')
        return False

    # Find donor players: same team, in OTHER foursomes of this round, real players
    phantom_team_pids = set(phantom_team.players.values_list('id', flat=True))
    print(f'[phantom setup] foursome {foursome.id}: team={phantom_team.name} team_pids={phantom_team_pids} round={round_obj.id}')

    donor_memberships = list(
        FoursomeMembership.objects
        .filter(
            foursome__round=round_obj,
            player_id__in=phantom_team_pids,
            player__is_phantom=False,
        )
        .exclude(foursome=foursome)
        .select_related('player')
    )

    print(f'[phantom setup] foursome {foursome.id}: found {len(donor_memberships)} donors: {[m.player.name for m in donor_memberships]}')

    if not donor_memberships:
        return False

    algo = get_algorithm(CROSS_FOURSOME_ALGORITHM_ID)
    donor_id_name_pairs = [(m.player_id, m.player.name) for m in donor_memberships]
    donor_hcaps = [m.playing_handicap for m in donor_memberships]

    config = algo.initial_config_with_names(donor_id_name_pairs)
    playing_hcp = algo.compute_playing_handicap(config, donor_hcaps)

    phantom_m.phantom_algorithm  = CROSS_FOURSOME_ALGORITHM_ID
    phantom_m.phantom_config     = config
    phantom_m.playing_handicap   = playing_hcp
    phantom_m.save(update_fields=['phantom_algorithm', 'phantom_config', 'playing_handicap'])

    # Clear pre-populated bogey scores — for cross-foursome phantom, scores
    # arrive one hole at a time via propagate_phantom_score() as donors submit.
    # Leaving the bogeys here would make _allScored() always return True on the
    # Flutter side, bypassing the per-hole blocking that forces the phantom's
    # foursome to wait for donor foursomes to post.
    from scoring.models import HoleScore
    HoleScore.objects.filter(
        foursome=foursome,
        player=phantom_m.player,
    ).delete()

    return True
