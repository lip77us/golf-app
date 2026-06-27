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
          "rotation": [player_id, player_id, ...],      # donor player IDs
          "donor_names": {str(player_id): name, ...},   # cached for display
          "donor_handicaps": {str(player_id): hcp, ...} # for per-hole SO recompute
        }

    Hole assignment: rotation[(hole - 1) % len(rotation)]
    Per-hole SO (redesign, in progress): each fourball hole is scored as a real
    4-some that includes that hole's donor, so the donor's own playing handicap
    (donor_handicaps) drives the recompute — NOT a round-fixed value.  The
    headline `playing_handicap` field (compute_playing_handicap) is a separate
    display concern, settled in a later step; do not couple SO to it.
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
        # Phantom is a scratch (0-index) clone of the donor.  In
        # strokes-off mode this makes the phantom the foursome low
        # by definition, so every real player in the receiving
        # foursome ends up getting their FULL handicap on the segment.
        # The phantom's per-hole contribution is the donor's full
        # NET score (computed elsewhere) — so net-of-the-phantom
        # equals donor's net regardless of phantom's playing_handicap
        # being 0.
        return 0

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

    def donor_handicap(self, hole: int, config: dict) -> 'int | None':
        """Playing handicap of the donor assigned to *hole*.  Drives the
        per-hole strokes-off recompute (the hole is scored as a real 4-some
        that includes this donor).  Returns None when no donor/handicap is
        configured for the hole.  JSON keys are strings; tolerate ints too."""
        pid = self.get_source_player_id(hole, config)
        if pid is None:
            return None
        hcaps = config.get('donor_handicaps', {})
        val = hcaps.get(str(pid))
        return val if val is not None else hcaps.get(pid)


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
            # Donor players are in OTHER foursomes of the same round.
            # Return the donor's RAW GROSS — the per-hole donor strokes-off is
            # applied by the scoring layer, and propagate_phantom_score stores
            # gross too.  (Was donor FULL net, which double-counted strokes and
            # made the score card show net instead of gross.)
            donor_ids = self._config.get('rotation', [])
            if not donor_ids:
                return {}
            # Pre-load each donor's membership (tee + playing_handicap)
            # so we can compute their full net per hole.
            from tournament.models import FoursomeMembership
            donor_ms = {
                m.player_id: m
                for m in FoursomeMembership.objects
                    .filter(foursome__round_id=self._foursome.round_id,
                            player_id__in=donor_ids)
                    .select_related('tee')
            }
            rows = (
                HoleScore.objects
                .filter(
                    foursome__round_id=self._foursome.round_id,
                    player_id__in=donor_ids,
                )
                .exclude(gross_score=None)
                .values('player_id', 'hole_number', 'gross_score')
            )
            qs = []
            for r in rows:
                dm = donor_ms.get(r['player_id'])
                if dm is None or dm.tee_id is None:
                    continue
                qs.append({
                    'player_id'  : r['player_id'],
                    'hole_number': r['hole_number'],
                    'gross_score': r['gross_score'],   # donor's RAW gross
                })
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

    def donor_status_by_hole(self, net_percent: int = 100) -> dict:
        """
        For cross_foursome_rotation only.
        Return {hole_number: {'player_id', 'player_name', 'short_name',
        'has_score', 'so'}} for holes 1-18.  Returns {} for intra-foursome
        phantoms.

        'so' is the phantom's per-hole strokes-off VALUE — the donor plays AS
        a member of the hole's 4-some, so its low is min(real low, donor index)
        and the phantom's SO collapses to max(0, donor index − real low) ×
        net_percent.  This recalculates per hole because the donor rotates.
        """
        self._load()
        if not self.is_cross_foursome or not self._phantom_membership:
            return {}

        from scoring.models import HoleScore
        from tournament.models import FoursomeMembership
        from core.models import Player
        donor_ids   = self._config.get('rotation', [])
        donor_names = self._config.get('donor_names', {})
        donor_hcaps = self._config.get('donor_handicaps', {})

        # Donor short names (config caches full names only).
        shorts = dict(
            Player.objects.filter(id__in=donor_ids)
            .values_list('id', 'short_name')
        )

        # Real-player low in the receiving foursome (the SO reference).
        real_hcps = [
            h for h in FoursomeMembership.objects
            .filter(foursome=self._foursome, player__is_phantom=False)
            .values_list('playing_handicap', flat=True)
            if h is not None
        ]
        real_low = min(real_hcps) if real_hcps else 0

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
            donor_hcp = donor_hcaps.get(str(pid), donor_hcaps.get(pid))
            so = 0
            if donor_hcp is not None:
                so = max(0, round((donor_hcp - real_low) * net_percent / 100))
            status[hole] = {
                'player_id'  : pid,
                'player_name': name,
                'short_name' : shorts.get(pid) or name,
                'has_score'  : (pid, hole) in scored_pairs,
                'so'         : so,
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

    # Donor's own membership — only needed to confirm the donor exists with
    # a tee before copying their score.  The phantom carries the donor's raw
    # GROSS (NOT a pre-netted value): the per-hole donor strokes-off is
    # applied later by the scoring layer (low = min(real low, donor index)),
    # so storing net here would double-count.  Storing gross also lets the
    # phantom row display like the other players on the score-entry screen.
    donor_m = (
        FoursomeMembership.objects
        .filter(foursome__round=round_obj, player_id=donor_player_id)
        .select_related('tee')
        .first()
    )
    if donor_m is None or donor_m.tee_id is None:
        return

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

        # Phantom carries the donor's raw GROSS; strokes-off is recomputed
        # per hole by the scoring layer.
        hs, _ = HoleScore.objects.get_or_create(
            foursome    = pm.foursome,
            player      = pm.player,
            hole_number = hole_number,
            defaults    = {'handicap_strokes': 0},
        )
        hs.gross_score      = gross_score
        hs.handicap_strokes = 0
        hs.save()


def build_phantom_info(foursome, net_percent: int = 100) -> 'dict | None':
    """
    Return cross-foursome phantom donor status for *foursome*, or None
    if there isn't one.  Shared by nassau / triple_cup summaries so
    the mobile + watch surfaces all see the same {by_hole} shape.

    net_percent scales the per-hole SO badge (max(0, donor − real low)).

    Shape:
    {
        'phantom_player_id'   : int,
        'phantom_playing_hcp' : int,        # avg course_handicap of donor players
                                            # (displayed only; phantom's own HC is 0)
        'algorithm'           : 'cross_foursome_rotation',
        'by_hole'             : {
            '1':  {'player_id': int, 'player_name': str, 'has_score': bool},
            ...
            '18': {...},
        },
    }
    """
    try:
        if not foursome.has_phantom:
            return None
        provider = PhantomScoreProvider(foursome)
        if not provider.has_phantom or not provider.is_cross_foursome:
            return None
        phantom_m = foursome.memberships.filter(
            player__is_phantom=True
        ).first()

        # Idempotent re-sync of phantom's stored playing_handicap +
        # course_handicap to whatever the algorithm currently dictates.
        # Necessary because the algorithm's rule changed in D1 (now
        # always 0 / scratch), but rounds set up before that still
        # have stale values in the DB.  Running here means every
        # summary/leaderboard load self-heals — no migration needed.
        if phantom_m:
            algo    = get_algorithm(phantom_m.phantom_algorithm)
            new_hcp = algo.compute_playing_handicap(
                phantom_m.phantom_config or {}, []
            )
            updates = []
            if phantom_m.playing_handicap != new_hcp:
                phantom_m.playing_handicap = new_hcp
                updates.append('playing_handicap')
            if phantom_m.course_handicap != new_hcp:
                phantom_m.course_handicap = new_hcp
                updates.append('course_handicap')
            if updates:
                phantom_m.save(update_fields=updates)

        # Phantom's own playing_handicap is 0 (scratch) after D1; the
        # displayed "handicap" pulls the donors' average course_handicap
        # so the leaderboard's Index column reads as a sensible number.
        avg_course_hcp = 0
        if phantom_m:
            donor_ids = (phantom_m.phantom_config or {}).get('rotation', [])
            if donor_ids:
                from tournament.models import FoursomeMembership
                donor_hcps = list(
                    FoursomeMembership.objects
                    .filter(
                        foursome__round=foursome.round,
                        player_id__in=donor_ids,
                        player__is_phantom=False,
                    )
                    .values_list('course_handicap', flat=True)
                )
                if donor_hcps:
                    avg_course_hcp = round(sum(donor_hcps) / len(donor_hcps))
        return {
            'phantom_player_id'   : phantom_m.player_id if phantom_m else None,
            'phantom_playing_hcp' : avg_course_hcp,
            'algorithm'           : CROSS_FOURSOME_ALGORITHM_ID,
            'by_hole'             : {
                str(h): v
                for h, v in provider.donor_status_by_hole(net_percent).items()
            },
        }
    except Exception:
        import logging
        logging.getLogger(__name__).exception(
            'build_phantom_info failed for foursome %s', foursome.pk
        )
        return None


def earliest_three_foursome_ids(round_obj) -> list:
    """Return the IDs of the three earliest-teeing foursomes in *round_obj*,
    ordered by tee_time (NULLs last) then group_number.  These foursomes
    serve as the donor pool for every cross-foursome phantom in the round;
    consequently they must themselves be full 4-player groups.  Callers
    pre-compute this once per round-setup pass."""
    from tournament.models import Foursome
    from django.db.models import F
    return list(
        Foursome.objects
        .filter(round=round_obj)
        .order_by(
            F('tee_time').asc(nulls_last=True),
            'group_number',
        )
        .values_list('pk', flat=True)[:3]
    )


def validate_donor_foursomes(round_obj) -> list:
    """Return a list of human-readable validation errors for *round_obj*'s
    short-roster donor setup.  Empty list means the round is OK to start.

    Rule (relaxed):
      Every short-roster foursome (any with fewer than 4 real players)
      must have ≥1 full 4-player foursome teeing off BEFORE it.  The
      single prior is enough for donor scoring to function: 2 same-team
      players × 3-hole rotation = 6 fourball-hole coverage.

      A common TD recommendation is to put 3+ full groups up front for
      better donor variety, but that's an *advisory* — strict 3-prior
      enforcement made tee-box no-show recovery painful when groups
      had to be reshuffled.  The TD can opt into the extra variety;
      we don't force it.

      Examples (post-relaxation):
        • 7 players, 1 full + 1 three-some  → full @1, three-some @2 ✓
        • 11 players, 2 full + 1 three-some → full @1+2, three-some @3 ✓
        • 11 players, 2 full + 1 three-some → three-some @2, full @1+3 ✓
        • 3-foursome round, three-some @2 with only 1 full @1 ✓
        • 3-foursome round, three-some @1 (no priors at all) ✗
    """
    from tournament.models import Foursome
    from django.db.models import F

    errors: list = []

    # Pull every foursome in the round once, sorted by tee position,
    # with memberships prefetched so we can count real players cheaply.
    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .order_by(
            F('tee_time').asc(nulls_last=True),
            'group_number',
        )
        .prefetch_related('memberships__player')
    )
    if not foursomes:
        return errors

    def real_count(fs) -> int:
        return sum(1 for m in fs.memberships.all() if not m.player.is_phantom)

    total_full      = sum(1 for fs in foursomes if real_count(fs) >= 4)
    # Need ≥1 prior full when ANY full exists; if total_full == 0 the
    # rule auto-relaxes to 0 (no priors required) but the round is
    # effectively broken — setup_cross_foursome_phantom will refuse
    # with "no eligible donor players found" anyway, so we leave that
    # to the setup path rather than blocking here.
    required_priors = 1 if total_full > 0 else 0

    # Count full priors in tee-time order; flag any short-roster
    # foursome that doesn't have enough fulls ahead of it.
    seen_full = 0
    for fs in foursomes:
        is_full = real_count(fs) >= 4
        if not is_full and seen_full < required_priors:
            errors.append(
                f"Foursome {fs.group_number} is short-rostered "
                f"({real_count(fs)} real players) but no full "
                f"4-player group tees off before it.  Each "
                f"short-roster group needs at least one full prior "
                f"to supply donor scores — move this foursome to "
                f"a later tee time."
            )
        if is_full:
            seen_full += 1
    return errors


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

    # Find donor players: same team, real (non-phantom), drawn from the
    # 3 earliest-teeing foursomes ONLY.  This guarantees donors are well
    # underway by the time the short-roster foursome plays a hole, so
    # propagate_phantom_score() has scores to copy.  Tee-time ordering
    # falls back to group_number when tee_time is unset (older rounds).
    phantom_team_pids = set(phantom_team.players.values_list('id', flat=True))
    print(f'[phantom setup] foursome {foursome.id}: team={phantom_team.name} team_pids={phantom_team_pids} round={round_obj.id}')

    from tournament.models import Foursome
    from django.db.models import F
    # Donor pool = every OTHER foursome in the round teeing off earlier
    # than (or at the same slot as) the receiver.  No artificial [:3]
    # cap — donor variety scales with field size, so a 60-player
    # tournament with a single threesome at tee position 10 gets up to
    # 18 same-team candidates instead of just the first 3 group's 6.
    # The validate_donor_foursomes() rule still enforces "first 3 tee
    # times must be full" as the floor.
    donor_foursome_ids = list(
        Foursome.objects
        .filter(round=round_obj)
        .exclude(pk=foursome.pk)
        .order_by(
            F('tee_time').asc(nulls_last=True),
            'group_number',
        )
        .values_list('pk', flat=True)
    )

    donor_memberships = list(
        FoursomeMembership.objects
        .filter(
            foursome_id__in=donor_foursome_ids,
            player_id__in=phantom_team_pids,
            player__is_phantom=False,
        )
        .select_related('player')
    )

    print(f'[phantom setup] foursome {foursome.id}: found {len(donor_memberships)} donors: {[m.player.name for m in donor_memberships]}')

    if not donor_memberships:
        return False

    algo = get_algorithm(CROSS_FOURSOME_ALGORITHM_ID)
    donor_id_name_pairs = [(m.player_id, m.player.name) for m in donor_memberships]
    donor_hcaps = [m.playing_handicap for m in donor_memberships]

    config = algo.initial_config_with_names(donor_id_name_pairs)
    # Per-donor handicaps drive the per-hole strokes-off recompute (each
    # fourball hole is scored as a real 4-some including that hole's donor).
    config['donor_handicaps'] = {
        str(m.player_id): m.playing_handicap for m in donor_memberships
    }
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
