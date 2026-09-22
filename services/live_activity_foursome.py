"""
services/live_activity_foursome.py
----------------------------------
**The foursome-format card — one composition, four games.**

Scramble, Shamble, Better Ball and Irish Rumble all put a GROUP on the board
against a field of groups, and a golfer standing on the tee wants the same
three figures from all four: **his team's net to par, his place, and the leader
with the gap.** Nothing about that question changes with the format, so nothing
about the card does either
(`handoff-foursome-formats/HANDOFF.md` §6, `live-activity-foursome-formats.html`).

The four differ in exactly one line each:

| Game | What changes |
| --- | --- |
| Scramble | nothing — it is the card |
| Shamble | the name |
| Better Ball | the count lives in the TITLE — `BEST 2 OF 4` |
| Irish Rumble | the header's YARDAGE becomes the count — `· 2 BALLS` |

Better Ball's count is in the title because the app names the game from it and
it cannot change mid-round; a header corner repeating it would be the same
three words eighteen times. Rumble's DOES change, and it is the one number that
changes what the group does on the tee — so it takes the corner, from the
yardage, which is the one figure on that card nobody needs. Neither costs a
slot, and all four measure the same.

## What this card does NOT have, and why each is deliberate

**No needle.** It can only say *two sides splitting a pool*, and a field of
nine groups has neither. The row comes out and the card is 120pt — the
shortest in the set, 40pt clear of the ceiling. The payload still sends
`needle: {blue: 0, orange: 0}` because the key is part of the required set;
**the widget must not draw an empty track**, which is a rule about the widget
rather than about this card.

**No popping band.** A scramble is one ball off a team allowance, so nobody
pops. Shamble, Better Ball and Rumble golfers do play their own balls off their
own handicaps — but the band is local to `triple_cup` until it has run through
a cup, so none of the four gets one yet. When it rolls out these are the first
three that should have it.

**No pushes.** Same as Points, Stableford and Stroke Play. Nine groups
resolving holes all afternoon would fire all afternoon.

## Colour

**The score and the place are both mint** — the two figures the card exists to
answer, on one baseline. Everything else stays quiet: the leader's line is
context, the header and footer are corners. **On the closing frame the headline
goes white and the place keeps the mint**, because the score has stopped being
a question and the place is the result.

Mint is safe here for the reason it is not safe on a cup card: **there are no
side colours to be confused with.** Gold keeps its separate job — the stakes
going up — so the two accents never compete.
"""
from services.live_activity_registry import (fmt_to_par, hole_facts,
                                             hole_in_play, holes_played,
                                             surname, thru_line)

KIND = 'foursome'

# Rumble's closer counts all four, and that is the hole the whole format is
# built around. Gold because gold means **the stakes just went up** — the same
# rule that keeps Skins' carry and Banker's counter-double amber.
#
# **First use of gold outside the popping band**, which the packet raises as a
# question rather than a ruling. The alternative is white, like every other
# count, and letting `ALL 4` speak for itself. Kept as its own field so
# answering it the other way is deleting one line rather than unpicking a
# string.
ALL_FOUR_TAIL = 'ALL 4'


def _place(rank, tied) -> str:
    """`1ST`, `T3RD`. **The `T` is in the layout, not bolted on** — a foursome
    field ties constantly, so a place that cannot show a tie is wrong most
    weeks rather than occasionally."""
    if not rank:
        return '—'
    n = int(rank)
    suffix = ('TH' if 11 <= n % 100 <= 13
              else {1: 'ST', 2: 'ND', 3: 'RD'}.get(n % 10, 'TH'))
    return f'{"T" if tied else ""}{n}{suffix}'


