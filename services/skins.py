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
from games.models import (SkinsGame, SkinsGreenieResult, SkinsHoleResult,
                          SkinsPlayerHoleResult)
# **Junk uses the same named types as Spots.** One vocabulary, one greenie
# carry, one reading of birdies off the card — see `services/spot_types.py`
# for why that is a shared module rather than a second copy.
from services.spot_types import (SHEET_TYPES, SPOT_META, catalogue_block,
                                 default_types,
                                 derived_from_scores, greenie_plan,
                                 in_play_block, normalise_types,
                                 par_si_by_hole, types_block)
from core.models import SpotType
from scoring.handicap import build_score_index, _strokes_on_hole
from scoring.models import HoleScore
from core.handicap_math import round_half_up
from services import skin_rules


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
    junk_types          = None,
    junk_greenie_carry: bool = True,
    junk_birdie_basis:  str  = 'gross',
    junk_net_percent:   int  = 100,
    payout_style:   str = 'pool',
    per_point_mode: str = 'first',
    per_point_rate      = 0,
    pool_ante           = None,
    loss_cap            = None,
    participant_player_ids = None,
    skin_minimum:   str = skin_rules.MIN_NONE,
    birdie_steal:  bool = False,
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

    # Junk belongs to the game that owns the CARD.  It is tapped in during
    # score entry, so it is only available while Skins is the round's primary
    # game; a side Skins uses Spots for per-hole extras, which is why the
    # catalog un-excluded Spots from Skins ("a side Skins has junk off → no
    # overlap").  `skins_setup_screen` already hides the control -- this is
    # what makes it a RULE rather than a convention one client happens to
    # follow, and it lives in the service so every caller is covered.
    #
    # A null `primary_game` is LEFT ALONE: tournament and legacy rounds store
    # none, there is no server-side equivalent of the client's
    # `primaryGameOf` fallback, and guessing would switch junk off for rounds
    # that legitimately have it.
    primary = getattr(foursome.round, 'primary_game', None)
    if primary and primary != 'skins':
        allow_junk = False
        junk_types = []

    game = SkinsGame.objects.create(
        skin_minimum   = skin_rules.normalise_minimum(skin_minimum),
        birdie_steal   = bool(birdie_steal),
        foursome       = foursome,
        handicap_mode  = handicap_mode,
        net_percent    = net_percent,
        carryover      = carryover,
        allow_junk     = allow_junk,
        # Omitted means the defaults, the way Spots reads it. An EMPTY list
        # with junk ON is refused by the view, because junk that counts
        # nothing is a switch that does nothing.
        junk_types     = _junk_types_or_refuse(allow_junk, junk_types),
        junk_greenie_carry = bool(junk_greenie_carry),
        junk_birdie_basis  = (junk_birdie_basis
                              if junk_birdie_basis in ('gross', 'net_so')
                              else 'gross'),
        junk_net_percent   = max(50, min(130, int(junk_net_percent or 100))),
        payout_style   = payout_style if payout_style in ('pool', 'per_point') else 'pool',
        per_point_mode = per_point_mode if per_point_mode in ('average', 'all', 'first') else 'first',
        per_point_rate = Decimal(str(per_point_rate or 0)),
        pool_ante      = (Decimal(str(pool_ante))
                          if pool_ante not in (None, '') else None),
        loss_cap       = (Decimal(str(loss_cap)) if loss_cap not in (None, '') else None),
        participant_player_ids = list(participant_player_ids or []),
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
        so = round_half_up(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
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

def _skins_withdrawal_plan(real_members, foursome) -> dict:
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

    A real member is *active* on hole h iff they have not withdrawn before it —
    read along the group's PLAY ORDER by `services/withdrawal.py`, which is the
    one place that rule lives. (It used to compare hole numbers here, which is
    the same integer only when the round starts on the 1st.)  A hole
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
    from services.withdrawal import (
        active_pids, killed_holes, play_plan,
    )
    order, positions = play_plan(foursome)
    wd = {
        m.player_id: m.withdrew_after_hole
        for m in real_members
        if m.withdrew_after_hole is not None
    }
    killed = killed_holes(real_members, order, positions)

    segments: list = []
    eligible: set = set()
    cur = None  # current run: {'holes': [...], 'roster': [...]}
    # **The group's own play order, not 1..18.** A run of holes is consecutive
    # in the order they were PLAYED: 18 and 1 are adjacent off a shotgun and
    # are not adjacent numbers, so walking the numbers split a segment the
    # group never stopped in and joined two it did.
    for h in order:
        roster = active_pids(real_members, h, positions)
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

def _gross_and_pars(foursome, player_ids):
    """({pid: {hole: gross}}, {pid: {hole: par}}) for the validation rules.

    `build_score_index` returns only the adjusted score, so the two new rules
    need gross and par fetched alongside rather than derived from it: a net
    score cannot tell you whether the gross was a par, which is the whole
    point of the gross-par minimum.

    Par is read from EACH GOLFER'S OWN TEE.  Every other game here takes one
    layout for the foursome, which is right when the question is about the
    hole; this question is about the golfer, and on a mixed-tee card the pars
    can differ (see services/skin_rules).
    """
    gross: dict = {}
    for hs in HoleScore.objects.filter(
            foursome=foursome, player_id__in=player_ids).only(
            'player_id', 'hole_number', 'gross_score'):
        if hs.gross_score is not None:
            gross.setdefault(hs.player_id, {})[hs.hole_number] = hs.gross_score

    pars: dict = {}
    for m in foursome.memberships.select_related('tee').all():
        if m.player_id not in player_ids or m.tee_id is None:
            continue
        pars[m.player_id] = {
            h['number']: h.get('par')
            for h in (m.tee.holes or []) if h.get('number')
        }
    return gross, pars


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
    # Subset side game: restrict Skins to the chosen players (empty = all).
    # Filtering `real_members` here flows through the pool, per-hole winner,
    # carryover, junk, and withdrawal segments (docs/parallel-games.md).
    _subset = set(game.participant_player_ids or [])
    if _subset:
        real_members = [m for m in real_members if m.player_id in _subset]
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

    # Gross + par for the validation rules.  Cheap and unconditional: the
    # rules are read per hole below and a branch here would only move the
    # question somewhere it is harder to see.
    gross_index, par_index = _gross_and_pars(foursome, real_ids)

    # Wipe prior hole results — re-created from scratch each call.
    SkinsHoleResult.objects.filter(game=game).delete()

    # Mid-round withdrawals partition the round into constant-roster segments
    # (one segment over all 18 holes when nobody withdrew). The carry pot is
    # scoped to a segment — it never crosses a withdrawal or a killed hole.
    plan          = _skins_withdrawal_plan(real_members, foursome)
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

            # One decider for both engines (services/skin_rules).  With
            # both rules off this is the plain min() it has always been; an
            # EMPTY answer means nobody validated, which falls through to the
            # same carry / kill branches a tie does -- the skin simply was
            # not won.
            leaders = skin_rules.decide(
                scores_by_id,
                {pid: gross_index.get(pid, {}).get(hole_num) for pid in roster},
                {pid: par_index.get(pid, {}).get(hole_num) for pid in roster},
                minimum      = game.skin_minimum,
                birdie_steal = game.birdie_steal,
            )

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

def _junk_types_or_refuse(allow_junk, junk_types) -> list:
    """What goes in `junk_types`, with the one case that is an error.

    Omitted means the defaults, the way Spots reads it. **Junk ON with an
    EMPTY list is refused**: a switch that counts nothing is a switch that
    does nothing, and the handoff asks for at least one. Junk OFF keeps
    whatever was last picked, so turning it back on does not lose the
    group's agreement.
    """
    if junk_types is None:
        return default_types()
    picked = normalise_types(junk_types)
    if allow_junk and not picked:
        raise ValueError(
            'Pick at least one junk to count — junk that counts nothing '
            'pays nobody.')
    return picked


@transaction.atomic
def tally_skins_junk(foursome, hole_number: int, entries: list) -> SkinsGame:
    """Set which junk types each named golfer made on one hole.

    entries: ``[{'player_id': int, 'types': ['sandy', 'chippy']}, ...]``

    The list is the WHOLE truth for that golfer on that hole — what is absent
    is unticked, which makes the sheet's Done button a plain save rather than
    a diff.

    **Writing ticks clears that row's legacy `junk_count`.** A hole from
    before junk had names converts the moment anybody touches it, and the two
    can never be counted together. Only the untouched holes of an old round
    keep their history.
    """
    game = foursome.skins_game
    real_ids = {m.player_id for m in
                foursome.memberships.filter(player__is_phantom=False)}
    in_play = set(game.junk_types or [])
    allowed = {str(t) for t in SHEET_TYPES} & in_play
    for e in entries:
        pid = e.get('player_id')
        if pid not in real_ids:
            continue
        picked = {str(t) for t in (e.get('types') or [])} & allowed
        qs = SkinsPlayerHoleResult.objects.filter(
            game=game, player_id=pid, hole_number=hole_number)
        # The legacy row for this golfer and hole, if any, is now superseded.
        qs.filter(junk_type__isnull=True).delete()
        qs.filter(junk_type__in=allowed).exclude(
            junk_type__in=picked).delete()
        for t in picked:
            SkinsPlayerHoleResult.objects.get_or_create(
                game=game, player_id=pid, hole_number=hole_number,
                junk_type=t, defaults={'junk_count': 0})
    return game


@transaction.atomic
def pick_skins_greenie(foursome, hole_number: int, player_id=None) -> SkinsGame:
    """Who took the greenie on a par 3 — or that nobody did.

    `player_id=None` is **Nobody**, a real answer rather than a missing one:
    it is what rolls the carry. Clearing the hole back to undecided is
    `clear_skins_greenie`, and the two are different states.
    """
    game = foursome.skins_game
    if player_id is not None:
        real_ids = {m.player_id for m in
                    foursome.memberships.filter(player__is_phantom=False)}
        if player_id not in real_ids:
            raise ValueError('That golfer is not playing in this group.')
    SkinsGreenieResult.objects.update_or_create(
        game=game, hole_number=hole_number,
        defaults={'player_id': player_id})
    return game


@transaction.atomic
def clear_skins_greenie(foursome, hole_number: int) -> SkinsGame:
    """Un-answer a par 3 — undecided, which is not the same as Nobody."""
    game = foursome.skins_game
    SkinsGreenieResult.objects.filter(
        game=game, hole_number=hole_number).delete()
    return game


def _junk_earned(foursome, game, real_members):
    """``(greenie_block, {pid: {hole: [(type, worth)]}})`` for junk.

    The same three sources Spots merges — ticks, the greenie pick, birdies off
    the card — plus a fourth that only junk has: **legacy untyped counts**.

    Sixteen of those exist, in four completed rounds from before junk had
    names. They are read and never rewritten, and they come back with a
    `None` type so the board shows the count without inventing a label for
    it. `tally_skins_junk` clears a row's count when it writes ticks for the
    same golfer and hole, so the two can never be added together.
    """
    in_play = set(game.junk_types or [])
    par_si  = par_si_by_hole(real_members)
    earned: dict = {}

    def _add(pid, hole, spot_type, worth):
        earned.setdefault(pid, {}).setdefault(hole, []).append(
            (spot_type if spot_type is None else str(spot_type), worth))

    rows = list(SkinsPlayerHoleResult.objects
                .filter(game=game).select_related('player'))
    for r in rows:
        if r.junk_type:
            if r.junk_type in in_play:
                meta = SPOT_META.get(SpotType(r.junk_type))
                if meta:
                    _add(r.player_id, r.hole_number, r.junk_type,
                         meta['worth'])
        elif r.junk_count:
            # A round played before junk had names. Its money is history.
            _add(r.player_id, r.hole_number, None, r.junk_count)

    plan = greenie_plan(foursome, greenies=game.greenies.all(),
                        carry=game.junk_greenie_carry)
    if str(SpotType.GREENIE) in in_play:
        for hole, (pid, worth) in plan['awards'].items():
            _add(pid, hole, SpotType.GREENIE, worth)

    for pid, holes_map in derived_from_scores(
            foursome, types=game.junk_types,
            basis=game.junk_birdie_basis,
            net_percent=game.junk_net_percent, par_si=par_si).items():
        for hole, got in holes_map.items():
            for spot_type, worth in got:
                _add(pid, hole, spot_type, worth)

    short = {m.player_id: (m.player.short_name or m.player.name)
             for m in real_members}
    greenie_block = {
        'carry'    : plan['carry'],
        'needs_par': True,
        'holes'    : [dict(h, winner_short=short.get(h['winner_id']))
                      for h in plan['holes']],
        'next'     : plan['next'],
    }
    return greenie_block, earned


def skins_summary(foursome) -> dict:
    """
    JSON-serialisable summary of a Skins game.

    Shape:
        {
            'status'    : 'pending' | 'in_progress' | 'complete',
            'handicap'  : {'mode': str, 'net_percent': int},
            'carryover' : bool,
            'allow_junk': bool,
            'skin_minimum': 'none' | 'net_par' | 'gross_par',
            'birdie_steal': bool,
            'skin_rules'  : str,   # '' when neither rule is on
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
            'skin_minimum': skin_rules.MIN_NONE,
            'birdie_steal': False,
            'skin_rules'  : '',
            'skin_rules_note': '',
            'skin_rule_copy' : skin_rules.copy_block(),
            'players'   : [],
            'holes'     : [],
            'money'     : {'bet_unit': bet_unit, 'pool': 0.0, 'total_skins': 0},
            # The junk CATALOGUE belongs here too, not only on a configured
            # game.  Without it a first-time setup drew the junk switch with
            # NO TYPE ROWS: nothing to tick, while the screen's own gate
            # ("junk on with nothing ticked is a switch that counts nothing")
            # refused to save.  The TD could neither pick junk nor get past
            # the form -- reported from the setup screen, 28 Oct 2026.
            #
            # `junk_catalogue` is the whole vocabulary and is always the same,
            # so it is safe to send before any game exists.  The three
            # in-play lists stay empty, because nothing has been chosen yet.
            'junk_catalogue'   : catalogue_block(),
            'junk_in_play'     : [],
            'junk_sheet_types' : [],
            # An ABSENCE, not a hand-built state: the client defaults every
            # greenie field (carry -> true), so spelling one out here would
            # only be a second shape to drift from the real one.
            'junk_greenie'     : {},
            'junk_birdie_basis': 'gross',
        }

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    # Subset side game: restrict to the chosen players (empty = all) so the pool,
    # standings, and per-hole scores only span participants.
    _subset = set(game.participant_player_ids or [])
    if _subset:
        real_members = [m for m in real_members if m.player_id in _subset]
    # The game's own ante when it has one; see SkinsGame.pool_ante.
    bet_unit    = float(game.pool_ante if game.pool_ante is not None
                        else foursome.round.bet_unit)
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
    # **A junk is worth a skin** — one share of the same pot, which is why
    # these fold straight into `total_skins_by_pid` below rather than
    # settling on their own. A greenie worth 2 is 2 junk; an eagle is 2.
    junk_skins: dict        = {m.player_id: 0 for m in real_members}
    junk_by_hole_player: dict = {}   # (hole_number, player_id) → entry dict
    junk_greenie: dict      = {'carry': True, 'needs_par': True,
                               'holes': [], 'next': None}

    if game.allow_junk:
        junk_greenie, earned = _junk_earned(foursome, game, real_members)
        for pid, holes_map in earned.items():
            if pid not in junk_skins:
                continue
            for hole, got in holes_map.items():
                worth = sum(w for _t, w in got)
                junk_skins[pid] += worth
                short = next((m.player.short_name or m.player.name
                              for m in real_members if m.player_id == pid), '')
                junk_by_hole_player[(hole, pid)] = {
                    'player_id' : pid,
                    'short_name': short,
                    'count'     : worth,
                    # Named, so the board can say "Greenie on 7 ×2" rather
                    # than "2 junk". The worth travels WITH each type: a
                    # carried greenie's belongs to the hole, not to the type.
                    'types'     : types_block([(t, w) for t, w in got
                                               if t is not None]),
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
    plan        = _skins_withdrawal_plan(real_members, foursome)
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
        # Only settle a segment once its pot is actually AWARDED (a skin has
        # been won).  Until then the pot is undecided and nobody is charged —
        # charging the ante while distributing nothing breaks zero-sum (each
        # player shows −ante with no offsetting winner).
        if seg_total > 0:
            for pid in seg['roster']:
                if pid in contribution_by_pid:
                    contribution_by_pid[pid] += per_player_ante
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
            return round_half_up(max(0, phcp - low_phcp) * npct / 100)
        return round_half_up(phcp * npct / 100)   # NET

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
    si_by_hole: dict = {}
    if sample_tee is not None:
        for h in range(1, 19):
            par_by_hole[h] = sample_tee.hole(h).get('par')
            si_by_hole[h]  = sample_tee.hole(h).get('stroke_index')

    # ---- Holes grid ---------------------------------------------------------
    # Holes the group abandoned at a withdrawal — voided for everyone, their
    # pot fraction evaporates. Surfaced so the UI can label them.
    killed_holes = plan['killed_holes']
    # Each player's in-play stroke count (net% / strokes-off number), allocated
    # by stroke index. Matches how skins actually issues strokes, but computed
    # PROSPECTIVELY so the scorecard shows a player's stroke holes up front
    # (dots on every stroke hole, not only the ones already played).
    phcp_by_pid = {
        m.player_id: _phcp_in_play(m.playing_handicap or 0)
        for m in real_members
    }
    from services.hole_plan import play_order as _play_order
    in_play = _play_order(foursome.round, foursome) or list(range(1, 19))
    holes_out: list = []
    for hole_num in in_play:
        hr        = hr_by_hole.get(hole_num)
        is_killed = hole_num in killed_holes
        si        = si_by_hole.get(hole_num) or 18

        scores = []
        for pid in real_pids:
            gross   = gross_index.get(pid, {}).get(hole_num)   # None until scored
            strokes = _strokes_on_hole(phcp_by_pid.get(pid, 0), si)
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
            'hole'         : hole_num,
            'par'          : par_by_hole.get(hole_num),
            'stroke_index' : si_by_hole.get(hole_num),
            'winner_id'    : winner_id,
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
        # The validation rules in force, plus a ready phrase for a board that
        # wants to state them.  Empty string when neither is on, so a client
        # can test it instead of rendering "no minimum" at a group playing
        # plain skins.
        'skin_minimum': game.skin_minimum,
        'birdie_steal': game.birdie_steal,
        'skin_rules'  : skin_rules.rules_line(game.skin_minimum,
                                              game.birdie_steal),
        # The CONSEQUENCE, and the catalogue a setup screen draws options
        # from. Both here for the reason the chips already were: this rule
        # was spelled in five places on the client and they had drifted.
        'skin_rules_note': skin_rules.rules_note(game.skin_minimum,
                                                 game.birdie_steal),
        'skin_rule_copy' : skin_rules.copy_block(),
        # What the group agreed junk means, for the leaderboard's Junk in
        # play card and the hole's tick sheet. Empty when junk is off.
        # The WHOLE list, so the setup checklist can draw an unticked row
        # without the client keeping its own copy of the names — the same
        # reason the Spots summary carries one.
        'junk_catalogue'   : catalogue_block(),
        'junk_in_play'     : in_play_block(game.junk_types or [])
                             if game.allow_junk else [],
        'junk_sheet_types' : in_play_block(
                                [t for t in (game.junk_types or [])
                                 if t in {str(x) for x in SHEET_TYPES}])
                             if game.allow_junk else [],
        'junk_greenie'     : junk_greenie,
        'junk_birdie_basis': game.junk_birdie_basis,
        'participant_player_ids': game.participant_player_ids or [],
        'players'   : players_out,
        'holes'     : holes_out,
        # The holes this round plays, IN PLAY ORDER, so the leaderboard grid
        # renders exactly those (14,15,…,18,1 for a shotgun; 10-18 for a back 9)
        # instead of a hardcoded 1..18.
        'holes_in_play': in_play,
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
