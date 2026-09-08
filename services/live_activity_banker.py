"""
services/live_activity_banker.py
--------------------------------
Banker on the lock screen
(docs/design-review/handoff-banker/live-activity-banker.html).

**This is the strongest Live Activity case in the app**, for a reason none of
the others has: who is banking, what you bet and whether somebody doubled it
were all spoken aloud on a tee box and written down nowhere.

**And the card is PERSONAL — a departure from every other card in the set.**
Sixes and Sequoya 3s put a neutral scoreboard on the lock screen: the same
string on four phones, with the money line the single exception. Banker cannot.
There is no shared state on a Banker hole — there are three separate
one-on-ones with three different numbers, and *the score* is not a thing that
exists. So the card reads from the holder's side, in two compositions:

* **The banker's phone** — the whole hole is his business, because every bet on
  it was made against him. His card names all three, what multiplied them, and
  the maximum he set.
* **A player's phone** — his own bet and the man he is playing, and nothing
  else. He has no business reading Sam's number off Dave's phone.

The 36pt number is **the hole, not the round.** The running total goes in the
footer with the stake, as everywhere in the set. A round total in the headline
would be the safer choice and the wrong one: it is the number he already knows,
and it does not change while he is walking.

**Gold marks the role and does nothing else.** Which is why this card's stroke
ribbon is BLUE rather than the shared gold — a stroke is a fact of the hole,
and a card where gold means both *banker* and *you are popping* has spent its
one loud colour twice. The tone is keyed off the card's own kind rather than a
new payload field: the rule belongs to this card.

No new Swift layout. Everything resolves into the five slots `BoardView`
already draws, so the client change is the kind string, two colours, and the
ribbon's tone.
"""

from decimal import Decimal

from services.live_activity_registry import (gross_to_par, hole_facts,
                                             thru_line)

KIND  = 'banker'
SLUGS = ('banker',)

_HOLES = 18


def _cash(v) -> str:
    """`+$10` / `−$10` / `$0`, with a real minus sign.

    Level takes no sign: `+$0` is not a figure anybody writes, and on a card
    whose whole job is which way the money went it reads as a rounding error.
    """
    v = float(v or 0)
    if not v:
        return '$0'
    body = f'{abs(v):.2f}'.rstrip('0').rstrip('.')
    return ('−$' if v < 0 else '+$') + body


def _amount(v) -> str:
    v = float(v or 0)
    body = f'{v:.2f}'.rstrip('0').rstrip('.')
    return f'${body}'


def _line_for(hole, player_id):
    for line in hole.get('lines') or []:
        if line['player_id'] == player_id:
            return line
    return None


def _multiplier_note(hole, line=None) -> tuple[str, str]:
    """What has happened to the bet(s), and the colour that owns it.

    Blue is a player's double, amber is the banker's counter — the packet's own
    mapping, and each colour means exactly one thing across the whole game.
    Amber wins when both are true, because the counter is the half the golfer
    did not agree to.
    """
    lines = [line] if line else (hole.get('lines') or [])
    if not lines:
        return '', 'dim'
    countered = any(x['countered'] for x in lines)
    doubles   = [x for x in lines if x['own_multiplier'] > 1]
    # **A birdie is a multiplier too**, and the only one the reader cannot
    # infer: he can see who doubled and he was there for the counter, but a
    # settled hole that paid twice what the chain says looks like an error
    # until the word `birdie` appears next to it. It is set on the line only
    # when the birdie actually WON, which is the only time it doubles anything.
    birdies = [x for x in lines if x.get('birdie')]
    bits = []
    if doubles:
        if line is not None:
            bits.append('tripled' if line['own_multiplier'] == 3 else 'doubled')
        else:
            word = 'tripled' if any(x['own_multiplier'] == 3 for x in doubles) \
                else 'doubled'
            bits.append(f'{len(doubles)} {word}')
    if countered:
        bits.append('countered' if line is not None else 'you countered')
    if birdies:
        if line is not None:
            bits.append('birdie ×2')
        elif len(birdies) == 1:
            bits.append(f'{birdies[0]["short_name"]} birdie ×2')
        else:
            bits.append(f'{len(birdies)} birdies ×2')
    if not bits:
        return ('no doubles' if line is None else 'straight up'), 'dim'
    return ' · '.join(bits), ('amber' if countered else 'blue')