def _team_name(row) -> str:
    """The group's own name when it has one; otherwise its golfers.

    **The leader is a TEAM, never a golfer** — a scramble has no individual
    score to name one with. Surnames in HANDICAP ORDER, lowest first, because
    that is what makes the cut worth anything: when the row overruns, the
    survivors are the two the field would name. What overruns becomes an
    **ellipsis on whole names only** — `Gunst · Maiolini…`, never a cut
    surname, which reads as a typo rather than as an abbreviation.
    """
    if row.get('name'):
        return row['name']
    names = [surname(n).title() for n in (row.get('players') or []) if n]
    if not names:
        return row.get('group') or ''
    # ~200pt of row at 12.5px is about 32 characters; four short surnames
    # usually fit, and the cut is whole names only.
    out, used = [], 0
    for n in names:
        cost = len(n) + (3 if out else 0)
        if used + cost > 32 and out:
            return ' · '.join(out) + '…'
        out.append(n)
        used += cost
    return ' · '.join(out)


def _sides(rows, mine, closed) -> list:
    """One row: who to chase, what they are on, and how far away they are.

    **The label flips rather than the row moving.** A reader in second is told
    who leads; a reader leading is told who is coming, because the number he
    needs is the same one from the other side. On the closing frame it becomes
    `WON BY`, which is the only state where the row is history rather than a
    target.
    """
    if not rows or mine is None:
        return []
    leader = rows[0]
    me = next((r for r in rows if r['key'] == mine), None)
    if me is None:
        return []

    i_lead = me['key'] == leader['key']
    # A leader is chasing the man behind him, so the row names the NEXT team.
    other = rows[1] if (i_lead and len(rows) > 1) else leader
    if other is me:
        return []

    mine_tp, theirs_tp = me.get('to_par'), other.get('to_par')
    if mine_tp is None or theirs_tp is None:
        gap = ''
    else:
        d = abs(mine_tp - theirs_tp)
        if d == 0:
            gap = 'LEVEL'
        elif i_lead:
            gap = f'LEAD {d}'
        else:
            gap = f'{d} BACK'

    if closed:
        label = 'WON BY'
        other = leader
        theirs_tp = leader.get('to_par')
    else:
        label = 'NEXT' if i_lead else 'LEADER'

    return [{
        'label'  : label,
        'names'  : _team_name(other),
        'note'   : fmt_to_par(theirs_tp) if theirs_tp is not None else '',
        'figure' : gap,
        # **No dot and no side colour.** This line is context, not a side —
        # there are no sides here for a colour to mark, and a coloured dot
        # would be the card's third accent competing with the two that mean
        # something.
        'colour' : '',
        'leading': False,
    }]


def _state(rows, mine, closed) -> dict:
    """The place, and what it is a place out of.

    `OF 9` is the half that makes a place mean anything: third of nine is a
    result and third of three is not.
    """
    ranked = [r for r in rows if r.get('rank')]
    me = next((r for r in rows if r['key'] == mine), None)
    word = _place(me.get('rank'), me.get('tied')) if me else '—'
    # **The place keeps the mint on the closing frame**, where the headline
    # gives it up: the score has stopped being a question and the place is the
    # result.
    return {'word': word, 'to_play': f'OF {len(rows)}' if rows else '',
            'colour': 'mint'} if closed else {
        'word': word, 'to_play': f'OF {len(rows)}' if rows else ''}


def foursome_activity_state(foursome, rows, *, player_id=None, mine=None,
                            game_name='', segment=None, tail='',
                            thru=None, closed=False) -> dict:
    """The card, given a ranked field.

    `rows` is the shared shape every adapter below produces — `key`, `name` or
    `players`, `to_par`, `rank`, `tied` — sorted best first. Keeping the
    adapters outside means the four games disagree only about how a group's
    number is arrived at, which is the only thing they actually disagree about.
    """
    played = thru if thru is not None else holes_played(foursome)
    hole = hole_in_play(foursome, played)
    me = next((r for r in rows if r['key'] == mine), None)
    my_par = me.get('to_par') if me else None

    state = {
        'kind'  : KIND,
        'header': {
            'game': (game_name or 'FOURSOME').upper(),
            # `ROUND COMPLETE` rather than an invented HOLE 19 — a finished
            # round has no hole in play, and a locked corner with no par and
            # no yardage reads as a failed fetch.
            'segment': ('ROUND COMPLETE' if closed
                        else (segment if segment is not None
                              else hole_facts(foursome, player_id, hole))),
        },
        # The team's net to par — mint while it is still a question, white on
        # the closing frame.
        'number': {'text': fmt_to_par(my_par) if my_par is not None else '—',
                   'colour': 'neutral' if closed else 'mint'},
        'sides' : _sides(rows, mine, closed),
        'state' : _state(rows, mine, closed),
        'pips'  : [],
        # **Required, and zero.** The widget must read the zeros as "no track"
        # rather than drawing an empty one — a scramble has neither two sides
        # nor a pool for a needle to be about.
        'needle': {'blue': 0.0, 'orange': 0.0},
        'final' : None,
        'footer': {'context': 'Dismisses in 5 min' if closed else '',
                   'money': ''},
        'thru'  : thru_line(played, my_par),
    }
    if closed:
        state['closed'] = True
    if tail:
        state['header']['tail'] = tail
    return state


