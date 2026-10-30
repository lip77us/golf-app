"""
services/live_activity_annandale_friday.py
------------------------------------------
The Annandale Friday lock screen.

Spec: `~/Downloads/handoff-annandale-friday-lock/HANDOFF.md`.

**The Nassaus only.** Skins is a side game for the whole group and stays in
the app.

Annandale Friday is three team Nassaus on one card — three pairs each playing
the other two, or (with five) a pair against each pair of a three. So it takes
the **Triple Nassau card as it stands**: one figure per match on one strip, the
bet it reports named once in the header, a press as a chip on the figure it
doubles, the exposure range in the footer, and **never the word DOWN** — a
figure wears the colour of whoever is up. The bet key, the figure and the
press chip are imported from that module rather than copied, because the two
cards must not come to disagree about what `3&2` or `+1` means.

What changes is that the matches are between TEAMS:

* **A label is two lines**, one team per line, each with its colour dot —
  `YOU` over `v DAVE·RAY`, or `DAVE·RAY` over `v JIM·SAM` for the match the
  reader is not in. First names, as on the leaderboard pills.
* **Colour is the team, not the golfer.** The reader's team is always blue;
  the other two take orange and plum in card order. With five, the three is
  one team, so all three of the pair's opponents wear one colour.
* **Which columns are at weight follows the reader**: two of three with six,
  all three for the pair with five, two of three for one of the three.

One departure, recorded where it is made: with five, a golfer in the three
plays with a DIFFERENT partner in each of his matches, so his side reads
`YOU·SAM` rather than `YOU` — the bare pronoun is right only when the partner
never changes.
"""
from services.live_activity_nassau import exposure_range, _money
from services.live_activity_registry import (gross_to_par, hole_in_play,
                                             thru_line)
from services.live_activity_triple_nassau import (_BET_LABEL, _bet_key,
                                                  _figure, _press_chip)

KIND = 'annandale_friday'
GAME = 'ANNANDALE FRIDAY'

# The reader's team is blue on his own phone. The other two take orange and
# plum in card order — **assigned per reader, never per team record**, or two
# golfers in one group would read the same match in two colour schemes. Same
# rule as Triple Nassau and Las Vegas.
_OTHERS = ('orange', 'plum')


def _summary(foursome):
    from services.annandale_friday import annandale_friday_summary
    s = annandale_friday_summary(foursome)
    if not s or not (s.get('matches') or []):
        return None
    return s


def _team_of(summary) -> dict:
    return {p.get('player_id'): p.get('team')
            for p in (summary.get('players') or [])}


def _playing(summary, player_id) -> bool:
    """An explicit membership test — `0` is a player id, not a falsehood."""
    return player_id in _team_of(summary)


def _team_colours(summary, player_id) -> dict:
    """`{team index: colour}` — **the reader's team blue, always.**

    A watcher owns no team, so card order supplies all three and nothing is
    held back: none of it is his money.
    """
    count = len(summary.get('teams') or [])
    order = list(range(count))
    mine = _team_of(summary).get(player_id)
    if mine is None:
        return dict(zip(order, ('blue',) + _OTHERS))
    others = [t for t in order if t != mine]
    return {mine: 'blue', **dict(zip(others, _OTHERS))}


def _first(name: str) -> str:
    return (name or '').split(' ')[0].upper()


def _side_name(ids, summary, player_id) -> str:
    """`DAVE·RAY`, or the reader's own side.

    `YOU` when the reader's partner never changes — every team of two. With
    five, a golfer in the three partners a different man in each match, so his
    side reads `YOU·SAM`: the pronoun alone would hide the one thing that
    differs between his two columns.
    """
    names = {p.get('player_id'): p.get('name', '')
             for p in (summary.get('players') or [])}
    if player_id in ids:
        team = _team_of(summary).get(player_id)
        size = sum(1 for t in _team_of(summary).values() if t == team)
        if size <= 2:
            return 'YOU'
        partners = [_first(names.get(i, '')) for i in ids if i != player_id]
        return '·'.join(['YOU'] + partners)
    return '·'.join(_first(names.get(i, '')) for i in ids)


def _mine(m, player_id) -> bool:
    return (player_id in (m.get('side1_ids') or [])
            or player_id in (m.get('side2_ids') or []))


