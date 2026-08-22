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


def shamble_hole(foursome, hole_number: int, counts: dict) -> dict:
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

    rows = []
    for m in members:
        gross = scores.get(m.player_id)
        strokes = _strokes_on_hole(m.playing_handicap, si)
        rows.append({
            'player_id'  : m.player_id,
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
        by_hole   = {h: {'gross': g} for h, g in scores.items()}
        gross     = sum(scores.values()) if scores else None
        allowance = (state.team_handicap if state and state.team_handicap
                     is not None else 0)
        thru      = len(scores)
        net       = None if gross is None else gross - allowance
    else:
        counts  = resolved_counts(foursome, config)
        by_hole = {}
        gross_total = net_total = 0
        thru = 0
        for n in sorted(counts):
            hole = shamble_hole(foursome, n, counts)
            if hole['team_net'] is None:
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

    return {
        'gross'     : gross,
        'net'       : net,
        'allowance' : allowance,
        'thru'      : thru,
        'complete'  : thru == len(holes) and thru > 0,
        'par'       : par,
        'penalty'   : penalty,
        'by_hole'   : by_hole,
    }


# ---------------------------------------------------------------------------
# 3. The board
# ---------------------------------------------------------------------------

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
        team.update(team_round(foursome, config))
        rows.append(team)

    # Rank the teams that have a score. A team with nothing entered sits at the
    # bottom unranked rather than tying for first at zero.
    scored = [r for r in rows if r['net'] is not None]
    scored.sort(key=lambda r: (r['net'], r['gross']))

    rank = 0
    previous = None
    for i, row in enumerate(scored, start=1):
        if row['net'] != previous:
            rank = i
            previous = row['net']
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
