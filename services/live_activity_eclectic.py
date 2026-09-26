"""
services/live_activity_eclectic.py
----------------------------------
Eclectic on the lock screen — **which it does not get a card of its own for.**

Side games never do. The tournament's Stroke Play card stays where it is, and
the eclectic appears on it only when it has NEWS: a hole just posted that
improved the reader's card, or the event closing with his final places.

Spec: `~/Downloads/handoff-eclectic/HANDOFF.md` §4.

Three rules, and each of them is about restraint
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* **It takes the quiet slot while it exists.** The card does NOT grow, and
  `FIELD 24` stays — the same rule the Vegas carry follows (RULINGS-2 §5).
* **Round 1 never shows it.** Every hole of the first round improves the card,
  because there is nothing yet to beat. An announcement that fires on all
  eighteen is not news, it is a status bar.
* **It clears on the next score posted.** If that hole also improves the card,
  the line updates rather than clearing.

Which pool
~~~~~~~~~~
If both improved, show the one where the reader PLACES HIGHER; on an equal
place, gross. If he is entered in only one, only that one can ever be named.

What counts as an improvement
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The hole just posted is KEPT for its hole number, and the kept candidate came
from the round being played. That is the whole test, and it is exact rather
than a re-derivation: a kept score IS the best of the candidates, and the
engine's tie rule keeps the EARLIER round, so a later round's score is kept
only when it is strictly better than everything before it.
"""
from services.eclectic import _all_round_cards, _build_cards


def _place_of(standings, player_id):
    """``(rank, tied)`` for the reader, or ``(None, False)``."""
    for row in standings:
        if row['player_id'] == player_id:
            return row['rank'], row['tied']
    return None, False


def _ordinal(n) -> str:
    if n is None:
        return ''
    return f"{n}{ {1: 'st', 2: 'nd', 3: 'rd'}.get(n if n < 20 else n % 10, 'th') }"


def eclectic_news(tournament, round_obj, player_id, last_hole) -> dict:
    """The optional `eclectic` block for the stroke play payload.

    Empty dict when there is nothing to say — the golfer is not entered, the
    event has no eclectic, it is round 1, or the last hole posted changed
    nothing. The caller omits the key entirely on an empty dict, so a card with
    no eclectic is byte-for-byte what it was.
    """
    config = getattr(tournament, 'eclectic_config', None)
    if config is None or player_id is None:
        return {}

    from services.eclectic import eclectic_standings
    from core.models import RoundStatus

    rounds = list(tournament.rounds.order_by('round_number'))
    if len(rounds) < 2:
        return {}
    try:
        round_index = [r.pk for r in rounds].index(round_obj.pk)
    except ValueError:
        return {}

    per_round = _all_round_cards(tournament)
    finished = all(r.status == RoundStatus.COMPLETE for r in rounds)

    places = {}
    improved = {}
    for pool in config.pools:
        cards, _ = _build_cards(tournament, pool, per_round)
        mine = cards.get(player_id)
        if mine is None:
            continue
        standings = eclectic_standings(tournament, pool, per_round, cards)
        rank, tied = _place_of(standings, player_id)
        if rank is None:
            continue
        places[pool] = {'place': rank, 'tied': tied}

        # **Round 1 is never news.** Every hole improves a card that has
        # nothing in it yet.
        if round_index == 0 or last_hole is None:
            continue
        kept = mine['holes'].get(last_hole)
        if kept is not None and kept['round_index'] == round_index:
            improved[pool] = rank

    if not places:
        return {}

    # **Higher place wins; gross on a tie.** `config.pools` is gross-first, so
    # a stable min over (place, index) gives gross the tie for free.
    shown = None
    if improved:
        shown = min(improved, key=lambda p: (improved[p], config.pools.index(p)))

    block = {
        'improved_hole': last_hole if shown else None,
        'pool'         : shown or (config.pools[0] if config.pools else None),
        'place'        : places.get(shown or config.pools[0], {}).get('place'),
        'tied'         : places.get(shown or config.pools[0], {}).get('tied', False),
        'final'        : None,
    }

    if finished:
        # The final state names BOTH pools when both are on, and only the one
        # the reader is entered in otherwise.
        block['final'] = {p: places[p] for p in config.pools if p in places}

    return block


def footer_line(block) -> str:
    """The left slot's text: `Improved on 7 · 3rd gross`, or the final places.

    Composed HERE rather than in Swift so the line and the structured block
    cannot disagree about which pool is being named.
    """
    if not block:
        return ''
    if block.get('final'):
        parts = []
        for pool, p in block['final'].items():
            place = f"T{p['place']}" if p['tied'] else _ordinal(p['place'])
            parts.append(f'{place} {pool}')
        return ' · '.join(parts)
    if block.get('improved_hole') is None:
        return ''
    place = (f"T{block['place']}" if block.get('tied')
             else _ordinal(block.get('place')))
    return f"Improved on {block['improved_hole']} · {place} {block['pool']}"
