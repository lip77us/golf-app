"""
services/live_activity_triple_cup.py
------------------------------------
The Triple Cup lock screen — **one composition carrying two games.**

Spec: `~/Downloads/handoff-lock-screens 2/triple-cup/HANDOFF.md`.

One eighteen-hole round cut into thirds: Fourball (1–6), Foursomes (7–12), and
two Singles run together (13–18). Four points. **2½ wins the cup, 2–2 halves
it.**

The same format is two different products depending on who is playing it, and
the card ships in both configurations off one view model:

| | Casual cup | Team cup |
|---|---|---|
| Headline | the CUP SCORE — `0–0`, `1–1`, `3–1` | the WHOLE cup — `6½–4½` |
| Right slot | the match you are in + its segment | `12½ · TO WIN` |
| Strip | four discrete cells | one continuous needle |
| Pushes | none | lead change, cup decided |

Nothing else differs: same panel, same slot order, same type sizes.

## The headline is the cup score, including 0–0

`1–1`, not `2 UP`. Triple Cup exists to produce a cup score; the match in front
of you is a way of earning one point in it, which is a different question and
gets the smaller slot.

So the first six holes headline **`0–0`**. An earlier design pass swapped the
slots for the Fourball to avoid it, and that was wrong: **a headline that means
one thing before the first point and another after is a slot nobody can
learn.** `0–0` over four grey cells is the complete and true state of the cup
on the third tee.

## The strip is the needle, flattened

Sixes cut its pips because a round has no fixed number of matches — one ends
when it is decided, so three bars would be wrong as often as right. **Triple
Cup always has exactly four points, in a fixed order**, so four cells are the
format rather than a guess. That is why this card can carry a structure graphic
where Sixes could not.

## The two Singles are the only simultaneous state

Holes 13–18 have two matches live at once — the composition problem the format
was going to have and does not: **it happens once, for six holes, with two
matches, not four.** Both go on ONE sides line, surnames, yours first always.

A row each measured 163pt, over the ceiling on its own. **The sides line is one
row everywhere in this packet**, and that is a requirement rather than a
preference.

## Reserved and unused by this card

Three keys are part of the required set and are always empty here. They cannot
be removed without a build, and that is fine — but they are **reserved, not
features that are switched off**, and nobody should fill them in to be helpful
(`RULINGS-team-cup-lock.md` §6):

* **`pips`** — `[]` in the team configuration, which draws the needle instead.
  The casual configuration does use it, for four cells.
* **`final`** — `null` in every state including the closing frame. This card
  keeps its BOARD on sign-off; `closed` is what tells the widget.
* **`footer.money`** — empty by design. **Cup money settles in the team room**,
  so the personal slot the casual cards carry has nothing to say here.

`footer.context` joined them on 22 Sep: `2 groups still out` is on the
leaderboard, and the footer keeps its row for `THRU` alone.
"""
from services.live_activity_registry import (hole_facts, hole_in_play,
                                             surname, thru_line)

KIND = 'triple_cup'

# 2½ of 4 wins it; 2–2 halves it. Derived from the points available rather
# than written down, so a format with a different shape cannot disagree.
def _to_win(points_available) -> float:
    return (points_available or 4) / 2 + 0.5


def _score(v) -> str:
    """`3`, `2½`. Halves are real points here and a `.5` reads as a decimal."""
    whole, half = divmod(round(float(v or 0) * 2), 2)
    return f'{whole}½' if half else f'{whole}'


