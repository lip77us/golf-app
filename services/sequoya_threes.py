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

    if game.presses.filter(match_index=match_index).exists():
        raise ValueError('This match already carries a hand-called press.')

    # **A press must be a NEW bet, not a repeat of one already running.** The
    # test is duplication, not the mere existence of an auto press: a live bet
    # that is LEVEL with exactly the holes this press would cover still to
    # play settles identically to it, and two identical bets are a double.
    #
    # A bet carrying a margin is not a twin, which is what lets the last hole
    # of a match be pressed after losing the first two — the match bet is
    # closed out and the auto press is dormie, so a fresh level bet over that
    # hole is genuinely different from both.
    covered = hi - start + 1
    for b in _bets_for_match(game, net, side1, side2, match_index, []):
        if b['result'] is None and b['margin'] == 0 and b['to_play'] == covered:
            raise ValueError(
                f"{b['label']} is level with the same holes left — a press "
                'over them would settle on exactly the same golf.')

    return SequoyaThreesPress.objects.create(
        game=game, match_index=match_index, side=side,
        called_by_id=called_by_id, start_hole=start)


def remove_press(foursome, *, match_index):
    """Take back a hand-called press. Raises ValueError with a reason.

    **Only before it has been played over.** A press is a bet: once a hole it
    covers is in the book the group has played it, and a bet that has been
    played cannot be taken back — that is a settlement question, not an undo.
    Before then it is a fat-fingered tap and should cost nothing.
    """
    game = foursome.sequoya_threes_game
    pr = game.presses.filter(match_index=match_index).first()
    if pr is None:
        raise ValueError('There is no hand-called press in this match.')

    lo, hi = MATCH_HOLES[match_index - 1]
    ids = [m.player_id for m in _real_members(foursome)]
    side1, side2 = pairing_for_match(ids, game.match1_side1, match_index)
    net = _net_by_hole(game, foursome)
    played = [h for h in range(pr.start_hole, hi + 1)
              if _hole_winner(net, side1, side2, h) is not None]
    if played:
        raise ValueError(
            f'This press is already running — hole {played[0]} has been '
            'played on it.')

    pr.delete()


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

    # Both presses can be live at once: an auto press over the tail of a
    # match and a hand-called one over the last hole of it are different
    # bets. What is refused is a DUPLICATE, and that is enforced where the
    # press is called — here every stored press is drawn.
    for pr in manual:
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
    # The same tally over EVERY bet, presses included. A press is worth the
    # same as a match, so this is the record that reconciles with the money:
    # net = (won - lost) x the stake. Counting matches alone left a golfer
    # 2-1 up and $0 richer, which reads as an arithmetic error.
    bet_record = {p: {'won': 0, 'lost': 0, 'halved': 0} for p in ids}
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
                    bet_record[p]['won'] += 1
                for p in lose:
                    nets[p] -= amount
                    bet_record[p]['lost'] += 1
            elif b['result'] == 0:
                for p in ids:
                    bet_record[p]['halved'] += 1

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
          'bet_record': bet_record[p],
          'bet_record_label':
              f"{bet_record[p]['won']}–{bet_record[p]['lost']}–"
              f"{bet_record[p]['halved']}",
          'partners': [{'player_id': q, 'name': names[q], **v}
                       for q, v in partners[p].items()]}
         for p in ids),
        # Money, not matches won: a match carrying three bets is worth three
        # flat ones, and a board that disagrees with settlement is worthless.
        # Ties break on the BET record — the one the money is made of — then
        # name.
        key=lambda e: (-e['money'], -e['bet_record']['won'], e['name']))

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
        # A match can carry the match bet, an auto press and one called by
        # hand — three, but only because none of them repeats another. Two
        # level bets over one set of holes are refused at the call.
        'exposure'     : {
            'no_presses' : round(MATCH_COUNT * amount, 2),
            'with_auto'  : round(MATCH_COUNT * amount * 2, 2),
            'ceiling'    : round(MATCH_COUNT * amount * {
                SequoyaThreesGame.PRESS_NONE       : 1,
                SequoyaThreesGame.PRESS_AUTO       : 2,
                SequoyaThreesGame.PRESS_MANUAL_AUTO: 3,
            }.get(game.press_mode, 2), 2),
        },
    }


