"""
services/wolf.py
----------------
Wolf calculator — a 3- or 4-player, per-hole casual game.

Each hole one player is the **Wolf**.  The Wolf is taken from a rotation
the group sets at setup (``wolf_order`` — like Pink Ball's carrier order):
the Wolf for hole H is ``wolf_order[(H-1) % n]``.  In a 4-player game,
holes 17 & 18 instead hand the Wolf to whoever is in **last place**
(fewest points so far) when ``last_place_wolf_1718`` is on — a catch-up
twist.

The Wolf tees last and then chooses one of:
  * **Partner** (4-player only) — Wolf + one teammate vs the other two
    (best ball per side).
  * **Lone Wolf** — Wolf alone vs the rest, for a bigger pot.
  * **Blind Wolf** — Wolf alone vs the rest, declared *before* the drives,
    for the biggest pot.

Scoring (zero-based)
~~~~~~~~~~~~~~~~~~~~
Every scored hole has a **pot** that the winning side splits (+) and the
losing side splits (−), so the hole always nets to zero.

  * Lone hole  → pot = ``lone_wolf_points``   (default 3)
  * Blind hole → pot = ``blind_wolf_points``  (default 6)
  * Partner    → each winner gets ``team_win_points`` (default 1); when the
                 NON-wolf side wins a clean hole and ``non_wolf_bonus`` is
                 on, each winner gets double.

Examples (4-player, defaults):
  * Lone Wolf wins      → Wolf +3, each of 3 opponents −1.
  * Lone Wolf loses     → each of 3 opponents +1, Wolf −3.
  * Partner side wins   → 2 winners +1 each, 2 losers −1 each.
3-player Lone splits the pot into halves (±1.5) because a side has 2.

Options:
  * ``wolf_loses_ties`` — a tied hole goes to the non-wolf side instead of
    being a push.
  * ``non_wolf_bonus``  — non-wolf side's clean win on a partner hole pays
    double.

A hole is only scored once it has BOTH a Wolf decision (partner/lone/blind)
AND a gross score for every real player; otherwise it is skipped and the
game stays 'in_progress'.

Handicap modes mirror Points 5-3-1 exactly (Net with percentage, Gross,
Strokes-Off-Low), reusing scoring.handicap.build_score_index and the
Points 5-3-1 strokes-off helper.

Workflow
~~~~~~~~
1. ``setup_wolf(...)`` creates the WolfGame row (idempotent — replaces any
   prior game and its decisions/results).
2. ``calculate_wolf(foursome)`` runs after every score submission; it
   replaces all WolfPlayerHoleResult rows from the current HoleScore +
   WolfHoleDecision tables and updates the game's status.
3. ``wolf_summary(foursome)`` returns the JSON shape the mobile UI uses,
   including the reverse-honors tee order for every hole.
"""

from decimal import Decimal, ROUND_HALF_UP

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import (
    WolfGame, WolfHoleDecision, WolfPlayerHoleResult,
)
from services.points_531 import _build_so_score_index
from services.hole_plan import play_order as _play_order
from scoring.handicap import build_score_index, make_strokes_fn, _effective_hcp
from scoring.models import HoleScore

_CENT = Decimal('0.01')


class WolfOrderLocked(Exception):
    """Raised when a rotation change would alter the Wolf on an already-played
    hole.  Carries a user-facing ``message``."""

    def __init__(self, message: str):
        self.message = message
        super().__init__(message)