def _number(a, b, colour_a, colour_b) -> dict:
    """The headline, with each digit wearing its own team's colour.

    `2–1` entirely in orange says *orange leads*. It does not say which digit
    is his, and the golfer has to hold a convention to work it out. Colouring
    them separately is strictly more information in the same pixels: it says
    whose each number is, and it still says who leads — more plainly than the
    old rule did, because the larger number now wears the leader's colour on
    its own. `0–0` with one digit of each colour is self-evidently level, so
    the neutral-white headline retires (`RULINGS-team-cup-lock.md` §4).

    **It ships as an optional field, never a rename.** `text` stays exactly as
    it was and stays authoritative for every installed phone; `parts` sits
    alongside it, which old builds ignore and new builds prefer. No phone goes
    dark, and the server can send parts before the build that draws them.

    `colour` is kept too, for the same reason — it is what an old build paints
    the whole string with.
    """
    lead = colour_a if a > b else (colour_b if b > a else 'neutral')
    return {
        'text'  : f'{_score(a)}–{_score(b)}',
        'colour': lead,
        # The separator is neither side's, so it is neither side's colour.
        'parts' : [{'text': _score(a), 'colour': colour_a},
                   {'text': '–',       'colour': 'sep'},
                   {'text': _score(b), 'colour': colour_b}],
    }


def _live_match(summary, hole):
    """The match the group is standing in, or None once the round is done."""
    if hole is None:
        return None
    for m in (summary.get('matches') or []):
        if (m.get('start_hole') or 0) <= hole <= (m.get('end_hole') or 0):
            return m
    return None


def _singles_live(summary, hole) -> list:
    """Both singles, when the round is in them. Empty everywhere else."""
    if hole is None:
        return []
    out = [m for m in (summary.get('matches') or [])
           if m.get('segment') == 'singles'
           and (m.get('start_hole') or 0) <= hole <= (m.get('end_hole') or 0)]
    return out if len(out) > 1 else []


def _margin_text(m) -> str:
    """`2 up`, `2 dn`, `all sq` — from team 1's side, flipped for the reader."""
    up = m.get('holes_up_final')
    if up is None:
        return 'all sq'
    if up == 0:
        return 'all sq'
    return f'{abs(up)} up' if up > 0 else f'{abs(up)} dn'


def _cells(summary) -> list:
    """Four cells, left to right in play order — no labels; the state slot
    names which one is live.

    `blue` / `orange` banked, `halved` for a 50/50 hard-stop gradient, and
    `out` for a point nobody has yet.
    """
    out = []
    for m in (summary.get('matches') or []):
        status = m.get('status')
        result = m.get('result')
        if status != 'complete' or result is None:
            out.append('out')
        elif result == 'halved':
            out.append('halved')
        elif result in ('team1', 'T1'):
            out.append('blue')
        elif result in ('team2', 'T2'):
            out.append('orange')
        else:
            out.append('out')
    return out


def _cannot_lose(t1, t2, available) -> bool:
    """The single moment the CUP outranks the hole.

    With one point still out at 2–1, blue cannot lose: the worst case is 2–2
    and a halved cup. That is the one override on the right-hand slot.
    """
    out = (available or 4) - t1 - t2
    lead = abs(t1 - t2)
    return out > 0 and lead >= out


def _pairing(m, key) -> str:
    """`Kelly & Moran` — surnames, because two of them and a `v.` is already
    most of a 320-point row."""
    names = (m.get(key) or {}).get('players') or []
    return ' & '.join(surname(n).title() for n in names if n)


