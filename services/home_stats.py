"""The home screen's "Your last 5 rounds" card.

Finished CASUAL rounds only, the rule home-course and game selection already
use. A round with a shared ball (Triple Cup, scramble) has no personal score
and is skipped, as is a round the golfer did not finish at least nine holes of.
"""
from collections import Counter

from django.db.models import Q

SHARED_BALL = {'triple_cup', 'scramble'}


def _fmt(n):
    return 'E' if n == 0 else f'{n:+d}'


def last_rounds(account, player, limit=5):
    from services import settlement
    from scoring.models import HoleScore
    from tournament.models import FoursomeMembership, Round

    rounds = (
        Round.objects.for_account(account)
        .filter(tournament__isnull=True, status='complete',
                foursomes__memberships__player=player)
        .select_related('course')
        .prefetch_related('foursomes__memberships')
        .distinct().order_by('-date', '-created_at')
    )
    out = []
    for r in rounds:
        if len(out) >= limit:
            break
        if SHARED_BALL & set(r.active_games or []):
            continue
        fs = next((f for f in r.foursomes.all()
                   if any(m.player_id == player.id for m in f.memberships.all())), None)
        if fs is None:
            continue
        m = next(m for m in fs.memberships.all() if m.player_id == player.id)
        scores = list(HoleScore.objects.filter(
            foursome=fs, player=player, gross_score__isnull=False))
        if len(scores) < 9:
            continue
        tee = m.tee
        par = sum((tee.hole(s.hole_number) or {}).get('par') or 0 for s in scores)
        net = sum((s.net_score if s.net_score is not None else s.gross_score)
                  for s in scores)
        birdies = [s.hole_number for s in scores
                   if (tee.hole(s.hole_number) or {}).get('par')
                   and s.gross_score < tee.hole(s.hole_number)['par']]
        money = settlement.player_round_net(
            r, player.id, foursomes=list(r.foursomes.all()))
        out.append({
            'round_id': r.id, 'date': str(r.date), 'course': r.course.name,
            'holes': len(scores), 'net_to_par': net - par,
            'money': money, 'birdie_holes': birdies,
            'staked': bool(r.bet_unit),
        })
    return out


def _fact(rows, n):
    facts = []
    holes = Counter(h for r in rows for h in r['birdie_holes'])
    if holes:
        h, c = holes.most_common(1)[0]
        if c >= 2:
            facts.append(f'Your most-birdied hole lately: {h} ({c} birdies).')
    wins = sum(1 for r in rows if r['money'] and r['money'] > 0)
    if wins >= 2:
        facts.append(f'You finished up in {wins} of your last {len(rows)}.')
    if len(rows) >= 3:
        d = [r['net_to_par'] for r in rows]  # newest first
        if d[0] < d[1] < d[2] or d[0] <= min(d):
            facts.append('Your latest round is your best of the last '
                         f'{len(rows)}.' if d[0] <= min(d)
                         else 'Three rounds in a row getting better.')
    return facts[n % len(facts)] if facts else ''


def home_stats(account, player, rotate=0):
    rows = last_rounds(account, player)
    if len(rows) < 2:
        return {'enough': False, 'rounds': []}
    ntp = [r['net_to_par'] for r in rows]
    best = min(rows, key=lambda r: r['net_to_par'])
    staked = any(r['staked'] and r['money'] is not None for r in rows)
    total = sum((r['money'] or 0) for r in rows) if staked else None
    return {
        'enough': True,
        # Oldest to newest, as the bars are drawn.
        'rounds': [{'date': r['date'], 'net_to_par': r['net_to_par'],
                    'label': _fmt(r['net_to_par']),
                    'best': r is best} for r in reversed(rows)],
        'avg_net': round(sum(ntp) / len(ntp), 1),
        'best': {'label': _fmt(best['net_to_par']), 'date': best['date']},
        'money': None if total is None else round(total, 2),
        'won': sum(1 for r in rows if r['money'] and r['money'] > 0),
        'count': len(rows),
        'index': str(player.handicap_index),
        'fact': _fact(rows, rotate),
    }