def _q(x) -> Decimal:
    """Quantize to cents, rounding half-up."""
    return Decimal(x).quantize(_CENT, rounding=ROUND_HALF_UP)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_wolf(
    foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    wolf_order: list | None = None,
    lone_wolf_points: int = 3,
    blind_wolf_points: int = 6,
    team_win_points: int = 1,
    wolf_loses_ties: bool = False,
    non_wolf_bonus: bool = False,
    last_place_wolf_1718: bool = True,
    require_lone_or_blind: bool = False,
    loss_cap=None,
) -> 'WolfGame':
    """
    Create (or replace) the Wolf game for a foursome.  Safe to call again —
    the prior game (and its cascaded decisions / results) is dropped first.

    The casual-round UI restricts Wolf to foursomes with 3 or 4 real
    players, but we don't enforce that here so admin scripts/tests can
    create the row; the calculator simply scores whichever real players
    are present.  net_percent and the point values are clamped to sane
    ranges so a bad caller can't poison the DB.
    """
    WolfGame.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))
    order = _clean_order(foursome, wolf_order)

    if loss_cap is not None:
        loss_cap = Decimal(str(loss_cap))
        if loss_cap < 0:
            loss_cap = None

    game = WolfGame.objects.create(
        foursome             = foursome,
        handicap_mode        = handicap_mode,
        net_percent          = net_percent,
        wolf_order           = order,
        lone_wolf_points     = max(0, int(lone_wolf_points)),
        blind_wolf_points    = max(0, int(blind_wolf_points)),
        team_win_points      = max(0, int(team_win_points)),
        wolf_loses_ties       = bool(wolf_loses_ties),
        non_wolf_bonus        = bool(non_wolf_bonus),
        last_place_wolf_1718  = bool(last_place_wolf_1718),
        require_lone_or_blind = bool(require_lone_or_blind),
        loss_cap              = loss_cap,
        status                = MatchStatus.PENDING,
    )
    return game


def _played_holes(foursome, game) -> set:
    """Hole numbers that are locked in — the Wolf has made a decision OR a gross
    score is posted.  The rotation positions these map to must not change, or a
    past hole's Wolf would be silently reassigned."""
    played = set(
        game.decisions
        .exclude(decision=WolfHoleDecision.PENDING)
        .values_list('hole_number', flat=True)
    )
    played.update(
        HoleScore.objects
        .filter(foursome=foursome, gross_score__isnull=False)
        .values_list('hole_number', flat=True)
    )
    return played


def _play_sequence(foursome) -> list:
    """The ordered holes this group plays (back-9 / 9-hole / shotgun aware).
    Defaults (num_holes=18, start=1) return 1..18, so a normal round is
    unchanged. The Wolf rotates by POSITION in this sequence, not hole number,
    so the first hole played is always the first rotation pick."""
    return _play_order(foursome.round, foursome)


def locked_wolf_positions(foursome) -> set:
    """Rotation positions (0-based) whose Wolf is fixed because the hole that
    uses them has already been played. Position is the hole's index in play
    order mod n (so a back-9 / shotgun locks the right rotation slots)."""
    game = foursome.wolf_game
    order = _clean_order(foursome, game.wolf_order)
    n = len(order)
    if n == 0:
        return set()
    pos_of = {h: i for i, h in enumerate(_play_sequence(foursome))}
    return {pos_of[h] % n for h in _played_holes(foursome, game) if h in pos_of}


def set_wolf_order(foursome, wolf_order: list) -> 'WolfGame':
    """Update just the rotation order without wiping decisions/results.

    Refuses to change a rotation position whose hole has already been played
    (scored or decided): changing it would silently rewrite that past hole's
    Wolf.  Reorder only the not-yet-played positions, or reset the Wolf game to
    fix a wrong Wolf.  Raises [WolfOrderLocked] on a disallowed change."""
    game = foursome.wolf_game  # raises WolfGame.DoesNotExist if absent
    current = _clean_order(foursome, game.wolf_order)
    new     = _clean_order(foursome, wolf_order)
    locked  = locked_wolf_positions(foursome)
    for pos in sorted(locked):
        if pos < len(current) and pos < len(new) and current[pos] != new[pos]:
            raise WolfOrderLocked(
                f"Hole {pos + 1} has already been played, so its Wolf can't be "
                "changed. You can still reorder the later positions, or reset "
                "the Wolf game to start over."
            )
    game.wolf_order = new
    game.save(update_fields=['wolf_order'])
    calculate_wolf(foursome)
    return game


# ---------------------------------------------------------------------------
# Roster / order helpers
# ---------------------------------------------------------------------------

def _real_members(foursome) -> list:
    return list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player__is_phantom=False)
    )