def _casual_sides(summary, live, hole, player_id, mine_is_t1) -> list:
    """The sides line — ONE row, always, and a list rather than a string.

    Each entry is a dot, a name at full weight, and a dim qualifier after it.
    That is what lets the two live Singles share a row: `You v. Reid · 1 up`
    and `Moran v. Naylor · 2 dn` at 12.5px are a line, where a row each
    measured 163pt and put the card over the ceiling on its own.

    **Yours first, always**, and the state slot holds yours.
    """
    mine = 'blue' if mine_is_t1 else 'orange'
    theirs = 'orange' if mine_is_t1 else 'blue'

    singles = _singles_live(summary, hole)
    if singles:
        def one(m):
            t1n = (m.get('team1') or {}).get('players') or []
            t2n = (m.get('team2') or {}).get('players') or []
            a = surname(t1n[0]).title() if t1n else ''
            b = surname(t2n[0]).title() if t2n else ''
            is_mine = player_id in {p.get('player_id')
                                    for p in (m.get('players') or [])}
            return {'names': f'{"You" if is_mine else a} v. {b}',
                    'note': f'· {_margin_text(m)}',
                    'colour': mine if is_mine else theirs,
                    'leading': is_mine}
        ordered = sorted(singles, key=lambda m: 0 if player_id in {
            p.get('player_id') for p in (m.get('players') or [])} else 1)
        return [one(m) for m in ordered]

    # One match live: both pairings, named. The `v.` rides as the first
    # entry's qualifier so the row is one renderer rather than two.
    if live is not None and (_pairing(live, 'team1')
                             or _pairing(live, 'team2')):
        first, second = ('team1', 'team2') if mine_is_t1 else ('team2', 'team1')
        return [{'names': _pairing(live, first), 'note': 'v.',
                 'colour': mine, 'leading': True},
                {'names': _pairing(live, second), 'note': '',
                 'colour': theirs, 'leading': False}]

    names = [summary.get('team1_name') or 'Blue',
             summary.get('team2_name') or 'Orange']
    if not mine_is_t1:
        names.reverse()
    return [{'names': names[0], 'note': 'v.', 'colour': mine, 'leading': True},
            {'names': names[1], 'note': '', 'colour': theirs,
             'leading': False}]


def _cup_standings(foursome):
    """The cup this group's match is one match IN, or None for a casual cup.

    **This is what makes it the team configuration** — not a setting, not a
    flag on the round. A Triple Cup inside a Ryder Cup is a different product
    from four men playing for twenty-five dollars, and the thing that
    distinguishes them is whether there is a cup-wide score to report.
    """
    rnd = getattr(foursome, 'round', None)
    tournament = getattr(rnd, 'tournament', None)
    if tournament is None:
        return None
    from services.cup_standings import (cup_round_live_summary,
                                        cup_standings_summary)
    # A round with no cup config contributes nothing to a cup and has none to
    # report — a tournament round is not automatically a cup round.
    if cup_round_live_summary(rnd) is None:
        return None
    return cup_standings_summary(tournament)


def _groups_still_out(round_obj) -> str:
    """`3 groups still out` — the footer-left slot in the team cup.

    **Cup money settles in the team room, not on a lock screen**, so the stake
    the casual card carries has nothing to say here. What a captain wants off
    a glance is how much of the cup is unresolved, and a group is the unit he
    thinks in.

    A group is counted once however many of its points are outstanding: two
    Singles still on the course are one group still out, not two.
    """
    from services.cup_standings import cup_round_live_summary
    live = cup_round_live_summary(round_obj)
    if not live:
        return ''
    out = set()
    for m in (live.get('matches') or []):
        awarded = float(m.get('team1_points') or 0) + \
                  float(m.get('team2_points') or 0)
        if awarded + 1e-9 < float(m.get('total_possible') or 0):
            out.update(m.get('groups') or [])
    if not out:
        return 'all groups in'
    return f'{len(out)} group{"s" if len(out) != 1 else ""} still out'


