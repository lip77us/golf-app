"""
services/sequoya_threes.py
--------------------------
Sequoya 3s — six three-hole 2v2 best-ball matches
(docs/design-review/handoff-sequoya-threes/README.md).

Four golfers, holes 1-3, 4-6, 7-9, 10-12, 13-15, 16-18. Each match is its own
bet at the same stake, and each may carry presses.

**The rotation is derived, not chosen.** Four golfers split 2v2 in exactly
three ways and there is no fourth, so the group sets match 1 and everything
after it follows: matches 2 and 3 are the other two pairings, and 4-6 repeat
1-3 in order. That repeat is the format — it is what makes every golfer partner
every other exactly twice.

**A press is a NEW BET at the same amount, never a doubling.** It runs over the
holes remaining and settles on its own, which is why a press can be halved
while the match is won, or won by the side that lost the match. Doubling a
wager already lost is a donation nobody would tap.

**Nothing is stored but the config, match 1's pairing and hand-called
presses.** Every bet's result is computed from one net-score table, because a
press over holes 5-6 and the match over 4-6 are decided by the same three holes
and must never be able to contradict each other.
"""
from decimal import Decimal

from core.models import HandicapMode
from games.models import SequoyaThreesGame, SequoyaThreesPress
from scoring.handicap import effective_hcp_for, make_strokes_fn
from services.hole_plan import play_order
from scoring.models import HoleScore

# Six matches, three holes each, fixed. The boundaries are what the whole
# format hangs off — a sudden-death extra hole would break them.
MATCH_HOLES = [(1, 3), (4, 6), (7, 9), (10, 12), (13, 15), (16, 18)]
MATCH_COUNT = len(MATCH_HOLES)


# ---------------------------------------------------------------------------
# The rotation
# ---------------------------------------------------------------------------

def pairings(player_ids, match1_side1) -> list:
    """The three pairings, in rotation order, as ``[(side1, side2), …]``.

    Anchored on one golfer: he partners each of the other three once, which
    enumerates all three splits and fixes their order. Match 1 is whichever of
    those the group chose; the remaining two follow in the roster's own order,
    so the rotation is stable across recalculation.
    """
    ids = list(player_ids)
    if len(ids) != 4:
        return []

    chosen = [p for p in ids if p in set(match1_side1 or [])]
    if len(chosen) != 2:
        chosen = ids[:2]                      # ungathered setup — take the first pair

    anchor = chosen[0]
    partner_first = chosen[1]
    others = [p for p in ids if p not in (anchor, partner_first)]

    order = [partner_first] + others          # who the anchor is with, per match
    out = []
    for mate in order:
        side1 = [anchor, mate]
        side2 = [p for p in ids if p not in side1]
        out.append((side1, side2))
    return out


def pairing_for_match(player_ids, match1_side1, match_index):
    """Match 1-6 -> ``(side1, side2)``. 4-6 repeat 1-3, hence the modulo."""
    rot = pairings(player_ids, match1_side1)
    if not rot:
        return [], []
    return rot[(match_index - 1) % len(rot)]


def match_of_hole(hole: int):
    """1-6, or None for a hole outside the six matches."""
    for i, (lo, hi) in enumerate(MATCH_HOLES, start=1):
        if lo <= hole <= hi:
            return i
    return None


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

def _real_members(foursome):
    return [m for m in foursome.memberships.select_related('player', 'tee').all()
            if not m.player.is_phantom]


def setup_sequoya_threes(foursome, side1_ids, *,
                         handicap_mode=HandicapMode.STROKES_OFF,
                         net_percent=100, bet_amount=5,
                         press_mode=SequoyaThreesGame.PRESS_AUTO):
    """Create or update the game. Only match 1's pairing is taken."""
    game, _ = SequoyaThreesGame.objects.update_or_create(
        foursome=foursome,
        defaults={
            'handicap_mode': handicap_mode,
            'net_percent'  : net_percent,
            'bet_amount'   : Decimal(str(bet_amount)),
            'press_mode'   : press_mode,
            'match1_side1' : list(side1_ids or []),
        },
    )
    # Drop the caller's cached relation. Django caches a reverse OneToOne on
    # the instance, so a summary taken from the SAME foursome object right
    # after a re-setup would read the previous configuration — press mode and
    # all — and silently score the round under settings nobody chose.
    foursome._state.fields_cache.pop('sequoya_threes_game', None)
    return game


