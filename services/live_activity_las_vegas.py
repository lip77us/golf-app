"""
services/live_activity_las_vegas.py
-----------------------------------
The Las Vegas lock screen.

Spec: `~/Downloads/handoff-las-vegas-lock/HANDOFF.md`.

**It carries arithmetic, not news.** Each hole a side's two net scores become
digits — the low score the tens, the high the ones — so a 4 and a 5 is `45`.
The lower number wins and the DIFFERENCE is the points. An ordinary hole
against an ordinary hole is 45 against 57: twelve points on a bet priced in
cents. A birdie against a bad hole is ninety.

Nothing else in the app swings like that, and nothing else asks a golfer to do
two-digit subtraction between shots. So this card sits with Stableford rather
than with Sixes.

## The headline is SIGNED, which is a departure

Every match card in the set headlines a neutral margin and names both sides to
fix the perspective problem — four golfers read the same string and the pairing
changes at the turn. **Vegas has no perspective problem to solve:** the sides
are fixed at setup and never change, so a signed figure that agrees with the
money two rows below is worth more than a neutral one that does not.

The same fact settles the packet's sharpest open question. **The reader's own
side is blue, per phone** — not per team record. Two golfers in one group would
otherwise see the same hole in opposite colours, and on a card whose headline
is signed that is not a cosmetic difference.

## Three special rules, each on the hole it applied to

Not in a legend and not in the header: the flip, the 9 cap and a carried tie
surface in the state slot of the hole they affected and then go away. **Orange
for all three**, because across this set orange means *somebody did this* or
*this is not the standard case*.

The flip needs the number as it was — `67 → 76` — and that is why
`VegasHoleResult` now records `team{1,2}_flipped`. The stored number is
post-flip and the flip is its own inverse, so the original is recoverable from
the flag; re-deriving it here from gross scores would have been a second copy
of the birdie rule, waiting to disagree with the first.

## The four open questions, answered

* **Which side is blue** — the reader's, per phone. See above.
* **Three-digit numbers** — impossible. `_team_number()` caps each digit at 9
  before composing, so 99 is the ceiling whatever the blow-up guard is set to.
  The sides line can be built for two digits.
* **Multiply, drawn nowhere** — built. The state reads `24 PTS · DOUBLED` with
  no strike-through, because under multiply a birdie changes what the hole is
  worth rather than what the numbers are.
* **Strokes off the low man** — deliberately NOT in the header. It changes the
  inputs to the number; the birdie rule changes what a hole can be worth, and
  the card cannot show that any other way. One slot, and it goes to the rule
  that moves the money.
"""
from services.live_activity_registry import (gross_to_par, hole_facts,
                                             hole_in_play, surname, thru_line)

KIND = 'vegas'

# The configuration screen's words, verbatim. Two groups on the same numbers
# under flip and multiply are not playing the same game — flip scales with how
# bad the opponents' hole was, multiply scales with the lead.
_BIRDIE = {'flip': 'FLIP', 'multiplier': 'MULTIPLY'}


def _sides(summary, player_id) -> tuple:
    """`(mine, theirs)` as team numbers — **the reader's side is blue.**

    A watcher has no side, and rather than leave the card colourless he reads
    it from team 1's point of view, which is the order the summary is in.
    """
    teams = {t.get('team_number'): t for t in (summary.get('teams') or [])}
    for n in (1, 2):
        ids = {p.get('player_id') for p in (teams.get(n) or {}).get('players', [])}
        if player_id in ids:
            return teams.get(n), teams.get(3 - n)
    return teams.get(1), teams.get(2)


def _names(team) -> str:
    """`Kelly & Moran`. Surnames, because two of them and an ampersand is most
    of the row and **the numbers may never shrink.**"""
    players = (team or {}).get('players') or []
    return ' & '.join(surname(p.get('name', '')).title() for p in players)


def _last_hole(summary, hole):
    """The hole the state slot is reporting — the last one fully scored.

    Not the hole in play: Vegas settles the moment four scores are in, and the
    number the reader wants is what the last one paid rather than what the
    current one might.
    """
    scored = [h for h in (summary.get('holes') or [])
              if h.get('winner') is not None]
    if not scored:
        return None
    return max(scored, key=lambda h: h.get('hole') or 0)


def _mine_is_t1(summary, player_id) -> bool:
    mine, _ = _sides(summary, player_id)
    return (mine or {}).get('team_number') == 1