def _stroke_ribbon(foursome, game, player_id, hole, banker_id, opponents,
                   stroke_index) -> str:
    """The blue band: who is getting a shot in the bet(s) on this hole.

    **Strokes come off inside each one-on-one**, so there is no field-wide
    allocation to report and the ribbon has to be written from the reader's
    side like everything else on this card. The banker's names all three
    matches; a player's names only the two men in his.

    Read from the game's own pairwise allocator rather than from played holes:
    the hole in play is by definition unscored, so a ribbon built from the
    scorecard could never fire.
    """
    from services.banker import pair_strokes

    if player_id is None or not hole:
        return ''
    si = f' · SI {stroke_index}' if stroke_index else ''

    if player_id == banker_id:
        bits = []
        for pid, short in opponents:
            s_b, s_o = pair_strokes(game, foursome, banker_id, pid, hole)
            if s_o:
                bits.append(f'{short.upper()} GETS {s_o}')
            elif s_b:
                bits.append(f'YOU GET {s_b} v {short.upper()}')
        if not bits:
            return f'SCRATCH HOLE{si}'
        return ' · '.join(bits) + si

    b_short = next((s for p, s in opponents if p == banker_id), 'THE BANK')
    s_b, s_o = pair_strokes(game, foursome, banker_id, player_id, hole)
    if s_o:
        return f'YOU GET {s_o} v {b_short.upper()}{si}'
    if s_b:
        return f'{b_short.upper()} GETS {s_b}{si}'
    return f'SCRATCH HOLE{si}'


