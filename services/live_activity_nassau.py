"""
services/live_activity_nassau.py
--------------------------------
The Nassau lock screen
(docs/design-review/handoff-live-activities/nassau-HANDOFF.md).

A projection of `nassau_summary`. It computes nothing about the golf, with one
exception below.

**The structural break from Sixes.** Sixes had one match at a time, so it got
one 36px number. Nassau always has two live — the nine you are playing and the
eighteen — and there is no honest way to nominate one as the headline. So two
equal rows at 25px, and nothing on the card is 36px.

That second row is paid for by the sides moving. Sixes had to restate both
pairings on every update because the pairing changed every match; Nassau's
sides are **fixed at setup and never move**, so they are named once above the
matches and a number can wear its side's colour without the reader re-learning
which is which.

**The exception is the exposure range**, which is genuinely computed here — see
below. It is the answer to the question people actually have on the 14th: not
*where am I* but *how bad can this get*.
"""
from services.nassau import nassau_summary

KIND = 'nassau'


def _reader_sign(summary, player_id) -> int:
    """+1 if the reader is on team1, -1 on team2, +1 for a neutral reader.

    Payouts come out of `nassau_summary` from team1's point of view, so this is
    the only place the board stops being neutral.
    """
    teams = summary.get('teams') or {}
    for p in (teams.get('team2') or []):
        if p.get('player_id') == player_id:
            return -1
    return 1


def _side_colour(summary, which) -> str:
    """Blue and orange are fixed for the whole round — blue is blue on the 1st
    and the 18th, in both matches. That stability is what lets a number wear a
    side's colour at all."""
    return 'blue' if which == 'team1' else 'orange'


def _margin_text(margin) -> str:
    """`2 UP` or `ALL SQ`.

    `ALL SQ` is white at 90%, never mint — mint is the app's colour, not a
    side's.
    """
    if not margin:
        return 'ALL SQ'
    return f'{abs(margin)} UP'


def _bet_rows(summary, game, hole, sign):
    """The current nine, then the eighteen.

    A settled nine **leaves the card**. It does not become a third row: it is
    over, its money is already in the exposure figure, and a row that cannot
    change spends space on history.
    """
    rows = []
    nine = 'front9' if hole <= 9 else 'back9'
    order = [(nine, 'FRONT 9' if nine == 'front9' else 'BACK 9'),
             ('overall', 'OVERALL')]

    for key, label in order:
        if not _bet_is_played(game, key):
            continue
        bet = summary.get(key) or {}
        if key != 'overall' and bet.get('result'):
            continue                      # settled — it leaves the card
        rows.append(_row(summary, key, label, bet, sign))
    return rows


def _bet_is_played(game, key) -> bool:
    return {'front9' : game.play_front,
            'back9'  : game.play_back,
            'overall': game.play_overall}.get(key, False)


def _holes_left(key, bet) -> int:
    played = bet.get('holes_played') or 0
    total  = 18 if key == 'overall' else 9
    return max(0, total - played)


def _row(summary, key, label, bet, sign) -> dict:
    """Label, number in the leading side's colour, press chip, then the state.

    The press chip lives on the row that owns the bet, never in the header.  A
    press is a bet on one match; floating the count to the top would say the
    round has presses without saying which match carries them, which is the
    whole content.
    """
    margin = bet.get('margin') or 0
    result = bet.get('result')
    leader = 'team1' if margin > 0 else ('team2' if margin < 0 else None)

    left = _holes_left(key, bet)
    if result:
        note = 'HALVED' if result == 'halved' else 'WON'
    elif margin and abs(margin) == left and left > 0:
        note = 'DORMIE'
    else:
        note = f'{left} TO PLAY'

    row = {
        'label' : label,
        'text'  : _margin_text(margin),
        'colour': _side_colour(summary, leader) if leader else 'neutral',
        'note'  : note,
    }
    presses = _live_press_count(summary, key)
    if presses:
        row['chip'] = f'+{presses} PRESS'
    return row


def _presses_for(summary, key):
    """Presses belonging to one bet. A press rides on a nine, never on the
    eighteen."""
    if key == 'overall':
        return []
    nine = 'front' if key == 'front9' else 'back'
    return [p for p in (summary.get('presses') or [])
            if p.get('nine') == nine]


def _live_press_count(summary, key) -> int:
    """Two presses on one match read `+2 PRESS`, not two chips."""
    return len(_presses_for(summary, key))


# ---------------------------------------------------------------------------
# The exposure range
# ---------------------------------------------------------------------------

