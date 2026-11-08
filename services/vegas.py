"""
services/vegas.py — Las Vegas (2v2) casual game.

Each hole, a team's "number" is its two NET scores with the low score as the
tens digit and the high as the ones (each digit capped at 9). The lower number
wins the hole and scores the *difference* between the two numbers. A gross
birdie either flips the opponents' digits or multiplies the points (per setup)
— and under `flip`, both sides going under par cancels, so nothing flips (an
eagle is a birdie for that rule). Tied holes can carry. Settlement is 1-to-1 per player: each player's money
is the running point differential × bet_unit (winners +, losers −), clipped by
the optional per-side loss cap.

Mirrors the Points 5-3-1 / Sixes service contract: setup_vegas / calculate_vegas
(idempotent, called from _recalculate_games) / vegas_summary.
"""
from __future__ import annotations

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import VegasGame, VegasTeam, VegasHoleResult
from scoring.handicap import (
    build_score_index, _par_by_hole, _cap_value,
    make_strokes_fn, effective_hcp_for,
)
from services import wager
from core.handicap_math import round_half_up


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_vegas(
    foursome,
    team1_ids: list,
    team2_ids: list,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    net_max_double_bogey: bool = True,
    birdie_mode: str = 'flip',
    carryover: bool = False,
    loss_cap=None,
) -> VegasGame:
    """Create (or replace) the Vegas game for a foursome. Idempotent."""
    VegasGame.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))
    if birdie_mode not in ('flip', 'multiplier'):
        birdie_mode = 'flip'
    if loss_cap is not None:
        loss_cap = Decimal(str(loss_cap))
        if loss_cap < 0:
            loss_cap = None

    game = VegasGame.objects.create(
        foursome             = foursome,
        handicap_mode        = handicap_mode,
        net_percent          = net_percent,
        net_max_double_bogey = bool(net_max_double_bogey),
        birdie_mode          = birdie_mode,
        carryover            = bool(carryover),
        loss_cap             = loss_cap,
        status               = MatchStatus.PENDING,
    )
    t1 = VegasTeam.objects.create(game=game, team_number=1)
    t1.players.set(team1_ids)
    t2 = VegasTeam.objects.create(game=game, team_number=2)
    t2.players.set(team2_ids)
    return game


# ---------------------------------------------------------------------------
# Score index (net digits, honouring the game's own net-double-bogey flag)
# ---------------------------------------------------------------------------

