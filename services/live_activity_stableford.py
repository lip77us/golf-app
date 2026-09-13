"""
services/live_activity_stableford.py
------------------------------------
The Stableford lock screen.

Spec: `~/Downloads/handoff-lock-screens 2/personal/HANDOFF.md`.

**This activity carries arithmetic, not news.** A points total after thirteen
holes is thirteen table lookups summed, and it is the number golfers most
reliably get wrong on their own card. That is the whole case for the card: not
that something happened, but that nobody in the group can be sure what the
number is.

It is one of three cards in the set with **no sides** — a personal
accumulation against a table — so nothing on it is blue or orange, which mean
*sides* everywhere else. The headline is the reader's own total, in mint.

**It pushes nothing.** One group, everything witnessed, and a total changing is
the sum being restated rather than an event.

**The money slot fills exactly once, at the end**, because a place payout
resolves on the 18th green. Never a `$0` — that would read as a round played
for nothing.

## It is a primary game, despite what the catalog said

Worth knowing because it nearly went the other way: `canBePrimary: false` sat
on Stableford's catalog entry, which reads like a statement that a Stableford
round cannot own an activity — an activity belongs to the round's PRIMARY game.

It was wrong. **The casual picker filters on `sideGameOnly`, not on
`canBePrimary`**, and has always offered Stableford as a primary; the flag's
only reader is a `primaryGames` getter nothing calls. So the flag was
describing a rule nothing enforced, and it was the one game in the catalog
where the two disagreed. Corrected there.

The lesson for the next card: **a flag with no reader is documentation, and a
wrong one is invisible until somebody believes it.**
"""
from services.live_activity_registry import (hole_facts, hole_in_play,
                                             strip_column, thru_line)

KIND = 'stableford'

# The standard table. Anything else is MODIFIED, which is a different table
# rather than a different card — and under one a total can fall and can go
# negative, which is the only place this card uses a second colour.
_STANDARD = {'albatross': 5, 'eagle': 4, 'birdie': 3,
             'par': 2, 'bogey': 1, 'double': 0}


def _is_modified(table) -> bool:
    return bool(table) and any(table.get(k) != v for k, v in _STANDARD.items())


def _ordinal(n: int) -> str:
    if n in (11, 12, 13):
        return f'{n}TH'
    return f'{n}{ {1: "ST", 2: "ND", 3: "RD"}.get(n % 10, "TH") }'.replace(' ', '')


def _row_for(results, player_id):
    return next((r for r in results if r.get('player_id') == player_id), None)


def _state_slot(results, mine):
    """Place, because **place is the money.**

    Stableford is nearly always a place payout, so a placing is not a soft fact
    here — it is exactly what the reader gets paid on. Leading reads `1ST` /
    `BY 4`; chasing reads `2ND` / `+3 TO 1ST`.
    """
    if mine is None or not results:
        return {'word': '', 'to_play': ''}
    rank = mine.get('rank') or 0
    best = max((r.get('total_points') or 0) for r in results)
    mine_pts = mine.get('total_points') or 0
    if rank == 1:
        # The gap to whoever is next, which is what a lead is worth.
        rest = [r.get('total_points') or 0 for r in results if r is not mine]
        margin = mine_pts - max(rest) if rest else 0
        return {'word': '1ST',
                'to_play': f'BY {margin}' if margin > 0 else 'TIED'}
    return {'word': _ordinal(rank), 'to_play': f'+{best - mine_pts} TO 1ST'}


def _sides(results, mine):
    """The one line that turns a place into a position: `Sam Reid leads · 27`.

    The state slot says WHERE the reader is; this says **against whom**, and a
    placing without that is a number he cannot act on. `2ND` is the same fact
    whether the man in front is one point clear or eleven.

    Leading inverts it and names the two chasers instead — a leader's question
    is who is coming, not who is in front.

    **No dot.** The dot marks a SIDE everywhere else in the set, and this card
    has none; an empty colour is how the shared frame is told that.
    """
    scored = [r for r in results if r.get('total_points') is not None]
    if not scored:
        return []
    if mine is not None and (mine.get('rank') or 0) == 1:
        chasers = [r for r in scored if r is not mine][:2]
        text = ' · '.join(f'{r.get("player_name", "")} '
                          f'{float(r.get("total_points") or 0):g}'
                          for r in chasers)
    else:
        leader = max(scored, key=lambda r: r.get('total_points') or 0)
        text = (f'{leader.get("player_name", "")} leads · '
                f'{float(leader.get("total_points") or 0):g}')
    if not text:
        return []
    return [{'names': text, 'colour': '', 'leading': False}]


def _footer(summary, mine, thru, to_par):
    """Left: **the ante first**, because it is the only figure already parted
    with, and the ladder is arithmetic on it. Right: the locked corner.
    """
    fee = float(summary.get('entry_fee') or 0)
    bits = []
    if fee:
        bits.append(f'${fee:,.0f} in')
    payouts = summary.get('payouts') or []
    for i, p in enumerate(payouts[:2]):
        amount = float((p or {}).get('amount') or 0)
        if amount:
            bits.append(f'{_ordinal(i + 1).lower()} ${amount:,.0f}')
    return {'context': ' · '.join(bits), 'money': ''}


def stableford_activity_state(round_obj, foursome, *, player_id=None,
                              thru=None) -> dict:
    """The card, right now."""
    from services.stableford import stableford_summary
    from services.live_activity_registry import gross_to_par

    summary = stableford_summary(round_obj)
    results = summary.get('results') or []
    if not results:
        return {}

    mine = _row_for(results, player_id)
    modified = _is_modified(summary.get('table'))

    played = thru or 0
    hole = hole_in_play(foursome, played)
    to_par = gross_to_par(summary.get('scorecard') or summary, player_id)

    pts = (mine or {}).get('total_points')
    return {
        'kind'  : KIND,
        'header': {
            'game': 'STABLEFORD' + (' · MODIFIED' if modified else ''),
            'segment': hole_facts(foursome, player_id, hole),
        },
        # The name above the number: a phone handed round a cart otherwise
        # breaks the assumption that the card is about the reader.
        'who'   : (mine or {}).get('player_name', ''),
        'number': {
            'text': '' if pts is None else f'{pts} PTS',
            # Mint on every state — and ORANGE below zero, which only a
            # modified table can produce. The one place this card uses a
            # second colour.
            'colour': 'orange' if (pts or 0) < 0 else 'mint',
        },
        'sides' : _sides(results, mine),
        'state' : _state_slot(results, mine),
        'pips'  : [],
        'final' : None,
        'footer': {**_footer(summary, mine, played, to_par),
                   'money': ''},
        'thru'  : thru_line(played, to_par),
    }


def stableford_strip(round_obj, *, player_id=None) -> list:
    """The whole-foursome frame — **the alternative, not the default.**

    It buys *where every stroke went*: a golfer two points back of the lead and
    three clear of third is being told two different things, and only the field
    says both. Four in a four-man group is the ceiling; a five-some or a field
    of twelve cannot use it.
    """
    from services.stableford import stableford_summary
    results = (stableford_summary(round_obj).get('results') or [])[:4]
    return [
        strip_column(
            name=r.get('player_name', ''),
            figure=str(r.get('total_points') or 0),
            label=_ordinal(r.get('rank') or 0),
            is_reader=r.get('player_id') == player_id,
            is_leader=(r.get('rank') or 0) == 1,
        )
        for r in results
    ]