def banker_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The five slots, written from the holder's side."""
    from games.models import BankerGame
    from services.banker import banker_summary

    try:
        game = foursome.banker_game
    except BankerGame.DoesNotExist:
        return {}
    summary = banker_summary(foursome)
    if not summary:
        return {}

    hole = summary.get('current')
    if hole is None:
        return {}

    played   = thru if thru is not None else 0
    finished = played >= _HOLES
    n        = hole['hole']
    banker_id = hole.get('banker_id')

    shorts = {p['player_id']: p['short_name'] for p in summary['players']}
    opponents = [(p['player_id'], shorts[p['player_id']])
                 for p in summary['players']]
    b_short = shorts.get(banker_id, '')

    mine   = next((p['total'] for p in summary['players']
                   if p['player_id'] == player_id), None)
    to_par = gross_to_par(summary, player_id)
    # **The band belongs with the maximum, not in the footer.** They are one
    # fact in two halves — what the banker set, inside what the round allows —
    # and a golfer reading `MAX $30` wants to know whether that is near the
    # ceiling. Splitting them put the ceiling at the bottom of the card and
    # left the reader to hold one number while finding the other.
    band = (f"${summary['min_bet']:.0f}–${summary['max_bet']:.0f}")
    max_bet = hole.get('max_bet')
    max_note = (f'MAX {_amount(max_bet)} · {band}' if max_bet
                else f'NO MAX YET · {band}')

    settled = bool(hole.get('resolved'))

    if settled:
        number, sides, state = _settled(summary, hole, player_id, banker_id,
                                        b_short, n)
    elif player_id == banker_id:
        # ── His hole. Every bet on it was made against him, so all three are
        #    his business and the card itemises them.
        lines = hole.get('lines') or []
        at_risk = sum((Decimal(str(x['stake'])) for x in lines), Decimal('0'))
        number = {'text': _amount(at_risk) if lines else '—',
                  'colour': 'gold'}
        bets = ' · '.join(f"{x['short_name']} {_amount(x['stake'])}"
                          for x in lines)
        note, tone = _multiplier_note(hole)
        sides = [
            {'names': bets or 'No bets in yet', 'colour': 'gold',
             'leading': True},
            {'names': note, 'colour': tone, 'leading': tone != 'dim'},
        ]
        state = {'word': 'BANKING', 'to_play': max_note}
    elif player_id is not None and _line_for(hole, player_id) is not None:
        # ── One bet, his own. Nobody else's number appears.
        line = _line_for(hole, player_id)
        note, tone = _multiplier_note(hole, line)
        number = {'text': _amount(line['stake']),
                  'colour': tone if tone != 'dim' else 'neutral'}
        sides = [
            {'names': f"Your bet {_amount(line['bet'])}",
             'colour': tone if tone != 'dim' else 'neutral', 'leading': True},
            {'names': f'{b_short} banks · {note}', 'colour': 'gold',
             'leading': False},
        ]
        # `v. Jim`, not `V. JIM`. Every other word in this slot is a STATE —
        # DORMIE, CLOSED, BANKING — and shouting suits them. This one is a
        # golfer's name, and a name in capitals reads as a different man.
        state = {'word': f'v. {b_short}'[:12], 'to_play': max_note}
    else:
        # ── No bet of his own yet, or a watcher. The neutral facts only: who
        #    is banking and what he set. A watcher must not be shown three
        #    golfers' private numbers because he happened to open the round.
        number = {'text': _amount(max_bet) if max_bet else '—',
                  'colour': 'gold'}
        outstanding = hole.get('outstanding') or []
        sides = [
            {'names': f'{b_short} banks the {_ordinal(n)}', 'colour': 'gold',
             'leading': True},
            {'names': (f"Waiting on {', '.join(outstanding)}" if outstanding
                       else 'Bets are in'),
             'colour': 'dim', 'leading': False},
        ]
        state = {'word': 'BETS OPEN' if outstanding else 'LOCKED',
                 'to_play': max_note}

    # A settled hole has no stroke to announce — the shots are spent, and a
    # ribbon left up after the result reads as a hole still to play.
    ribbon = '' if (finished or settled) else _stroke_ribbon(
        foursome, game, player_id, n, banker_id,
        [(p, s) for p, s in opponents if p != player_id],
        hole.get('stroke_index'))

    return {
        'kind'  : KIND,
        'header': {
            'game'   : 'BANKER',
            'segment': ('ROUND COMPLETE' if finished
                        else hole_facts(foursome, player_id, n)),
        },
        'number': number,
        'sides' : sides,
        'state' : state,
        'ribbon': ribbon,
        # No pips. Banker has no segments — every hole is its own settlement,
        # and eighteen of anything will not fit a row this card does not have.
        'pips'  : [],
        # The footer's left is the reader's own money now that the band has
        # gone up beside the maximum, and its right is the locked corner. One
        # personal figure and one round figure, which is what the pair is for.
        'footer': {
            'context': '',
            # A watcher has no position, so no money. `$0` would read as a
            # round played for nothing rather than one he is not in.
            'money'  : _cash(mine) if mine else '',
        },
        'thru'  : thru_line(played, to_par),
        'final' : None,
    }


