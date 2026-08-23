"""
services/team_play_scoring.py
-----------------------------
Team Play scoring — the two cards, the board and the pot
(docs/design-review/handoff-team-play/SPEC.md §10).

Two formats, two scorecards, and the difference reaches all the way down here:

**Scramble** — four men make ONE number.  Pretending otherwise (four boxes,
three of them ignored) is the single easiest way to get a scramble card wrong.
The team score is a :class:`games.models.TeamHoleScore` row with a null team —
the team IS the foursome, so the (foursome, hole) pair is unambiguous — and the
handicap is one whole-number team figure applied to the ROUND, not a stroke on
a hole.

**Shamble** — four men play four balls and the best N net count.  Ordinary
per-golfer ``HoleScore`` rows; the counting subset is DERIVED on read and never
stored, because the ball count can be edited right up until the first score
lands and a stored subset would go stale silently.

Net on the board, gross on the card.  A whole-number team figure applied to the
round is not a stroke on a hole, and showing it on the card would invite
subtracting it per hole.
"""

from decimal import Decimal

from django.db import transaction

from scoring.handicap import _strokes_on_hole
from services.payout import payouts_by_place, split_tied_places, split_to_cents
from services.team_play import drive_penalty_strokes
from services.team_play_state import (
    _phantom_membership, _real_memberships, drive_picks, hole_data,
    resolved_counts, team_dict,
)


# ---------------------------------------------------------------------------
# 1. The card
# ---------------------------------------------------------------------------

@transaction.atomic
def submit_team_score(foursome, hole_number: int, gross_score):
    """
    A scramble hole: one number for the ball the team played.

    Stamps the tournament's format lock on the first score — a one-number card
    cannot be re-read as four, and a hole scored under 'best 2' cannot be
    re-read as 'best 1'.
    """
    from django.utils import timezone
    from games.models import TeamHoleScore

    if gross_score in (None, ''):
        TeamHoleScore.objects.filter(
            foursome=foursome, team=None, hole_number=hole_number).delete()
    else:
        TeamHoleScore.objects.update_or_create(
            foursome=foursome, team=None, hole_number=hole_number,
            defaults={'gross_score': int(gross_score)},
        )
        config = getattr(foursome.round.tournament, 'team_play_config', None)
        if config is not None and not config.is_locked:
            config.format_locked_at = timezone.now()
            config.save(update_fields=['format_locked_at'])


def team_hole_scores(foursome) -> dict:
    """``{hole_number: gross}`` for a scramble team."""
    from games.models import TeamHoleScore
    return {
        r.hole_number: r.gross_score
        for r in TeamHoleScore.objects.filter(foursome=foursome, team=None)
        if r.gross_score is not None
    }


def shamble_hole(foursome, hole_number: int, counts: dict,
                 config) -> dict:
    """
    One shamble hole: four scores, and which of them counted.

    The counting scores are tinted and the rest greyed, live, as they are
    entered — because two men's cards do nothing on a given hole, and a man who
    shot 5 needs to see instantly that his 5 was not used.  Otherwise the team
    total looks wrong and someone re-enters it.

    The phantom's ball is one of the four available.  Nothing about the count
    changes for a short team; that is the point of handicapping it as four.
    """
    from scoring.models import HoleScore

    holes  = {h['number']: h for h in hole_data(foursome)}
    hole   = holes.get(hole_number, {})
    si     = hole.get('stroke_index', hole_number)
    n      = counts.get(hole_number, 2)

    members = _real_memberships(foursome)
    phantom = _phantom_membership(foursome)
    if phantom is not None:
        members = members + [phantom]

    scores = {
        s.player_id: s.gross_score
        for s in HoleScore.objects.filter(foursome=foursome, hole_number=hole_number)
        if s.gross_score is not None
    }

    # Each golfer plays off HIS OWN course handicap at the format's allowance —
    # 85% at two balls, 75% at one, 95% at three — not off the membership's
    # playing_handicap, which for a Foursome Play round is the untouched course
    # handicap because the round itself never carries an allowance. Using it
    # handed everybody 100% and quietly inflated every net score on the board.
    from services.team_handicap import player_shamble_handicap
    from services.team_play_state import allowance_label

    gross_only = config.handicap_mode == 'gross'
    pct = allowance_label(foursome, config).get('pct') or 100

    rows = []
    for m in members:
        gross = scores.get(m.player_id)
        handicap = 0 if gross_only else player_shamble_handicap(
            m.course_handicap, pct)
        strokes = _strokes_on_hole(handicap, si)
        rows.append({
            'player_id'  : m.player_id,
            # The golfer's figure for the ROUND — what "gets N" means on every
            # other card. Which holes carry one is the dots' job.
            'handicap'   : handicap,
            'name'       : 'Phantom 4th' if m.player.is_phantom else m.player.name,
            'is_phantom' : m.player.is_phantom,
            'gross'      : gross,
            'strokes'    : strokes,
            'net'        : None if gross is None else gross - strokes,
            'counts'     : False,
        })

    # The two lowest NET count. The rest are recorded and ignored.
    scored = sorted((r for r in rows if r['net'] is not None),
                    key=lambda r: (r['net'], r['gross']))
    for r in scored[:n]:
        r['counts'] = True

    counted = [r['net'] for r in rows if r['counts']]
    return {
        'hole_number' : hole_number,
        'par'         : hole.get('par'),
        'stroke_index': si,
        'count'       : n,
        'rows'        : rows,
        'complete'    : len(scored) >= len(rows),
        'team_net'    : sum(counted) if len(counted) == n else None,
    }