def auto_press_holes(game, net, side1, side2, match_index):
    """The holes an auto press covers in this match, or None if none opened.

    Derived, never stored — and derived in ONE place, because the rule that
    a hand-called press cannot sit on top of an auto press is only true if
    both agree on whether one exists.
    """
    if game.press_mode == SequoyaThreesGame.PRESS_NONE:
        return None
    lo, hi = MATCH_HOLES[match_index - 1]
    # The first hole of the match being WON (not halved) opens a second bet
    # over the holes that remain.
    if _hole_winner(net, side1, side2, lo) not in (1, 2):
        return None
    rest = list(range(lo + 1, hi + 1))
    return rest or None


def press_start_hole(net, side1, side2, match_index, current_hole):
    """The first hole a press called from ``current_hole`` would cover.

    **A press is called on the tee, so it covers the hole being played.** That
    is what lets the LAST hole of a match be pressed — on the 9th tee, two
    holes down, a press over the 9th alone is the whole point of pressing.

    The exception is a hole already in the book: a press must never be able to
    cover a result somebody has seen, so from a scored hole it starts on the
    next one. Returns None when nothing is left in the match.
    """
    lo, hi = MATCH_HOLES[match_index - 1]
    start = max(current_hole, lo)
    if _hole_winner(net, side1, side2, start) is not None:
        start += 1                      # that hole is played; press the next
    return start if start <= hi else None


def call_press(foursome, *, match_index, side, called_by_id, current_hole):
    """Record a hand-called press. Raises ValueError with a reason if refused.

    It covers the hole being played (see :func:`press_start_hole`), and only
    the trailing side may call — both are rules the offer card states, and
    both are enforced here rather than only in the UI, so they hold however
    the call arrives.
    """
    game = foursome.sequoya_threes_game
    if game.press_mode != SequoyaThreesGame.PRESS_MANUAL_AUTO:
        raise ValueError('This round is not playing hand-called presses.')

    lo, hi = MATCH_HOLES[match_index - 1]
    if not (lo <= current_hole <= hi):
        raise ValueError('That hole is not in this match.')

    ids = [m.player_id for m in _real_members(foursome)]
    side1, side2 = pairing_for_match(ids, game.match1_side1, match_index)
    net = _net_by_hole(game, foursome)

    start = press_start_hole(net, side1, side2, match_index, current_hole)
    if start is None:
        raise ValueError('No holes left in this match for a press to cover.')

    # Whoever is down over the holes ALREADY decided — the press covers the
    # rest, so the holes it covers cannot count towards who may call it.
    margin = 0
    for h in range(lo, start):
        w = _hole_winner(net, side1, side2, h)
        if w == 1:
            margin += 1
        elif w == 2:
            margin -= 1
    if margin == 0:
        raise ValueError('The match is all square — only the side that is '
                         'down may press.')
    trailing = 2 if margin > 0 else 1
    if side != trailing:
        raise ValueError('Only the side that is down may press.')

    # A match carries ONE press. Which bet a second one would merely repeat
    # changes as the match runs — on the second hole it is the auto press,
    # on the last hole of a level match it is the match bet itself — so the
    # refusal states the rule rather than guessing at the twin. The screen,
    # which knows the margins, names it.
    if auto_press_holes(game, net, side1, side2, match_index) is not None:
        raise ValueError('This match already carries its press — the auto '
                         'press. A match carries one, not two.')

    if game.presses.filter(match_index=match_index).exists():
        raise ValueError('This match already carries a hand-called press.')

    return SequoyaThreesPress.objects.create(
        game=game, match_index=match_index, side=side,
        called_by_id=called_by_id, start_hole=start)


# ---------------------------------------------------------------------------
# Scoring — one net table, every bet computed from it
# ---------------------------------------------------------------------------

def _effective_hcps(game, members):
    """``{pid: effective handicap}`` under the game's own handicap setting."""
    npct  = game.net_percent or 100
    phcps = [m.playing_handicap for m in members
             if m.playing_handicap is not None]
    low   = min(phcps) if phcps else 0

    out = {}
    for m in members:
        if game.handicap_mode == HandicapMode.STROKES_OFF:
            from core.handicap_math import round_half_up
            out[m.player_id] = int(round_half_up(
                max(0, (m.playing_handicap or 0) - low) * npct / 100))
        else:
            out[m.player_id] = effective_hcp_for(m, npct)
    return out