# ---------------------------------------------------------------------------
# Settlement — the nets, the fewest handovers, and one golfer's receipt
# ---------------------------------------------------------------------------
#
# **Nets are real; pairwise debts are not.** The stake is a man a match, so
# two losers owe twenty and two winners are owed ten each — and nothing in the
# format says WHICH winner a given ten dollars belongs to. So the payments
# below the nets are presented as what they are: the shortest way to make four
# numbers true, never a record of who beat whom.
#
# This reads `sequoya_threes_summary` and recomputes no money, for the same
# reason the tournament receipt reads settlement: the screen and the message
# must not be able to disagree with the board.

def _close_out(bet):
    """`2 & 1` when a bet was decided early, else None.

    Read off the hole it CLOSED ON. In this game the holes after a close-out
    are usually still played — a press is running over them — so the margin
    keeps moving and `to_play` falls to zero.
    """
    closed = bet.get('closed_on')
    if closed is None:
        return None
    holes = bet.get('holes') or []
    try:
        left = len(holes) - holes.index(closed) - 1
    except ValueError:
        return None
    # The margin crosses the holes left by exactly one.
    return f'{left + 1} & {left}' if left > 0 else None


def _bet_phrase(bet, my_side):
    """One bet from a given golfer's side: `won 2 & 1`, `your press halved`."""
    kind   = bet['kind']
    result = bet.get('result')
    noun = {'match': '', 'auto_press': 'auto press ',
            'manual_press': 'press '}.get(kind, '')
    if result is None:
        return f'{noun}in play'.strip()
    if result == 0:
        return f'{noun}halved'.strip() if noun else 'halved'
    won = (result == my_side)
    margin = abs(bet.get('margin') or 0)
    if kind == 'match':
        shape = _close_out(bet) or (f'{margin} up' if won else f'{margin} down')
        return f"{'won' if won else 'lost'} {shape}"
    return f"{noun}{'won' if won else 'lost'}".strip()


def _fmt_money(v):
    if not v:
        return '$0'
    return f"{'+' if v > 0 else '−'}${abs(v):,.0f}"