# ---------------------------------------------------------------------------
# 2. The team's round
# ---------------------------------------------------------------------------

def team_round(foursome, config) -> dict:
    """
    A team's gross, net and progress — the row the leaderboard draws.

    A scramble's net is ``gross − team allowance``, taken once off the round
    total.  A shamble's net is the sum of the counting nets, hole by hole,
    because its handicap never stopped being per golfer.
    """
    state   = getattr(foursome, 'team_play_state', None)
    holes   = hole_data(foursome)
    par     = sum(h.get('par', 0) for h in holes)

    if config.is_scramble:
        scores    = team_hole_scores(foursome)
        allowance = (state.team_handicap if state and state.team_handicap
                     is not None else 0)
        si_map    = {h['number']: h.get('stroke_index', h['number'])
                     for h in holes}

        # Net is summed PER HOLE, not `gross − allowance`.
        #
        # Taking the whole allowance off a part round credits strokes on holes
        # the team has not reached: thru 7 of an 18-hole 10-stroke allowance it
        # has actually received about 5, and deducting 10 flattered every
        # unfinished team on the board and in the card's own summary. At 18
        # holes the two agree exactly, which is why it went unnoticed.
        by_hole = {}
        for h, g in scores.items():
            st = _strokes_on_hole(allowance, si_map.get(h, h))
            by_hole[h] = {'gross': g, 'net': g - st, 'strokes': st}

        gross = sum(scores.values()) if scores else None
        thru  = len(scores)
        net   = (sum(v['net'] for v in by_hole.values())
                 if by_hole else None)
    else:
        counts  = resolved_counts(foursome, config)
        by_hole = {}
        gross_total = net_total = 0
        thru = 0
        for n in sorted(counts):
            hole = shamble_hole(foursome, n, counts, config)
            # A hole counts once EVERY ball is in, not once enough are in to
            # make a "best two". Two of four already satisfies a best-2, so the
            # old check read a part-scored hole as finished: the board showed
            # the team further round than it was, the net moved when the other
            # two landed, and a round of half-scored holes could reach "signed
            # for 18" — which is what gates settlement.
            #
            # (A golfer who withdraws mid-round therefore stalls his team's
            # count. Mid-round withdrawal is not wired into this shape yet;
            # see docs/mid-round-withdrawal.md for how the other games do it.)
            if not hole['complete'] or hole['team_net'] is None:
                continue
            thru += 1
            counted_gross = sum(r['gross'] for r in hole['rows'] if r['counts'])
            gross_total += counted_gross
            net_total   += hole['team_net']
            by_hole[n] = {'gross': counted_gross, 'net': hole['team_net'],
                          'count': hole['count']}
        gross     = gross_total if thru else None
        net       = net_total if thru else None
        allowance = state.team_handicap if state else None

    # Two strokes per missing drive, added to the team's gross at the END of
    # the round — and only when the TD opted in.
    real_ids = [m.player_id for m in _real_memberships(foursome)]
    penalty  = drive_penalty_strokes(config, drive_picks(foursome), real_ids)
    if penalty and gross is not None:
        gross += penalty
        net   += penalty

    # Par over the holes actually PLAYED. A team thru 14 measured against the
    # full 72 would read eighteen under, which is how a leading team looks like
    # a runaway on a board where half the field is still out.
    #
    # And on a SHAMBLE par is multiplied by the ball count, because the team's
    # figure is the sum of the counting balls: best-2 on a par 4 is a par of 8,
    # not 4. Comparing a two-ball total against one hole's par put every
    # shamble team about +70 and made the column meaningless.
    par_map    = {h['number']: h.get('par', 0) for h in holes}
    if config.is_scramble:
        par_played = sum(par_map.get(n, 0) for n in by_hole)
    else:
        counts_map = resolved_counts(foursome, config)
        par_played = sum(
            par_map.get(n, 0) * counts_map.get(n, 1) for n in by_hole)

    return {
        'gross'      : gross,
        'net'        : net,
        'allowance'  : allowance,
        'thru'       : thru,
        'complete'   : thru == len(holes) and thru > 0,
        'par'        : par,
        'par_played' : par_played,
        # What the board ranks and prints: the app shows scores against par,
        # not as totals, on every other leaderboard it draws.
        'gross_to_par': None if gross is None else gross - par_played,
        'net_to_par'  : None if net   is None else net   - par_played,
        'penalty'    : penalty,
        'by_hole'    : by_hole,
    }


