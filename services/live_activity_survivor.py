"""
services/live_activity_survivor.py
----------------------------------
The Survivor lock screen, plain and Zombie
(docs/design-review/handoff-survivor-zombie/README.md, screen 3).

**Survivor is the strongest case for a live activity in the app: you can be
knocked out by a shot you did not see.** Three golfers play one hole; the
moment the last card is in, one of them is out of that Survivor and out of the
money on it. Elimination is a NET comparison, so watching a man hole out does
not tell you whether it was you — it depends on strokes. The card carries news,
not arithmetic.

That is what separates this card from match play, which pushes nothing: there
the reader sees the result directly, here he cannot.

Three departures from every card before it:

* **The headline is a WORD, not a number.** Every other game is measured in
  something — holes, points, skins, dollars. Survivor is measured in whether
  you are still in it.
* **The track is two-dimensional** — a row per golfer, a cell per hole, scoped
  to the Survivor being played. Sixes' three pips are a 1-D shape and cannot
  carry it.
* **Two locked corners**: the hole you are standing on (upper right, with the
  yardage from THAT golfer's tee — two players in one group see different
  numbers) and the round behind you (lower right). Neither may wrap or yield.
"""

KIND = 'survivor'

# Five cells is the practical ceiling at lock-screen width — beyond that the
# cells fall under 40px and the ruler crowds, so a longer Survivor says how
# many holes rather than drawing them.
MAX_TRACK_HOLES = 5


def _cash(v) -> str:
    v = float(v or 0)
    body = f'{abs(v):.2f}'.rstrip('0').rstrip('.')
    return ('−$' if v < 0 else '+$') + body


def _stake(v) -> str:
    v = float(v or 0)
    body = f'{v:.2f}'.rstrip('0').rstrip('.')
    return f'${body} a Survivor'


def _gross_to_par(summary, player_id):
    """The reader's round against GROSS par — not net, not the game's unit."""
    if player_id is None:
        return None, 0
    total, played = 0, 0
    for h in (summary.get('holes') or []):
        par = h.get('par')
        for e in (h.get('entries') or []):
            if e.get('player_id') != player_id:
                continue
            if e.get('gross') is not None and par:
                total  += e['gross'] - par
                played += 1
    return (total if played else None), played


def _current_survivor(summary):
    idx = (summary.get('current') or {}).get('survivor')
    for s in (summary.get('survivors') or []):
        if s.get('index') == idx:
            return s
    return None


def _holes_of(summary, sv_index):
    return [h for h in (summary.get('holes') or [])
            if h.get('survivor') == sv_index]


def _entry(hole, pid):
    for e in (hole.get('entries') or []):
        if e.get('player_id') == pid:
            return e
    return {}


def _headline(summary, player_id, holes, zombie_on):
    """The reader's own state, as a word.

    A count of survivors is a GROUP fact and belongs in the state slot, not
    here. `BACK IN` is the only headline in the set reporting an event rather
    than a standing state; it holds for one hole and reverts to `ALIVE`.
    """
    cur = summary.get('current') or {}
    alive = set(cur.get('alive_ids') or [])
    zombie_id = cur.get('zombie_id')

    if holes:
        last = holes[-1]
        if last.get('resurrected_id') == player_id:
            return 'BACK IN', 'mint'

    if zombie_on and player_id is not None and player_id == zombie_id:
        return 'ZOMBIE', 'plum'
    if player_id is not None and player_id not in alive:
        # In a Zombie round nobody is OUT while the Survivor runs — they are in
        # the seat, which the branch above already named.
        return ('ZOMBIE', 'plum') if zombie_on else ('OUT', 'orange')
    return 'ALIVE', 'mint'


def _state_slot(summary, player_id, holes, zombie_on, names):
    """Standing over qualifier, right-aligned. Two lines, never money."""
    cur   = summary.get('current') or {}
    alive = list(cur.get('alive_ids') or [])
    zid   = cur.get('zombie_id')
    sv    = cur.get('survivor')
    n     = len(alive)

    def nm(pid):
        return names.get(pid, '')

    if holes:
        last = holes[-1]
        if last.get('resurrected_id') == player_id and last.get('eliminated_id'):
            # A return names who paid for it — one that did not would read as
            # a gift.
            return {'word': f'{n} IN',
                    'to_play': f'{nm(last["eliminated_id"]).upper()} TO ZOMBIEVILLE'}

    if zombie_on and player_id is not None and player_id == zid:
        # The only actionable line on any card in the set — and it states the
        # RULE, not a probability.
        return {'word': 'LOW GETS', 'to_play': 'YOU BACK IN'}

    if zombie_on and zid is not None:
        return {'word': f'{n} IN', 'to_play': f'{nm(zid).upper()} IS THE ZOMBIE'}

    if player_id is not None and player_id not in alive:
        # He is no longer one of them, so the count changes person.
        return {'word': f'{n} PLAYING', 'to_play': f'FOR SURVIVOR {sv}'}

    if n == 2:
        gone = next((h.get('eliminated_short') for h in reversed(holes)
                     if h.get('eliminated_id')), None)
        if gone:
            return {'word': '2 IN', 'to_play': f'{gone.upper()} IS OUT'}

    return {'word': f'{n} IN', 'to_play': f'SURVIVOR {sv}' if sv else ''}