def _settled(summary, hole, player_id, banker_id, b_short, n):
    """The hole is over. **This is the state the card was missing.**

    It used to draw what was at RISK for the whole life of a hole, so a golfer
    standing on the green watching the result on his phone had a lock screen
    still telling him what he might lose. The number a settled hole owes its
    reader is what actually moved, and the slot beside it owes them the one
    thing that has not happened yet: who banks the next one.
    """
    lines = hole.get('lines') or []
    awaiting = summary.get('awaiting_tie') == n
    # The SHORT name. `next_banker_name` is the full one, and a 17pt slot cut
    # it mid-surname — `PAUL LIPKI BANKS NEXT` names nobody. Short names are
    # what the group set and what every other slot on this card uses.
    shorts = {p['player_id']: p['short_name'] for p in summary['players']}
    nxt = shorts.get(summary.get('next_banker_id')) or ''

    # The state slot carries what happens NEXT, because the result is already
    # the headline. A tie the group has to answer outranks it: until somebody
    # says who holed out first, the next hole cannot open at all.
    if awaiting:
        state = {'word': 'TIED', 'to_play': 'GROUP DECIDES'}
    elif nxt:
        state = {'word': nxt, 'to_play': 'BANKS NEXT'}
    else:
        state = {'word': 'SETTLED', 'to_play': ''}

    if player_id == banker_id:
        # Signed from HIS side: an opponent who won took it off him.
        def mine(line):
            if line['outcome'] == 'won':
                return -line['amount']
            if line['outcome'] == 'lost':
                return line['amount']
            return 0

        number = {'text': _cash(hole.get('banker_delta') or 0),
                  'colour': 'neutral'}
        note, tone = _multiplier_note(hole)
        sides = [
            {'names': ' · '.join(f"{x['short_name']} {_cash(mine(x))}"
                                 for x in lines) or 'No bets',
             'colour': 'gold', 'leading': True},
            {'names': note, 'colour': tone, 'leading': tone != 'dim'},
        ]
        return number, sides, state

    line = _line_for(hole, player_id)
    if line is not None:
        got = (line['amount'] if line['outcome'] == 'won'
               else -line['amount'] if line['outcome'] == 'lost' else 0)
        number = {'text': _cash(got), 'colour': 'neutral'}
        note, tone = _multiplier_note(hole, line)
        word = ('Halved' if line['outcome'] == 'tied'
                else 'You won' if line['outcome'] == 'won' else 'You lost')
        sides = [
            {'names': f"{word} v {b_short}", 'colour': 'gold', 'leading': True},
            {'names': note, 'colour': tone, 'leading': tone != 'dim'},
        ]
        return number, sides, state

    # A watcher sees that the hole is done and who has it next — never the
    # money, which was none of his business while it was live either.
    number = {'text': '—', 'colour': 'gold'}
    sides = [
        {'names': f'{b_short} banked the {_ordinal(n)}', 'colour': 'gold',
         'leading': True},
        {'names': 'Hole settled', 'colour': 'dim', 'leading': False},
    ]
    return number, sides, state


def _ordinal(n) -> str:
    if n in (11, 12, 13):
        return f'{n}th'
    return f'{n}th' if n % 10 > 3 else f'{n}{["th", "st", "nd", "rd"][n % 10]}'


def banker_final_state(foursome, *, player_id=None) -> dict:
    """Round sign-off — what he made, and which half of the game made it.

    Banking and betting are different games and this is the last chance to say
    so: a golfer who was −$80 as banker and +$60 as a player had a very
    different day from one who drifted to −$20 without banking a hole.
    """
    from services.banker import banker_settlement

    s = banker_settlement(foursome)
    if not s:
        return {}
    me = next((r for r in s['receipts'] if r['player_id'] == player_id), None)
    if me is None:
        return {}

    detail = (f"banking {_cash(me['banking'])} · "
              f"betting {_cash(me['betting'])}")
    money = me['total']
    if money > 0:
        owed = [t for t in s['transfers'] if t['to'] == player_id]
        collect = f"Collect from {owed[0]['from_name']}" if owed else ''
    elif money < 0:
        owes = [t for t in s['transfers'] if t['from'] == player_id]
        collect = f"Pay {owes[0]['to_name']}" if owes else ''
    else:
        collect = 'All square'

    return {
        'kind'  : KIND,
        'header': {'game': 'BANKER', 'segment': 'FINAL'},
        'number': {'text': _cash(money) if money else 'EVEN',
                   'colour': 'gold'},
        'sides' : [],
        'state' : {'word': '', 'to_play': ''},
        'pips'  : [],
        'footer': {'context': detail, 'money': ''},
        'final' : {'headline': _cash(money) if money else 'EVEN',
                   'detail': detail, 'collect': collect},
    }