def _clean_order(foursome, wolf_order: list | None) -> list:
    """
    Return a rotation order over the real player ids.  Any ids in
    ``wolf_order`` that aren't real members are dropped; any real members
    missing from it are appended in membership order.  Falls back to plain
    membership order when nothing usable is supplied.
    """
    real_ids = [m.player_id for m in _real_members(foursome)]
    real_set = set(real_ids)
    out: list = []
    for pid in (wolf_order or []):
        try:
            pid = int(pid)
        except (TypeError, ValueError):
            continue
        if pid in real_set and pid not in out:
            out.append(pid)
    for pid in real_ids:
        if pid not in out:
            out.append(pid)
    return out


def _score_index(game, foursome) -> dict:
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_so_score_index(foursome, net_percent=game.net_percent)
    return build_score_index(
        foursome,
        handicap_mode=game.handicap_mode,
        net_percent=game.net_percent,
    )


def wolf_player_hole_strokes(foursome, game) -> dict:
    """``{player_id: {hole_number: strokes}}`` — the handicap strokes each real
    player receives on each hole AS WOLF ISSUES THEM.

    PROSPECTIVE: strokes are allocated over EVERY hole in play (play order),
    not just holes already scored, so the tee-box partner picker (and the
    leaderboard scorecard) can show who gets a stroke on a hole before it is
    played — the Wolf needs that to choose a partner. Mirrors ``_score_index``:

    * Gross → empty (no strokes).
    * Net (100% or custom %) → the partial-round-aware allocation from the
      effective handicap (same allocator ``build_score_index`` uses).
    * Strokes-Off-Low → the low playing handicap plays to 0; everyone else
      gets ``round((phcp − low) × net% / 100)`` strokes on the hardest holes
      (SI ≤ remainder), identical to ``_build_so_score_index``.
    """
    if game.handicap_mode == HandicapMode.GROSS:
        return {}

    order   = _play_sequence(foursome) or list(range(1, 19))
    members = _real_members(foursome)
    out: dict = {}

    if game.handicap_mode != HandicapMode.STROKES_OFF:
        strokes_fn = make_strokes_fn(foursome)
        for m in members:
            if m.tee_id is None:
                continue
            eff = _effective_hcp(m.playing_handicap or 0, game.net_percent or 100)
            if eff <= 0:
                continue
            for h in order:
                s = strokes_fn(eff, m.tee, h)
                if s > 0:
                    out.setdefault(m.player_id, {})[h] = s
        return out

    # Strokes-Off-Low
    phcps = [m.playing_handicap for m in members if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0
    for m in members:
        if m.tee_id is None:
            continue
        so = round(max(0, (m.playing_handicap or 0) - low) * (game.net_percent or 100) / 100)
        if so <= 0:
            continue
        full, rem = so // 18, so % 18
        for h in order:
            si = m.tee.hole(h).get('stroke_index', 18)
            s = full + (1 if si <= rem else 0)
            if s > 0:
                out.setdefault(m.player_id, {})[h] = s
    return out


def _last_place(real_ids, order, running_points: dict, running_net: dict):
    """
    The player in last place: fewest points, then worst (highest) net
    total, then earliest in the rotation order.  Used for the holes-17/18
    catch-up Wolf in a 4-player game.
    """
    def key(pid):
        return (
            running_points.get(pid, Decimal('0')),   # fewest points first
            -running_net.get(pid, 0),                 # worst golfer first
            order.index(pid) if pid in order else 99, # stable
        )
    return min(real_ids, key=key)


def _hole_sides(decision, wolf, real_ids: list):
    """
    Resolve (mode, wolf_side, opp_side) for a decided hole.  ``decision`` is
    a WolfHoleDecision; ``wolf`` is the resolved Wolf player id.  An invalid
    partner pick (3-player, missing, or the Wolf itself) degrades to Lone.
    """
    n = len(real_ids)
    mode = decision.decision
    if mode == WolfHoleDecision.PARTNER:
        partner = decision.partner_id
        if n == 4 and partner in real_ids and partner != wolf:
            wolf_side = [wolf, partner]
        else:
            mode = WolfHoleDecision.LONE
            wolf_side = [wolf]
    else:
        wolf_side = [wolf]
    opp_side = [pid for pid in real_ids if pid not in wolf_side]
    return mode, wolf_side, opp_side


def _award_points(game, mode, winner, wolf_side, opp_side, wolf) -> dict:
    """
    Compute {player_id: Decimal points} for a decided, fully-scored hole.
    Zero-based: the result is quantized to cents and the residual is folded
    onto the Wolf so each hole sums to exactly zero regardless of config.
    """
    real_ids = wolf_side + opp_side
    points = {pid: Decimal('0') for pid in real_ids}

    if winner == 'tie':
        return points  # push — everyone zero

    winners = wolf_side if winner == 'wolf' else opp_side
    losers  = opp_side if winner == 'wolf' else wolf_side

    if mode == WolfHoleDecision.PARTNER:
        per_winner = game.team_win_points
        if winner == 'opponents' and game.non_wolf_bonus:
            per_winner = game.team_win_points * 2
        pot = Decimal(per_winner) * len(winners)
        for w in winners:
            points[w] = Decimal(per_winner)
        share = pot / Decimal(len(losers))
        for l in losers:
            points[l] = -share
    else:
        # Lone / Blind — fixed pot split across each side.
        pot = Decimal(
            game.blind_wolf_points if mode == WolfHoleDecision.BLIND
            else game.lone_wolf_points
        )
        win_share  = pot / Decimal(len(winners))
        lose_share = pot / Decimal(len(losers))
        for w in winners:
            points[w] = win_share
        for l in losers:
            points[l] = -lose_share

    # Quantize and balance the residual onto the Wolf so the hole is
    # exactly zero-sum even for configs that produce thirds.
    for pid in points:
        points[pid] = _q(points[pid])
    residual = -sum(points.values())
    points[wolf] = _q(points[wolf] + residual)
    return points


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_wolf(foursome) -> list:
    """
    Re-compute WolfPlayerHoleResult rows for the foursome's Wolf game from
    the current HoleScore + WolfHoleDecision tables.  Idempotent — replaces
    all result rows and updates the game's status.
    """
    try:
        game = foursome.wolf_game
    except WolfGame.DoesNotExist:
        return []

    members  = _real_members(foursome)
    real_ids = [m.player_id for m in members]
    WolfPlayerHoleResult.objects.filter(game=game).delete()

    if not real_ids:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    order       = _clean_order(foursome, game.wolf_order)
    n           = len(real_ids)
    score_index = _score_index(game, foursome)
    decisions   = {d.hole_number: d for d in game.decisions.all()}
    sequence    = _play_sequence(foursome)
    last_two    = set(sequence[-2:])          # last-place-Wolf holes (was 17/18)

    running_points = {pid: Decimal('0') for pid in real_ids}
    running_net    = {pid: 0 for pid in real_ids}

    rows = []
    resolved_holes = 0
    for pos, hole in enumerate(sequence):
        # Net scores for the hole (None if any real player hasn't scored).
        net = {}
        complete = True
        for pid in real_ids:
            s = score_index.get(pid, {}).get(hole)
            if s is None:
                complete = False
                break
            net[pid] = s

        # Resolve the Wolf for this hole — rotate by POSITION in play order, so
        # the first hole played is the first rotation pick (back-9 / shotgun).
        if n == 4 and hole in last_two and game.last_place_wolf_1718:
            wolf = _last_place(real_ids, order, running_points, running_net)
        else:
            wolf = order[pos % n] if n else None

        decision = decisions.get(hole)
        decided  = decision is not None and decision.decision in (
            WolfHoleDecision.PARTNER, WolfHoleDecision.LONE, WolfHoleDecision.BLIND
        )

        if not complete:
            continue
        # Net totals progress on every fully-scored hole (used as the
        # last-place tiebreaker), even before the Wolf has decided.
        for pid in real_ids:
            running_net[pid] += net[pid]
        if not decided:
            continue

        mode, wolf_side, opp_side = _hole_sides(decision, wolf, real_ids)
        wolf_best = min(net[pid] for pid in wolf_side)
        opp_best  = min(net[pid] for pid in opp_side)
        if wolf_best < opp_best:
            winner = 'wolf'
        elif opp_best < wolf_best:
            winner = 'opponents'
        else:
            winner = 'opponents' if game.wolf_loses_ties else 'tie'

        points = _award_points(game, mode, winner, wolf_side, opp_side, wolf)

        partner_id = wolf_side[1] if (mode == WolfHoleDecision.PARTNER and
                                      len(wolf_side) == 2) else None
        for pid in real_ids:
            if pid == wolf:
                role = WolfPlayerHoleResult.ROLE_WOLF
            elif pid == partner_id:
                role = WolfPlayerHoleResult.ROLE_PARTNER
            else:
                role = WolfPlayerHoleResult.ROLE_OPPONENT
            rows.append(WolfPlayerHoleResult(
                game        = game,
                player_id   = pid,
                hole_number = hole,
                net_score   = net[pid],
                role        = role,
                points      = points[pid],
            ))
            running_points[pid] += points[pid]
        resolved_holes += 1

    if rows:
        WolfPlayerHoleResult.objects.bulk_create(rows)

    if resolved_holes == 0:
        game.status = MatchStatus.PENDING
    elif resolved_holes >= len(sequence):
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])

    return rows