# ---------------------------------------------------------------------------
# 3. The board
# ---------------------------------------------------------------------------

def _board_strokes_by_hole(foursome, config, allowance) -> dict:
    """`{hole: strokes}` for the row the board draws.

    A scramble has one team figure, so the dots are the team's. A shamble keeps
    handicaps per golfer and the board row is the TEAM's counted total, so
    there is no single golfer whose dots belong on it — the entry card shows
    those, per golfer, where the question is "where do I get shots".
    """
    from scoring.handicap import _strokes_on_hole

    if not config.is_scramble or not allowance:
        return {}
    return {
        str(h['number']): _strokes_on_hole(
            allowance, h.get('stroke_index', h['number']))
        for h in hole_data(foursome)
    }


def _board_to_par_by_hole(foursome, config, rnd) -> dict:
    """`{hole: team score against par}`.

    A scramble plays one ball, so par is the hole's. A shamble's figure is the
    sum of the COUNTING balls, so par is multiplied by the count — best-2 on a
    par 4 is a par of 8.
    """
    holes   = {h['number']: h.get('par', 0) for h in hole_data(foursome)}
    by_hole = rnd.get('by_hole') or {}
    counts  = {} if config.is_scramble else resolved_counts(foursome, config)

    out = {}
    for n, v in by_hole.items():
        gross = v.get('gross')
        if gross is None:
            continue
        par = holes.get(n, 0) * (1 if config.is_scramble else counts.get(n, 1))
        out[str(n)] = gross - par
    return out


def net_to_par_by_hole(foursome, config, rnd) -> dict:
    """`{hole: net against par}` for the team's net line.

    A scramble's per-hole net is already on `by_hole`; a shamble's is the sum
    of the counting nets, and its par is multiplied by the ball count.
    """
    holes   = {h['number']: h.get('par', 0) for h in hole_data(foursome)}
    by_hole = rnd.get('by_hole') or {}
    counts  = {} if config.is_scramble else resolved_counts(foursome, config)

    out = {}
    for n, v in by_hole.items():
        net = v.get('net')
        if net is None:
            continue
        par = holes.get(n, 0) * (1 if config.is_scramble else counts.get(n, 1))
        out[str(n)] = net - par
    return out


def golfers_by_hole(foursome, config) -> list:
    """Per-golfer gross, net, strokes and counted-flag, hole by hole.

    Shamble only — a scramble has no per-golfer ball to show.
    """
    # A LIST either way. Returning {} for the scramble made the field change
    # type between formats, and the client — which casts it once — died on the
    # scramble board. Same fault as the allowance clobber: a payload key that
    # is a map on one path and a list on another.
    if config.is_scramble:
        return []

    counts = resolved_counts(foursome, config)
    names  = {
        m.player_id: (m.player.short_name or m.player.name[:5])
        for m in foursome.memberships.select_related('player')
    }
    out = {}
    for n in sorted(counts):
        for r in shamble_hole(foursome, n, counts, config)['rows']:
            entry = out.setdefault(r['player_id'], {
                'player_id' : r['player_id'],
                'name'      : r['name'],
                # The scorecard's label column is five characters wide; full
                # names wrap to two lines and turn the grid into a wall.
                'short_name': names.get(r['player_id'], r['name'][:5]),
                'is_phantom': r['is_phantom'],
                'handicap'  : r['handicap'],
                'scores'    : {},
                'counted'   : {},
                'strokes'   : {},
            })
            if r['gross'] is not None:
                entry['scores'][str(n)]  = r['gross']
                entry['counted'][str(n)] = r['counts']
            entry['strokes'][str(n)] = r['strokes']
    return list(out.values())