def exposure_range(summary, game, player_id):
    """`settled ± the sum of every live stake`, presses included.

    Midpoint is money already banked; half-span is what is still on the table.
    Both ends move on every settlement and every press.

    **All three bets are live from the 1st tee.** The back nine has not been
    played but it is at stake, so a $5 Nassau opens at −$15 to +$15. Counting
    only the matches under way (−$10) is wrong: the slot is about money at
    risk, not money in progress.

    A running total cannot do this job. Presses mean the amount at stake is not
    fixed at setup — three open bets at $5 is a $30 swing, the same round after
    two presses is a $50 swing, and a running total reads identically in both.

    Two properties worth preserving, and both are tested:

    * **It includes settled money**, so it is a forecast rather than a bracket
      around zero. Win the front nine and the floor rises with you.
    * **It converges.** Every bet that settles pulls the ends together, until on
      the 18th green they meet at the single number that is the final state.

    A **halved** bet pays nothing and is not banked — it leaves both the
    midpoint and the span, which is the Sixes ruling on halves applied here.
    """
    sign       = _reader_sign(summary, player_id)
    bet_unit   = float(summary.get('bet_unit') or 0)
    press_unit = float(summary.get('press_unit') or 0)

    payouts = summary.get('payouts') or {}
    settled = sign * float(payouts.get('total') or 0)

    live = 0.0
    for key in ('front9', 'back9', 'overall'):
        if not _bet_is_played(game, key):
            continue
        if (summary.get(key) or {}).get('result'):
            continue                      # settled, or halved and worth nothing
        live += bet_unit

    for press in (summary.get('presses') or []):
        if not press.get('result'):
            live += press_unit

    low, high = settled - live, settled + live

    # A loss cap truncates the floor, which is most of this slot's value — so
    # the card shows the capped figure rather than a number the golfer cannot
    # actually lose.
    cap = getattr(game, 'loss_cap', None)
    if cap is not None:
        cap = float(cap)
        low, high = max(low, -cap), min(high, cap)

    return low, high


def _money(low, high) -> str:
    def fmt(v):
        return f'{"+" if v > 0 else ("-" if v < 0 else "")}${abs(v):,.0f}'
    if abs(high - low) < 0.005:
        return fmt(low)                   # converged — the final number
    return f'{fmt(low)} to {fmt(high)}'


def _gross_to_par(summary, player_id):
    """The reader's own gross against par."""
    if player_id is None:
        return None
    total, played = 0, 0
    for hole in (summary.get('holes') or []):
        par = hole.get('par')
        for e in (hole.get('players') or []):
            if e.get('player_id') != player_id:
                continue
            gross = e.get('gross')
            if gross is not None and par:
                total  += gross - par
                played += 1
    return total if played else None


def nassau_activity_state(foursome, *, player_id=None, thru=None,
                          game_type=None) -> dict:
    """The five slots for this foursome's Nassau, right now."""
    from games.models import NassauGame
    from services.nassau import resolve_nassau_game_type

    summary = nassau_summary(foursome, game_type=game_type)
    if not summary:
        return {}

    gt = resolve_nassau_game_type(foursome, game_type)
    game = NassauGame.objects.filter(foursome=foursome,
                                     game_type=gt).first()
    if game is None:
        return {}

    thru = thru or 0
    hole = min(18, max(1, thru + 1))      # the hole being played, not completed
    sign = _reader_sign(summary, player_id)

    rows = _bet_rows(summary, game, hole, sign)
    if not rows:
        return {}

    teams = summary.get('teams') or {}
    def names(side):
        people = teams.get(side) or []
        # Full names in 1v1, surnames in 2v2 — the longest string this design
        # has to hold, and the reason it shrinks to fit.
        key = 'name' if len(people) == 1 else 'short_name'
        return ' & '.join((p.get(key) or p.get('name') or '') for p in people)

    is_team = len(teams.get('team1') or []) > 1
    low, high = exposure_range(summary, game, player_id)

    to_par = _gross_to_par(summary, player_id)
    bits = []
    if to_par is not None:
        bits.append('E' if to_par == 0 else f'{to_par:+d}')
    bits.append(f'${float(summary.get("bet_unit") or 0):,.0f} a match')

    return {
        'header': {'game': 'NASSAU' + (' · 2v2' if is_team else ''),
                   'segment': f'HOLE {hole}'},
        # Nothing on this card is 36px, so the single-number slot is unused and
        # the rows carry the numbers instead.
        'number': {'text': '', 'colour': 'neutral'},
        'rows'  : rows,
        'sides' : [
            {'names': names('team1'), 'colour': 'blue',   'leading': False},
            {'names': names('team2'), 'colour': 'orange', 'leading': False},
        ],
        'state' : {'word': '', 'to_play': ''},
        'pips'  : [],
        'final' : None,
        'footer': {'context': ' · '.join(bits), 'money': _money(low, high)},
    }