# ---------------------------------------------------------------------------
# Wolf-per-hole resolution from persisted results (for summary / validation)
# ---------------------------------------------------------------------------

def _wolf_by_hole(game, real_ids, order, score_index, points_by_hole,
                  sequence) -> dict:
    """
    Return {hole_number: wolf_player_id} for the holes in play, replaying the
    same position-based rotation + last-two last-place logic calculate_wolf
    uses.  Standings are reconstructed from persisted results (points) plus the
    score index (net totals), so this stays consistent with the calculator.
    """
    n = len(real_ids)
    last_two = set(sequence[-2:])
    running_points = {pid: Decimal('0') for pid in real_ids}
    running_net    = {pid: 0 for pid in real_ids}
    out = {}
    for pos, hole in enumerate(sequence):
        if n == 4 and hole in last_two and game.last_place_wolf_1718:
            out[hole] = _last_place(real_ids, order, running_points, running_net)
        else:
            out[hole] = order[pos % n] if n else None
        # Advance standings for the NEXT hole's last-place calc.
        for pid in real_ids:
            s = score_index.get(pid, {}).get(hole)
            if s is not None:
                running_net[pid] += s
            running_points[pid] += points_by_hole.get(hole, {}).get(pid, Decimal('0'))
    return out


def resolve_wolf_for_hole(foursome, hole_number: int):
    """The resolved Wolf player id for a single hole (used to validate a
    partner pick).  Returns None if there's no game / no real players."""
    try:
        game = foursome.wolf_game
    except WolfGame.DoesNotExist:
        return None
    members  = _real_members(foursome)
    real_ids = [m.player_id for m in members]
    if not real_ids:
        return None
    order       = _clean_order(foursome, game.wolf_order)
    score_index = _score_index(game, foursome)
    points_by_hole = _points_by_hole(game)
    sequence    = _play_sequence(foursome)
    return _wolf_by_hole(game, real_ids, order, score_index, points_by_hole,
                         sequence).get(hole_number)