def _margin(summary, player_id) -> tuple:
    """The running margin, signed from the reader's side, and its colour."""
    mine, theirs = _sides(summary, player_id)
    diff = int((mine or {}).get('points') or 0) - int((theirs or {}).get('points') or 0)
    if diff > 0:
        return f'+{diff}', 'blue'
    if diff < 0:
        return f'−{abs(diff)}', 'orange'
    # **`LEVEL` in white, never mint.** Mint is the app's colour and this slot
    # belongs to whichever side is ahead — at level it belongs to neither.
    return 'LEVEL', 'neutral'


def _cap_reached(summary) -> bool:
    """A pair 212 points down is not tracking the arithmetic, and **a frozen
    money figure with no explanation beside it is the one way this card could
    mislead.**"""
    cap = (summary.get('money') or {}).get('loss_cap')
    if not cap:
        return False
    return any(abs(float(t.get('money') or 0)) >= float(cap) - 1e-9
               for t in (summary.get('teams') or []))


def _state_slot(summary, row, player_id) -> dict:
    """What the hole just paid — and where all three special rules surface."""
    if _cap_reached(summary):
        cap = float((summary.get('money') or {}).get('loss_cap') or 0)
        return {'word': 'CAP HELD', 'to_play': f'${cap:,.0f} MAX A SIDE',
                'colour': 'orange'}
    if row is None:
        return {'word': '', 'to_play': ''}

    mine_t1 = _mine_is_t1(summary, player_id)
    mine_key = 'team1' if mine_t1 else 'team2'
    pts = int(row.get('points') or 0)

    if row.get('winner') == 'halved':
        if row.get('carry'):
            return {'word': 'TIED', 'to_play': 'NEXT HOLE DOUBLES',
                    'colour': 'orange'}
        return {'word': '0 PTS', 'to_play': ''}

    # A settled hole's `carry` is the carry it ABSORBED, not one still
    # pending — the engine records it on the row that consumed it and then
    # resets. So this is the hole the ties paid for, and saying only what it
    # paid would leave the reader to wonder why one hole was worth triple.
    carried = int(row.get('carry') or 0)
    if carried:
        word = 'DOUBLED' if carried == 1 else f'×{carried + 1}'
        return {'word': f'{pts} PTS', 'to_play': f'THE CARRY {word}',
                'colour': 'orange'}

    # The flip. `67 → 76` goes on the sides line; the slot names it.
    if row.get('team1_flipped') or row.get('team2_flipped'):
        return {'word': f'{pts} PTS', 'to_play': 'FLIPPED', 'colour': 'orange'}
    # The 9 cap held on this hole — a 10 and a 4 became 49.
    if row.get('team1_capped') or row.get('team2_capped'):
        return {'word': f'{pts} PTS', 'to_play': 'THE 9 CAP HELD',
                'colour': 'orange'}
    # Multiply: a birdie doubled what the hole was worth and no number moved.
    if int(row.get('multiplier') or 1) > 1:
        mult = int(row['multiplier'])
        word = 'DOUBLED' if mult == 2 else f'×{mult}'
        return {'word': f'{pts} PTS', 'to_play': word, 'colour': 'orange'}

    won_by_me = row.get('winner') == mine_key
    side = 'BLUE' if won_by_me else 'ORANGE'
    return {'word': f'{pts} PTS', 'to_play': f'{side}, LAST HOLE'}


