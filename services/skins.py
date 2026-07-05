"""
services/skins.py
-----------------
Skins calculator — played within a single foursome by 2–4 real players
(phantom players are excluded).

Scoring rules
~~~~~~~~~~~~~
* Each hole is worth 1 skin.  The player with the BEST score-to-compare
  on a hole wins it outright.
* If two or more players tie for the best score:
    - carryover=True  → the skin carries to the next hole, accumulating
                         until one player wins outright.
    - carryover=False → the skin is killed (voided for that hole).
* Skins still in the pot after hole 18 (tied carry with no winner) are
  voided — the settlement denominator simply reflects skins actually won.

Handicap modes
~~~~~~~~~~~~~~
* Net (with net_percent) and Gross reuse scoring.handicap.build_score_index
  directly — same behavior as Points 5-3-1 and Sixes.
* Strokes-Off-Low uses the same course-wide SI helper as Points 5-3-1:
  the lowest playing handicap in the foursome plays to 0 and every
  other player gets (own HCP − low HCP) strokes allocated by hole SI.

Junk skins
~~~~~~~~~~
When allow_junk=True the UI lets scorers record extra junk skins
(birdies, sandies, chip-ins, etc.) per player per hole as a count.
Junk skins are stored in SkinsPlayerHoleResult and included in the
pool split alongside the regular per-hole skins.

Settlement
~~~~~~~~~~
Pool = number_of_real_players × Round.bet_unit.
payout_i = (skins_i / total_skins_won) × pool
where skins_i = regular_skins_i + junk_skins_i.
Players with zero skins receive nothing; the pool is always fully
distributed (sum of payouts = pool when total_skins > 0).

Workflow
~~~~~~~~
1. setup_skins(foursome, ...)  — creates the SkinsGame row.  Safe to
   call repeatedly (deletes and re-creates).
2. calculate_skins(foursome)   — called after every score submission by
   api.views._recalculate_games.  Replaces all SkinsHoleResult rows.
3. skins_summary(foursome)     — returns the JSON shape consumed by the
   mobile UI and the leaderboard.
"""

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import SkinsGame, SkinsHoleResult, SkinsPlayerHoleResult
from scoring.handicap import build_score_index
from scoring.models import HoleScore


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_skins(
    foursome,
    handicap_mode: str  = HandicapMode.NET,
    net_percent:   int  = 100,
    carryover:     bool = True,
    allow_junk:    bool = False,
    payout_style:   str = 'pool',
    per_point_mode: str = 'first',
    per_point_rate      = 0,
    loss_cap            = None,
) -> 'SkinsGame':
    """
    Create (or replace) the Skins game for a foursome.

    Deleting the old SkinsGame cascades to all SkinsHoleResult and
    SkinsPlayerHoleResult rows, so the game starts fresh each time.
    net_percent is clamped to [0, 200].

    payout_style 'pool' keeps the classic ante-pool economics; 'per_point'
    settles total skins through services.wager at per_point_mode/rate.
    """
    SkinsGame.objects.filter(foursome=foursome).delete()
    net_percent = max(0, min(200, int(net_percent)))

    game = SkinsGame.objects.create(
        foursome       = foursome,
        handicap_mode  = handicap_mode,
        net_percent    = net_percent,
        carryover      = carryover,
        allow_junk     = allow_junk,
        payout_style   = payout_style if payout_style in ('pool', 'per_point') else 'pool',
        per_point_mode = per_point_mode if per_point_mode in ('average', 'all', 'first') else 'first',
        per_point_rate = Decimal(str(per_point_rate or 0)),
        loss_cap       = (Decimal(str(loss_cap)) if loss_cap not in (None, '') else None),
        status         = MatchStatus.PENDING,
    )
    return game


# ---------------------------------------------------------------------------
# Strokes-Off support (course-wide SI threshold — mirrors points_531.py)
# ---------------------------------------------------------------------------