def _cup_palette(cup) -> tuple:
    """Which of the set's two side colours each cup team wears.

    Position — team 1 blue, team 2 orange — is the app's convention and is
    what the casual card, the cells and the needle all use. But a cup's teams
    have their OWN names and colours, and a card that headlines a blue number
    while the state slot says `ORANGE TAKES IT` is telling a golfer the
    opposite of the truth in the one glance the card exists for. That is the
    same defect as the fourball's hardcoded blue, arriving by a different
    route.

    So the declared colours win when they can: both sides must name a colour
    the widget actually draws, and they must name different ones. Anything
    else — a Red/Green cup, a cup where both picked blue, a cup with no
    colours set — falls back to position, where at least the two halves of
    the needle are always distinguishable.

    **Red wears orange.** Red v. Blue is the app's own DEFAULT cup
    (`cup_standings` fills team 1 as Red), and before this alias it was the
    case that fell back on position: Red's points drawn in BLUE and the Blue
    team in orange — the exact inversion this function exists to prevent, on
    the most common cup there is. The widget draws two side colours and red
    is not one of them; orange is the nearest hue and can never be mistaken
    for blue. Mapping it here, on the server, means every installed build
    gets it — adding a red to the widget would have needed a release, and a
    needle payload that stopped carrying its required `orange` key would have
    taken the whole card down on every older phone. (Paul, 22 Sep 2026:
    orange is the better read on the glass anyway.)
    """
    known = {'blue', 'orange'}
    alias = {'red': 'orange'}
    one = (cup.get('team1_colour') or '').strip().lower()
    two = (cup.get('team2_colour') or '').strip().lower()
    one, two = alias.get(one, one), alias.get(two, two)
    if one in known and two in known and one != two:
        return one, two
    return 'blue', 'orange'


def _team_sides(summary, overall, hole, mine_is_t1, palette) -> list:
    """`Your Triple Cup · 1–0, in the Foursomes` — one entry.

    The headline has been taken by the cup, and your own match is the thing
    you can still do something about, so it keeps the sides line. **It reads
    as a sub-total of the cup rather than as a match**, which is why the
    qualifier is a cup score and not `2 up`.
    """
    t1 = float(overall.get('team1_points') or 0)
    t2 = float(overall.get('team2_points') or 0)
    mine, theirs = (t1, t2) if mine_is_t1 else (t2, t1)
    my_colour, their_colour = ((palette[0], palette[1]) if mine_is_t1
                               else (palette[1], palette[0]))
    # **`leading` is driven, not hardcoded** (`RULINGS-team-cup-lock.md` §6).
    # It was `True` in every fixture including the one where the reader's group
    # lost 0–4, and the widget appears not to read it — a field that is always
    # true is a trap for the next person who believes it, and this is a
    # contract where believing the wrong thing takes cards down. It is a
    # required key, so it cannot be dropped without a build; it is driven
    # instead, and it means what the row is about: your group ahead in its own
    # four points.
    entry = {'names': 'Your Triple Cup',
             'colour': my_colour,
             'leading': mine > theirs}

    live = _live_match(summary, hole)
    if live is not None:
        # **`Playing singles`, not `in the singles 1`.** The ordinal named
        # which singles match inside the segment, which is not something the
        # reader needs on a lock screen — he knows which match he is in, he is
        # standing in it. Naming the segment is useful; numbering it is not
        # (`RULINGS-team-cup-lock.md` §4b). `segment` rather than `label` is
        # what carries that: the segment name is the unnumbered one.
        label = (live.get('segment') or live.get('label') or '').lower()
        entry['note'] = f'· {_score(mine)}–{_score(theirs)}, Playing {label}'
        # **The same split-digit rule, one row down** — `2–0` in one colour has
        # the identical defect the headline had: monochrome, so it does not say
        # which figure is the reader's group. Additive, like `number.parts`:
        # `note` above stays authoritative and an old build draws it whole,
        # while a build that knows these two draws `names · sub · note_short`,
        # which is the drawing.
        entry['sub'] = {
            'text' : f'{_score(mine)}–{_score(theirs)}',
            'parts': [{'text': _score(mine),   'colour': my_colour},
                      {'text': '–',            'colour': 'sep'},
                      {'text': _score(theirs), 'colour': their_colour}],
        }
        entry['note_short'] = f'· Playing {label}'
        return [entry]

    # The round is over. **No `sub` here, and that is not an oversight**: the
    # verb already says which figure is the reader's, so the defect §4 exists
    # to fix is absent, and every build draws this frame identically.
    if mine > theirs:
        entry['note'] = f'· won {_score(mine)}–{_score(theirs)}'
    elif theirs > mine:
        entry['note'] = f'· lost {_score(mine)}–{_score(theirs)}'
    else:
        entry['note'] = f'· halved {_score(mine)}–{_score(theirs)}'
    return [entry]