def _points_by_hole(game) -> dict:
    """{hole: {player_id: Decimal points}} from persisted results."""
    out: dict = {}
    for r in game.hole_results.all():
        out.setdefault(r.hole_number, {})[r.player_id] = r.points
    return out


# ---------------------------------------------------------------------------
# "Require a Lone/Blind by hole 16" rule
# ---------------------------------------------------------------------------

def _partner_locked(game, real_ids, order, decisions, hole, wolf,
                    sequence) -> bool:
    """
    True when the require-lone-or-blind rule forces the Wolf to go solo on
    this hole: a 4-player game, the hole is NOT one of the last two (those are
    the last-place-Wolf holes), and the Wolf has already been the Wolf on >= 3
    prior holes all as partner — never solo.  On a player's final rotation Wolf
    turn this leaves Lone/Blind as the only options.  Prior-hole Wolves are read
    by POSITION in play order, so a back-9 / shotgun locks the right holes.
    """
    if not game.require_lone_or_blind:
        return False
    n = len(real_ids)
    if n != 4 or wolf is None:
        return False
    pos_of = {h: i for i, h in enumerate(sequence)}
    pos = pos_of.get(hole)
    # Only the plain-rotation holes (everything before the last two) qualify.
    if pos is None or pos >= len(sequence) - 2:
        return False
    partner_count = 0
    for i in range(pos):
        h = sequence[i]
        if (order[i % n] if n else None) != wolf:
            continue
        d = decisions.get(h)
        if d is None:
            continue
        if d.decision in (WolfHoleDecision.LONE, WolfHoleDecision.BLIND):
            return False          # requirement already satisfied
        if d.decision == WolfHoleDecision.PARTNER:
            partner_count += 1
    return partner_count >= 3