def leaderboard(tournament) -> dict:
    """
    Six rows, one column, sorted on net ascending.

    **Ties are marked, drawn adjacent and never silently ordered.**  The
    allowance is a whole number, so ties happen most weeks — there is no
    countback and no card-off; tied teams combine the places they occupy and
    split the money.

    **Teams still out are marked, not sorted away.**  A team leading through
    fourteen is not leading, and the board must not let that read as a result.
    """
    config = getattr(tournament, 'team_play_config', None)
    if config is None:
        return None

    round_obj = tournament.rounds.order_by('round_number').first()
    if round_obj is None:
        return None

    rows = []
    for foursome in round_obj.foursomes.order_by('group_number'):
        team = team_dict(foursome, config)
        rnd  = team_round(foursome, config)
        # `allowance` means two different things in the two dicts: the worked
        # BLOCK in team_dict (kind, pct, label) and the plain whole-number
        # figure in team_round. Merging blind replaced the block with an int
        # and the board's client blew up casting it back to a map. The figure
        # is already on the row as `team_handicap`, so drop the duplicate.
        # Keep the figure before dropping the key — the dots and the net row
        # are both allocated off it, and popping first silently produced a
        # scorecard with no strokes marked anywhere.
        allowance = rnd.get('allowance')
        rnd.pop('allowance', None)
        team.update(rnd)
        # Enough for the expanded row to draw the same scorecard the entry
        # screen draws, rather than a second, thinner grid of its own.
        holes = hole_data(foursome)
        team['pars'] = {str(h['number']): h.get('par') for h in holes}
        team['stroke_indexes'] = {
            str(h['number']): h.get('stroke_index') for h in holes}
        team['scores_by_hole'] = {
            str(n): v.get('gross') for n, v in (rnd.get('by_hole') or {}).items()}
        team['strokes_by_hole'] = _board_strokes_by_hole(
            foursome, config, allowance)
        # The net line, against par. A scramble's net is gross minus the
        # strokes that fall on THAT hole; a shamble's is the counted nets.
        team['net_to_par_by_hole'] = net_to_par_by_hole(
            foursome, config, rnd)
        # A shamble's expanded row shows all FOUR balls with the counting ones
        # marked — the team's total is two of them, and a board that shows only
        # the total cannot answer "whose scores made it".
        team['golfers_by_hole'] = golfers_by_hole(foursome, config)
        # The team's line reads against par, not as a raw total: two 5s on a
        # par 4 is +2, and "10" says nothing without doing the multiplication
        # in your head.
        team['to_par_by_hole'] = _board_to_par_by_hole(foursome, config, rnd)
        rows.append(team)

    # Rank the teams that have a score. A team with nothing entered sits at the
    # bottom unranked rather than tying for first at zero.
    #
    # Ranked on net TO PAR, not on the raw net total. The board prints to par,
    # so sorting on anything else makes it contradict its own column — and
    # while teams are still out the totals are not comparable at all: nine
    # holes of net 30 is not better than eighteen of net 70. Once everybody is
    # in, par is the same for all of them and the two orders agree, which is
    # what settlement needs.
    scored = [r for r in rows if r['net_to_par'] is not None]
    scored.sort(key=lambda r: (r['net_to_par'], r['gross_to_par'] or 0))

    rank = 0
    previous = None
    for i, row in enumerate(scored, start=1):
        if row['net_to_par'] != previous:
            rank = i
            previous = row['net_to_par']
        row['rank'] = rank
    counts = {}
    for row in scored:
        counts[row['rank']] = counts.get(row['rank'], 0) + 1
    for row in scored:
        row['tied'] = counts[row['rank']] > 1

    for row in rows:
        row.setdefault('rank', None)
        row.setdefault('tied', False)

    rows.sort(key=lambda r: (r['rank'] is None, r['rank'] or 0,
                             r['group_number']))

    all_in = bool(rows) and all(r['complete'] for r in rows)
    return {
        'format'    : config.team_format,
        'teams'     : rows,
        'all_in'    : all_in,
        # Money is a PROJECTION until every team has signed for 18 — one line
        # under the board, muted italic until then. Money on the rows would put
        # a dollar figure next to a team with four holes left.
        'projected' : not all_in,
        'pool'      : pool_summary(tournament, rows),
    }


# ---------------------------------------------------------------------------
# 4. The money
# ---------------------------------------------------------------------------