def _group_alloc(summary, hole) -> dict:
    """`{player_id: {hole: strokes}}` for every golfer live on this hole.

    Triple Cup allocates per MATCH, and holes 13–18 have two matches running
    at once, so the group's allocation is the union of whatever is live — not
    one match's. `strokes_by_hole` is the same prospective map the score-entry
    dots read, which is what lets the band fire on a hole nobody has scored.
    """
    out: dict = {}
    for m in (summary.get('matches') or []):
        if not ((m.get('start_hole') or 0) <= hole <= (m.get('end_hole') or 0)):
            continue
        for p in (m.get('players') or []):
            pid = p.get('player_id')
            by_hole = p.get('strokes_by_hole') or {}
            if pid is None or not by_hole:
                continue
            # The summary's keys can arrive as strings through a cache.
            out.setdefault(pid, {}).update(
                {int(k): int(v or 0) for k, v in by_hole.items()})
    return out


def _band(foursome, summary, player_id, hole) -> dict | None:
    """The popping band, or None — `triple_cup` only, for now.

    **The foursomes segment is the one shape this form cannot describe.**
    Alternate shot allocates a TEAM stroke and mirrors it onto both partners,
    so naming golfers there would put two names up for one stroke on the ball
    — and four names when both sides pop, which says nothing. The segment
    falls back to the shared personal band, which stays true: the reader's own
    ball gets a stroke on this hole. Design has not drawn the team form.
    """
    from services.live_activity_registry import (group_stroke_band,
                                                 stroke_ribbon)
    if not hole:
        return None
    alloc = _group_alloc(summary, hole)
    live = _live_match(summary, hole)
    if live is not None and live.get('segment') == 'foursomes':
        text = stroke_ribbon(foursome, player_id, hole, alloc)
        return {'text': text, 'filled': True} if text else None
    return group_stroke_band(foursome, player_id, hole, alloc)


def _cup_header(foursome, cup) -> str:
    """`SHELDON CUP · ROUND 2`.

    **`ROUND`, not the design's `DAY`.** The app has called them rounds
    everywhere since it had them, and two vocabularies for one thing is how a
    golfer ends up believing he is looking at a different competition — the
    same argument that kept the Points payoff models in the config screen's
    words. A cup can also play two rounds in one day, which `DAY 2` would then
    be lying about.
    """
    rnd = getattr(foursome, 'round', None)
    tt = getattr(getattr(rnd, 'tournament', None), 'team_tournament', None)
    name = (getattr(tt, 'cup_name', '') or '').upper()
    number = getattr(rnd, 'round_number', None) or 0
    if name and number > 1:
        return f'{name} · ROUND {number}'
    return name or 'TRIPLE CUP'


