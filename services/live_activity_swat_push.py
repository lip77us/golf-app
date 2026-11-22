"""
services/live_activity_swat_push.py
-----------------------------------
SWAT's one push (`handoff-oakmont-swat` §6): **at the turn**. A team's front
nine settles against every other team at once, so that is the single moment
worth ringing a phone for — who the team beat, who beat it, and the money each.
No push per hole, and none for the phantom.

Fired once per team, on `SwatConfig.announced` (NULL = nothing pushed yet, so
the first call records what has already happened without announcing it).
Called once per posted score from `push_round`, never per recipient.
"""
from services import swat as _swat


def swat_alerts(round_obj) -> dict:
    from games.models import SwatConfig
    loaded = _swat._load(round_obj)
    if loaded is None:
        return {}
    cfg, teams, gross = loaded
    if len(teams) < 2:
        return {}
    for t in teams:
        t['holes'] = _swat._team_holes(cfg, t, gross)
    stake_c = _swat.TEAM_STAKE_FACTOR * _swat._cents(cfg.stake)

    ready = {}
    for me in teams:
        beat, lost, level, net = [], [], [], 0
        settled = True
        for opp in teams:
            if opp is me:
                continue
            front = _swat._nassau(me['holes'], opp['holes'])['bets'][0]
            if not front['done']:
                settled = False
                break
            name = opp['name'].replace('Team ', '', 1)
            if front['result'] == 'W':
                beat.append((name, front['margin'])); net += stake_c
            elif front['result'] == 'L':
                lost.append((name, -front['margin'])); net -= stake_c
            else:
                level.append(name)
        if settled:
            ready[me['foursome'].pk] = (me, beat, lost, level, net)

    if cfg.announced is None:
        cfg.announced = sorted(ready)
        cfg.save(update_fields=['announced'])
        return {}
    fresh = [k for k in ready if k not in set(cfg.announced)]
    if not fresh:
        return {}
    cfg.announced = sorted(set(cfg.announced) | set(ready))
    cfg.save(update_fields=['announced'])

    alerts = {}
    for k in fresh:
        me, beat, lost, level, net = ready[k]
        each = net / 100.0 / me['size']
        money = (f'{"+" if each > 0 else "−"}${abs(each):,.0f} each'
                 if each else 'even')
        parts = []
        if beat:
            parts.append('Beat ' + ', '.join(f'{n} by {m}' for n, m in beat))
        if lost:
            parts.append('lost to ' + ', '.join(f'{n} by {m}' for n, m in lost))
        if level:
            parts.append('halved with ' + ', '.join(level))
        body = (' · '.join(parts)).capitalize() + f'. {money} so far.'
        alert = {'title': f'Front nine: {len(beat)} won, {len(lost)} lost',
                 'body': body}
        for g in me['golfers']:
            alerts[g['id']] = alert
    return alerts