def _net_index(foursome, game) -> dict:
    """{player_id: {hole: net_score}} per the game's handicap policy, with the
    game's own net-double-bogey cap applied."""
    if game.handicap_mode != HandicapMode.STROKES_OFF:
        return build_score_index(
            foursome,
            handicap_mode=game.handicap_mode,
            net_percent=game.net_percent,
            net_double_bogey=game.net_max_double_bogey,
        )

    # Strokes-off-low: low playing handicap plays to 0; others get
    # (phcp − low) strokes on the hardest holes. Cap applied per the game flag.
    index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)
    members = list(
        foursome.memberships.select_related('player', 'tee')
        .filter(player__is_phantom=False))
    phcps = [m.playing_handicap for m in members if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0
    par_by_hole = _par_by_hole(foursome) if game.net_max_double_bogey else {}
    for m in members:
        if m.tee_id is None:
            continue
        so = round_half_up(max(0, (m.playing_handicap or 0) - low) * game.net_percent / 100)
        per_player = index.get(m.player_id)
        if not per_player:
            continue
        full, rem = so // 18, so % 18
        for hole_num, gross in list(per_player.items()):
            si = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = full + (1 if si <= rem else 0)
            value = gross - strokes
            per_player[hole_num] = _cap_value(
                value, par_by_hole.get(hole_num), game.net_max_double_bogey)
    return index


# ---------------------------------------------------------------------------
# Per-hole stroke allocation (for the leaderboard scorecard's stroke dots)
# ---------------------------------------------------------------------------

def vegas_player_hole_strokes(foursome, game) -> dict:
    """``{player_id: {hole_number: strokes}}`` — the handicap strokes each real
    player receives on each hole AS VEGAS ISSUES THEM.

    PROSPECTIVE: strokes are allocated over EVERY hole in play (play order),
    not just holes already scored, so the leaderboard scorecard can show the
    whole stroke plan up front — "you get a stroke on these holes" before the
    round is played. Mirrors ``_net_index``:

    * Gross → empty (no strokes).
    * Net (100% or custom %) → the partial-round-aware allocation from the
      effective handicap (same allocator ``build_score_index`` uses).
    * Strokes-Off-Low → the low playing handicap plays to 0; everyone else
      gets ``round((phcp − low) × net% / 100)`` strokes on the hardest holes
      (SI ≤ remainder), identical to ``_net_index``'s SO branch.

    The net-double-bogey cap is deliberately NOT applied here — it adjusts a
    blow-up hole's score, not the count of handicap strokes the dots represent.
    """
    if game.handicap_mode == HandicapMode.GROSS:
        return {}

    from services.hole_plan import play_order
    order = play_order(foursome.round, foursome) or list(range(1, 19))

    members = list(
        foursome.memberships.select_related('player', 'tee')
        .filter(player__is_phantom=False))

    out: dict = {}

    if game.handicap_mode != HandicapMode.STROKES_OFF:
        strokes_fn = make_strokes_fn(foursome)
        for m in members:
            if m.tee_id is None:
                continue
            eff = effective_hcp_for(m, game.net_percent)
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
        so = round_half_up(max(0, (m.playing_handicap or 0) - low) * game.net_percent / 100)
        if so <= 0:
            continue
        full, rem = so // 18, so % 18
        for h in order:
            si = m.tee.hole(h).get('stroke_index', 18)
            s = full + (1 if si <= rem else 0)
            if s > 0:
                out.setdefault(m.player_id, {})[h] = s
    return out


# ---------------------------------------------------------------------------
# Engine helpers
# ---------------------------------------------------------------------------

def _team_number(net_a: int, net_b: int) -> int:
    """Two net scores → the team's 2-digit number (low = tens, high = ones),
    each digit capped at 9 so the number stays two digits."""
    a, b = min(net_a, 9), min(net_b, 9)
    lo, hi = (a, b) if a <= b else (b, a)
    return lo * 10 + hi


def _flip(num: int) -> int:
    """Reverse a 2-digit team number (high digit becomes the tens)."""
    return (num % 10) * 10 + (num // 10)


def _best_under(gross_index, par_by_hole, player_ids, hole) -> int:
    """How far under par a side's BEST ball was on [hole], or 0.

    Module-level because the score-entry card has to ask the same question
    the calculator does — whether a side birdied — and a second copy of this
    would be a second opinion about whether a flip happened.
    """
    par = par_by_hole.get(hole)
    if par is None:
        return 0
    best = 0
    for pid in player_ids:
        gross = gross_index.get(pid, {}).get(hole)
        if gross is not None and (par - gross) > best:
            best = par - gross
    return best


# ---------------------------------------------------------------------------
# Calculate
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_vegas(foursome) -> list:
    """Recompute VegasHoleResult rows for the foursome's game. Idempotent."""
    try:
        game = foursome.vegas_game
    except VegasGame.DoesNotExist:
        return []

    teams = {t.team_number: list(t.players.values_list('id', flat=True))
             for t in game.teams.all()}
    t1_ids, t2_ids = teams.get(1, []), teams.get(2, [])

    VegasHoleResult.objects.filter(game=game).delete()

    # Need exactly two players per team to form a number.
    if len(t1_ids) != 2 or len(t2_ids) != 2:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    net_index   = _net_index(foursome, game)
    gross_index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)
    par_by_hole = _par_by_hole(foursome)

    rows = []
    carry = 0
    scored = 0
    # **PLAY ORDER, not hole number.** A carried tie passes to the NEXT HOLE
    # PLAYED, and on a shotgun those are different sequences: a group starting
    # on 13 that ties the 18th carries into the 1st, while a 1..18 loop reaches
    # 18 last and drops the carry on the floor. The summary has always ordered
    # its chips by play order — this is the half that decides the money.
    from services.hole_plan import play_order
    for hole in (play_order(foursome.round, foursome) or list(range(1, 19))):
        n1a = net_index.get(t1_ids[0], {}).get(hole)
        n1b = net_index.get(t1_ids[1], {}).get(hole)
        n2a = net_index.get(t2_ids[0], {}).get(hole)
        n2b = net_index.get(t2_ids[1], {}).get(hole)
        if None in (n1a, n1b, n2a, n2b):
            continue  # hole not fully scored yet
        scored += 1

        num1 = _team_number(n1a, n1b)
        num2 = _team_number(n2a, n2b)
        # The 9 cap: a net of 10 or worse becomes a 9 digit, so a 10 and a 4
        # is 49 rather than 410. Recorded per side because the card names the
        # cap on the hole it held — the one place `49` reads as a ten.
        cap1 = max(n1a, n1b) > 9
        cap2 = max(n2a, n2b) > 9
        birdie1 = _best_under(gross_index, par_by_hole, t1_ids, hole) >= 1
        birdie2 = _best_under(gross_index, par_by_hole, t2_ids, hole) >= 1
        multiplier = 1
        flip1 = flip2 = False

        if game.birdie_mode == 'flip':
            # A team's birdie flips the OTHER team's number, before deciding —
            # but they **CANCEL**: when both sides go under par, nothing
            # flips. `_best_under >= 1` is the gate, so an eagle is a birdie
            # for this rule and two eagles cancel exactly as two birdies do
            # (Paul, 8 Nov 2026).
            #
            # Paul, 8 Nov 2026, settling the question
            # `~/Downloads/handoff-vegas-score-entry` asks. This engine used
            # to apply each flip independently, which is a different outcome
            # rather than a wash: 35 against 38 with birdies both ways became
            # 53 against 83, turning a 3-point hole into a 30-point one. The
            # published guide's own reasoning for the old rule — "it usually
            # leaves the hole roughly where it started, which is the point,
            # you matched them" — is only true when the two sides happen to
            # have the same digit spread, and cancelling gets there directly.
            if birdie1 != birdie2:
                if birdie1:
                    num2 = _flip(num2)
                    flip2 = True
                else:
                    num1 = _flip(num1)
                    flip1 = True

        if num1 < num2:
            winner, diff = 'team1', num2 - num1
            if game.birdie_mode == 'multiplier':
                multiplier = 1 + _best_under(gross_index, par_by_hole, t1_ids, hole)
        elif num2 < num1:
            winner, diff = 'team2', num1 - num2
            if game.birdie_mode == 'multiplier':
                multiplier = 1 + _best_under(gross_index, par_by_hole, t2_ids, hole)
        else:
            winner, diff = 'halved', 0

        if winner == 'halved':
            if game.carryover:
                carry += 1
            rows.append(VegasHoleResult(
                game=game, hole_number=hole, team1_number=num1,
                team2_number=num2, winner='halved', points=0,
                multiplier=1, carry_count=carry,
                team1_flipped=flip1, team2_flipped=flip2,
                team1_capped=cap1, team2_capped=cap2))
        else:
            carry_mult = (carry + 1) if game.carryover else 1
            points = diff * multiplier * carry_mult
            rows.append(VegasHoleResult(
                game=game, hole_number=hole, team1_number=num1,
                team2_number=num2, winner=winner, points=points,
                multiplier=multiplier, carry_count=carry,
                team1_flipped=flip1, team2_flipped=flip2,
                team1_capped=cap1, team2_capped=cap2))
            carry = 0

    if rows:
        VegasHoleResult.objects.bulk_create(rows)

    game.status = (MatchStatus.PENDING if scored == 0
                   else MatchStatus.COMPLETE if scored >= 18
                   else MatchStatus.IN_PROGRESS)
    game.save(update_fields=['status'])
    return rows


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def vegas_summary(foursome) -> dict:
    """JSON-serialisable summary for the leaderboard / game screen."""
    bet_unit = float(foursome.round.bet_unit)
    try:
        game = foursome.vegas_game
    except VegasGame.DoesNotExist:
        # Empty/pending → mirror the mobile casual default (Strokes-Off Low) so
        # the setup screen lands there for a fresh game.
        return {
            'status': 'pending',
            'handicap': {'mode': HandicapMode.STROKES_OFF, 'net_percent': 100},
            'net_max_double_bogey': True,
            'birdie_mode': 'flip',
            'carryover': False,
            'teams': [],
            'holes': [],
            'money': {'bet_unit': bet_unit, 'loss_cap': None},
        }

    team_objs = {t.team_number: t for t in game.teams.prefetch_related('players')}

    def team_players(n):
        t = team_objs.get(n)
        if not t:
            return []
        return [{'player_id': p.id, 'name': p.name, 'short_name': p.short_name}
                for p in t.players.all()]

    holes = list(game.hole_results.all())
    t1_points = sum(h.points for h in holes if h.winner == 'team1')
    t2_points = sum(h.points for h in holes if h.winner == 'team2')

    # 1-to-1 per player: each player's money = the point differential × bet_unit.
    # Encode that via vs_average by feeding each player 2× their team total, then
    # let wager.settle apply the per-side (per-player) loss cap, zero-sum.
    money_by_team = {1: 0.0, 2: 0.0}
    p1, p2 = team_players(1), team_players(2)
    if (p1 and p2) and (t1_points or t2_points):
        sides = {}
        for pl in p1:
            sides[pl['player_id']] = 2 * t1_points
        for pl in p2:
            sides[pl['player_id']] = 2 * t2_points
        cfg = wager.WagerConfig(
            funding='per_point', settlement='vs_average',
            rate=Decimal(str(bet_unit)),
            cap=game.loss_cap,
        )
        settled = wager.settle(sides, cfg)
        # Players on a team settle to the same amount; read one per team.
        money_by_team[1] = float(settled.get(p1[0]['player_id'], 0))
        money_by_team[2] = float(settled.get(p2[0]['player_id'], 0))

    teams_out = [
        {'team_number': 1, 'players': p1, 'points': t1_points,
         'money': money_by_team[1]},
        {'team_number': 2, 'players': p2, 'points': t2_points,
         'money': money_by_team[2]},
    ]
    holes_out = [
        {'hole': h.hole_number, 'team1_number': h.team1_number,
         'team2_number': h.team2_number, 'winner': h.winner,
         'points': h.points, 'multiplier': h.multiplier,
         'carry': h.carry_count,
         'team1_flipped': h.team1_flipped, 'team2_flipped': h.team2_flipped,
         'team1_capped': h.team1_capped, 'team2_capped': h.team2_capped}
        for h in holes
    ]
    # Order the per-hole chips by PLAY ORDER (14,15,…,18,1) rather than hole
    # number — Vegas is a chronological betting log, not a scorecard, so it reads
    # in the order the holes were played. Also puts the current hole last, so the
    # grid's scroll-to-end lands there.
    from services.hole_plan import play_order
    order = play_order(foursome.round, foursome) or list(range(1, 19))
    _pos = {h: i for i, h in enumerate(order)}
    holes_out.sort(key=lambda e: _pos.get(e['hole'], 999))

    # ── Scorecard grid ────────────────────────────────────────────────────
    # Vegas is a digit game with no scorecard of its own, so a strokes-off /
    # net player couldn't otherwise see where their handicap strokes fall.
    # Emit a play-order grid (par + stroke index + per-player gross + strokes)
    # so the leaderboard can render the SAME dots+Index scorecard the other
    # games show. Strokes are PROSPECTIVE (every hole in play) so the plan is
    # visible before the holes are played; the winning team's cells tint per
    # hole once scored.
    from scoring.models import HoleScore
    real_members = [
        m for m in foursome.memberships.select_related('player', 'tee').all()
        if not m.player.is_phantom
    ]
    team_of = {}
    for tnum, tobj in team_objs.items():
        for p in tobj.players.all():
            team_of[p.id] = tnum
    sample_tee = next((m.tee for m in real_members if m.tee_id is not None), None)
    par_by_hole, si_by_hole = {}, {}
    if sample_tee is not None:
        for h in order:
            hd = sample_tee.hole(h)
            par_by_hole[h] = hd.get('par')
            si_by_hole[h]  = hd.get('stroke_index')
    gross_by = {}
    for hs in HoleScore.objects.filter(
        foursome=foursome, player_id__in=[m.player_id for m in real_members]
    ).exclude(gross_score=None).values('player_id', 'hole_number', 'gross_score'):
        gross_by[(hs['player_id'], hs['hole_number'])] = hs['gross_score']
    strokes_by = vegas_player_hole_strokes(foursome, game)
    winner_by_hole = {
        h.hole_number: (1 if h.winner == 'team1' else 2 if h.winner == 'team2' else None)
        for h in holes
    }
    scorecard_players = [
        {'player_id': m.player_id, 'name': m.player.name,
         'short_name': m.player.short_name, 'team': team_of.get(m.player_id)}
        for m in real_members
    ]
    scorecard_holes = [
        {
            'hole'         : hn,
            'par'          : par_by_hole.get(hn),
            'stroke_index' : si_by_hole.get(hn),
            'winner_id'    : None,
            'winner_team'  : winner_by_hole.get(hn),
            'scores'       : [
                {'player_id': m.player_id,
                 'gross'    : gross_by.get((m.player_id, hn)),
                 'strokes'  : strokes_by.get(m.player_id, {}).get(hn, 0)}
                for m in real_members
            ],
        }
        for hn in order
    ]

    return {
        'status': game.status,
        'handicap': {'mode': game.handicap_mode, 'net_percent': game.net_percent},
        'net_max_double_bogey': game.net_max_double_bogey,
        'birdie_mode': game.birdie_mode,
        'carryover': game.carryover,
        'teams': teams_out,
        'holes': holes_out,
        'scorecard': {
            'players'      : scorecard_players,
            'holes'        : scorecard_holes,
            'holes_in_play': order,
        },
        # The per-side round cap. Surfaced because a frozen money figure with
        # no explanation beside it is the one way the lock-screen card could
        # mislead — a pair 212 points down is not tracking the arithmetic.
        'money': {'bet_unit': bet_unit,
                  'loss_cap': (float(game.loss_cap)
                               if game.loss_cap is not None else None)},
    }


# ---------------------------------------------------------------------------
# Score-entry card — `~/Downloads/handoff-vegas-score-entry`
# ---------------------------------------------------------------------------

def vegas_hole_card(foursome, hole: int) -> dict:
    """Everything the Las Vegas score-entry screen draws for ONE hole.

    **It renders the engine.**  The handoff lists three rules to confirm, and
    this is what `calculate_vegas` does with them:

    * **Both sides under par CANCELS**, so nothing flips (Paul, 8 Nov 2026).
      An eagle is a birdie for this rule, so two eagles cancel too. The card
      says so in `note`, because a group that went under par both ways and
      saw no flip would otherwise think the app had missed one.
    * **Carries stack.**  A second tie makes the next decided hole ×3.
    * **The 9 cap is applied before the flip**, inside `_team_number` — which
      is what the reference does too.

    Two numbers, deliberately:

    * `raw` is the side's two nets as a number, which is what the golfer
      card's header tag shows while the hole fills up.  Computable from the
      nets alone, through the engine's own `_team_number`.
    * `number` is the STORED result, after any flip.  Only the engine knows
      it, because only the engine knows whose birdie it was.

    Returns `{}` when the game is not set up, so a caller can test the key.
    Gated on the GAME, not its status, which stays `pending` until a hole is
    fully scored — no card means no keypad, the failure Points, Rabbit, Sixes
    and Wolf each hit in turn.
    """
    from services.hole_plan import play_order
    from services.player_labels import first_names
    from scoring.models import HoleScore

    try:
        game = foursome.vegas_game
    except VegasGame.DoesNotExist:
        return {}

    teams = {t.team_number: t for t in game.teams.prefetch_related('players')}
    members = [m for m in foursome.memberships.select_related('player', 'tee')
               if not m.player.is_phantom]
    # **In MEMBERSHIP order**, which is the order the names appear on the
    # card above the tray. `VegasTeam.players` is a many-to-many and comes
    # back in whatever order the database gives, so `Paul + Dave` could read
    # either way round against a card listing them the other — the same trap
    # Sixes' anchor fell into when it took a side's first golfer out of a set.
    rank = {m.player_id: i for i, m in enumerate(members)}
    side_ids = {n: sorted((p.id for p in t.players.all()),
                          key=lambda pid: rank.get(pid, 99))
                for n, t in teams.items()}
    if len(side_ids.get(1, [])) != 2 or len(side_ids.get(2, [])) != 2:
        return {}

    order = play_order(foursome.round, foursome) or list(range(1, 19))
    if hole not in order:
        return {}
    pos = order.index(hole)
    by_pid = {m.player_id: m.player for m in members}
    label = first_names(by_pid)
    side_of = {pid: n for n, ids in side_ids.items() for pid in ids}

    net_index  = _net_index(foursome, game)
    strokes_by = vegas_player_hole_strokes(foursome, game)
    gross_by = {
        r['player_id']: r['gross_score']
        for r in (HoleScore.objects
                  .filter(foursome=foursome, hole_number=hole,
                          player_id__in=list(by_pid))
                  .exclude(gross_score=None)
                  .values('player_id', 'gross_score'))
    }

    summary  = vegas_summary(foursome)
    per_hole = {h['hole']: h for h in (summary.get('holes') or [])}
    entry    = per_hole.get(hole) or {}

    tee = next((m.tee for m in members if m.tee_id), None)
    geometry = tee.hole(hole) if tee else {}

    # Rows in SIDE order — side 1's two golfers, then side 2's — which is the
    # order the card above the tray draws them in, so the two read together.
    rows = []
    for n in (1, 2):
        for pid in side_ids[n]:
            m = next((x for x in members if x.player_id == pid), None)
            rows.append({
                'player_id'      : pid,
                'name'           : by_pid[pid].name,
                'short'          : by_pid[pid].short_name,
                'first'          : label.get(pid, ''),
                'course_handicap': m.course_handicap if m else None,
                'strokes'        : strokes_by.get(pid, {}).get(hole, 0),
                'gross'          : gross_by.get(pid),
                'net'            : net_index.get(pid, {}).get(hole),
                'side'           : n,
            })

    hole_complete = all(r['gross'] is not None for r in rows)
    winner = entry.get('winner')

    sides = []
    for n in (1, 2):
        nets = [net_index.get(pid, {}).get(hole) for pid in side_ids[n]]
        whole = all(x is not None for x in nets)
        raw = _team_number(nets[0], nets[1]) if whole else None
        stored = entry.get(f'team{n}_number')
        result = None
        if winner == 'halved':
            result = 'tied'
        elif winner in ('team1', 'team2'):
            result = 'won' if winner == f'team{n}' else 'lost'
        sides.append({
            'side'      : n,
            'label'     : ' + '.join(label.get(pid, '') for pid in side_ids[n]),
            'player_ids': list(side_ids[n]),
            'nets'      : [x for x in nets if x is not None] if whole else [],
            'raw'       : raw,
            'number'    : stored if stored is not None else raw,
            'flipped'   : bool(entry.get(f'team{n}_flipped')),
            'capped'    : bool(entry.get(f'team{n}_capped')),
            'result'    : result,
        })

    # Points **through this hole** — never the round's totals, which is what
    # `summary['teams']` carries and what put a golfer on the 2nd at the
    # 18th's figure on Points' tray.
    def _totals(upto_pos):
        t1 = t2 = 0
        for h in order[:upto_pos + 1]:
            e = per_hole.get(h) or {}
            if e.get('winner') == 'team1':
                t1 += e.get('points') or 0
            elif e.get('winner') == 'team2':
                t2 += e.get('points') or 0
        return t1, t2

    t1_pts, t2_pts = _totals(pos)
    b1, b2 = _totals(pos - 1)
    before, after = b1 - b2, t1_pts - t2_pts
    bet_unit = float(foursome.round.bet_unit)

    # Money through this hole, through the same arithmetic `vegas_summary`
    # uses: feed each golfer twice his side's points so the vs-average
    # baseline is the other side, then let the game's own loss cap apply — so
    # a capped round settles in the tray exactly as it does on the board.
    money1 = money2 = 0.0
    if t1_pts or t2_pts:
        cfg = wager.WagerConfig(
            funding='per_point', settlement='vs_average',
            rate=Decimal(str(bet_unit)), cap=game.loss_cap)
        sides_in = {}
        for pid in side_ids[1]:
            sides_in[pid] = 2 * t1_pts
        for pid in side_ids[2]:
            sides_in[pid] = 2 * t2_pts
        settled = wager.settle(sides_in, cfg)
        money1 = float(settled.get(side_ids[1][0], 0))
        money2 = float(settled.get(side_ids[2][0], 0))

    hole_points = entry.get('points') or 0
    swing = {1: 0, 2: 0}
    if winner == 'team1':
        swing = {1: hole_points, 2: -hole_points}
    elif winner == 'team2':
        swing = {1: -hole_points, 2: hole_points}

    standing = sorted(
        ({'side'       : n,
          'label'      : sides[n - 1]['label'],
          'hole_points': swing[n],
          'points'     : (t1_pts - t2_pts) if n == 1 else (t2_pts - t1_pts),
          'money'      : money1 if n == 1 else money2}
         for n in (1, 2)),
        key=lambda s: -s['points'])

    # What this hole was worth, and what a tie makes the next one worth.
    carry_in = entry.get('carry') or 0
    bits = []
    tie_note = ''
    if winner in ('team1', 'team2'):
        mult = (carry_in + 1) if game.carryover else 1
        if mult > 1:
            bits.append(f'×{mult} carried')
        if (entry.get('multiplier') or 1) > 1:
            bits.append(f"×{entry['multiplier']} birdie")
    if winner == 'halved':
        nxt = order[pos + 1] if pos + 1 < len(order) else None
        if not game.carryover:
            tie_note = 'no points'
        elif carry_in <= 1:
            tie_note = (f'hole {nxt} doubles' if nxt
                        else 'nothing left to carry into')
        else:
            tie_note = (f'hole {nxt} pays ×{carry_in + 1}' if nxt
                        else 'nothing left to carry into')

    # **The cancel**, which is a thing that HAPPENED and leaves no other
    # mark: both flips are suppressed, so without this a group that went
    # under par on both sides and saw no flip would think the app had missed
    # one. The test is the calculator's own `_best_under`, not a second
    # reading of the same scores.
    #
    # It names the RULE rather than the shot — `both under par` covers an
    # eagle against a birdie and two eagles, which cancel exactly as two
    # birdies do and which `birdies cancelled` would have described wrongly.
    if game.birdie_mode == 'flip' and hole_complete:
        par_by_hole = _par_by_hole(foursome)
        gross_index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)
        if all(_best_under(gross_index, par_by_hole, side_ids[n], hole) >= 1
               for n in (1, 2)):
            bits.append('both under par — no flip')
    note = ' · '.join(bits)

    round_over = hole_complete and pos == len(order) - 1
    winner_box = None
    if round_over and standing:
        top = standing[0]
        winner_box = {
            'side'   : top['side'],
            'label'  : top['label'],
            'points' : top['points'],
            'money'  : top['money'],
            'stake'  : bet_unit,
            'level'  : top['points'] == 0,
        }

    return {
        'hole'        : hole,
        'par'         : geometry.get('par'),
        'stroke_index': geometry.get('stroke_index'),
        'yards'       : geometry.get('yards'),
        'nine'        : 'front nine' if hole <= 9 else 'back nine',
        'thru'        : pos + 1,
        'stake'       : bet_unit,
        'carryover'   : game.carryover,
        'birdie_mode' : game.birdie_mode,
        'players'     : rows,
        'sides'       : sides,
        'winner'      : winner,
        'points'      : hole_points,
        'note'        : note,
        'tie_note'    : tie_note,
        'margin_before': before,
        'margin_after' : after,
        'standing'    : standing,
        'hole_complete': hole_complete,
        'round_over'  : round_over,
        'winner_box'  : winner_box,
        'next_hole'   : order[pos + 1] if pos + 1 < len(order) else None,
    }