def pool_summary(tournament, rows) -> dict:
    """
    One pool, the places the TD set, and what each is worth.

    **Ties combine the places they occupy and split what those places pay** —
    a T2 pair shares 2nd AND 3rd rather than halving 2nd and leaving 3rd in the
    pot. A tie for a place that pays nothing costs nothing and is left
    unresolved.
    """
    config  = tournament.team_play_config
    golfers = sum(r['real_player_count'] for r in rows)
    pool    = round(float(config.entry_fee or 0) * golfers, 2)

    splits = list(config.split_pcts or [])
    places = {
        i + 1: round(pool * pct / 100.0, 2)
        for i, pct in enumerate(splits[:config.places_paid])
    }

    ranks = [r['rank'] for r in rows]
    per_rank = split_tied_places(places, ranks)

    return {
        'pool'    : pool,
        'golfers' : golfers,
        'entry_fee': float(config.entry_fee or 0),
        'places'  : [{'place': p, 'pct': splits[p - 1], 'amount': a}
                     for p, a in sorted(places.items())],
        'by_rank' : per_rank,
    }


def settlement(tournament) -> dict:
    """
    One pot against twenty-three golfers — one number in, three payments out
    (SPEC §10.4).

    Three rules meet here:

    * **A tie is one prize, drawn as one block with both teams inside it.**
      Two rows each reading $143.75 would hide that it was one prize.
    * **A three-man team divides its share three ways and takes more each.**
      The phantom 4th earned the strokes and cannot be paid.
    * **Odd cents go to the team's highest course handicap**, so the pool
      balances to zero rather than leaving an unexplained $71.89 beside three
      $71.87s.

    Settle is gated on every team signing for 18: money does not move while a
    score can.
    """
    board = leaderboard(tournament)
    if board is None:
        return None

    config  = tournament.team_play_config
    pool    = board['pool']
    rows    = board['teams']
    by_rank = pool['by_rank']

    # Group the tied teams so each prize is drawn once, with both teams inside.
    blocks, seen = [], set()
    for row in rows:
        rank = row['rank']
        if rank is None or rank in seen:
            continue
        seen.add(rank)
        tied = [r for r in rows if r['rank'] == rank]
        each = by_rank.get(rank, 0.0)
        places_covered = list(range(rank, rank + len(tied)))
        paying = [p for p in places_covered if p <= config.places_paid]

        team_blocks = []
        for team in tied:
            # Odd cents to the team's HIGHEST course handicap — arbitrary, but
            # stated and deterministic, and it always balances.
            payable = [m for m in team['members'] if not m['is_phantom']]
            payable.sort(key=lambda m: -m['course_handicap'])
            shares = split_to_cents(each, len(payable))
            team_blocks.append({
                'foursome_id' : team['foursome_id'],
                'name'        : team['name'],
                'colour'      : team['colour'],
                'net'         : team['net'],
                'gross'       : team['gross'],
                'ways'        : len(payable),
                'amount'      : each,
                'golfers'     : [
                    {'player_id': m['player_id'], 'name': m['name'],
                     'amount': share,
                     'odd_cents': i == 0 and len(set(shares)) > 1}
                    for i, (m, share) in enumerate(zip(payable, shares))
                ],
                'phantom'     : any(m['is_phantom'] for m in team['members']),
            })

        blocks.append({
            'rank'    : rank,
            'tied'    : len(tied) > 1,
            'places'  : places_covered,
            'paying'  : paying,
            'total'   : round(each * len(tied), 2),
            'teams'   : team_blocks,
        })

    paid_out = sum(
        g['amount'] for b in blocks for t in b['teams'] for g in t['golfers']
    )

    return {
        'pool'        : pool['pool'],
        'entry_fee'   : pool['entry_fee'],
        'golfers'     : pool['golfers'],
        'places_paid' : config.places_paid,
        'split_pcts'  : config.split_pcts or [],
        'blocks'      : blocks,
        'out_of_money': [
            {'foursome_id': r['foursome_id'], 'name': r['name'],
             'net': r['net'], 'rank': r['rank'], 'tied': r['tied'],
             'per_man': -pool['entry_fee'],
             'drive_shortfall': r['drive'].get('shortfall', 0)}
            for r in rows
            if r['rank'] is None or by_rank.get(r['rank'], 0) == 0
        ],
        'balance'     : round(pool['pool'] - paid_out, 2),
        # Money does not move while a score can.
        'can_settle'  : board['all_in'],
        'waiting_on'  : [r['name'] for r in rows if not r['complete']],
    }
