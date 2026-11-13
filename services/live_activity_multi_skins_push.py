"""
services/live_activity_multi_skins_push.py
------------------------------------------
The Multi-Group Skins lock-screen push: **a hole closing with a skin won.**

A pool hole is decided only when the LAST group posts it, so the result lands
on a phone while its owner is on another fairway — exactly what the card
exists to report and what a golfer cannot see from where he stands. Everyone
in the pool gets it; the winner's reads in the second person.

**A halved hole does not ring.** It moves the card silently (`NO SKIN`): a
phone buzzing to say nothing happened is the activity doing the notification's
job badly. When several holes close on one score the push names the latest.

**Fired once**, via `MultiSkinsGame.announced`, NULL until the first score is
pushed (a baseline, not a backlog) — the Annandale / Nassau Nine mechanism.

"Hole 11 is yours" (a personal nudge that your group is the last one out) is
NOT built: it needs per-group pace across every foursome and a rule for
"last", which the pool summary does not carry.
"""
import logging

logger = logging.getLogger(__name__)


def multi_skins_alerts(round_obj) -> dict:
    """`{player_id: alert}` for the skins this posted score closed. Called
    ONCE per posted score; it records what it announced."""
    from games.models import MultiSkinsGame
    from services.multi_skins import multi_skins_summary

    game = MultiSkinsGame.objects.filter(round=round_obj).first()
    if game is None:
        return {}
    summary = multi_skins_summary(round_obj)
    if not summary or not summary.get('players'):
        return {}

    holes = summary.get('holes') or []
    closed = [h for h in holes
              if h.get('winner_id') is not None or h.get('is_dead')]
    current = {f'hole:{h["hole"]}' for h in closed}
    if game.announced is None:
        game.announced = sorted(current)
        game.save(update_fields=['announced'])
        return {}
    seen = set(game.announced)
    fresh = [h for h in closed
             if f'hole:{h["hole"]}' not in seen
             and h.get('winner_id') is not None]
    if current - seen:
        game.announced = sorted(seen | current)
        game.save(update_fields=['announced'])
    if not fresh:
        return {}

    h = max(fresh, key=lambda x: x['hole'])
    players = summary['players']
    by_id = {p['player_id']: p for p in players}
    winner = by_id.get(h['winner_id']) or {}
    won = winner.get('skins_won') or 0
    tally = f'{won} so far' if won != 1 else 'your first'
    out = {}
    for p in players:
        pid = p['player_id']
        if pid == h['winner_id']:
            out[pid] = {'title': f'Hole {h["hole"]} · skin',
                        'body': f'You took the skin on {h["hole"]}. {tally.capitalize()}.'}
        else:
            name = winner.get('name') or 'Someone'
            out[pid] = {'title': f'Hole {h["hole"]} · skin',
                        'body': f'{name} took the skin on {h["hole"]}. '
                                f'{won} on the day.'}
    return out
