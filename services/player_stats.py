"""Your stats — what scoring already records, shown back to the golfer.

Finished CASUAL rounds only (the home card's rule): a shared-ball game has no
personal score and a round under nine holes is skipped. One pass builds a row
per round; everything the screen shows is a fold over those rows, so the
filters (window / course / game) cannot disagree with the totals.
"""
from collections import Counter, defaultdict

SHARED_BALL = {'triple_cup', 'scramble'}


def _round_rows(account, player):
    from services import settlement
    from scoring.models import HoleScore
    from tournament.models import Round

    rounds = (
        Round.objects.for_account(account)
        .filter(tournament__isnull=True, status='complete',
                foursomes__memberships__player=player)
        .select_related('course')
        .prefetch_related('foursomes__memberships__player')
        .distinct().order_by('-date', '-created_at'))
    rows = []
    for r in rounds:
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
        holes = []
        for s in scores:
            par = (tee.hole(s.hole_number) or {}).get('par') or 0
            if par:
                holes.append({'n': s.hole_number, 'par': par, 'gross': s.gross_score})
        if not holes:
            continue
        gross = sum(h['gross'] for h in holes)
        par = sum(h['par'] for h in holes)
        net = sum((s.net_score if s.net_score is not None else s.gross_score)
                  for s in scores)
        try:
            sett = settlement.round_settlement(r, min_games=1)
        except Exception:
            sett = None
        others = [x.player for x in fs.memberships.all()
                  if x.player_id != player.id and not x.player.is_phantom]
        rows.append({
            'round': r, 'holes': holes, 'gross': gross, 'par': par,
            'net_to_par': net - par, 'full': len(holes) >= 17,
            'sett': sett, 'others': others, 'staked': bool(r.bet_unit),
            'games': list(r.active_games or []),
            'primary': r.primary_game,
        })
    return rows


def _fmt(n):
    return 'E' if n == 0 else f'{n:+.1f}'.replace('+0.0', 'E')