def _team_state(foursome, summary, cup, *, player_id, thru, mine_is_t1):
    """The team configuration — same composition, a different view model.

    Seven rows of the packet's difference table, and the headline is the one
    that carries the rest: **the whole cup**, not this group's four points. A
    point here is one twenty-fourth of the thing being decided, and the card
    stops being about the match the moment there is a cup score to report.
    """
    from services.live_activity_registry import gross_to_par

    overall = summary.get('overall') or {}
    played = thru or 0
    hole = hole_in_play(foursome, played)

    t1 = float(cup.get('team1_points') or 0)
    t2 = float(cup.get('team2_points') or 0)
    total = float(cup.get('total_possible') or 0)

    palette = _cup_palette(cup)

    # **Your own match cannot go in this slot.** The headline now counts
    # twenty-four points and eleven other golfers, and a `1 up` beside it
    # reads as a contradiction. Points-to-win is the figure a captain recites
    # all afternoon.
    winner = cup.get('winner_team')
    if winner in (1, 2):
        # The cup can clinch while your group is still on the fourteenth, and
        # when it does it outranks everything else on the card — the same rule
        # that gives the casual cup its CANNOT LOSE override.
        side = (cup.get('team1_name') if winner == 1
                else cup.get('team2_name')) or ''
        state = {'word': side.upper(), 'to_play': 'TAKES IT', 'colour': 'mint'}
    elif cup.get('cup_status') == 'tied':
        state = {'word': 'HALVED', 'to_play': 'CUP SHARED', 'colour': 'mint'}
    else:
        state = {'word': _score(cup.get('to_win')), 'to_play': 'TO WIN'}

    band = _band(foursome, summary, player_id, hole)

    return {
        'kind'  : KIND,
        'header': {'game': _cup_header(foursome, cup),
                   'segment': hole_facts(foursome, player_id, hole)},
        # The band names the group's strokes rather than the reader's alone
        # — see `live_activity_registry.group_stroke_band`. `filled` is
        # optional and additive: an old build draws the text in the shipped
        # solid gold, which is right for the case it is most often in. The key
        # is one word because a snake_case one would force a `CodingKeys` enum
        # onto the Swift `ContentState`, where a missed case takes the whole
        # card down.
        **({'ribbon': band['text'],
            'filled': band['filled']} if band else {}),
        'number': _number(t1, t2, palette[0], palette[1]),
        'sides' : _team_sides(summary, overall, hole, mine_is_t1, palette),
        'state' : state,
        # **The needle instead of the cells.** Twenty-four points as discrete
        # cells at 320 points would be decoration; the same 7pt strip carries
        # the same fact as one continuous bar.
        'pips'  : [],
        # Keyed by SIDE, not by team number — the needle's left half is
        # team 1 and wears whatever colour team 1 wears.
        'needle': {palette[0]: (t1 / total) if total else 0.0,
                   palette[1]: (t2 / total) if total else 0.0},
        'final' : None,
        # **`2 groups still out` comes off** (`RULINGS-team-cup-lock.md` §4b).
        # It is real information and it is on the leaderboard, which is where
        # somebody who wants it will look. On the card it was competing for the
        # widest row with the one thing that has to be there, and `THRU` is the
        # locked corner. The footer keeps its row and its height — `THRU`
        # alone, right-aligned. `_groups_still_out` stays: the cup pushes use
        # it for their body, which is a sentence rather than a corner.
        'footer': {'context': '', 'money': ''},
        'thru'  : thru_line(played, gross_to_par(summary, player_id)),
    }


