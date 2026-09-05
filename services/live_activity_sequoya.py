"""
services/live_activity_sequoya.py
---------------------------------
Sequoya 3s on the lock screen
(docs/design-review/handoff-sequoya-threes/live-activity-sequoya-threes.html).

**Structurally this is the Sixes card and deliberately so** — same three rows,
same locked corners, same neutral scoreboard that names both pairs and never
says "you". Two things differ, and both come from the three-hole match: the
wager moves, and there is far more news.

**The press rides with the money, not the headline.** A match that quietly
picks up a second bet is the one number on this card a reader cannot derive
from anything else. It cannot go in the top row — the right half of that row
is locked to hole, par and yardage across the whole set — and it must not go
in the headline, which belongs to the match state. So it sits in the footer
beside the total at risk, cause printed with effect: money that has silently
appeared is worse than no money on the card at all.

**The state slot is the match.** It takes a word only when one is true of the
position: DORMIE when the lead equals the holes remaining, CLOSED when the
match is decided early (and the headline then holds `2 & 1`). Anything else
takes an em dash over the holes left, because a state word that is not true is
worse than no word — 1 UP with 2 to play is not dormie and must never be
labelled it.

**The press OFFER does not take that slot.** A Live Activity showing a live
offer with no way to accept it is worse than one that stays quiet; the push
does that job and the card stays a glance.

Six pips would be honest here — this round has exactly six matches, unlike
Sixes — but they stay off the lock card because it has no room for a fourth
row. They belong in the expanded island, where there is no footer and where
the second half repeating the first is worth seeing.
"""

from services.live_activity_registry import (fmt_to_par, gross_to_par,
                                             hole_facts, thru_line)

KIND  = 'sequoya'
SLUGS = ('sequoya_threes',)

_HOLES = 18


def _cash(v) -> str:
    """`+$10` / `−$10`, with a real minus sign."""
    v = float(v or 0)
    body = f'{abs(v):.2f}'.rstrip('0').rstrip('.')
    return ('−$' if v < 0 else '+$') + body


def _stake(v) -> str:
    v = float(v or 0)
    body = f'{v:.2f}'.rstrip('0').rstrip('.')
    return f'${body} a man'


def _close_out(bet):
    """`2 & 1` read off the hole it CLOSED ON.

    Not off `to_play`: in this game the holes after a close-out are usually
    still played, because a press is running over them, so the margin keeps
    moving and the holes left fall to zero.
    """
    closed = bet.get('closed_on')
    holes  = bet.get('holes') or []
    if closed is None or closed not in holes:
        return None
    left = len(holes) - holes.index(closed) - 1
    return f'{left + 1} & {left}' if left > 0 else None


def _match_for(summary, hole):
    for m in summary.get('matches') or []:
        if m['start_hole'] <= hole <= m['end_hole']:
            return m
    return None


def _played_holes(summary) -> int:
    """Holes with a gross from everybody — the round's position, not a golfer's."""
    n = 0
    for h in (summary.get('scorecard') or {}).get('holes') or []:
        if all(e.get('gross') is not None for e in h['scores']):
            n += 1
    return n