def _order(matches, player_id):
    """**The reader's matches first, then the third.** His are what he acts
    on; the third is context for the settlement."""
    mine = [m for m in matches if _mine(m, player_id)]
    return mine + [m for m in matches if m not in mine]


def _lines(m, summary, player_id, colours):
    """The two label lines and their dots: the reader's side on top when it
    is his match, otherwise card order."""
    s1, s2 = m.get('side1_ids') or [], m.get('side2_ids') or []
    t1, t2 = m.get('side1_team'), m.get('side2_team')
    if player_id in s2:
        s1, s2, t1, t2 = s2, s1, t2, t1
    top = _side_name(s1, summary, player_id)
    bottom = 'v ' + _side_name(s2, summary, player_id)
    return top, bottom, [colours.get(t1, 'dim'), colours.get(t2, 'dim')]


def _as_triple(matches) -> list:
    """The shape Triple Nassau's bet key reads — `{'match': summary}`."""
    return [{'match': m.get('summary') or {}} for m in matches]


def _strip(summary, player_id, key) -> list:
    colours = _team_colours(summary, player_id)
    playing = _playing(summary, player_id)
    out = []
    for m in _order(summary.get('matches') or [], player_id):
        s = m.get('summary') or {}
        # `_figure` colours by LEADER id; hand it the two TEAMS as the two
        # "players", so the colour that comes back is the leading team's.
        t1, t2 = m.get('side1_team'), m.get('side2_team')
        fig = _figure(s.get(key) or {}, t1, t2, colours)
        top, bottom, dots = _lines(m, summary, player_id, colours)
        mine = _mine(m, player_id)
        out.append({
            'label' : top,
            'label2': bottom,
            'name'  : '',
            'figure': fig['figure'],
            'colour': fig['colour'],
            'rule'  : fig['rule'],
            'dots'  : dots,
            'chip'  : _press_chip(s, key),
            'dim'   : not mine and playing,
            'is_reader': mine,
        })
    return out


def _exposure(summary, player_id) -> str:
    """`settled ± every live stake the reader is party to`, presses included,
    **each** — so six golfers at $10 open at −$60 to +$60, and the pair in a
    five at −$90 to +$90. The match he is not in never enters it.

    Each match is clamped to its own loss cap before summing, because the cap
    is per side PER NASSAU — clamping the sum would let a golfer lose past the
    cap in one match against winnings in another.
    """
    if not _playing(summary, player_id):
        return ''
    low = high = 0.0
    for m in summary.get('matches') or []:
        if not _mine(m, player_id):
            continue
        l, h = exposure_range(m.get('summary') or {}, None, player_id)
        low += l
        high += h
    return _money(low, high)


def _reader_scorecard(summary, player_id) -> dict:
    """A scorecard carrying the reader's own holes — any of his matches has
    all of them. A watcher has none."""
    for m in summary.get('matches') or []:
        if _mine(m, player_id):
            return (m.get('summary') or {}).get('scorecard') or {}
    return {}


def _context(summary, key, played) -> str:
    """The left of the footer: the stake, or the round's state once the fronts
    are in — `$10 a bet`, `$10 a bet · 5 golfers`, `fronts in · 2 to play`.

    `5 golfers` because the pair's exposure (nine bets) reads as a typo
    against the six-golfer card a group may have played last week.
    """
    first = ((summary.get('matches') or [{}])[0] or {}).get('summary') or {}
    if key != 'front9' and (first.get('front9') or {}).get('result'):
        left = max(0, 18 - played)
        return 'fronts in' + (f' · {left} to play' if left else '')
    unit = float(summary.get('bet_unit') or 0)
    bits = [f'${unit:,.0f} a bet'] if unit else []
    if summary.get('group_size') == 5:
        bits.append('5 golfers')
    return ' · '.join(bits)