def partner_locked_for_hole(foursome, hole_number: int) -> bool:
    """Whether a partner pick is disallowed on this hole (used by the
    decision endpoint to reject an illegal partner)."""
    try:
        game = foursome.wolf_game
    except WolfGame.DoesNotExist:
        return False
    real_ids = [m.player_id for m in _real_members(foursome)]
    n = len(real_ids)
    if n == 0:
        return False
    order = _clean_order(foursome, game.wolf_order)
    sequence = _play_sequence(foursome)
    pos_of = {h: i for i, h in enumerate(sequence)}
    pos = pos_of.get(hole_number)
    # Plain rotation pick on non-last-two holes; last-place holes → no partner rule.
    wolf = (order[pos % n] if (pos is not None and pos < len(sequence) - 2 and n)
            else None)
    decisions = {d.hole_number: d for d in game.decisions.all()}
    return _partner_locked(game, real_ids, order, decisions, hole_number, wolf,
                           sequence)


# ---------------------------------------------------------------------------
# Tee order (reverse honors — worst on the previous hole tees first)
# ---------------------------------------------------------------------------

def _phcp_in_play(mode, npct, phcp, low_phcp) -> int:
    if mode == HandicapMode.GROSS:
        return 0
    if mode == HandicapMode.STROKES_OFF:
        return round(max(0, phcp - low_phcp) * npct / 100)
    return round(phcp * npct / 100)