# ---------------------------------------------------------------------------
# The four adapters — the one thing the games actually disagree about
# ---------------------------------------------------------------------------
#
# Each turns its own engine's board into the shared row shape: `key`, a name or
# a list of players, `to_par`, `rank`, `tied`, best first. Everything after
# that is one composition, which is the point.


def _ranked(rows) -> list:
    """Rank on net to par, ties sharing a place and marked as sharing it.

    **No countbacks.** A foursome field ties most weeks — the allowance is a
    whole number — and an arbitrary tiebreak decides real money on a rule
    nobody agreed to. The same call every other board in this app makes.
    """
    scored = sorted([r for r in rows if r.get('to_par') is not None],
                    key=lambda r: r['to_par'])
    rank, previous = 0, None
    for i, r in enumerate(scored, start=1):
        if r['to_par'] != previous:
            rank, previous = i, r['to_par']
        r['rank'] = rank
    counts: dict = {}
    for r in scored:
        counts[r['rank']] = counts.get(r['rank'], 0) + 1
    for r in scored:
        r['tied'] = counts[r['rank']] > 1
    unscored = [dict(r, rank=None, tied=False)
                for r in rows if r.get('to_par') is None]
    return scored + unscored


def _my_foursome_key(rows, foursome) -> int | None:
    return foursome.id if any(r['key'] == foursome.id for r in rows) else None


def _group_field_rows(round_obj, config, balls_by_hole, *, force_cap):
    """Irish Rumble and Better Ball — the shared group-vs-field board."""
    from services.group_field import group_standings
    from services.irish_rumble import (_build_ir_score_index,
                                       _par_index_for_round)
    standings = group_standings(
        round_obj,
        balls_by_hole = balls_by_hole,
        score_index   = _build_ir_score_index(
            round_obj, config.handicap_mode, config.net_percent,
            force_cap=force_cap),
        par_by_hole   = _par_index_for_round(round_obj),
        entry_fee     = config.entry_fee,
        payouts       = config.payouts or [],
        net_percent   = config.net_percent,
    )
    # `group_standings` has already ranked and split ties; it carries the
    # figures this card needs under different names.
    return [{'key'    : r['foursome_id'],
             'name'   : r['group'],
             'to_par' : r['net_to_par'],
             'rank'   : r['rank'],
             # It ranks but does not mark ties, and this card must show them.
             'tied'   : sum(1 for x in standings
                            if x['rank'] == r['rank'] and r['rank']) > 1}
            for r in standings]


def better_ball_state(foursome, *, player_id=None, thru=None, final=False):
    from games.models import BetterBallConfig
    from services.better_ball import default_name
    rnd = foursome.round
    config = BetterBallConfig.objects.filter(round=rnd).first()
    if config is None:
        return {}
    rows = _group_field_rows(
        rnd, config, {h: config.balls_to_count for h in range(1, 19)},
        force_cap=True)
    return foursome_activity_state(
        foursome, rows, player_id=player_id,
        mine=_my_foursome_key(rows, foursome),
        # **The count lives in the title** — the app names the game from it and
        # it cannot change mid-round, so a header corner repeating it would be
        # the same three words on all eighteen holes.
        game_name=config.name or default_name(config.balls_to_count),
        thru=thru, closed=final)