def annandale_friday_activity_state(foursome, *, player_id=None,
                                    thru=None) -> dict:
    """The card, right now."""
    summary = _summary(foursome)
    if summary is None:
        return {}

    played = thru or 0
    hole = hole_in_play(foursome, played)
    key = _bet_key(_as_triple(summary['matches']), hole)

    return {
        'kind'  : KIND,
        # All three matches are on the same bet at the same time — the HOLES
        # are shared — so the bet is named once, up here.
        'header': {'game': GAME,
                   'segment': f'HOLE {hole} · {_BET_LABEL[key]}' if hole
                              else _BET_LABEL[key]},
        # No headline while the round runs: the strip is the content.
        'number': {'text': '', 'colour': 'neutral'},
        'sides' : [],
        'strip' : _strip(summary, player_id, key),
        'state' : {'word': '', 'to_play': ''},
        'pips'  : [],
        'final' : None,
        'footer': {'context': _context(summary, key, played),
                   'money': _exposure(summary, player_id)},
        'thru'  : thru_line(played, gross_to_par(
            _reader_scorecard(summary, player_id), player_id)),
    }


def _cash(v) -> str:
    sign = '+' if v > 0 else ('−' if v < 0 else '')
    return f'{sign}${abs(v):,.0f}'


def _team_title(ids, summary) -> str:
    names = {p.get('player_id'): p.get('name', '')
             for p in (summary.get('players') or [])}
    return ' & '.join(_first(names.get(i, '')).title() for i in ids)


def annandale_friday_final_state(foursome, *, player_id=None) -> dict:
    """Round sign-off — **keeps the board**, with money in place of holes.

    The big figure is the reader's net across every match he is in; the strip
    is each match's result FOR HIM, the third still held back; the footer names
    whom he collects from and whom he pays, **each** — every golfer settles
    with every golfer on the other side. The rules come off: nothing can
    change, so a 2px underline repeating the colour is decoration.

    Money is `total_capped` throughout, the same figure settlement uses — the
    loss cap is per side per Nassau and an uncapped figure here would tell a
    golfer he owes more than he can be asked for.
    """
    summary = _summary(foursome)
    if summary is None:
        return {}

    colours = _team_colours(summary, player_id)
    playing = _playing(summary, player_id)
    nets = {p.get('player_id'): float(p.get('net') or 0)
            for p in (summary.get('players') or [])}

    strip, owed, owing = [], [], []
    for m in _order(summary.get('matches') or [], player_id):
        s = m.get('summary') or {}
        s1 = m.get('side1_ids') or []
        s2 = m.get('side2_ids') or []
        total = float((s.get('payouts') or {}).get('total_capped')
                      or (s.get('payouts') or {}).get('total') or 0)
        winner = (m.get('side1_team') if total > 0
                  else (m.get('side2_team') if total < 0 else None))
        mine = _mine(m, player_id)
        # From the READER's side when it is his; from side 1's when it is not,
        # which is the only honest reading of a match he is not in.
        signed = -total if player_id in s2 else total
        top, bottom, dots = _lines(m, summary, player_id, colours)
        strip.append({
            'label' : top,
            'label2': bottom,
            'name'  : '',
            'figure': _cash(signed) if total else 'EVEN',
            'colour': colours.get(winner, '') if winner is not None else '',
            'rule'  : '',
            'dots'  : dots,
            'chip'  : '',
            'dim'   : not mine and playing,
            'is_reader': mine,
        })
        if mine and total:
            other = s2 if player_id in s1 else s1
            (owed if signed > 0 else owing).append(
                (_team_title(other, summary), abs(total)))

    bits = [f'collect ${a:,.0f} from {n}' for n, a in owed]
    bits += [f'pay {n} ${a:,.0f}' for n, a in owing]
    context = ('Each · ' + ' · '.join(bits)) if bits else 'Nothing to settle'
    played_in = sum(1 for m in summary.get('matches') or []
                    if _mine(m, player_id))
    net = nets.get(player_id, 0.0)

    return {
        'kind'  : KIND,
        'header': {'game': GAME, 'segment': 'ROUND COMPLETE'},
        'closed': True,
        'number': {'text': _cash(net) if net else 'EVEN', 'colour': 'mint'},
        'sides' : [],
        'strip' : strip,
        'state' : {'word': f'{played_in} NASSAUS' if played_in else '',
                   'to_play': ''},
        'pips'  : [],
        'final' : None,
        'footer': {'context': context, 'money': ''},
        'thru'  : thru_line(18, gross_to_par(
            _reader_scorecard(summary, player_id), player_id)),
    }