def strokes_by_hole(game, foursome, holes):
    """``{pid: {hole: strokes}}`` over EVERY hole, played or not.

    The allocation is a fact about the card and the handicap, so it is known
    before a ball is struck — which is what lets the scorecard show the whole
    stroke plan up front rather than revealing it one played hole at a time.
    """
    members = [m for m in _real_members(foursome) if m.tee_id is not None]
    if game.handicap_mode == HandicapMode.GROSS:
        return {m.player_id: {} for m in members}
    strokes = make_strokes_fn(foursome)
    eff     = _effective_hcps(game, members)
    return {
        m.player_id: {h: strokes(eff[m.player_id], m.tee, h) for h in holes}
        for m in members
    }


def _net_by_hole(game, foursome):
    """``{pid: {hole: net}}`` under the game's own handicap setting.

    **Full course allocation by stroke index**, never spread across the six
    matches. A stroke falls where the card says it falls, whichever match that
    lands in — the matches are not equally hard and normalising them would be
    the larger distortion.
    """
    members = [m for m in _real_members(foursome) if m.tee_id is not None]
    gross = {}
    for hs in HoleScore.objects.filter(
            foursome=foursome, gross_score__isnull=False):
        gross.setdefault(hs.player_id, {})[hs.hole_number] = hs.gross_score

    if game.handicap_mode == HandicapMode.GROSS:
        return {m.player_id: dict(gross.get(m.player_id, {})) for m in members}

    strokes = make_strokes_fn(foursome)
    eff     = _effective_hcps(game, members)

    out = {}
    for m in members:
        per = {}
        for hole, g in (gross.get(m.player_id) or {}).items():
            per[hole] = g - strokes(eff[m.player_id], m.tee, hole)
        out[m.player_id] = per
    return out


def _hole_winner(net, side1, side2, hole):
    """Best net per pair; lower wins, equal halves. None when unscored."""
    a = [net.get(p, {}).get(hole) for p in side1]
    b = [net.get(p, {}).get(hole) for p in side2]
    if any(v is None for v in a + b):
        return None
    lo_a, lo_b = min(a), min(b)
    if lo_a < lo_b:
        return 1
    if lo_b < lo_a:
        return 2
    return 0            # halved


def _settle_bet(net, side1, side2, holes):
    """One bet over ``holes``.

    Returns ``{'result', 'margin', 'closed_on', 'played', 'to_play'}``.
    `result` is 1 / 2 / 0 (halved) / None (still live).

    A bet closes early the moment a side is up by MORE than the holes left in
    that bet — which is a per-bet fact, so a press closes on its own holes and
    not the match's.
    """
    margin = 0
    played = 0
    closed_on = None
    for i, h in enumerate(holes):
        w = _hole_winner(net, side1, side2, h)
        if w is None:
            break
        played += 1
        if w == 1:
            margin += 1
        elif w == 2:
            margin -= 1
        if closed_on is None and abs(margin) > len(holes) - (i + 1):
            closed_on = h

    to_play = len(holes) - played
    if closed_on is not None:
        result = 1 if margin > 0 else 2
    elif played == len(holes):
        result = 0 if margin == 0 else (1 if margin > 0 else 2)
    else:
        result = None
    return {'result': result, 'margin': margin, 'closed_on': closed_on,
            'played': played, 'to_play': to_play}


def _bets_for_match(game, net, side1, side2, match_index, manual):
    """Every bet in one match: the match bet, the auto press, the called one.

    Each is settled over its OWN holes. A press can be halved while the match
    is won, or won by the side that lost it — both normal, and neither may be
    folded into a match total.
    """
    lo, hi = MATCH_HOLES[match_index - 1]
    holes  = list(range(lo, hi + 1))
    amount = float(game.bet_amount)

    bets = [{
        'kind'   : 'match',
        'label'  : f'Match {match_index}',
        'holes'  : holes,
        'amount' : amount,
        **_settle_bet(net, side1, side2, holes),
    }]

    auto = auto_press_holes(game, net, side1, side2, match_index)
    if auto:
        bets.append({
            'kind'   : 'auto_press',
            'label'  : 'Auto press',
            'holes'  : auto,
            'amount' : amount,
            'opened_by_side': _hole_winner(net, side1, side2, lo),
            **_settle_bet(net, side1, side2, auto),
        })

    # A stored hand-called press is IGNORED while an auto press is running.
    # The rule is that the two never coexist, and this module derives rather
    # than stores, so it has to hold of the summary however the row got
    # there — including a round that predates the rule, and a round where an
    # edited first hole opens the auto press after the fact.
    for pr in (manual if auto is None else []):
        rest = [h for h in holes if h >= pr.start_hole]
        if not rest:
            continue
        bets.append({
            'kind'      : 'manual_press',
            'label'     : 'Press',
            'holes'     : rest,
            'amount'    : amount,
            'called_by' : pr.called_by.name if pr.called_by else None,
            'called_side': pr.side,
            **_settle_bet(net, side1, side2, rest),
        })
    return bets


