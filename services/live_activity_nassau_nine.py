"""
services/live_activity_nassau_nine.py
-------------------------------------
The Nassau Nine lock screen
(`~/Downloads/handoff-lock-screens-mgskins-minisingles-nassaunine-solo`,
section 3).

One bet over nine holes, with presses. It does not get the Nassau card's two
rows — there is no back nine and no overall — so it takes the **match card's
single number**, with Nassau's press chip and exposure range added. A
projection of `nassau_summary`; it decides no golf.

**The holes-remaining fix.** Every other card counts holes to play against
eighteen, because the game and the round are the same length. A Nassau Nine's
clock is its own: `6 TO PLAY` is holes left in the *bet*, never the round, and
`HOLES 1–9` (or `HOLES 10–18`) sits under it on every running state — the one
word that tells a golfer the 6 is not a mistake. The header still carries the
reader's hole in the round (`HOLE 13` on a back-nine game).

**Sides are fixed for the bet, so colour is too:** the reader's side blue, the
other orange, two lines, leader first. 1 v 1 is the same card, one name a line.

It declares the kind the installed app already draws (`match`), so there is
nothing for `UNSHIPPED_KINDS` to hold back. The press chip rides on the number
(`number.chip`); a build that does not draw that field simply omits it.
"""
from services.live_activity_registry import (fmt_to_par, gross_to_par,
                                             hole_facts, hole_in_play,
                                             thru_line)

KIND = 'match'


def _cash(v) -> str:
    v = float(v or 0)
    body = f'{abs(v):,.2f}'.rstrip('0').rstrip('.')
    return ('−$' if v < 0 else '+$') + body


def _range(low, high) -> str:
    def fmt(v):
        return f'{"+" if v > 0 else ("−" if v < 0 else "")}${abs(v):,.0f}'
    return fmt(low) if abs(high - low) < 0.005 else f'{fmt(low)} to {fmt(high)}'


def _sides(summary, player_id):
    """`(mine, theirs)` as lists of display names, reader first."""
    teams = summary.get('teams') or {}

    def names(key):
        people = teams.get(key) or []
        field = 'name' if len(people) == 1 else 'short_name'
        return ' & '.join((p.get(field) or p.get('name') or '')
                          for p in people)

    from services.live_activity_nassau import _reader_sign
    if _reader_sign(summary, player_id) > 0:
        return names('team1'), names('team2'), 1
    return names('team2'), names('team1'), -1


def _label(order) -> str:
    return f'HOLES {order[0]}–{order[-1]}' if order else ''


def nassau_nine_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    from games.models import NassauGame
    from services.hole_plan import play_order
    from services.live_activity_nassau import (_bet_is_played,
                                               _live_press_count,
                                               exposure_range)
    from services.nassau import nassau_summary, resolve_nassau_game_type

    summary = nassau_summary(foursome)
    if not summary or not summary.get('single_match'):
        return {}
    game = NassauGame.objects.filter(
        foursome=foursome,
        game_type=resolve_nassau_game_type(foursome)).first()
    if game is None:
        return {}

    order = play_order(foursome.round, foursome) or list(range(1, 19))
    played = thru or 0
    bet = summary.get('front9') or {}
    margin = bet.get('margin') or 0
    mine, theirs, sign = _sides(summary, player_id)
    my_margin = margin * sign                    # + = the reader's side up
    left = max(len(order) - (bet.get('holes_played') or 0), 0)
    hole = hole_in_play(foursome, played)

    colour = ('blue' if my_margin > 0 else
              'orange' if my_margin < 0 else 'neutral')
    number = {'text': f'{abs(margin)} UP' if margin else 'ALL SQ',
              'colour': colour}
    presses = _live_press_count(summary, 'front9')
    if presses:
        number['chip'] = f'+{presses} PRESS'

    # Leader first; the reader's side keeps its colour either way.
    me = {'names': mine or '—', 'colour': 'blue', 'leading': my_margin > 0}
    them = {'names': theirs or '—', 'colour': 'orange',
            'leading': my_margin < 0}
    sides = [them, me] if my_margin < 0 else [me, them]

    stake = float(summary.get('bet_unit') or 0)
    team = len((summary.get('teams') or {}).get('team1') or []) > 1
    low, high = exposure_range(summary, game, player_id)

    state = {'word': f'{left} TO PLAY', 'to_play': _label(order)}
    card = {
        'kind'  : KIND,
        'header': {'game': 'NASSAU NINE',
                   'segment': hole_facts(foursome, player_id, hole)},
        'number': number,
        'sides' : sides,
        'state' : state,
        'pips'  : [],
        'final' : None,
        'footer': ({'context': f'${stake:,.0f} a bet' + (', each' if team
                                                          else ''),
                    'money': _range(low, high)} if stake
                   else {'context': '', 'money': ''}),
        'thru'  : thru_line(played, gross_to_par(summary, player_id)),
    }
    return card


def nassau_nine_final_state(foursome, *, player_id=None) -> dict:
    """A nine-hole round ends on signing: the money, the gross, who to see."""
    from services.hole_plan import play_order
    from services.nassau import nassau_summary
    from services.live_activity_registry import gross_total

    summary = nassau_summary(foursome)
    if not summary or not summary.get('single_match'):
        return {}
    order = play_order(foursome.round, foursome) or list(range(1, 19))
    mine, theirs, sign = _sides(summary, player_id)
    money = sign * float((summary.get('payouts') or {}).get('total') or 0)
    bet = summary.get('front9') or {}
    margin = (bet.get('margin') or 0) * sign

    card = nassau_nine_activity_state(foursome, player_id=player_id,
                                      thru=len(order))
    if not card:
        return {}
    presses = [p for p in (summary.get('presses') or [])]
    bits = [f'match {abs(margin)} UP' if margin else 'match AS']
    if presses:
        p_up = [(p.get('margin') or 0) * sign for p in presses]
        word = ('press ' + ', '.join(f'{abs(m)} UP' if m else 'AS'
                                     for m in p_up))
        bits.append(word)
    each = ' each' if len((summary.get('teams') or {}).get('team1') or []) > 1 \
        else ''
    if money > 0:
        collect = f'Collect from {theirs}'
    elif money < 0:
        collect = f'Pay {theirs}'
    else:
        collect = 'All square — nothing to settle'
    gross = gross_total({'holes': summary.get('scorecard', {}).get('holes')
                         or []}, player_id)
    card['header']['segment'] = 'NINE COMPLETE'
    card['closed'] = True
    card['number'] = {'text': _cash(money) if money else 'EVEN',
                      'colour': 'neutral'}
    card['state'] = {'word': f'{gross}' if gross else '',
                     'to_play': f'GROSS, {len(order)} HOLES'}
    card['sides'] = [{'names': f'Each · {", ".join(bits)}' if each
                      else ' · '.join(bits), 'colour': '', 'leading': False}]
    card['footer'] = {'context': f'{collect} · 5 min', 'money': ''}
    return card