def _tee_order(hole, wolf, real_ids, score_index, phcp_by_pid, order,
               sequence) -> list:
    """
    Reverse-honors order for a hole: the non-Wolf player who scored worst
    (highest net) on the PREVIOUS hole (in play order) tees first; ties break by
    the hole before that, and so on back to the first hole played; final
    fallback is higher handicap first, then rotation order.  The Wolf is always
    last.
    """
    non_wolf = [pid for pid in real_ids if pid != wolf]
    pos = sequence.index(hole) if hole in sequence else 0
    prior = list(reversed(sequence[:pos]))     # previous holes, most-recent first

    def key(pid):
        # Descending net on the prior holes (most recent first) → negate so
        # 'worst first' sorts ascending.  Missing scores contribute 0.
        prev = tuple(-score_index.get(pid, {}).get(k, 0) for k in prior)
        return prev + (-phcp_by_pid.get(pid, 0),
                       order.index(pid) if pid in order else 99)

    non_wolf.sort(key=key)
    return non_wolf + [wolf]


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def wolf_summary(foursome) -> dict:
    """JSON-serialisable summary consumed by the mobile Wolf screen and the
    leaderboard.  See the module docstring for the scoring model."""
    bet_unit = float(foursome.round.bet_unit)
    try:
        game = foursome.wolf_game
    except WolfGame.DoesNotExist:
        return {
            'status'    : 'pending',
            'handicap'  : {'mode': HandicapMode.STROKES_OFF, 'net_percent': 100},
            'points'    : {'lone_wolf': 3, 'blind_wolf': 6, 'team_win': 1,
                           'wolf_loses_ties': False, 'non_wolf_bonus': False,
                           'last_place_wolf_1718': True,
                           'require_lone_or_blind': False},
            'wolf_order': [],
            'locked_positions': [],
            'players'   : [],
            'holes'     : [],
            'money'     : {'bet_unit': bet_unit, 'loss_cap': None},
        }

    members  = _real_members(foursome)
    by_pid   = {m.player_id: m.player for m in members}
    real_ids = list(by_pid.keys())
    order    = _clean_order(foursome, game.wolf_order)
    n        = len(real_ids)
    sequence = _play_sequence(foursome)         # holes in play order

    score_index = _score_index(game, foursome)

    # Gross scores per hole (for display cells) and par per hole.
    gross_index: dict = {}
    for r in (
        HoleScore.objects
        .filter(foursome=foursome, player_id__in=real_ids)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    ):
        gross_index.setdefault(r['player_id'], {})[r['hole_number']] = r['gross_score']

    sample_tee = next(
        (m.tee for m in members if m.tee_id is not None), None,
    )
    par_by_hole: dict = {}
    si_by_hole:  dict = {}
    if sample_tee is not None:
        for h in sequence:
            hd = sample_tee.hole(h)
            par_by_hole[h] = hd.get('par')
            si_by_hole[h]  = hd.get('stroke_index')

    # Prospective per-hole handicap strokes (as Wolf issues them) so the tee-box
    # partner picker and the leaderboard scorecard can show who gets a stroke on
    # each hole in advance of playing it.
    strokes_by = wolf_player_hole_strokes(foursome, game)

    # Handicap-in-play per player (tee-order tiebreak + display).
    phcps = [(m.playing_handicap or 0) for m in members
             if m.playing_handicap is not None]
    low_phcp = min(phcps) if phcps else 0
    phcp_by_pid = {
        m.player_id: _phcp_in_play(game.handicap_mode, game.net_percent or 100,
                                   (m.playing_handicap or 0), low_phcp)
        for m in members
    }

    # Persisted results → grouped lookups.
    results = list(
        WolfPlayerHoleResult.objects
        .filter(game=game).select_related('player')
        .order_by('hole_number', '-points')
    )
    points_by_hole: dict = {}
    res_by_hole: dict = {}
    for r in results:
        points_by_hole.setdefault(r.hole_number, {})[r.player_id] = r.points
        res_by_hole.setdefault(r.hole_number, []).append(r)

    wolf_by_hole = _wolf_by_hole(game, real_ids, order, score_index,
                                 points_by_hole, sequence)
    decisions    = {d.hole_number: d for d in game.decisions.all()}

    def short(pid):
        p = by_pid.get(pid)
        return p.short_name if p else ''

    def name(pid):
        p = by_pid.get(pid)
        return p.name if p else ''

    holes_out: list = []
    for hole in sequence:
        wolf = wolf_by_hole.get(hole)
        decision = decisions.get(hole)
        dstr = decision.decision if decision else WolfHoleDecision.PENDING
        partner_id = (decision.partner_id
                      if decision and decision.decision == WolfHoleDecision.PARTNER
                      else None)

        tee = _tee_order(hole, wolf, real_ids, score_index, phcp_by_pid, order,
                         sequence)
        tee_order_out = []
        pos = 0
        for pid in tee:
            is_wolf = (pid == wolf)
            if not is_wolf:
                pos += 1
            tee_order_out.append({
                'player_id' : pid,
                'short_name': short(pid),
                'name'      : name(pid),
                'is_wolf'   : is_wolf,
                'order_num' : None if is_wolf else pos,
                # Handicap strokes this player gets on THIS hole (Wolf's mode),
                # so the partner picker can see who's getting a shot.
                'strokes'   : strokes_by.get(pid, {}).get(hole, 0),
            })

        rows = res_by_hole.get(hole, [])
        entries = [{
            'player_id' : r.player_id,
            'name'      : r.player.name,
            'short_name': r.player.short_name,
            'role'      : r.role,
            'net_score' : r.net_score,
            'gross'     : gross_index.get(r.player_id, {}).get(hole),
            'points'    : float(r.points),
        } for r in rows]

        # Winning side + pot from persisted points.
        winning_side = None
        pot = 0.0
        if rows:
            wolf_pts = next((float(r.points) for r in rows
                             if r.player_id == wolf), 0.0)
            if wolf_pts > 0:
                winning_side = 'wolf'
            elif wolf_pts < 0:
                winning_side = 'opponents'
            else:
                winning_side = 'tie'
            pot = float(sum(r.points for r in rows if r.points > 0))

        holes_out.append({
            'hole'         : hole,
            'par'          : par_by_hole.get(hole),
            'stroke_index' : si_by_hole.get(hole),
            'wolf_id'      : wolf,
            'wolf_short'   : short(wolf),
            'decision'     : dstr,
            'partner_id'   : partner_id,
            'partner_short': short(partner_id) if partner_id else None,
            'partner_locked': _partner_locked(game, real_ids, order,
                                              decisions, hole, wolf, sequence),
            'winning_side' : winning_side,
            'pot'          : pot,
            'tee_order'    : tee_order_out,
            'entries'      : entries,
        })

    # Player totals.
    points_total = {pid: Decimal('0') for pid in real_ids}
    holes_played = {pid: 0 for pid in real_ids}
    for r in results:
        points_total[r.player_id] += r.points
        holes_played[r.player_id] += 1

    # Money via the shared wager engine. Wolf points already net to zero per
    # hole, so the vs-average baseline is 0 and settle reproduces
    # points × bet_unit — but now the optional loss_cap (clip losers, rescale
    # winners pro-rata) applies too.
    from services.wager import PER_POINT, VS_AVERAGE, WagerConfig, settle
    cfg = WagerConfig(funding=PER_POINT, settlement=VS_AVERAGE,
                      rate=Decimal(str(bet_unit)), cap=game.loss_cap)
    payouts = settle(
        {pid: points_total.get(pid, Decimal('0')) for pid in by_pid}, cfg)

    players_out = []
    for pid, player in by_pid.items():
        pts = float(points_total.get(pid, Decimal('0')))
        players_out.append({
            'player_id'   : pid,
            'name'        : player.name,
            'short_name'  : player.short_name,
            'points'      : pts,
            'holes_played': holes_played.get(pid, 0),
            'money'       : float(payouts[pid]),
            'phcp_in_play': phcp_by_pid.get(pid),
        })
    players_out.sort(key=lambda e: (-e['money'], e['name']))

    # ── Scorecard grid (dots + stroke-index row) for the leaderboard ─────────
    # Wolf has no scorecard of its own, so a strokes-off / net player couldn't
    # otherwise see which holes they get strokes on. Strokes are prospective
    # (all holes in play), so the whole plan shows before the holes are played.
    scorecard_players = [
        {'player_id': pid, 'name': by_pid[pid].name,
         'short_name': by_pid[pid].short_name}
        for pid in real_ids
    ]
    scorecard_holes = [
        {
            'hole'         : hole,
            'par'          : par_by_hole.get(hole),
            'stroke_index' : si_by_hole.get(hole),
            'winner_id'    : None,
            'scores'       : [
                {'player_id': pid,
                 'gross'    : gross_index.get(pid, {}).get(hole),
                 'strokes'  : strokes_by.get(pid, {}).get(hole, 0),
                 'points'   : (float(points_by_hole[hole][pid])
                               if hole in points_by_hole
                               and pid in points_by_hole[hole] else None)}
                for pid in real_ids
            ],
        }
        for hole in sequence
    ]

    return {
        'status'    : game.status,
        'scorecard' : {
            'players'      : scorecard_players,
            'holes'        : scorecard_holes,
            'holes_in_play': sequence,
        },
        'handicap'  : {'mode': game.handicap_mode, 'net_percent': game.net_percent},
        'points'    : {
            'lone_wolf'           : game.lone_wolf_points,
            'blind_wolf'          : game.blind_wolf_points,
            'team_win'            : game.team_win_points,
            'wolf_loses_ties'      : game.wolf_loses_ties,
            'non_wolf_bonus'       : game.non_wolf_bonus,
            'last_place_wolf_1718' : game.last_place_wolf_1718,
            'require_lone_or_blind': game.require_lone_or_blind,
        },
        'wolf_order': order,
        # Rotation positions (0-based) frozen because their hole has been
        # played — the mobile reorder sheet locks these so a past Wolf can't
        # be changed.
        'locked_positions': sorted(locked_wolf_positions(foursome)),
        'players'   : players_out,
        'holes'     : holes_out,
        'money'     : {
            'bet_unit': bet_unit,
            'loss_cap': float(game.loss_cap) if game.loss_cap is not None else None,
        },
    }