def _build_so_score_index(foursome, net_percent: int = 100) -> dict:
    """
    Return a gross-based score index with Strokes-Off adjustments baked in.

    The lowest playing handicap in the foursome plays to 0.  Every other
    player has SO = own_phcp − low.  Each of those players receives one
    stroke on every hole whose stroke_index ≤ SO.  If SO > 18 the
    remaining strokes wrap (full laps × all holes + partial lap by SI).
    """
    score_index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)

    memberships = list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player__is_phantom=False)
    )
    if not memberships:
        return score_index

    phcps = [m.playing_handicap for m in memberships
             if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0

    for m in memberships:
        if m.tee_id is None:
            continue
        so = round(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
        if so <= 0:
            continue

        per_player = score_index.get(m.player_id)
        if not per_player:
            continue

        full_laps = so // 18
        remainder = so % 18

        for hole_num, score in list(per_player.items()):
            si = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = full_laps + (1 if si <= remainder else 0)
            if strokes:
                per_player[hole_num] = score - strokes

    return score_index


# ---------------------------------------------------------------------------
# Mid-round withdrawal — segment plan
# ---------------------------------------------------------------------------

def _skins_withdrawal_plan(real_members) -> dict:
    """
    Derive the segment structure a mid-round withdrawal imposes on Skins.

    Returns::

        {
          'killed_holes' : set[int],   # abandoned holes — score for nobody
          'segments'     : [           # ordered, each a constant-roster run
              {'holes': [int, ...], 'roster': [player_id, ...]},
          ],
          'eligible'     : set[int],   # holes that belong to some segment
          'has_wd'       : bool,
          'withdrawals'  : [{'player_id', 'after_hole', 'killed_next_hole'}],
        }

    A real member is *active* on hole h iff they have not withdrawn before it
    (``withdrew_after_hole`` is None or ``h <= withdrew_after_hole``).  A hole
    is *eligible* (contested) when it is not killed and ≥ 2 players are active
    — fewer than two players is "game over", so those holes evaporate.
    Segments are maximal runs of consecutive eligible holes that share the same
    active roster; both a killed hole and a roster change start a new segment
    (so a pot can never carry across a withdrawal).

    With no withdrawals this yields exactly one segment over holes 1..18 with
    the full roster — i.e. the historical single-pool behaviour, unchanged.

    NOTE — per-skin payout styles (pay-the-winner / pay-those-above-you), if
    added to Skins later, don't use these fractional segment pots: they settle
    each segment as an independent closed game (void the killed hole, then a
    fresh calculation for the survivor segment). This helper still gives them
    the right hole→segment partition; only the money math differs.
    """
    all_pids = [m.player_id for m in real_members]
    wd = {
        m.player_id: m.withdrew_after_hole
        for m in real_members
        if m.withdrew_after_hole is not None
    }
    killed = {
        m.withdrew_after_hole + 1
        for m in real_members
        if m.withdrew_after_hole is not None
        and m.withdrew_killed_next_hole
        and m.withdrew_after_hole + 1 <= 18
    }

    def active_on(h):
        return [pid for pid in all_pids if pid not in wd or h <= wd[pid]]

    segments: list = []
    eligible: set = set()
    cur = None  # current run: {'holes': [...], 'roster': [...]}
    for h in range(1, 19):
        roster = active_on(h)
        if h in killed or len(roster) < 2:
            cur = None  # boundary — close the current run, carry dies
            continue
        eligible.add(h)
        if cur is not None and cur['roster'] == roster:
            cur['holes'].append(h)
        else:
            cur = {'holes': [h], 'roster': roster}
            segments.append(cur)

    return {
        'killed_holes': killed,
        'segments'    : segments,
        'eligible'    : eligible,
        'has_wd'      : bool(wd),
        'withdrawals' : [
            {'player_id'      : m.player_id,
             'after_hole'     : m.withdrew_after_hole,
             'killed_next_hole': m.withdrew_killed_next_hole}
            for m in real_members
            if m.withdrew_after_hole is not None
        ],
    }


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_skins(foursome) -> list:
    """
    Re-compute SkinsHoleResult rows for the foursome's game.

    * Reads all HoleScore rows through the appropriate score index
      (net / gross / strokes-off).
    * For each hole where *every* real player has a score:
        - One clear winner → award the accumulated pot.
        - Tie + carryover  → skin carries, pot grows.
        - Tie + no carryover → skin is killed, pot resets.
    * Bulk-replaces existing SkinsHoleResult rows atomically.
    * Updates the game's status field.

    Returns the list of newly-saved SkinsHoleResult instances.
    """
    try:
        game = foursome.skins_game
    except SkinsGame.DoesNotExist:
        return []

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    real_ids = [m.player_id for m in real_members]

    if not real_ids:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        SkinsHoleResult.objects.filter(game=game).delete()
        return []

    # Build the appropriate score index.
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        score_index = _build_so_score_index(foursome, net_percent=game.net_percent)
    else:
        score_index = build_score_index(
            foursome,
            handicap_mode = game.handicap_mode,
            net_percent   = game.net_percent,
        )

    # Wipe prior hole results — re-created from scratch each call.
    SkinsHoleResult.objects.filter(game=game).delete()

    # Mid-round withdrawals partition the round into constant-roster segments
    # (one segment over all 18 holes when nobody withdrew). The carry pot is
    # scoped to a segment — it never crosses a withdrawal or a killed hole.
    plan          = _skins_withdrawal_plan(real_members)
    total_eligible = len(plan['eligible'])
    rows          = []
    scored        = 0   # eligible holes where the active roster all scored

    for seg in plan['segments']:
        roster = seg['roster']
        pot    = 0   # skins accumulated in this segment's carry run
        for hole_num in seg['holes']:
            # Every *active* player on this hole must have a score for it to
            # be counted (withdrawn players are simply not expected).
            scores_by_id: dict = {}
            missing = False
            for pid in roster:
                s = score_index.get(pid, {}).get(hole_num)
                if s is None:
                    missing = True
                    break
                scores_by_id[pid] = s
            if missing:
                continue  # at least one active player missing — skip

            scored += 1
            pot    += 1  # this hole adds 1 to the pot

            min_score = min(scores_by_id.values())
            leaders   = [pid for pid, s in scores_by_id.items() if s == min_score]

            if len(leaders) == 1:
                # Outright winner — collects the whole pot.
                rows.append(SkinsHoleResult(
                    game        = game,
                    hole_number = hole_num,
                    winner_id   = leaders[0],
                    skins_value = pot,
                    is_carry    = False,
                ))
                pot = 0  # reset after a win

            elif game.carryover:
                # Tied hole with carryover — skin carries within this segment.
                rows.append(SkinsHoleResult(
                    game        = game,
                    hole_number = hole_num,
                    winner      = None,
                    skins_value = pot,   # current pot being carried
                    is_carry    = True,
                ))
                # pot keeps accumulating; do NOT reset

            else:
                # Tied hole without carryover — skin is killed.
                rows.append(SkinsHoleResult(
                    game        = game,
                    hole_number = hole_num,
                    winner      = None,
                    skins_value = 1,     # the 1 skin that died
                    is_carry    = False,
                ))
                pot = 0  # reset; next hole starts a fresh 1-skin pot

    if rows:
        SkinsHoleResult.objects.bulk_create(rows)

    # Status: pending / in_progress / complete. "Complete" means every
    # *eligible* (contested) hole has been scored — killed and game-over
    # holes are never expected, so a withdrawn round still completes.
    if total_eligible > 0 and scored >= total_eligible:
        game.status = MatchStatus.COMPLETE
    elif scored == 0 and not plan['has_wd']:
        game.status = MatchStatus.PENDING
    elif scored == 0 and total_eligible == 0:
        # All remaining holes evaporated (e.g. only one player left) — the
        # contested portion is settled, so the game is done.
        game.status = MatchStatus.COMPLETE if plan['has_wd'] else MatchStatus.PENDING
    elif scored == 0:
        game.status = MatchStatus.PENDING
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])

    return rows