def triple_cup_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """One composition, two games — the configuration follows the cup.

    Nothing about the panel changes between them: same slot order, same type
    sizes, same one-row sides line. What changes is what each slot is ABOUT,
    and that is decided by whether this group's match is one match in a
    tournament cup.
    """
    from services.triple_cup import triple_cup_summary
    from services.live_activity_registry import gross_to_par

    summary = triple_cup_summary(foursome)
    if not summary:
        return {}

    overall = summary.get('overall') or {}
    t1 = float(overall.get('team1_points') or 0)
    t2 = float(overall.get('team2_points') or 0)
    available = overall.get('points_available') or 4

    played = thru or 0
    hole = hole_in_play(foursome, played)
    live = _live_match(summary, hole)

    # Which side the reader is on, so "yours first" and the margin can be
    # written from his side rather than team 1's.
    mine_is_t1 = player_id in set(summary.get('team1_ids') or [])

    cup = _cup_standings(foursome)
    if cup is not None:
        return _team_state(foursome, summary, cup, player_id=player_id,
                           thru=thru, mine_is_t1=mine_is_t1)

    # The right-hand slot: the live segment and how its point is going, unless
    # the cup can no longer be lost.
    if _cannot_lose(t1, t2, available):
        state = {'word': 'CANNOT LOSE',
                 'to_play': f'{_score(available / 2)}–{_score(available / 2)} '
                            f'HALVES IT'}
    elif live is not None:
        label = (live.get('label') or live.get('segment') or '').upper()
        up = live.get('holes_up_final')
        if up is None or up == 0:
            word = 'ALL SQ'
        else:
            mine_up = up if mine_is_t1 else -up
            word = f'{abs(mine_up)} {"UP" if mine_up > 0 else "DN"}'
        state = {'word': word, 'to_play': f'IN THE {label}'}
    else:
        state = {'word': '', 'to_play': ''}

    sides = _casual_sides(summary, live, hole, player_id, mine_is_t1)

    unit = float((summary.get('money') or {}).get('bet_unit') or 0)
    band = _band(foursome, summary, player_id, hole)
    return {
        'kind'  : KIND,
        'header': {'game': 'TRIPLE CUP',
                   'segment': hole_facts(foursome, player_id, hole)},
        **({'ribbon': band['text'],
            'filled': band['filled']} if band else {}),
        # The casual cup's headline has the identical defect and comes off the
        # same builder, so it gets the same split. Position is the palette here
        # — team 1 blue — which is the app's own convention everywhere else on
        # this card.
        'number': _number(t1, t2, 'blue', 'orange'),
        'sides' : sides,
        'state' : state,
        # Four cells are the FORMAT, not a guess — which is why this card can
        # carry a structure graphic where Sixes could not.
        'pips'  : _cells(summary),
        'final' : None,
        'footer': {'context': f'${unit:,.0f} a man' if unit else '',
                   'money': ''},
        'thru'  : thru_line(played, gross_to_par(summary, player_id)),
    }


def _cash(v) -> str:
    sign = '+' if v > 0 else ('−' if v < 0 else '')
    return f'{sign}${abs(v):,.0f}'


def _cup_word(mine, theirs) -> str:
    """`CUP WON` / `CUP LOST` / `CUP HALVED`, from the reader's side.

    **Not the design's `CUP RETAINED`.** Retaining is a holder keeping a cup
    he already had, and nothing in the app knows who held it last — a card
    that said RETAINED would be guessing at the one moment it is most
    obviously checkable.
    """
    if mine > theirs:
        return 'CUP WON'
    if theirs > mine:
        return 'CUP LOST'
    return 'CUP HALVED'