def sequoya_threes_settlement(foursome) -> dict | None:
    """Everything the settle-up screen and the receipts need."""
    summary = sequoya_threes_summary(foursome)
    if not summary:
        return None

    matches = summary['matches']
    amount  = summary['bet_amount']
    card    = summary['scorecard']
    names   = {p['player_id']: p['name']       for p in card['players']}
    short   = {p['player_id']: p['short_name'] for p in card['players']}
    ids     = [p['player_id'] for p in card['players']]

    gross = {p: 0 for p in ids}
    for h in card['holes']:
        for e in h['scores']:
            if e['gross'] is not None:
                gross[e['player_id']] += e['gross']

    # Per golfer, per match: what the match did to him and who he had.
    per_match  = {p: [] for p in ids}
    partner_money = {p: {} for p in ids}
    manual_out = {p: [] for p in ids}
    n_auto = n_manual = n_halved = n_bets = 0

    for m in matches:
        s1 = [e['player_id'] for e in m['side1']]
        s2 = [e['player_id'] for e in m['side2']]
        for b in m['bets']:
            n_bets += 1
            if b['kind'] == 'auto_press':
                n_auto += 1
            elif b['kind'] == 'manual_press':
                n_manual += 1
            if b.get('result') == 0:
                n_halved += 1

        for pid in ids:
            my_side = 1 if pid in s1 else 2
            mine, theirs = (s1, s2) if my_side == 1 else (s2, s1)
            partner = next(q for q in mine if q != pid)
            money = 0.0
            for b in m['bets']:
                if b.get('result') in (1, 2):
                    money += amount if b['result'] == my_side else -amount
            money = round(money, 2)
            partner_money[pid][partner] = round(
                partner_money[pid].get(partner, 0.0) + money, 2)
            per_match[pid].append({
                'index'      : m['index'],
                'holes'      : f"holes {m['start_hole']}–{m['end_hole']}",
                'partner'    : short[partner],
                'opponents'  : ' & '.join(short[q] for q in theirs),
                'line'       : ', '.join(_bet_phrase(b, my_side)
                                         for b in m['bets']),
                'bet_count'  : len(m['bets']),
                'money'      : money,
            })

            # Hand-called presses are itemised: they are a DECISION, and the
            # dispute in this format is nearly always about one. An auto press
            # has no author and no decision in it, so it stays a second bet on
            # the match line.
            for b in m['bets']:
                if b['kind'] != 'manual_press':
                    continue
                caller = b.get('called_by')
                if caller and caller == names[pid]:
                    by = 'you'
                elif caller:
                    by = caller
                else:
                    # No author recorded — the scorer called it for the pair
                    # that was down, which is the usual case on one phone.
                    # Name the PAIR rather than "the trailing side": a press
                    # nobody is named on defeats the point of listing it.
                    pressing = s1 if b.get('called_side') == 1 else s2
                    by = ' & '.join(short[q] for q in pressing)
                lo = (b.get('holes') or [None])[0]
                manual_out[pid].append({
                    'match_index': m['index'],
                    'hole'       : lo,
                    'called_by'  : caller,
                    'line'       : f"Called by {by} — ${amount:,.0f} on "
                                   f"{'hole ' + str(lo) if len(b['holes']) == 1 else 'holes %s–%s' % (b['holes'][0], b['holes'][-1])}"
                                   f", {_bet_phrase(b, 1 if pid in s1 else 2)}",
                })

    by_pid = {p['player_id']: p for p in summary['players']}
    players = []
    for pid in ids:
        best = max(partner_money[pid].items(), key=lambda kv: kv[1], default=None)
        players.append({
            'player_id'   : pid,
            'name'        : names[pid],
            'short_name'  : short[pid],
            'money'       : by_pid[pid]['money'],
            'record_label': by_pid[pid]['bet_record_label'],
            'gross'       : gross[pid] or None,
            'best_partner': short[best[0]] if best else None,
        })

    transfers = summary['transfers']

    def owed_line(pid):
        me = by_pid[pid]['money']
        if me > 0:
            payers = [t for t in transfers if t['to_name'] == names[pid]]
            if not payers:
                return 'Nobody owes you anything.'
            return ' '.join(
                f"{t['from_name']} owes you ${t['amount']:,.0f}." for t in payers)
        if me < 0:
            owed = [t for t in transfers if t['from_name'] == names[pid]]
            return ' '.join(
                f"You owe {t['to_name']} ${t['amount']:,.0f}." for t in owed) \
                or 'You owe nothing.'
        return 'You are square.'

    receipts = [{
        'player_id'     : pid,
        'name'          : names[pid],
        'short_name'    : short[pid],
        'money'         : by_pid[pid]['money'],
        'owed_line'     : owed_line(pid),
        'matches'       : per_match[pid],
        'manual_presses': manual_out[pid],
        'text'          : _receipt_text(names[pid], by_pid[pid]['money'],
                                        owed_line(pid), amount),
    } for pid in ids]

    return {
        'status'    : summary['status'],
        'bet_amount': amount,
        'handicap'  : summary['handicap'],
        'press_mode': summary['press_mode'],
        'headline'  : _headline(n_bets, n_auto, n_manual, n_halved),
        'players'   : players,
        'transfers' : transfers,
        # Four numbers that sum to zero is the whole assertion; if they ever
        # did not, nothing below is worth showing.
        'balances'  : abs(sum(p['money'] for p in players)) < 0.005,
        'receipts'  : receipts,
        'group_text': _group_text(names, players, transfers, amount),
    }


def _headline(n_bets, n_auto, n_manual, n_halved):
    bits = [f'{n_bets} bet{"" if n_bets == 1 else "s"}']
    if n_auto:
        bits.append(f'{n_auto} auto press{"" if n_auto == 1 else "es"}')
    if n_manual:
        bits.append(f'{n_manual} called by hand')
    if n_halved:
        bits.append(f'{n_halved} halved')
    return ('Six matches of three holes, best ball. '
            + ', '.join(bits) + '.')


def _group_text(names, players, transfers, amount):
    """Plain text for the group thread: the nets, then the shortest clear.

    Label, en dash, amount — no columns and no six match lines. Nobody needs
    a scorecard in a text message; they need what they owe.
    """
    lines = [f'Sequoya 3s — ${amount:,.0f} a man, every bet', '']
    lines += [f"{p['name']} — {_fmt_money(p['money'])}" for p in players]
    if transfers:
        lines.append('')
        lines += [f"{t['from_name']} pays {t['to_name']} ${t['amount']:,.0f}"
                  for t in transfers]
    return '\n'.join(lines)


def _receipt_text(name, money, owed, amount):
    return '\n'.join([
        f'Sequoya 3s — {name}',
        f'Net {_fmt_money(money)}',
        owed,
        f'${amount:,.0f} a man, every bet. Presses are separate bets, '
        'never a doubling.',
    ])