# ---------------------------------------------------------------------------
# The summary
# ---------------------------------------------------------------------------

def _scorecard(foursome, game, net, ids, members, match1_side1):
    """The Sixes-style grid: gross + stroke dots per golfer per hole.

    **The side tint is per HOLE, not per golfer.** In every other team game a
    golfer is on one side all round, so the grid reads the side off the player
    row. Here the pairing rotates every third hole, so the side rides on each
    SCORE — `team` beside the gross — and the shared widget prefers it when
    it is there.
    """
    order  = play_order(foursome.round, foursome)
    by_pid = {m.player_id: m.player for m in members}

    sample_tee = next((m.tee for m in members if m.tee_id is not None), None)
    par_by_hole, si_by_hole = {}, {}
    if sample_tee is not None:
        for h in order:
            par_by_hole[h] = sample_tee.hole(h).get('par')
            si_by_hole[h]  = sample_tee.hole(h).get('stroke_index')

    gross = {}
    for hs in HoleScore.objects.filter(
            foursome=foursome, gross_score__isnull=False):
        gross.setdefault(hs.player_id, {})[hs.hole_number] = hs.gross_score

    # The whole stroke plan, including holes nobody has played. Inferring it
    # from gross - net would show a stroke only once the hole was in the book,
    # so a golfer could not see where his strokes fall until he no longer
    # needed to know.
    alloc = strokes_by_hole(game, foursome, order)

    holes_out = []
    for hole in order:
        idx = match_of_hole(hole)
        if idx is None:
            continue                       # outside the six matches
        side1, side2 = pairing_for_match(ids, match1_side1, idx)
        side_of = {p: 1 for p in side1} | {p: 2 for p in side2}
        winner  = _hole_winner(net, side1, side2, hole)
        scores  = []
        for pid in ids:
            scores.append({
                'player_id': pid,
                'gross'    : gross.get(pid, {}).get(hole),
                'strokes'  : alloc.get(pid, {}).get(hole, 0),
                # Which side this golfer is on FOR THIS HOLE.
                'team'     : side_of.get(pid),
            })
        holes_out.append({
            'hole'        : hole,
            'match'       : idx,
            'par'         : par_by_hole.get(hole),
            'stroke_index': si_by_hole.get(hole),
            # 0 (halved) and None (unplayed) both mean nobody is tinted.
            'winner_team' : winner if winner in (1, 2) else None,
            'scores'      : scores,
        })

    return {
        'players': [
            {'player_id': pid, 'name': by_pid[pid].name,
             'short_name': by_pid[pid].short_name}
            for pid in ids
        ],
        'holes'        : holes_out,
        'holes_in_play': [h for h in order if match_of_hole(h) is not None],
    }


def _transfers(nets, names):
    """The fewest handovers that clear four nets.

    **Nothing in the format assigns a loser's money to a specific winner** —
    only the four nets are real, so payments are derived here rather than
    recorded per bet. For four golfers that settles in two handovers.
    """
    owe  = sorted(((p, -v) for p, v in nets.items() if v < 0),
                  key=lambda e: -e[1])
    due  = sorted(((p, v) for p, v in nets.items() if v > 0),
                  key=lambda e: -e[1])
    out, i, j = [], 0, 0
    while i < len(owe) and j < len(due):
        (fp, fv), (tp, tv) = owe[i], due[j]
        amt = round(min(fv, tv), 2)
        if amt > 0:
            out.append({'from': fp, 'from_name': names.get(fp, ''),
                        'to': tp, 'to_name': names.get(tp, ''),
                        'amount': amt})
        owe[i] = (fp, round(fv - amt, 2))
        due[j] = (tp, round(tv - amt, 2))
        if owe[i][1] <= 0.001:
            i += 1
        if due[j][1] <= 0.001:
            j += 1
    return out