def sequoya_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The five slots for the match being played right now."""
    from services.sequoya_threes import sequoya_threes_summary
    summary = sequoya_threes_summary(foursome)
    if not summary:
        return {}

    played   = _played_holes(summary) if thru is None else thru
    finished = played >= _HOLES
    hole     = min(played + 1, _HOLES)
    match    = _match_for(summary, hole)
    if match is None:
        return {}

    bets = match['bets']
    head = bets[0]
    left = max(match['end_hole'] - played, 0)

    # ── The two sides. Blue is side 1 of THIS match — the pairing rotates
    #    every third hole, so a colour belongs to a side of a match rather
    #    than to a golfer for the round.
    lead = None if head['margin'] == 0 else (1 if head['margin'] > 0 else 2)
    sides = [
        {'names': ' & '.join(p['name'] for p in match['side1']) or '—',
         'colour': 'blue', 'leading': lead == 1},
        {'names': ' & '.join(p['name'] for p in match['side2']) or '—',
         'colour': 'orange', 'leading': lead == 2},
    ]

    # ── The headline is the match, and the state word beneath it.
    closed = _close_out(head)
    if closed:
        number = {'text': closed,
                  'colour': 'blue' if head['result'] == 1 else 'orange'}
        state  = {'word': 'CLOSED', 'to_play': 'MATCH BET'}
    elif head['result'] == 0:
        number = {'text': 'ALL SQ', 'colour': 'neutral'}
        state  = {'word': 'HALVED', 'to_play': ''}
    else:
        margin = head['margin']
        number = {'text': f'{abs(margin)} UP' if margin else 'ALL SQ',
                  'colour': ('blue' if margin > 0 else
                             'orange' if margin < 0 else 'neutral')}
        # DORMIE only when the lead EQUALS the holes remaining. Over three
        # holes that is the ordinary case rather than the dramatic one, which
        # is exactly why it must not be stretched to cover 1 up with 2 to play.
        if left and abs(margin) == left:
            state = {'word': 'DORMIE', 'to_play': f'{left} TO PLAY'}
        else:
            state = {'word': '—',
                     'to_play': f'{left} TO PLAY' if left else ''}

    # ── The footer: what is at risk, then what the reader has settled.
    #
    # The press chip lives HERE, printed with the stake that caused it. It is
    # folded into the context string rather than sent as its own field because
    # no shipped layout draws a footer chip; the placement is the part that
    # matters, and a tinted pill can follow when there is a build to check it
    # against.
    live_presses = [b for b in bets[1:] if b['result'] is None]
    at_risk = _stake(len(bets) * summary['bet_amount'])
    if any(b['kind'] == 'auto_press' for b in live_presses):
        at_risk += ' · + AUTO PRESS'
    elif any(b['kind'] == 'manual_press' for b in live_presses):
        at_risk += ' · + PRESS'

    mine = next((p['money'] for p in summary['players']
                 if p['player_id'] == player_id), None)
    to_par = gross_to_par(summary, player_id)

    return {
        'kind'  : KIND,
        'header': {
            'game'   : f"SEQUOYA 3s · MATCH {match['index']}",
            'segment': ('ROUND COMPLETE' if finished
                        else hole_facts(foursome, player_id, hole)),
        },
        'number': number,
        'sides' : sides,
        'state' : state,
        # Six pips would be true — there are always six matches — but the lock
        # card has no room for a fourth row. They belong to expanded.
        'pips'  : [],
        'footer': {
            'context': at_risk,
            # An observer has no position, so no money. `$0` would read as a
            # round played for nothing rather than one that has not settled.
            'money'  : _cash(mine) if mine else '',
        },
        'thru'  : thru_line(played, to_par),
        'final' : None,
    }


def sequoya_final_state(foursome, *, player_id=None) -> dict:
    """Round sign-off — and it names the format's own question.

    Not just the money. Won, lost, halved, and the partner who carried you:
    you played every other golfer twice, so this round has an answer to *who*,
    which no other game in the app produces.
    """
    from services.sequoya_threes import sequoya_threes_settlement
    s = sequoya_threes_settlement(foursome)
    if not s:
        return {}

    me = next((p for p in s['players'] if p['player_id'] == player_id), None)
    if me is None:
        return {}

    detail = me['record_label'].replace('–', ' · ')
    if me['best_partner']:
        detail += f" · best with {me['best_partner']}"

    money = me['money']
    if money > 0:
        owed = [t for t in s['transfers'] if t['to_name'] == me['name']]
        collect = f"Collect from {owed[0]['from_name']}" if owed else ''
    elif money < 0:
        owes = [t for t in s['transfers'] if t['from_name'] == me['name']]
        collect = f"Pay {owes[0]['to_name']}" if owes else ''
    else:
        collect = 'All square'

    return {
        'kind'  : KIND,
        'header': {'game': 'SEQUOYA 3s', 'segment': 'FINAL'},
        'number': {'text': _cash(money) if money else 'EVEN',
                   'colour': 'neutral'},
        'sides' : [],
        'state' : {'word': '', 'to_play': ''},
        'pips'  : [],
        'footer': {'context': detail, 'money': ''},
        'final' : {'headline': _cash(money) if money else 'EVEN',
                   'detail': detail, 'collect': collect},
    }