def _sides_line(summary, row, player_id) -> list:
    """`● Kelly & Moran 45   ● Reid & Naylor 57` — one row, both numbers.

    **The number IS the game**, so it does not sit at footnote size; and it
    does not get a row of its own either, because a dedicated number row is
    24pt and the names were going on the card regardless. Set beside its own
    side's name it needs no label, and the pair read as the subtraction the
    headline came from.

    It also replaces the *who took that one* sentence: two numbers and a
    weight difference say it without words — the same call the Points card
    makes with its award column.
    """
    mine, theirs = _sides(summary, player_id)
    mine_t1 = _mine_is_t1(summary, player_id)

    def one(team, key, colour):
        num = (row or {}).get(f'{key}_number')
        flipped = (row or {}).get(f'{key}_flipped')
        won = (row or {}).get('winner') == key
        entry = {'names': _names(team), 'colour': colour,
                 # The opacity difference is the ONLY thing marking who won
                 # the hole, so it has to survive the always-on reduction.
                 'leading': bool(won),
                 'figure': '' if num is None else str(num)}
        if flipped and num is not None:
            # The old number struck through before the new one, so the swing
            # is visible rather than asserted.
            entry['was'] = str((num % 10) * 10 + (num // 10))
        return entry

    first = one(mine, 'team1' if mine_t1 else 'team2', 'blue')
    second = one(theirs, 'team2' if mine_t1 else 'team1', 'orange')
    return [first, second]


def _footer(summary, player_id) -> dict:
    """**Priced in cents**, and live from the first hole.

    `25¢ a point`, not `$0.25 a point`: that is how it is set and how it is
    said, and a dollar figure on a card whose points run to three figures
    invites the reader to do the multiplication himself.
    """
    money = summary.get('money') or {}
    unit = float(money.get('bet_unit') or 0)
    if _cap_reached(summary):
        context = 'Cap reached'
    elif unit and unit < 1:
        context = f'{round(unit * 100)}¢ a point'
    elif unit:
        context = f'${unit:,.2f} a point'.replace('.00', '') + ''
    else:
        context = ''

    mine, _ = _sides(summary, player_id)
    cash = float((mine or {}).get('money') or 0)
    # Live from hole one: a hole settles the moment four scores are in, so
    # there is nothing pending to hedge about. Points is the only other card
    # in the set where that is true.
    if cash:
        sign = '+' if cash > 0 else '−'
        figure = f'{sign}${abs(cash):,.2f}'
    else:
        figure = ''
    return {'context': context, 'money': figure}


def las_vegas_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The card, right now."""
    from services.vegas import vegas_summary

    summary = vegas_summary(foursome)
    if not summary or not (summary.get('teams') or []):
        return {}

    played = thru or 0
    hole = hole_in_play(foursome, played)
    row = _last_hole(summary, hole)
    text, colour = _margin(summary, player_id)

    game = f'LAS VEGAS · {_BIRDIE.get(summary.get("birdie_mode"), "FLIP")}'
    header = {'game': game,
              'segment': hole_facts(foursome, player_id, hole)}
    # The carry chip rides the header only while a tie is actually carrying —
    # it is a state of the round, not a setting, and the setting is already
    # readable from the state slot that created it.
    # **Only while a tie is actually carrying.** A settled hole's `carry` is
    # the one it absorbed, so reading the flag alone would leave the chip up
    # on the hole that ended the carry — which is the hole it is least true
    # of.
    if (row or {}).get('winner') == 'halved' and (row or {}).get('carry'):
        header['accent'] = 'orange'
        header['chip'] = 'CARRY'

    return {
        'kind'  : KIND,
        'header': header,
        'number': {'text': text, 'colour': colour},
        'sides' : _sides_line(summary, row, player_id),
        'state' : _state_slot(summary, row, player_id),
        'pips'  : [],
        'final' : None,
        'footer': _footer(summary, player_id),
        'thru'  : thru_line(played, gross_to_par(summary, player_id)),
    }


def las_vegas_final_state(foursome, *, player_id=None) -> dict:
    """Round sign-off — **the card keeps its board.**

    Every slot still has something to say: the margin is the result, the last
    hole is still the last hole, and the two pairs are the two pairs. What
    changes is the state slot, which turns from what a hole paid into what the
    round paid, and the footer, which stops quoting a rate.
    """
    from services.vegas import vegas_summary

    summary = vegas_summary(foursome)
    if not summary or not (summary.get('teams') or []):
        return {}

    mine, theirs = _sides(summary, player_id)
    text, colour = _margin(summary, player_id)
    cash = float((mine or {}).get('money') or 0)
    pts = int((mine or {}).get('points') or 0)
    their_pts = int((theirs or {}).get('points') or 0)

    if cash > 0:
        collect = f'Collect from {_names(theirs)}'
    elif cash < 0:
        collect = f'Pay {_names(theirs)}'
    else:
        collect = 'Level — nothing to settle'

    sign = '+' if cash > 0 else ('−' if cash < 0 else '')
    amount = f'{sign}${abs(cash):,.2f}' if cash else 'EVEN'
    return {
        'kind'  : KIND,
        'header': {'game': f'LAS VEGAS · '
                           f'{_BIRDIE.get(summary.get("birdie_mode"), "FLIP")}',
                   'segment': 'ROUND COMPLETE'},
        'closed': True,
        'number': {'text': text, 'colour': colour},
        'sides' : [
            {'names': f'{pts}–{their_pts} on points', 'colour': '',
             'leading': False},
            {'names': collect, 'colour': '', 'leading': False},
        ],
        # The money, which the running card kept in the footer because the
        # margin was the thing that moved. Nothing moves now.
        'state' : {'word': amount, 'to_play': 'SETTLED', 'colour': 'mint'},
        'pips'  : [],
        'final' : None,
        'footer': {'context': 'Dismisses in 5 min', 'money': ''},
        'thru'  : thru_line(18, gross_to_par(summary, player_id)),
    }