def sequoya_threes_summary(foursome) -> dict | None:
    """Everything the play screen, leaderboard, settlement and card need."""
    try:
        game = foursome.sequoya_threes_game
    except SequoyaThreesGame.DoesNotExist:
        return None

    members = _real_members(foursome)
    if len(members) != 4:
        return None

    ids   = [m.player_id for m in members]
    names = {m.player_id: m.player.name for m in members}
    short = {m.player_id: m.player.short_name for m in members}

    net     = _net_by_hole(game, foursome)
    manual  = list(game.presses.all())
    amount  = float(game.bet_amount)

    nets    = {p: 0.0 for p in ids}
    matches = []
    record  = {p: {'won': 0, 'lost': 0, 'halved': 0} for p in ids}
    partners = {p: {} for p in ids}

    for idx in range(1, MATCH_COUNT + 1):
        side1, side2 = pairing_for_match(ids, game.match1_side1, idx)
        bets = _bets_for_match(
            game, net, side1, side2, idx,
            [pr for pr in manual if pr.match_index == idx])

        for b in bets:
            if b['result'] in (1, 2):
                win, lose = (side1, side2) if b['result'] == 1 else (side2, side1)
                for p in win:
                    nets[p] += amount
                for p in lose:
                    nets[p] -= amount

        head = bets[0]
        if head['result'] in (1, 2):
            win, lose = (side1, side2) if head['result'] == 1 else (side2, side1)
            for p in win:
                record[p]['won'] += 1
            for p in lose:
                record[p]['lost'] += 1
        elif head['result'] == 0:
            for p in ids:
                record[p]['halved'] += 1

        # Every golfer partners every other exactly twice — the one question
        # this format generates that no other in the app can answer.
        for a, b_ in ((side1[0], side1[1]), (side2[0], side2[1])):
            for x, y in ((a, b_), (b_, a)):
                e = partners[x].setdefault(y, {'with': 0, 'money': 0.0})
                e['with'] += 1

        lo, hi = MATCH_HOLES[idx - 1]
        matches.append({
            'index'      : idx,
            'start_hole' : lo,
            'end_hole'   : hi,
            'side1'      : [{'player_id': p, 'name': names[p],
                             'short_name': short[p]} for p in side1],
            'side2'      : [{'player_id': p, 'name': names[p],
                             'short_name': short[p]} for p in side2],
            'bets'       : bets,
            'bet_count'  : len(bets),
            'at_risk'    : round(len(bets) * amount, 2),
        })

    nets = {p: round(v, 2) for p, v in nets.items()}
    players = sorted(
        ({'player_id': p, 'name': names[p], 'short_name': short[p],
          'money': nets[p], 'record': record[p],
          'record_label': f"{record[p]['won']}–{record[p]['lost']}–"
                          f"{record[p]['halved']}",
          'partners': [{'player_id': q, 'name': names[q], **v}
                       for q, v in partners[p].items()]}
         for p in ids),
        # Money, not matches won: a match carrying three bets is worth three
        # flat ones, and a board that disagrees with settlement is worthless.
        # Ties break on match record, then name.
        key=lambda e: (-e['money'], -e['record']['won'], e['name']))

    live_bets = sum(1 for m in matches for b in m['bets']
                    if b['result'] is None)
    return {
        'status'       : game.status,
        'handicap'     : {'mode': game.handicap_mode,
                          'net_percent': game.net_percent},
        'press_mode'   : game.press_mode,
        'bet_amount'   : amount,
        'matches'      : matches,
        'players'      : players,
        'scorecard'    : _scorecard(foursome, game, net, ids, members,
                                    game.match1_side1),
        'transfers'    : _transfers(nets, names),
        'live_bets'    : live_bets,
        # What the round could still cost, printed on setup and in the footer.
        #
        # **A match carries at most TWO bets**, never three: an auto press and
        # a hand-called one cannot coexist — the auto press already covers the
        # rest of the match, so a second bet over the same holes would be a
        # double, not a press. So the ceiling with presses on is 2x, whichever
        # press mode is chosen.
        'exposure'     : {
            'no_presses' : round(MATCH_COUNT * amount, 2),
            'with_auto'  : round(MATCH_COUNT * amount * 2, 2),
            'ceiling'    : round(
                MATCH_COUNT * amount
                * (1 if game.press_mode == SequoyaThreesGame.PRESS_NONE else 2),
                2),
        },
    }