def _sides(summary, holes, zombie_on, names):
    """Who is in, who is out — one line, the reader's row carried by the
    `who` label above rather than by a colour here."""
    cur   = summary.get('current') or {}
    alive = list(cur.get('alive_ids') or [])
    zid   = cur.get('zombie_id')

    ins  = ' & '.join(names.get(p, '') for p in alive if p != zid)
    out  = names.get(zid) if zid else next(
        (h.get('eliminated_short') for h in reversed(holes)
         if h.get('eliminated_id') and h['eliminated_id'] not in alive), None)

    rows = [{'names': ins or '—', 'colour': 'neutral', 'leading': True}]
    if out:
        rows.append({'names': (f'{out} in Zombieville' if zombie_on and zid
                               else f'{out} out'),
                     'colour': 'plum' if (zombie_on and zid) else 'dim',
                     'leading': False})
    return rows


def _track(summary, holes, hole_in_play, players, player_id, zombie_on):
    """The current Survivor, one row per golfer, one cell per hole.

    Scoped to the Survivor being played rather than the round: on a lock screen
    the only Survivor that can still cost you money is the one you are in, and
    a round-length track is the leaderboard's job.

    A Zombie's row cannot simply empty after he goes out — he is still hitting
    shots, which is the entire mechanic — so it carries two extra marks: the
    hole that sent him to the seat, and every hole he has played from it.
    """
    played = [h for h in holes if h.get('hole')]
    if not played:
        # A Survivor that starts on the hole in play has no history to draw.
        # One cell is the honest picture — "this one starts here" — where the
        # round's other holes would be a different Survivor's story.
        return ([hole_in_play], [
            {'label': p.get('short_name') or p.get('name') or '',
             'cells': ['now'],
             'is_reader': p['player_id'] == player_id}
            for p in players
        ]) if hole_in_play else ([], [])

    # The window ENDS at the hole in play.
    #
    # `survivor_summary` emits a row for every hole a Survivor covers, played or
    # not, so a Survivor running from the 1st gave a hole list of 1..18 and the
    # last five of that is 14-18 — a track showing holes nobody has reached
    # while the group stands on the 8th. Third bug from this same shape; the
    # rule is that a row's existence says nothing about whether it was played.
    ruler = [h['hole'] for h in played]
    if hole_in_play and hole_in_play not in ruler:
        ruler.append(hole_in_play)
    if hole_in_play:
        ruler = [h for h in ruler if h <= hole_in_play]
    ruler = ruler[-MAX_TRACK_HOLES:]

    by_hole = {h['hole']: h for h in played}
    rows = []
    for p in players:
        pid, cells = p['player_id'], []
        gone = False
        for h in ruler:
            hole = by_hole.get(h)
            if hole is None:
                # An eliminated golfer is not standing on the next hole in this
                # Survivor's sense — his row stays empty (or, for a Zombie,
                # keeps showing that he is still swinging at it).
                if gone:
                    cells.append('zplay' if zombie_on else 'gone')
                elif h == hole_in_play:
                    cells.append('now')
                else:
                    cells.append('fut')
                continue
            e = _entry(hole, pid)
            if hole.get('resurrected_id') == pid:
                cells.append('back')
                gone = False
            elif hole.get('eliminated_id') == pid:
                cells.append('zom' if zombie_on else 'out')
                gone = True
            elif gone:
                # A Zombie keeps playing; a plain eliminated golfer does not.
                cells.append('zplay' if (zombie_on and e.get('zombie')) else 'gone')
            else:
                cells.append('now' if h == hole_in_play else 'played')
        rows.append({'label': p.get('short_name') or p.get('name') or '',
                     'cells': cells,
                     'is_reader': pid == player_id})
    return ruler, rows