def triple_cup_final_state(foursome, *, player_id=None) -> dict:
    """Round sign-off, in whichever configuration the card has been in.

    **The headline does not move.** It has been the cup score since the third
    tee and it is the cup score now — the one card in the set whose closing
    frame changes the least, because the thing it reports is the thing that
    just finished. What changes is the right-hand slot: the segment you were
    in becomes the money, or in a team cup the cup's own verdict.
    """
    from services.triple_cup import triple_cup_summary
    from services.live_activity_registry import gross_to_par

    summary = triple_cup_summary(foursome)
    if not summary:
        return {}

    overall = summary.get('overall') or {}
    t1 = float(overall.get('team1_points') or 0)
    t2 = float(overall.get('team2_points') or 0)
    mine_is_t1 = player_id in set(summary.get('team1_ids') or [])
    mine, theirs = (t1, t2) if mine_is_t1 else (t2, t1)

    thru = thru_line(18, gross_to_par(summary, player_id))
    cup = _cup_standings(foursome)

    if cup is not None:
        # The team cup signs off on the CUP's verdict, not the group's. Your
        # four points are one twenty-fourth of it and the card has said so all
        # afternoon; it does not change its mind at the last.
        palette = _cup_palette(cup)
        c1 = float(cup.get('team1_points') or 0)
        c2 = float(cup.get('team2_points') or 0)
        winner = cup.get('winner_team')
        status = cup.get('cup_status')
        # **The verdict is the CUP's, from the reader's cup side.** This used
        # to pass the GROUP's points to `_cup_word`, so a foursome that won
        # its four on a cup that finished 4–4 signed off `CUP WON` directly
        # above `HALVED · CUP SHARED` — the card contradicting itself in the
        # one frame people screenshot.
        my_team = 1 if mine_is_t1 else 2
        if winner in (1, 2):
            side = (cup.get('team1_name') if winner == 1
                    else cup.get('team2_name')) or ''
            state = {'word': side.upper(), 'to_play': 'TAKES IT',
                     'colour': 'mint'}
            verdict = 'CUP WON' if winner == my_team else 'CUP LOST'
        elif status == 'tied':
            state = {'word': 'HALVED', 'to_play': 'CUP SHARED',
                     'colour': 'mint'}
            verdict = 'CUP HALVED'
        else:
            # **Not decided yet — a cup with rounds still to play.** This fell
            # into the HALVED branch too, so Red finishing round 1 of 2 at 5–3
            # would have been told the cup was shared. The running card's
            # slot still answers the question a captain has now.
            state = {'word': _score(cup.get('to_win')), 'to_play': 'TO WIN'}
            verdict = 'ROUND COMPLETE'
        total = float(cup.get('total_possible') or 0)
        return {
            'kind'  : KIND,
            'header': {'game': _cup_header(foursome, cup),
                       'segment': verdict},
            'closed': True,
            'number': _number(c1, c2, palette[0], palette[1]),
            'sides' : _team_sides(summary, overall, None, mine_is_t1, palette),
            'state' : state,
            'pips'  : [],
            'needle': {palette[0]: (c1 / total) if total else 0.0,
                       palette[1]: (c2 / total) if total else 0.0},
            'final' : None,
            'footer': {'context': 'Dismisses in 5 min', 'money': ''},
            'thru'  : thru,
        }

    # The casual cup settles into money. **Winners take all** — the losing
    # side gets nothing, which is why there is no running per-golfer figure to
    # track all round and no `$0` to print on a halved cup.
    money = summary.get('money') or {}
    by_player = money.get('by_player') or []
    losers = [e for e in by_player if float(e.get('amount') or 0) < 0]
    winners = [e for e in by_player if float(e.get('amount') or 0) > 0]
    # The reader's own figure follows his SIDE, which the cup score has
    # already settled — `by_player` carries names and amounts but no
    # player_id, so there is nothing to match him on directly.
    amount = 0.0
    if mine > theirs:
        amount = abs(float((winners[0] or {}).get('amount') or 0)) if winners else 0.0
    elif theirs > mine:
        amount = -abs(float((losers[0] or {}).get('amount') or 0)) if losers else 0.0

    if amount > 0:
        names = ' and '.join(surname(e.get('name', '')).title() for e in losers)
        line = f'Collect from {names}' if names else ''
    elif amount < 0:
        names = ' and '.join(surname(e.get('name', '')).title() for e in winners)
        line = f'Pay {names}' if names else ''
    else:
        # **Not `$0`.** A halved cup means nothing changes hands, and a zero
        # in a money slot reads as a round played for nothing.
        line = 'Halved — nothing changes hands'

    return {
        'kind'  : KIND,
        'header': {'game': 'TRIPLE CUP', 'segment': _cup_word(mine, theirs)},
        'closed': True,
        'number': _number(t1, t2, 'blue', 'orange'),
        'sides' : [{'names': line, 'colour': '', 'leading': False}],
        'state' : {'word': _cash(amount) if amount else 'EVEN',
                   'to_play': 'WINNERS TAKE ALL', 'colour': 'mint'},
        # All four cells filled: **the segments won are readable off the
        # strip**, which is the strip earning its place one last time.
        'pips'  : _cells(summary),
        'final' : None,
        'footer': {'context': 'Dismisses in 5 min', 'money': ''},
        'thru'  : thru,
    }