def irish_rumble_state(foursome, *, player_id=None, thru=None, final=False):
    from games.models import IrishRumbleConfig
    from services.group_field import balls_by_hole_from_segments
    from services.live_activity_registry import hole_in_play, holes_played
    rnd = foursome.round
    config = IrishRumbleConfig.objects.filter(round=rnd).first()
    if config is None:
        return {}
    balls = balls_by_hole_from_segments(config.segments)
    rows = _group_field_rows(rnd, config, balls, force_cap=False)

    # **The yardage becomes the count.** Of hole, par and yardage, the yardage
    # is the one nobody needs — the hole is in front of them and this corner is
    # a scorecard corner, not a rangefinder. The count is the one number that
    # changes what the group does on the tee, and it changes hole to hole,
    # which is what earns it the slot Better Ball's does not need.
    played = thru if thru is not None else holes_played(foursome)
    hole = hole_in_play(foursome, played)
    segment, tail = None, ''
    if hole and not final:
        n = balls.get(hole)
        if n:
            par = _par_of(foursome, hole)
            head = f'HOLE {hole}' + (f' · PAR {par}' if par else '')
            if n >= 4:
                segment, tail = f'{head} · ', ALL_FOUR_TAIL
            else:
                segment = f'{head} · {n} BALL{"" if n == 1 else "S"}'
    return foursome_activity_state(
        foursome, rows, player_id=player_id,
        mine=_my_foursome_key(rows, foursome),
        game_name='Irish Rumble', segment=segment, tail=tail,
        thru=thru, closed=final)


def _par_of(foursome, hole):
    for m in foursome.memberships.select_related('tee'):
        if m.tee_id is None:
            continue
        return (m.tee.hole(hole) or {}).get('par')
    return None


def scramble_state(foursome, *, player_id=None, thru=None, final=False):
    """One ball a team, ranked on net against the field."""
    from services.scramble import scramble_summary
    rnd = foursome.round
    par = sum((_par_of(foursome, h) or 4) for h in range(1, 19))
    rows = _ranked([
        {'key'    : r.get('foursome_id') or r.get('group'),
         'name'   : r.get('group'),
         'players': [n.strip() for n in (r.get('players') or '').split(',')],
         'to_par' : (r['total_net'] - par) if r.get('total_net') is not None
                    else None}
        for r in (scramble_summary(rnd) or [])
    ])
    if not rows:
        return {}
    mine = next((r['key'] for r in rows
                 if r['key'] in (foursome.id, foursome.display_name)), None)
    return foursome_activity_state(
        foursome, rows, player_id=player_id, mine=mine,
        game_name='Scramble', thru=thru, closed=final)


def shamble_state(foursome, *, player_id=None, thru=None, final=False):
    """Four balls, best N, off each golfer's own handicap.

    **Team Play's board, not the group-vs-field one.** A shamble here is a
    Team Play format, where a playing group can hold two TEAMS in two slots —
    so the reader's team is his slot, not his foursome, and the row key has to
    carry both.
    """
    from services.team_play_scoring import leaderboard
    from services.team_play_state import team_slots
    tournament = getattr(getattr(foursome, 'round', None), 'tournament', None)
    board = leaderboard(tournament) if tournament else None
    if not board:
        return {}
    rows = [{'key'   : (r['foursome_id'], r['slot']),
             'name'  : r.get('name'),
             'to_par': r.get('net_to_par'),
             'rank'  : r.get('rank'),
             'tied'  : bool(r.get('tied'))}
            for r in (board.get('teams') or board.get('rows') or [])]
    if not rows:
        return {}
    # The reader's own team inside the group — his slot, which for a
    # four-golfer event is the only one there is.
    mine = None
    for slot in team_slots(foursome, tournament.team_play_config):
        if any(m.player_id == player_id
               for m in foursome.memberships.filter(team_play_slot=slot)):
            mine = (foursome.id, slot)
            break
    if mine is None and rows:
        mine = next((r['key'] for r in rows if r['key'][0] == foursome.id),
                    None)
    return foursome_activity_state(
        foursome, rows, player_id=player_id, mine=mine,
        game_name='Shamble', thru=thru, closed=final)