def _stroke_ribbon(foursome, player_id, hole) -> str:
    """`POPPING ON HOLE 13` — the gold band, when the reader gets a stroke on
    the hole he is about to play.

    Gold appears nowhere else in the system, so the band cannot be mistaken for
    a state. Running states only: the always-on card drops it, and a watcher
    never has one.

    Read from the game's own allocator rather than from the summary's played
    holes. The summary reports strokes as part of a SCORED hole, and the hole
    in play by definition is not one — a ribbon built from it could never fire.
    """
    from services.survivor import SurvivorGame, _alloc_by_hole, _real_members
    from services.hole_plan import play_order

    if player_id is None or not hole:
        return ''
    try:
        game = foursome.survivor_game
    except SurvivorGame.DoesNotExist:
        return ''
    if not any(m.player_id == player_id for m in _real_members(foursome)):
        return ''          # a watcher is not playing, so nothing pops for him

    alloc = _alloc_by_hole(game, foursome, play_order(foursome.round, foursome))
    return (f'POPPING ON HOLE {hole}'
            if alloc.get(player_id, {}).get(hole) else '')


def survivor_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The Survivor card's slots, right now."""
    from services.survivor import survivor_summary
    from services.live_activity_registry import hole_facts, thru_line

    summary = survivor_summary(foursome)
    if not summary or not summary.get('players'):
        return {}

    zombie_on = bool(summary.get('zombie_option'))
    players   = summary.get('players') or []
    names     = {p['player_id']: (p.get('short_name') or p.get('name') or '')
                 for p in players}

    holes_all = [h for h in (summary.get('holes') or []) if h.get('entries')]
    cur_idx   = (summary.get('current') or {}).get('survivor')
    # ONLY this Survivor's holes. The previous fallback to the whole round
    # meant a Survivor that has not reached its first hole yet — the common
    # case the moment one closes — drew the last five holes of the ROUND,
    # spanning three different Survivors, and let the state slot name an
    # elimination from a Survivor that is already settled.
    holes     = _holes_of(summary, cur_idx)

    to_par, played = _gross_to_par(summary, player_id)
    played_holes   = thru if thru is not None else played

    # A finished round has no hole in play, and inventing one produced a
    # `HOLE 19` with no par and no yardage — the locked corner reading as a
    # broken fetch. The packet's one exception to that corner is exactly this.
    from core.models import RoundStatus
    from services.hole_plan import holes_in_play as _hip
    order    = list(_hip(foursome.round, foursome))
    finished = (foursome.round.status == RoundStatus.COMPLETE
                or (order and played_holes >= len(order)))

    hole_in_play = None
    if not finished:
        hole_in_play = (played_holes + 1) if played_holes else (
            holes_all[-1]['hole'] + 1 if holes_all else 1)

    headline, colour = _headline(summary, player_id, holes, zombie_on)

    ribbon = _stroke_ribbon(foursome, player_id, hole_in_play)

    ruler, track = _track(summary, holes, hole_in_play, players, player_id,
                          zombie_on)

    bet = (summary.get('money') or {}).get('bet_unit') or 0
    mine = next((p.get('money') for p in players
                 if p['player_id'] == player_id), None)
    # Never a `$0` — the slot is empty until the first Survivor closes. Each
    # Survivor is its own pot, so money lands two or three times a round.
    settled = any(s.get('complete') for s in (summary.get('survivors') or []))

    return {
        'kind'   : KIND,
        'header' : {
            'game'   : 'SURVIVOR · ZOMBIE' if zombie_on else 'SURVIVOR',
            'segment': ('ROUND COMPLETE' if finished
                        else hole_facts(foursome, player_id, hole_in_play)),
        },
        'who'    : names.get(player_id, ''),
        'number' : {'text': headline, 'colour': colour},
        'sides'  : _sides(summary, holes, zombie_on, names),
        'state'  : _state_slot(summary, player_id, holes, zombie_on, names),
        'pips'   : [],
        'track'  : track,
        'ruler'  : ruler,
        'ribbon' : ribbon,
        'footer' : {
            'context': _stake(bet) if bet else 'Playing for nothing',
            'money'  : _cash(mine) if (settled and mine) else '',
        },
        # The locked lower right. Thru is the last hole FINISHED, which is why
        # it trails the hole in play above it by one. It survives the always-on
        # state, where the stake half of the footer goes and this half stays.
        'thru'   : thru_line(played_holes, to_par),
        'final'  : None,
    }