# ---------------------------------------------------------------------------
# Summary (for the game screen and leaderboard)
# ---------------------------------------------------------------------------

def skins_summary(foursome) -> dict:
    """
    JSON-serialisable summary of a Skins game.

    Shape:
        {
            'status'    : 'pending' | 'in_progress' | 'complete',
            'handicap'  : {'mode': str, 'net_percent': int},
            'carryover' : bool,
            'allow_junk': bool,
            'players'   : [
                {
                    'player_id'  : int,
                    'name'       : str,
                    'short_name' : str,
                    'skins_won'  : int,   # regular per-hole skins
                    'junk_skins' : int,   # junk skins (0 if allow_junk=False)
                    'total_skins': int,
                    'payout'     : float, # pool × (total / grand_total)
                },
                ...  sorted by total_skins desc
            ],
            'holes'     : [
                {
                    'hole'        : int,
                    'par'         : int | null,
                    'winner_id'   : int | null,
                    'winner_short': str | null,
                    'skins_value' : int,
                    'is_carry'    : bool,
                    'is_dead'     : bool,   # played, no winner, no carry
                    'scores'      : [
                        {'player_id': int, 'gross': int, 'strokes': int},
                        ...
                    ],
                    'junk'        : [
                        {'player_id': int, 'short_name': str, 'count': int},
                        ...
                    ],
                },
                ...
            ],
            'money'     : {
                'bet_unit'   : float,
                'pool'       : float,   # num_players × bet_unit
                'total_skins': int,     # grand total skins won (denom)
            },
        }
    """
    try:
        game = foursome.skins_game
    except SkinsGame.DoesNotExist:
        bet_unit = float(foursome.round.bet_unit)
        # Empty/pending state: mirror the mobile casual defaults so the
        # setup screen lands on the same starting picks every game uses
        # (Strokes-Off Low, full handicap percent, carryover on, no junk).
        return {
            'status'    : MatchStatus.PENDING,
            'handicap'  : {'mode': HandicapMode.STROKES_OFF, 'net_percent': 100},
            'carryover' : True,
            'allow_junk': False,
            'players'   : [],
            'holes'     : [],
            'money'     : {'bet_unit': bet_unit, 'pool': 0.0, 'total_skins': 0},
        }

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    bet_unit    = float(foursome.round.bet_unit)
    num_players = len(real_members)
    pool        = num_players * bet_unit

    # ---- Regular skins per player -------------------------------------------
    regular_skins: dict = {m.player_id: 0 for m in real_members}
    hole_results = list(
        SkinsHoleResult.objects
        .filter(game=game)
        .select_related('winner')
        .order_by('hole_number')
    )
    for hr in hole_results:
        if hr.winner_id and hr.winner_id in regular_skins:
            regular_skins[hr.winner_id] += hr.skins_value

    # ---- Junk skins per player (only when allow_junk=True) ------------------
    junk_skins: dict        = {m.player_id: 0 for m in real_members}
    junk_by_hole_player: dict = {}   # (hole_number, player_id) → entry dict

    if game.allow_junk:
        for jr in (
            SkinsPlayerHoleResult.objects
            .filter(game=game)
            .select_related('player')
        ):
            if jr.player_id in junk_skins:
                junk_skins[jr.player_id] += jr.junk_count
            if jr.junk_count > 0:
                junk_by_hole_player[(jr.hole_number, jr.player_id)] = {
                    'player_id' : jr.player_id,
                    'short_name': jr.player.short_name,
                    'count'     : jr.junk_count,
                }

    # ---- Totals and payouts -------------------------------------------------
    total_skins_by_pid = {
        pid: regular_skins[pid] + junk_skins[pid]
        for pid in regular_skins
    }
    grand_total = sum(total_skins_by_pid.values())

    # Segment-aware settlement. A withdrawal partitions the round into
    # constant-roster segments. Each player antes one bet_unit spread evenly
    # over the 18 holes (bet_unit/18 per hole), and a withdrawn player stops
    # contributing the moment they leave — so a segment's pot is funded only by
    # the players actually IN it:
    #     seg_pot = holes_in_segment × roster_size × bet_unit / 18
    # split *within* the segment proportional to skins won there (regular +
    # junk). A killed/abandoned hole and any holes after the group drops below
    # two players are in no segment, so those stakes evaporate. With no
    # withdrawal there's one 18-hole segment with the full roster, so this is
    # identical to the historical "pool × skins / total_skins" split.
    plan        = _skins_withdrawal_plan(real_members)
    hr_by_hole  = {hr.hole_number: hr for hr in hole_results}
    payout_by_pid: dict = {m.player_id: 0.0 for m in real_members}
    # What each player actually anted (pool mode) — one bet_unit spread over 18
    # holes, only for the holes they were in play. Drives the signed net below.
    contribution_by_pid: dict = {m.player_id: 0.0 for m in real_members}
    pool_at_risk = 0.0
    for seg in plan['segments']:
        seg_pot      = len(seg['holes']) * len(seg['roster']) * bet_unit / 18.0
        pool_at_risk += seg_pot
        per_player_ante = len(seg['holes']) * bet_unit / 18.0
        for pid in seg['roster']:
            if pid in contribution_by_pid:
                contribution_by_pid[pid] += per_player_ante
        seg_skins: dict = {}
        seg_total = 0
        for hole_num in seg['holes']:
            hr = hr_by_hole.get(hole_num)
            if hr is not None and hr.winner_id:
                seg_skins[hr.winner_id] = seg_skins.get(hr.winner_id, 0) + hr.skins_value
                seg_total += hr.skins_value
            if game.allow_junk:
                for (hn, pid), entry in junk_by_hole_player.items():
                    if hn == hole_num:
                        seg_skins[pid] = seg_skins.get(pid, 0) + entry['count']
                        seg_total     += entry['count']
        if seg_total > 0:
            for pid, sk in seg_skins.items():
                if pid in payout_by_pid:
                    payout_by_pid[pid] += seg_pot * sk / seg_total

    # ── Signed net per player (settlement-ready, zero-sum) ────────────────────
    # Pool: net = pot share − ante (WD-aware, preserves the classic economics).
    # Per-skin: settle total skins through the shared wager engine (pay the
    # leader / pay everyone above you / vs the field average), which is itself
    # zero-sum; 'payout' then mirrors the signed net (no ante pool).
    if game.payout_style == 'per_point':
        from services.wager import (settle as _wager_settle, WagerConfig,
                                    PER_POINT, VS_AVERAGE, PAY_ABOVE, PAY_WINNER)
        _MODE = {'average': VS_AVERAGE, 'all': PAY_ABOVE, 'first': PAY_WINNER}
        cfg = WagerConfig(
            funding    = PER_POINT,
            settlement = _MODE.get(game.per_point_mode, PAY_WINNER),
            rate       = Decimal(str(game.per_point_rate or 0)),
            cap        = (Decimal(str(game.loss_cap))
                          if game.loss_cap is not None else None),
        )
        net_by_pid = {pid: float(v)
                      for pid, v in _wager_settle(dict(total_skins_by_pid), cfg).items()}
        payout_by_pid = {pid: net_by_pid.get(pid, 0.0) for pid in payout_by_pid}
    else:
        net_by_pid = {pid: round(payout_by_pid[pid] - contribution_by_pid[pid], 2)
                      for pid in payout_by_pid}

    # Net strokes actually in play for each foursome member — drives
    # the "(N)" label on the scorecard so observers can see whose
    # handicap is feeding which gross-to-net adjustment.
    mode    = game.handicap_mode
    npct    = game.net_percent or 100
    phcps   = [
        (m.playing_handicap or 0) for m in real_members
        if m.playing_handicap is not None
    ]
    low_phcp = min(phcps) if phcps else 0

    def _phcp_in_play(phcp: int) -> int:
        if mode == HandicapMode.GROSS:
            return 0
        if mode == HandicapMode.STROKES_OFF:
            return round(max(0, phcp - low_phcp) * npct / 100)
        return round(phcp * npct / 100)   # NET

    players_out: list = []
    for m in real_members:
        pid    = m.player_id
        ts     = total_skins_by_pid[pid]
        players_out.append({
            'player_id'   : pid,
            'name'        : m.player.name,
            'short_name'  : m.player.short_name,
            'skins_won'   : regular_skins[pid],
            'junk_skins'  : junk_skins[pid],
            'total_skins' : ts,
            'payout'      : round(payout_by_pid[pid], 2),
            # Signed, zero-sum net for the Settlement view (+received / −owed).
            'net'         : round(net_by_pid[pid], 2),
            'withdrew_after_hole': m.withdrew_after_hole,
            'phcp_in_play': _phcp_in_play(m.playing_handicap or 0),
        })
    players_out.sort(key=lambda x: (-x['total_skins'], x['name']))

    # ---- Per-hole gross + strokes index (for the scorecard grid) ────────────
    # Gross scores straight from HoleScore — these are what the scorecard
    # shows.  We pair them with the net/strokes-off index that the skins
    # calculator already uses to derive how many strokes each player
    # received on each hole.
    real_pids = [m.player_id for m in real_members]
    gross_index: dict = {}
    for r in (
        HoleScore.objects
        .filter(foursome=foursome, player_id__in=real_pids)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    ):
        gross_index.setdefault(r['player_id'], {})[r['hole_number']] = r['gross_score']

    if game.handicap_mode == HandicapMode.STROKES_OFF:
        score_index = _build_so_score_index(foursome, net_percent=game.net_percent)
    else:
        score_index = build_score_index(
            foursome,
            handicap_mode = game.handicap_mode,
            net_percent   = game.net_percent,
        )

    # Par per hole from the first scoring member's tee — the foursome
    # plays one course so every member's tee shares the same par layout.
    par_by_hole: dict = {}
    sample_tee = next(
        (m.tee for m in real_members if m.tee_id is not None),
        None,
    )
    if sample_tee is not None:
        for h in range(1, 19):
            par_by_hole[h] = sample_tee.hole(h).get('par')

    # ---- Holes grid ---------------------------------------------------------
    # Holes the group abandoned at a withdrawal — voided for everyone, their
    # pot fraction evaporates. Surfaced so the UI can label them.
    killed_holes = plan['killed_holes']
    holes_out: list = []
    for hole_num in range(1, 19):
        hr            = hr_by_hole.get(hole_num)
        scored_pids   = [
            pid for pid in real_pids
            if hole_num in gross_index.get(pid, {})
        ]
        is_killed = hole_num in killed_holes
        if hr is None and not scored_pids and not is_killed:
            continue   # nobody has played this hole yet

        scores = []
        for pid in scored_pids:
            gross   = gross_index[pid][hole_num]
            net     = score_index.get(pid, {}).get(hole_num)
            strokes = max(0, gross - net) if net is not None else 0
            scores.append({
                'player_id': pid,
                'gross'    : gross,
                'strokes'  : strokes,
            })

        junk_entries = [
            v for (hn, _pid), v in junk_by_hole_player.items()
            if hn == hole_num
        ]

        winner_id   = hr.winner_id if hr else None
        is_carry    = hr.is_carry if hr else False
        # "Dead" hole = a played hole with no winner that is not part of
        # an active carry — i.e. the skin was killed (no-carryover rule).
        # Carries already light up via the running-pot total, so we keep
        # the dead-flag tight to the skin-killed case.
        is_dead = (hr is not None and winner_id is None and not is_carry)

        holes_out.append({
            'hole'        : hole_num,
            'par'         : par_by_hole.get(hole_num),
            'winner_id'   : winner_id,
            'winner_short': hr.winner.short_name if hr and hr.winner else None,
            'skins_value' : hr.skins_value if hr else 0,
            'is_carry'    : is_carry,
            'is_dead'     : is_dead,
            'is_killed'   : is_killed,
            'scores'      : scores,
            'junk'        : junk_entries,
        })

    return {
        'status'    : game.status,
        'handicap'  : {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'carryover' : game.carryover,
        'allow_junk': game.allow_junk,
        'players'   : players_out,
        'holes'     : holes_out,
        # Withdrawal context for the UI (empty list = normal round). Lets the
        # leaderboard explain a shrunken pool / voided holes.
        'withdrawals': plan['withdrawals'],
        'money'     : {
            'bet_unit'    : bet_unit,
            'pool'        : pool,                    # full ante pool
            # When a withdrawal voids holes, less than the full pool is
            # actually contested; pool_at_risk is what gets distributed.
            'pool_at_risk': round(pool_at_risk, 2),
            'total_skins' : grand_total,
        },
        # Payout mode (2-axis, maps to services.wager). Drives the settlement
        # math above and the setup UI.
        'payout_style'  : game.payout_style,
        'per_point_mode': game.per_point_mode,
        'per_point_rate': float(game.per_point_rate or 0),
        'loss_cap'      : (float(game.loss_cap)
                           if game.loss_cap is not None else None),
    }