def player_stats(account, player, *, window='20', course_id=None, game=None):
    from services.settlement import _LABELS

    allrows = _round_rows(account, player)
    courses = {}
    for r in allrows:
        courses.setdefault(r['round'].course_id, r['round'].course.name)
    played = sorted({g for r in allrows for g in r['games']})

    rows = allrows
    if course_id:
        rows = [r for r in rows if r['round'].course_id == course_id]
    if game:
        rows = [r for r in rows if game in r['games']]
    if window == 'year':
        import datetime
        y = datetime.date.today().year
        rows = [r for r in rows if r['round'].date.year == y]
    elif window == '20':
        rows = rows[:20]

    out = {'count': len(rows), 'filters': {
        'courses': [{'id': k, 'name': v} for k, v in sorted(courses.items(), key=lambda x: x[1])],
        'games': [{'id': g, 'name': _LABELS.get(g, g)} for g in played],
    }}
    if not rows:
        return out

    holes = [h for r in rows for h in r['holes']]
    mix = Counter()
    for h in holes:
        d = h['gross'] - h['par']
        mix['eagle' if d <= -2 else 'birdie' if d == -1 else 'par' if d == 0
            else 'bogey' if d == 1 else 'double'] += 1
    total = len(holes)
    full = [r for r in rows if r['full']]
    by_par = {}
    for p in (3, 4, 5):
        hs = [h['gross'] - h['par'] for h in holes if h['par'] == p]
        by_par[str(p)] = round(sum(hs) / len(hs), 1) if hs else None
    best = min(full, key=lambda r: r['gross']) if full else None
    out['scoring'] = {
        'avg_gross': round(sum(r['gross'] for r in full) / len(full), 1) if full else None,
        'best_gross': best['gross'] if best else None,
        'avg_net_to_par': round(sum(r['net_to_par'] for r in rows) / len(rows), 1),
        'birdies': mix['birdie'] + mix['eagle'],
        'birdies_per_round': round((mix['birdie'] + mix['eagle']) / len(rows), 1),
        'mix': {k: round(100 * mix[k] / total, 1)
                for k in ('eagle', 'birdie', 'par', 'bogey', 'double')},
        'par_avg': by_par,
    }

    # Money by game (rounds with a stake only).
    money = defaultdict(lambda: {'rounds': 0, 'won': 0, 'net': 0.0})
    for r in rows:
        if not r['staked'] or not r['sett']:
            continue
        for g in r['sett']['per_game']:
            v = (g['nets'] or {}).get(player.id)
            if v is None:
                continue
            e = money[g['game']]
            e['rounds'] += 1
            e['net'] += v
            e['won'] += 1 if v > 0 else 0
    games = [{'game': g, 'label': _LABELS.get(g, g), 'rounds': e['rounds'],
              'won': e['won'], 'net': round(e['net'], 2)}
             for g, e in money.items()]
    games.sort(key=lambda e: -abs(e['net']))
    out['money'] = {'total': round(sum(e['net'] for e in games), 2), 'games': games}

    # The Money card: the same stake-only rounds, read four ways.
    money_rows = []   # (row, my_net) oldest -> newest
    for r in reversed(rows):
        if not r['staked'] or not r['sett']:
            continue
        mine = next((p['net'] for p in r['sett']['players']
                     if p['player_id'] == player.id), None)
        if mine is None:
            continue
        money_rows.append((r, mine))
    run, series = 0.0, []
    for _r, m in money_rows:
        run += m
        series.append(round(run, 2))
    by_partner, by_opponent, by_course = {}, {}, {}
    for r, m in money_rows:
        by_course.setdefault(r['round'].course.name, [0.0, 0])
        by_course[r['round'].course.name][0] += m
        by_course[r['round'].course.name][1] += 1
        for o in r['others']:
            e = by_partner.setdefault(o.name, [0.0, 0])
            e[0] += m
            e[1] += 1
        names = {o.id: o.name for o in r['others']}
        for t in r['sett']['transfers']:
            if t['from'] == player.id:
                other, amt = names.get(t['to'], t['to_name']), -t['amount']
            elif t['to'] == player.id:
                other, amt = names.get(t['from'], t['from_name']), t['amount']
            else:
                continue
            e = by_opponent.setdefault(other, [0.0, 0])
            e[0] += amt
            e[1] += 1

    def _items(d):
        out_ = [{'name': k, 'net': round(v[0], 2), 'rounds': v[1]}
                for k, v in d.items()]
        out_.sort(key=lambda e: -abs(e['net']))
        return out_

    out['money'].update({
        'series': series,
        'record': {'won': sum(1 for _r, m in money_rows if m > 0),
                   'lost': sum(1 for _r, m in money_rows if m < 0)},
        'views': {
            'game': [{'name': g['label'], 'net': g['net'], 'rounds': g['rounds']}
                     for g in games],
            'partner': _items(by_partner),
            'opponent': _items(by_opponent),
            'course': _items(by_course),
        },
    })

    # Who you play — rounds together, how you do on net, money between you.
    pals = {}
    for r in rows:
        for o in r['others']:
            e = pals.setdefault(o.id, {'name': o.name, 'rounds': 0, 'beat': 0, 'money': 0.0})
            e['rounds'] += 1
            sett = r['sett']
            if sett:
                for t in sett['transfers']:
                    if t['from'] == player.id and t['to'] == o.id:
                        e['money'] -= t['amount']
                    elif t['to'] == player.id and t['from'] == o.id:
                        e['money'] += t['amount']
                nets = {p['player_id']: p['net'] for p in sett['players']}
                if nets.get(player.id, 0) > nets.get(o.id, 0):
                    e['beat'] += 1
    people = sorted(pals.items(), key=lambda kv: -kv[1]['rounds'])[:5]
    out['people'] = [{'player_id': k, 'name': e['name'], 'rounds': e['rounds'],
                      'beat': e['beat'], 'money': round(e['money'], 2)}
                     for k, e in people if e['rounds'] >= 2]

    # Courses and holes.
    by_course = defaultdict(list)
    for r in rows:
        by_course[r['round'].course_id].append(r)
    cs = []
    for cid, rs in by_course.items():
        per_hole = defaultdict(list)
        for r in rs:
            for h in r['holes']:
                per_hole[h['n']].append(h['gross'] - h['par'])
        avgs = {n: sum(v) / len(v) for n, v in per_hole.items() if len(v) >= 2}
        fulls = [r for r in rs if r['full']]
        cs.append({
            'course_id': cid, 'name': courses.get(cid, ''), 'rounds': len(rs),
            'avg_gross': round(sum(r['gross'] for r in fulls) / len(fulls), 1) if fulls else None,
            'best_hole': (lambda n: {'hole': n, 'avg': round(avgs[n], 1)})(min(avgs, key=avgs.get)) if avgs else None,
            'worst_hole': (lambda n: {'hole': n, 'avg': round(avgs[n], 1)})(max(avgs, key=avgs.get)) if avgs else None,
        })
    cs.sort(key=lambda c: -c['rounds'])
    out['courses'] = cs
    return out


def profile_summary(account, player):
    from tournament.models import Round
    rs = Round.objects.for_account(account).filter(
        status='complete', foursomes__memberships__player=player).distinct()
    first = rs.order_by('date').values_list('date', flat=True).first()
    return {'rounds': rs.count(), 'since': first.year if first else None}
