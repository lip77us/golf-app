"""
services/banker.py
------------------
Banker — one golfer against three, every hole, each bet on its own
(Downloads/handoff-banker/HANDOFF.md).

The banker names a maximum for the hole, each opponent picks his own number
between the round floor and that maximum, **the bets lock**, and only then does
the banker tee off. Balls in the air, a player may double on his own shot and
the banker may counter-double every standing bet at once. Then three separate
one-on-ones settle on net, and the lowest net takes the bank for the next hole.

Three asymmetries, all deliberate and all load-bearing:

* **A tie is no action.** The banker does not win ties. The bet is void and
  nobody pays — but what it had GROWN to is still reported, because a doubled
  bet that paid nothing is a fact the group wants to see. It is also what makes
  the counter a real gamble: a counter-double into two halves collects on
  neither.
* **The birdie bonus pays out only.** A gross birdie doubles a player's
  winnings and never the banker's. One against three is lopsided already;
  letting him double three collections at once would make the role unplayable.
* **Par 3s replace the double with a triple.** Not a fourth option — the same
  slot with a different number. The banker's counter still doubles what stands.

**Strokes come off inside each one-on-one, not off the field.** A Banker hole
is three separate matches, and a match is played off the difference between
two handicaps — so the banker carries THREE stroke relationships at once while
each opponent carries exactly one. There is no single "the banker's net";
there are three, and they live on the three bet lines. See `pair_strokes`.

**What is stored and what is derived.** Everything declared BEFORE a ball is
struck is stored, because it cannot be recovered from a scorecard: who banked,
his maximum, each bet, each double, the counter, and how a tie for the bank was
settled. Everything decided by the scores — who won each one-on-one, what it
paid, who banks next — is derived every time, so a corrected score cannot leave
a stale result behind it.
"""
from decimal import Decimal
from random import Random

from core.models import HandicapMode
from games.models import BankerBet, BankerGame, BankerHole
from scoring.handicap import effective_hcp_for, make_strokes_fn
from scoring.models import HoleScore
from services.hole_plan import play_order

ZERO = Decimal('0.00')


# ---------------------------------------------------------------------------
# Roster and handicap
# ---------------------------------------------------------------------------

def _real_members(foursome):
    return [m for m in foursome.memberships.select_related('player', 'tee')
            if not m.player.is_phantom]


def _effective_hcps(game, members):
    """``{pid: effective handicap}`` under the game's own setting.

    No strokes-off branch: the model refuses that mode, because Banker is three
    one-on-ones rather than a match against one low ball.
    """
    npct = game.net_percent or 100
    return {m.player_id: effective_hcp_for(m, npct) for m in members}


def _playing_hcps(game, members) -> dict:
    """``{pid: playing handicap}`` under the game's own allowance.

    The RAW number for each golfer. Under strokes-off it is only an input —
    what settles a bet is the DIFFERENCE between two of these.
    """
    npct = game.net_percent or 100
    return {m.player_id: effective_hcp_for(m, npct) for m in members}


def _gross_by_hole(foursome) -> dict:
    out = {}
    for hs in HoleScore.objects.filter(foursome=foursome,
                                       gross_score__isnull=False):
        out.setdefault(hs.player_id, {})[hs.hole_number] = hs.gross_score
    return out


def pair_strokes(game, foursome, banker_id, opponent_id, hole) -> tuple:
    """``(strokes_to_banker, strokes_to_opponent)`` for ONE one-on-one.

    **This is the shape of Banker's handicap and the reason it needed its own
    function.** Strokes off the low man is a MATCH mechanism, and a Banker hole
    is three separate matches — so the banker carries three different stroke
    relationships at once while each opponent carries exactly one. There is no
    single "his strokes" number for the banker to put on a scorecard, which is
    a fact about the format rather than a gap in the data.

    One of the two returns is always 0: in a one-on-one the lower playing
    handicap goes to scratch and the higher receives the difference, allocated
    by stroke index on the RECEIVER's own card. The direction is the half that
    matters and the half a single-number model loses — the banker giving four
    to Dave and receiving two from Sam is an ordinary hole.
    """
    members = {m.player_id: m for m in _real_members(foursome)
               if m.tee_id is not None}
    b, o = members.get(banker_id), members.get(opponent_id)
    if b is None or o is None or game.handicap_mode == HandicapMode.GROSS:
        return 0, 0

    strokes = make_strokes_fn(foursome)
    ph = _playing_hcps(game, [b, o])

    if game.handicap_mode == HandicapMode.NET:
        # Full allocation, each golfer off his own handicap — offered for a
        # group that plays it that way, but it is not the game's own rule.
        return (strokes(ph[banker_id], b.tee, hole),
                strokes(ph[opponent_id], o.tee, hole))

    diff = ph[opponent_id] - ph[banker_id]
    if diff > 0:
        return 0, strokes(diff, o.tee, hole)
    if diff < 0:
        return strokes(-diff, b.tee, hole), 0
    return 0, 0


def stroke_plan(game, foursome, holes) -> dict:
    """``{banker_id: {opponent_id: {hole: signed strokes}}}`` — the whole plan,
    before a ball is struck.

    Signed FROM THE OPPONENT'S SIDE: positive means he receives in that match,
    negative means the banker does. A golfer choosing a bet on the tee needs
    to see the shots ahead of him, and in this game "ahead of him" depends on
    who is banking — so the plan is computed for every golfer as banker, not
    only the one who currently is.
    """
    ids = [m.player_id for m in _real_members(foursome)
           if m.tee_id is not None]
    out = {}
    for b in ids:
        out[b] = {}
        for o in ids:
            if o == b:
                continue
            per = {}
            for h in holes:
                sb, so = pair_strokes(game, foursome, b, o, h)
                per[h] = so - sb
            out[b][o] = per
    return out


def _par_for(foursome, hole) -> int | None:
    """Par off any real member's tee — par is a fact of the hole, not the tee
    box, so the first tee that knows it answers for the group."""
    for m in _real_members(foursome):
        if m.tee_id is None:
            continue
        try:
            info = m.tee.hole(hole)
        except Exception:
            continue
        if info and info.get('par'):
            return int(info['par'])
    return None


def is_par_3(foursome, hole) -> bool:
    return _par_for(foursome, hole) == 3


def _si_for(foursome, hole) -> int | None:
    """Stroke index off any real member's tee.

    Load-bearing on this screen rather than decoration: the index is what
    decides who strokes in each of the three matches, so a golfer looking at
    the hole header is reading the reason his bet is worth what it is.
    """
    for m in _real_members(foursome):
        if m.tee_id is None:
            continue
        try:
            info = m.tee.hole(hole)
        except Exception:
            continue
        if info and info.get('stroke_index'):
            return int(info['stroke_index'])
    return None


# ---------------------------------------------------------------------------
# Setup and the declared state of a hole
# ---------------------------------------------------------------------------

class BankerLocked(Exception):
    """Raised when a declaration would move money after the bets locked."""


def setup_banker(foursome, *, first_banker_id, min_bet=5, max_bet=50,
                 handicap_mode=HandicapMode.STROKES_OFF, net_percent=100,
                 rotation_rule=BankerGame.ROTATION_ASK,
                 allow_player_double=True, allow_counter=True,
                 par3_triples=True, birdie_bonus=True,
                 hole_cap_enabled=False, hole_cap_amount=None,
                 loss_caps=None):
    """Create or reconfigure the game and open its first hole."""
    lo, hi = Decimal(str(min_bet)), Decimal(str(max_bet))
    if lo <= 0 or hi < lo:
        raise ValueError('The wager band needs a floor above zero and a '
                         'ceiling at or above it.')

    game, _ = BankerGame.objects.update_or_create(
        foursome=foursome,
        defaults=dict(
            handicap_mode=handicap_mode, net_percent=net_percent,
            min_bet=lo, max_bet=hi, rotation_rule=rotation_rule,
            allow_player_double=bool(allow_player_double),
            allow_counter=bool(allow_counter),
            par3_triples=bool(par3_triples),
            birdie_bonus=bool(birdie_bonus),
            loss_caps=_clean_caps(loss_caps),
            hole_cap_enabled=bool(hole_cap_enabled),
            hole_cap_amount=(Decimal(str(hole_cap_amount))
                             if hole_cap_amount not in (None, '') else None),
            first_banker_id=first_banker_id,
            status='in_progress',
        ),
    )
    # Callers read the summary straight afterwards off the SAME instance, and
    # Django caches a reverse one-to-one in `_state.fields_cache` — so a
    # reconfigure would otherwise be read back with the OLD handicap mode
    # still attached, which is a silent wrong answer rather than an error.
    getattr(foursome, '_state', None) and \
        foursome._state.fields_cache.pop('banker_game', None)

    holes = play_order(foursome.round, foursome)
    if holes:
        BankerHole.objects.get_or_create(
            game=game, hole_number=holes[0],
            defaults={'banker_id': first_banker_id},
        )
    return game


def _clean_caps(raw) -> dict:
    """`{player_id: amount}`, keyed by string because it lives in JSON.

    A missing or non-positive entry means NO cap — a golfer who did not name a
    number is not protected by a zero, he is simply playing without one.
    """
    out = {}
    for k, v in (raw or {}).items():
        # A key that is not a player id identifies nobody, so there is nothing
        # to cap — skip it rather than taking the whole setup down with a
        # ValueError. (A client once sent the literal string "$k" for every
        # key, and this raised out of a POST that was otherwise fine.)
        try:
            pid = int(k)
            amount = Decimal(str(v))
        except (TypeError, ValueError, ArithmeticError):
            continue
        if amount > 0:
            out[str(pid)] = str(amount)
    return out


def cap_for(game, player_id):
    """This golfer's own loss cap, or None."""
    raw = (game.loss_caps or {}).get(str(player_id))
    return Decimal(raw) if raw not in (None, '') else None


def _hole_row(game, hole_number) -> BankerHole:
    try:
        return game.holes.get(hole_number=hole_number)
    except BankerHole.DoesNotExist:
        raise ValueError(f'Hole {hole_number} has no banker yet.')


def _refuse_if_locked(row, what):
    if row.locked_at is not None:
        raise BankerLocked(
            f'{what} is fixed — the bets locked at '
            f'{row.locked_at:%H:%M} and the banker has teed off.')


def set_hole_max(foursome, hole_number, amount) -> BankerHole:
    """The banker's maximum for this hole, at or under the round ceiling."""
    game = foursome.banker_game
    row = _hole_row(game, hole_number)
    _refuse_if_locked(row, 'The hole maximum')
    amt = Decimal(str(amount))
    if amt < game.min_bet or amt > game.max_bet:
        raise ValueError(f'The maximum has to sit inside the band, '
                         f'${game.min_bet:.0f}-${game.max_bet:.0f}.')
    row.max_bet = amt
    row.save(update_fields=['max_bet'])
    # A bet already above the new maximum comes down with it rather than
    # standing at a number the banker just refused.
    row.bets.filter(amount__gt=amt).update(amount=amt)
    return row


def place_bet(foursome, hole_number, player_id, amount) -> BankerBet:
    """An opponent's own number, between the round floor and the banker's max."""
    game = foursome.banker_game
    row = _hole_row(game, hole_number)
    _refuse_if_locked(row, 'A bet')
    if row.banker_id == player_id:
        raise ValueError('The banker does not bet against himself.')
    if row.max_bet is None:
        raise ValueError('The banker has not named his maximum yet.')
    amt = Decimal(str(amount))
    if player_id in cut_off_players(foursome, upto_hole=hole_number):
        # He is held to the floor for the rest of the round, so there is no
        # number to choose — the screen shows the one bet he has.
        amt = Decimal(game.min_bet)
    elif amt < game.min_bet or amt > row.max_bet:
        raise ValueError(f'That bet is outside ${game.min_bet:.0f}-'
                         f'${row.max_bet:.0f} for this hole.')
    bet, _ = BankerBet.objects.update_or_create(
        hole=row, player_id=player_id, defaults={'amount': amt})
    return bet


def lock_bets(foursome, hole_number) -> BankerHole:
    """The load-bearing moment: the banker tees off knowing all three numbers,
    and nothing above the lock moves again without a visible correction."""
    from django.utils import timezone
    game = foursome.banker_game
    row = _hole_row(game, hole_number)
    if row.max_bet is None:
        raise ValueError('The banker has not named his maximum yet.')
    opponents = {m.player_id for m in _real_members(foursome)
                 if m.player_id != row.banker_id}
    missing = opponents - {b.player_id for b in row.bets.all()}
    if missing:
        # Everybody is in the game every hole; a silent floor bet would be the
        # app choosing somebody's stake for him.
        raise ValueError('Every opponent needs a bet before the lock.')
    if row.locked_at is None:
        row.locked_at = timezone.now()
        row.save(update_fields=['locked_at'])
    return row


def set_double(foursome, hole_number, player_id, on=True) -> BankerBet:
    """A player doubling on his own shot — a triple on a par 3, where the
    triple REPLACES the double rather than joining it."""
    game = foursome.banker_game
    if on and not game.allow_player_double:
        raise ValueError('This group is playing without the player double.')
    if on and player_id in cut_off_players(foursome, upto_hole=hole_number):
        raise ValueError('He has reached his loss cap — floor bets only for '
                         'the rest of the round.')
    row = _hole_row(game, hole_number)
    if _first_score_in(foursome, hole_number):
        raise BankerLocked('The doubles closed when the first score went in.')
    bet = row.bets.filter(player_id=player_id).first()
    if bet is None:
        raise ValueError('That golfer has no bet on this hole.')
    par3 = is_par_3(foursome, hole_number) and game.par3_triples
    bet.own_multiplier = (3 if par3 else 2) if on else 1
    bet.save(update_fields=['own_multiplier'])
    return bet


def set_counter(foursome, hole_number, on=True) -> BankerHole:
    """The banker's counter — one decision landing on every standing bet."""
    game = foursome.banker_game
    if on and not game.allow_counter:
        raise ValueError('This group is playing without the counter-double.')
    row = _hole_row(game, hole_number)
    if _first_score_in(foursome, hole_number):
        raise BankerLocked('The counter closed when the first score went in.')
    row.countered = bool(on)
    row.save(update_fields=['countered'])
    return row


def _first_score_in(foursome, hole_number) -> bool:
    return HoleScore.objects.filter(foursome=foursome,
                                    hole_number=hole_number,
                                    gross_score__isnull=False).exists()


# ---------------------------------------------------------------------------
# Resolution — the chain, and why every number on it is shown
# ---------------------------------------------------------------------------

def _stake(bet, countered) -> Decimal:
    return (Decimal(bet.amount)
            * bet.own_multiplier
            * (2 if countered else 1))


def resolve_hole(game, foursome, row, gross, cut_off=frozenset()) -> dict:
    """One hole's three one-on-ones — each settled on its OWN pair of strokes.

    There is no field-wide net here and there cannot be one: under strokes-off
    the banker plays Dave off a four-shot difference and Sam off a two-shot
    difference in the same breath, so "the banker's net" is three numbers, not
    one. Every line therefore carries the two nets that decided IT, and the
    hole reports the banker's GROSS — the one figure of his that is single.
    """
    hole = row.hole_number
    b_gross = gross.get(row.banker_id, {}).get(hole)
    par = _par_for(foursome, hole)
    members = {m.player_id: m for m in _real_members(foursome)}
    b_member = members.get(row.banker_id)

    # **Displayed off the LOW golfer, not raw.** The strokes in a match are the
    # gap between two handicaps, and a gap is easier to read when one end is
    # zero: 11 against 5 is a glance, 17 against 11 is arithmetic. Subtracting
    # the same constant from everybody cannot change a difference, so this is
    # a display convention and never touches what is settled — `pair_strokes`
    # still works off the raw numbers. There is a test that says so.
    hcps = [m.playing_handicap for m in members.values()
            if m.playing_handicap is not None]
    low = min(hcps) if hcps else 0

    def gets(pid):
        m = members.get(pid)
        if m is None or m.playing_handicap is None:
            return None
        return m.playing_handicap - low

    b_hcp = gets(row.banker_id)
    b_short = ((b_member.player.short_name or b_member.player.name)
               if b_member else '')

    bets = list(row.bets.select_related('player').all())

    # **The hole cap has to reach the MONEY, not just the banner.** It was
    # applied only inside `hole_exposure`, so the number on screen obeyed it
    # and not a penny of the settlement did — the setup screen promised "one
    # ceiling for the whole hole, all bets and doubles included" and delivered
    # a display convention.
    #
    # It caps the TOTAL at stake, which is the same quantity the banner shows,
    # and it scales every bet by the same factor. A hole is one closed
    # settlement, so scaling inside it stays zero-sum and rewrites nothing
    # that was agreed on another hole — the objection that rules out a
    # round-level clamp does not apply here.
    raw_total = ZERO
    for bet in bets:
        raw_total += (Decimal(bet.amount) if bet.player_id in cut_off
                      else _stake(bet, row.countered))
    hole_cap = (Decimal(game.hole_cap_amount)
                if game.hole_cap_enabled and game.hole_cap_amount else None)
    scale = (hole_cap / raw_total
             if hole_cap is not None and raw_total > hole_cap else None)

    lines, banker_delta = [], ZERO

    for bet in bets:
        # A cut off golfer plays the floor with no multipliers, and the
        # banker's counter goes past him. He is not out of the game — he is
        # out of the ACTION.
        capped = bet.player_id in cut_off
        countered = row.countered and not capped
        stake = (Decimal(bet.amount) if capped
                 else _stake(bet, row.countered))
        if scale is not None:
            stake = (stake * scale).quantize(Decimal('0.01'))
        o_gross = gross.get(bet.player_id, {}).get(hole)
        s_b, s_o = pair_strokes(game, foursome, row.banker_id, bet.player_id,
                                hole)
        b_net = None if b_gross is None else b_gross - s_b
        o_net = None if o_gross is None else o_gross - s_o
        birdie = bool(game.birdie_bonus and par and o_gross is not None
                      and o_gross <= par - 1)

        chain = [f'${bet.amount:.0f} bet']
        if not capped and bet.own_multiplier > 1:
            chain.append(f'×{bet.own_multiplier} his '
                         f'{"triple" if bet.own_multiplier == 3 else "double"}')
        if countered:
            chain.append('×2 counter')
        if capped:
            chain.append('capped — floor only')
        if scale is not None:
            chain.append(f'hole capped at ${hole_cap:.0f}')

        if o_net is None or b_net is None:
            outcome, amount = 'open', ZERO
        elif o_net == b_net:
            # No action. The chain still prints what it had reached — a doubled
            # bet that paid nothing is a fact, not an omission.
            outcome, amount = 'tied', ZERO
        elif o_net < b_net:
            outcome = 'won'
            amount = stake * 2 if birdie else stake
            if birdie:
                chain.append('×2 his birdie')
        else:
            outcome, amount = 'lost', stake

        if outcome == 'won':
            banker_delta -= amount
        elif outcome == 'lost':
            banker_delta += amount

        o_short = bet.player.short_name or bet.player.name
        lines.append({
            'player_id'  : bet.player_id,
            'name'       : bet.player.name,
            'short_name' : o_short,
            'bet'        : Decimal(bet.amount),
            'own_multiplier': 1 if capped else bet.own_multiplier,
            'countered'  : countered,
            'capped'     : capped,
            'birdie'     : birdie and outcome == 'won',
            'stake'      : stake,
            'chain'      : ' · '.join(chain) + f' = ${stake:.0f}',
            'outcome'    : outcome,
            'amount'     : amount,
            # The stroke belongs to the MATCH, so it is reported on the match.
            # Signed from the opponent's side: + he receives, − the banker does.
            # The WHS index, so a screen can order the three opponents by it:
            # an opponent's handicap only ever matters here as a DIFFERENCE
            # from the banker's, so index order is the order the strokes are
            # in.
            'handicap_index': (float(members[bet.player_id]
                                     .player.handicap_index)
                               if bet.player_id in members else 0.0),
            # What he gets off the low golfer, so a reader can check the
            # differential himself: the strokes in this match are simply this
            # number minus the banker's, allocated by stroke index.
            'playing_handicap': gets(bet.player_id),
            'strokes'    : s_o - s_b,
            'stroke_note': _stroke_note(s_b, s_o, o_short, b_short),
            'banker_net' : b_net,
            'net'        : o_net,
            'gross'      : o_gross,
        })

    return {
        'hole'         : hole,
        'par'          : par,
        'stroke_index' : _si_for(foursome, hole),
        'is_par_3'     : par == 3,
        'banker_id'    : row.banker_id,
        # His gross, not "his net" — see the docstring. The three nets live on
        # the three lines, which is where the three matches are.
        'banker_gross' : b_gross,
        'banker_handicap': b_hcp,
        'max_bet'      : row.max_bet,
        'locked'       : row.locked_at is not None,
        'countered'    : row.countered,
        'tie_reason'   : row.tie_reason,
        'hole_capped'  : scale is not None,
        'lines'        : lines,
        'banker_delta' : banker_delta,
        'resolved'     : bool(lines) and all(l['outcome'] != 'open'
                                             for l in lines),
    }


def _stroke_note(s_b, s_o, opponent_short, banker_short) -> str:
    """The phrase a bet line carries.

    Never the word "gets" and never a round-long quantity — this is one shot,
    on one hole, in one match. It NAMES whoever is receiving rather than
    saying "you", because the play screen is the group's phone and the reader
    is not reliably either man in the bet.
    """
    if s_o and not s_b:
        return f'{opponent_short} strokes'
    if s_b and not s_o:
        return f'{banker_short} strokes'
    return 'scratch hole'


def hole_exposure(game, row) -> Decimal:
    """What this hole can cost the banker at the multipliers CURRENTLY STANDING.

    The only live worst case anywhere in the app, because it is the only place
    one exists: three bets at once and both sides able to double them.

    The birdie bonus is deliberately NOT in here. It doubles a payout, but it
    is an OUTCOME rather than a multiplier standing on the hole — folding it in
    would make the banner read as though somebody had already holed a putt, and
    the number would move for a reason the reader cannot see. The setup
    screen's ladder is where the birdie belongs, because that is a statement
    about what the game can reach rather than about this hole.
    """
    total = ZERO
    for bet in row.bets.all():
        total += _stake(bet, row.countered)
    return _capped(game, total)


def hole_exposure_if_max(game, row, opponent_ids) -> Decimal:
    """The same number with every OUTSTANDING bet taken at the banker's own
    maximum.

    Before all three numbers are in his exposure is not a figure, it is a
    range — so the banner projects the top of it and names who is still to
    bet. A total that grows silently as bets arrive tells him nothing about
    the decision he is making now.
    """
    in_already = {b.player_id for b in row.bets.all()}
    missing = [p for p in opponent_ids if p not in in_already]
    top = Decimal(row.max_bet or game.max_bet)
    return _capped(game, hole_exposure(game, row) + top * len(missing))


def _capped(game, amount) -> Decimal:
    if game.hole_cap_enabled and game.hole_cap_amount:
        return min(amount, Decimal(game.hole_cap_amount))
    return amount


def exposure_ladder(game, n_opponents=3) -> list:
    """The setup screen's argument.

    Not one worst case — the whole ladder, because the point is not that the
    top number is likely, it is that it EXISTS, and a golfer who reads the
    second line sets his ceiling differently. Rungs a switched-off rule cannot
    reach are dropped rather than shown greyed: a ladder that overstates what
    this group can actually lose is not an argument, it is a scare.
    """
    top = Decimal(game.max_bet)
    base = top * n_opponents
    rungs = [{'label': f'{n_opponents} opponents at the max', 'amount': base}]
    step = base
    if game.allow_player_double:
        step = base * 2
        rungs.append({'label': 'All of them double off the tee',
                      'amount': step})
    if game.allow_counter:
        step = step * 2
        rungs.append({'label': 'Banker counter-doubles', 'amount': step})
    if game.allow_player_double and game.par3_triples:
        step = base * (3 if not game.allow_counter else 6)
        rungs.append({'label': 'On a par 3, tripled instead', 'amount': step})
    if game.birdie_bonus:
        rungs.append({'label': f'{n_opponents} birdies against him',
                      'amount': step * 2})
    return rungs


# ---------------------------------------------------------------------------
# The loss cap — a threshold, never a clamp
# ---------------------------------------------------------------------------

def cut_off_players(foursome, upto_hole=None) -> set:
    """Golfers whose SETTLED losses have reached the cap.

    **Nothing is forgiven.** The cap does not scale a debt or clamp a total —
    every bet stands exactly as it was agreed on the tee, which is what keeps
    this game's itemised receipt honest. What it changes is the FUTURE: a cut
    off golfer bets the floor, cannot double, is skipped by the banker's
    counter, and cannot take the bank. He can still drift past his own number
    at the minimum, slowly, and that is the point — the cap buys him a soft
    landing rather than an exit.

    **Settled holes only**, so the hole being played can never move the line
    underneath it. Nassau calls this the non-aggressive rule and blocks a
    press the same way, for the same reason: being cut off must be a fact
    about what has already happened.

    **Irreversible.** Winning back above the line does not restore his
    doubles — he has been cut off by the house until the next round. A cap
    that switched off and on would be a free option: lose to the line, get
    protection, win one hole, take the protection off again.
    """
    game = foursome.banker_game
    if not (game.loss_caps or {}):
        return set()

    order = play_order(foursome.round, foursome)
    gross = _gross_by_hole(foursome)
    rows = {r.hole_number: r for r in
            game.holes.prefetch_related('bets__player').all()}

    running, out = {}, set()
    for h in order:
        if upto_hole is not None and h >= upto_hole:
            break
        row = rows.get(h)
        if row is None:
            continue
        res = resolve_hole(game, foursome, row, gross, cut_off=frozenset(out))
        if not res['resolved']:
            continue
        running[row.banker_id] = (running.get(row.banker_id, ZERO)
                                  + res['banker_delta'])
        for line in res['lines']:
            delta = (line['amount'] if line['outcome'] == 'won'
                     else -line['amount'] if line['outcome'] == 'lost' else ZERO)
            running[line['player_id']] = running.get(line['player_id'],
                                                     ZERO) + delta
        for pid, total in running.items():
            cap = cap_for(game, pid)
            if cap is not None and total <= -cap:
                out.add(pid)
    return out


# ---------------------------------------------------------------------------
# Rotation
# ---------------------------------------------------------------------------

def rotation_net(game, foursome, gross=None) -> dict:
    """``{pid: {hole: net}}`` on a FIELD-WIDE scale, for the rotation only.

    Bets settle strokes-off inside each one-on-one, which gives no common
    scale — the banker's net exists three times over — but the bank still has
    to pass to ONE man, so the rotation needs a scale the whole field shares.

    **It is the game's own: strokes off the LOW golfer.** That is what the
    card draws, what the dots show and what the `gets` chips state, so the
    rotation now agrees with the only numbers the group can see.

    It used to rank on each golfer's FULL allocation, and that was a real bug
    rather than a defensible alternative: the two disagree, and not by a
    constant. Allocation is not linear — a golfer off 11 strokes down to
    stroke index 11, but off a low man of 6 he strokes only to index 5. On a
    stroke index 9 hole the full scale gave him a shot the card plainly did
    not, and he was offered the bank in a tie he had not tied. Ranking on
    something no screen displays is a losing position however coherent it is
    on its own terms.

    Net and gross modes rank on their own convention, for the same reason.
    """
    members = [m for m in _real_members(foursome) if m.tee_id is not None]
    gross = _gross_by_hole(foursome) if gross is None else gross
    if game.handicap_mode == HandicapMode.GROSS:
        return {m.player_id: dict(gross.get(m.player_id, {})) for m in members}

    strokes = make_strokes_fn(foursome)
    ph = _playing_hcps(game, members)

    def allocation(pid):
        if game.handicap_mode == HandicapMode.NET:
            return ph[pid]
        low = min(ph.values()) if ph else 0
        return max(0, ph[pid] - low)

    return {
        m.player_id: {hole: g - strokes(allocation(m.player_id), m.tee, hole)
                      for hole, g in (gross.get(m.player_id) or {}).items()}
        for m in members
    }


def low_net_on(net, hole, player_ids) -> list:
    """Everyone tied for the low net on this hole, or [] while it is unscored."""
    vals = {p: net.get(p, {}).get(hole) for p in player_ids}
    if any(v is None for v in vals.values()):
        return []
    lo = min(vals.values())
    return [p for p, v in vals.items() if v == lo]


def next_banker(game, row, net, player_ids, cut_off=frozenset()):
    """Who banks the hole after ``row`` — and whether the group has to be asked.

    Returns ``(player_id | None, tie_ids)``. A non-empty ``tie_ids`` with a
    None id means the next hole cannot open until somebody says who holed out
    first; a phone did not see the balls drop and must not pretend it did.
    """
    winners = low_net_on(net, row.hole_number, player_ids)
    if not winners:
        return None, []
    # A cut off golfer cannot take the bank. The role is the biggest exposure
    # in the game — three bets at once — and handing it to the one man the cap
    # exists to protect would undo the cap in a single hole. If everybody left
    # is cut off, the bank stays where it is rather than the round stalling.
    eligible = [p for p in winners if p not in cut_off]
    if eligible:
        winners = eligible
    else:
        remaining = [p for p in player_ids if p not in cut_off]
        if not remaining:
            return row.banker_id, []
        winners = sorted(remaining, key=lambda p: net.get(p, {})
                         .get(row.hole_number, 99))
        winners = [p for p in winners
                   if net.get(p, {}).get(row.hole_number)
                   == net.get(winners[0], {}).get(row.hole_number)]
    if len(winners) == 1:
        return winners[0], []

    if game.rotation_rule == BankerGame.ROTATION_KEEP:
        # Concentrates the role with whoever is playing well, which is the
        # opposite of what rotation is for — offered, never the default.
        return (row.banker_id if row.banker_id in winners else winners[0]), winners
    if game.rotation_rule == BankerGame.ROTATION_DRAW:
        # Seeded on the hole so the same tie always draws the same way; a draw
        # that moved on every recalculation would rewrite who banked.
        return Random(f'{game.id}:{row.hole_number}').choice(sorted(winners)), winners
    return None, winners            # ROTATION_ASK — the group answers


def open_next_hole(foursome, after_hole, *, banker_id=None,
                   tie_reason='') -> BankerHole | None:
    """Open the hole after ``after_hole``, once the bank is settled."""
    game = foursome.banker_game
    holes = play_order(foursome.round, foursome)
    if after_hole not in holes:
        return None
    idx = holes.index(after_hole)
    if idx + 1 >= len(holes):
        return None
    nxt = holes[idx + 1]

    row = _hole_row(game, after_hole)
    ids = [m.player_id for m in _real_members(foursome)]
    net = rotation_net(game, foursome)
    who, tied = next_banker(game, row, net, ids,
                            cut_off=frozenset(cut_off_players(foursome)))

    if banker_id is not None:
        if tied and banker_id not in tied:
            raise ValueError('That golfer was not tied for the low net.')
        who = banker_id
    if who is None:
        raise ValueError('The group has to say who holed out first.')

    if tied:
        row.tie_reason = tie_reason or (
            BankerHole.TIE_DRAWN if game.rotation_rule == BankerGame.ROTATION_DRAW
            else BankerHole.TIE_KEPT if game.rotation_rule == BankerGame.ROTATION_KEEP
            else BankerHole.TIE_HOLED_FIRST)
        row.save(update_fields=['tie_reason'])

    nxt_row, _ = BankerHole.objects.get_or_create(
        game=game, hole_number=nxt, defaults={'banker_id': who})
    return nxt_row


def calculate_banker(foursome):
    """No stored results to refresh — every outcome is derived from the scores
    on read. Present so the recalc dispatcher has something to call."""
    return getattr(foursome, 'banker_game', None)


# ---------------------------------------------------------------------------
# The summary — play screen, leaderboard and card all read this
# ---------------------------------------------------------------------------

def _transfers(nets, names):
    """The fewest handovers that clear the table.

    Banker's debts really ARE pairwise — every bet was one named golfer against
    one named golfer for an agreed number, and the receipt itemises them. This
    is only the collapse: nobody settles fifty-four transactions in a car park.
    """
    owe = sorted(((p, -v) for p, v in nets.items() if v < 0), key=lambda e: -e[1])
    due = sorted(((p, v) for p, v in nets.items() if v > 0), key=lambda e: -e[1])
    out, i, j = [], 0, 0
    while i < len(owe) and j < len(due):
        (fp, fv), (tp, tv) = owe[i], due[j]
        amt = min(fv, tv).quantize(Decimal('0.01'))
        if amt > 0:
            out.append({'from': fp, 'from_name': names.get(fp, ''),
                        'to': tp, 'to_name': names.get(tp, ''),
                        'amount': amt})
        owe[i] = (fp, fv - amt)
        due[j] = (tp, tv - amt)
        if owe[i][1] <= ZERO:
            i += 1
        if due[j][1] <= ZERO:
            j += 1
    return out


def banker_summary(foursome) -> dict | None:
    """Everything the play screen, the leaderboard and the card need."""
    try:
        game = foursome.banker_game
    except BankerGame.DoesNotExist:
        return None

    members = _real_members(foursome)
    ids     = [m.player_id for m in members]
    names   = {m.player_id: m.player.name for m in members}
    shorts  = {m.player_id: (m.player.short_name or m.player.name)
               for m in members}
    order   = play_order(foursome.round, foursome)
    gross   = _gross_by_hole(foursome)
    net     = rotation_net(game, foursome, gross)
    plan    = stroke_plan(game, foursome, order)

    rows = {r.hole_number: r for r in
            game.holes.prefetch_related('bets__player').all()}

    # Two numbers per golfer, not one: what he made BANKING and what he made
    # BETTING are different games played by the same man, and a golfer can
    # finish level having been wildly up in one and down in the other.
    banking = {p: ZERO for p in ids}
    betting = {p: ZERO for p in ids}

    # Walked forward, because being cut off is a fact about the holes BEFORE
    # the one being resolved — and the cut-off changes what the next hole
    # settles for. Sequential, never circular.
    caps = {p: cap_for(game, p) for p in ids}
    cut_off, cut_at = set(), {}

    holes, swings = [], []
    for h in order:
        row = rows.get(h)
        if row is None:
            # The SAME shape an opened hole returns, minus the banker. A short
            # dict here meant an unopened hole silently lacked half the keys —
            # readers of `holes` would work fine for sixteen holes and then
            # trip on the seventeenth.
            par = _par_for(foursome, h)
            holes.append({
                'hole': h, 'par': par, 'stroke_index': _si_for(foursome, h),
                'is_par_3': par == 3, 'banker_id': None, 'banker_gross': None,
                'banker_handicap': None, 'max_bet': None, 'locked': False,
                'countered': False, 'tie_reason': '', 'lines': [],
                'banker_delta': ZERO, 'resolved': False,
                'exposure': ZERO, 'exposure_if_max': ZERO, 'outstanding': [],
                'cut_off': [], 'hole_capped': False,
            })
            continue
        res = resolve_hole(game, foursome, row, gross,
                           cut_off=frozenset(cut_off))
        res['cut_off'] = sorted(cut_off)
        if res['resolved']:
            banking[row.banker_id] += res['banker_delta']
            for line in res['lines']:
                if line['outcome'] == 'won':
                    betting[line['player_id']] += line['amount']
                elif line['outcome'] == 'lost':
                    betting[line['player_id']] -= line['amount']
            for pid in ids:
                cap = caps.get(pid)
                if (cap is not None and pid not in cut_off
                        and banking[pid] + betting[pid] <= -cap):
                    cut_off.add(pid)
                    cut_at[pid] = h
            moved = sum(abs(l['amount']) for l in res['lines'])
            if moved > ZERO:
                # ONE quantity in the right-hand column, and it is NAMED:
                # "+$120 Sam", not a bare figure. A column that silently
                # alternates between the banker's net and one opponent's bet
                # is unreadable — and ranking by the banker's own delta would
                # bury the round's biggest hole, the one where three tripled
                # bets cancelled to nothing for him while the money moved
                # around him.
                top = max(res['lines'], key=lambda l: abs(l['amount']))
                swings.append({
                    'hole'        : h,
                    'amount'      : moved,
                    'banker'      : shorts.get(row.banker_id, ''),
                    'banker_delta': res['banker_delta'],
                    'top_name'    : top['short_name'],
                    'top_amount'  : (top['amount'] if top['outcome'] == 'won'
                                     else -top['amount']),
                })
        opp = [p for p in ids if p != row.banker_id]
        pending = [shorts.get(p, '') for p in opp
                   if p not in {b.player_id for b in row.bets.all()}]
        res['exposure']        = hole_exposure(game, row)
        res['exposure_if_max'] = hole_exposure_if_max(game, row, opp)
        res['outstanding']     = pending
        holes.append(res)

    nets = {p: banking[p] + betting[p] for p in ids}
    idx = {m.player_id: float(m.player.handicap_index) for m in members}
    # Off the low golfer, the same convention the bet lines use — see
    # `resolve_hole`. The bets do not exist yet while a hole is being set up,
    # so the roster has to carry it too or the figure would appear only after
    # the money was already agreed.
    phcps = [m.playing_handicap for m in members
             if m.playing_handicap is not None]
    low_ph = min(phcps) if phcps else 0
    gets = {m.player_id: (None if m.playing_handicap is None
                          else m.playing_handicap - low_ph)
            for m in members}
    players = sorted(
        ({'player_id': p, 'name': names[p], 'short_name': shorts[p],
          'handicap_index': idx.get(p, 0.0),
          'playing_handicap': gets.get(p),
          # Cut off by the house until next round — floor bets, no doubles,
          # no bank. Nothing he already owes has changed.
          'cut_off': p in cut_off, 'cut_off_hole': cut_at.get(p),
          'loss_cap': caps.get(p),
          'banking': banking[p], 'betting': betting[p], 'total': nets[p]}
         for p in ids),
        key=lambda e: -e['total'])

    # The current hole is the last one opened — the play screen's whole subject.
    current = None
    for h in reversed(order):
        if h in rows:
            current = next((x for x in holes if x['hole'] == h), None)
            break

    tie_ids = []
    awaiting = None
    next_id = None
    if current and current.get('resolved'):
        # With the cut-off, or the board announces a banker `open_next_hole`
        # will then refuse — the screen and the action have to agree.
        who, tied = next_banker(game, rows[current['hole']], net, ids,
                                cut_off=frozenset(cut_off))
        if tied and who is None:
            awaiting, tie_ids = current['hole'], tied
        else:
            # Outright, so the app can simply SAY who takes it. A role that
            # changed hands unannounced is the fastest way to have two golfers
            # both think they are banking the 8th.
            next_id = who

    swings.sort(key=lambda e: -e['amount'])
    return {
        'status'        : game.status,
        'handicap_mode' : game.handicap_mode,
        'net_percent'   : game.net_percent,
        'min_bet'       : Decimal(game.min_bet),
        'max_bet'       : Decimal(game.max_bet),
        'rotation_rule' : game.rotation_rule,
        'rules'         : {
            'player_double': game.allow_player_double,
            'counter'      : game.allow_counter,
            'par3_triples' : game.par3_triples,
            'birdie_bonus' : game.birdie_bonus,
        },
        'exposure_ladder': exposure_ladder(
            game, max(1, len([p for p in ids]) - 1)),
        'hole_cap'      : (Decimal(game.hole_cap_amount)
                           if game.hole_cap_enabled and game.hole_cap_amount
                           else None),
        'players'       : players,
        'holes'         : holes,
        'current_hole'  : current['hole'] if current else None,
        'current'       : current,
        # The tie a phone cannot settle. Until it is answered the next hole
        # does not open.
        'awaiting_tie'  : awaiting,
        'tie_candidates': [{'player_id': p, 'short_name': shorts.get(p, '')}
                           for p in tie_ids],
        'next_banker_id'   : next_id,
        'next_banker_name' : names.get(next_id, '') if next_id else '',
        'biggest_swings': swings[:3],
        'bets_settled'  : sum(len(h['lines']) for h in holes
                              if h.get('resolved')),
        # The whole plan, for every golfer AS BANKER — a man choosing a bet
        # needs the shots ahead of him, and in this game those depend on who
        # is banking.
        'stroke_plan'   : plan,
        # The SHARED grid's own shape, so Banker draws the card every other
        # game draws — header shading, a stroke-index row, pinned labels —
        # rather than a bespoke one that would drift from it.
        'grid'          : _grid(order, ids, gross, plan, rows, foursome, idx),
        'grid_players'  : [{'player_id': p, 'short_name': shorts.get(p, ''),
                            'name': names.get(p, '')}
                           for p in sorted(ids, key=lambda p: idx.get(p, 0))],
        'money'         : {'transfers': _transfers(nets, shorts),
                           'nets': nets},
    }


def _grid(order, ids, gross, plan, rows, foursome, idx) -> list:
    """The shared `HoleGridScorecard` payload.

    **The card shows the PLAN, off the low golfer — not the pairwise match.**
    That is a deliberate split from the bet rows, and the reason is future
    holes. A card is read forwards: a golfer planning a bet needs to see the
    shots ahead of him, and on a hole nobody has reached there is no banker
    yet, so a pairwise dot has nobody to be pairwise WITH and computes to
    nothing. Every hole would have shown an empty plan until the moment it was
    played.

    Off the low man the allocation exists on all eighteen from the first tee,
    it is the same number the `gets` chip states, and it is what every other
    strokes-off game in the app already draws. The match-specific stroke — the
    one that settles a bet — is named on the bet row itself, where the match
    is the subject.

    No `winner_id`: green means "won the hole" everywhere else in the app, and
    a Banker hole has three separate results rather than one winner. Gold
    marks who banked instead.
    """
    low = min(ids, key=lambda p: idx.get(p, 0)) if ids else None
    out = []
    for h in order:
        row = rows.get(h)
        banker = row.banker_id if row else None
        scores = []
        for p in ids:
            g = gross.get(p, {}).get(h)
            # The low man gives to everybody and receives from nobody, so he
            # never carries a dot.
            dots = (0 if low is None or p == low
                    else max(0, plan.get(low, {}).get(p, {}).get(h, 0)))
            scores.append({'player_id': p, 'gross': g, 'strokes': dots})
        out.append({
            'hole'        : h,
            'par'         : _par_for(foursome, h),
            'stroke_index': _si_for(foursome, h),
            'winner_id'   : None,
            # Gold on the shared grid marks the ROLE. Reading it down the card
            # shows the rotation, which is the one thing the card can say that
            # the numbers cannot.
            'banker_id'   : banker,
            'scores'      : scores,
        })
    return out


# ---------------------------------------------------------------------------
# Settlement — the one game in the set whose debts really are pairwise
# ---------------------------------------------------------------------------

def banker_settlement(foursome) -> dict | None:
    """Per-golfer receipts, plus the collapse to the fewest handovers.

    The receipt itemises the holes he BANKED in full — three bets each — and
    GROUPS the ones he played by whose bank he was betting into. Twelve
    five-dollar lines would bury the six that matter, and the grouping answers
    what a golfer actually asks: who took my money.
    """
    summary = banker_summary(foursome)
    if summary is None:
        return None

    shorts = {p['player_id']: p['short_name'] for p in summary['players']}
    names  = {p['player_id']: p['name'] for p in summary['players']}

    receipts = []
    for p in summary['players']:
        pid = p['player_id']
        banked, against = [], {}
        for h in summary['holes']:
            if not h.get('resolved'):
                continue
            if h['banker_id'] == pid:
                banked.append({
                    'hole'   : h['hole'],
                    'par'    : h['par'],
                    'delta'  : h['banker_delta'],
                    'lines'  : [{'name': l['short_name'], 'chain': l['chain'],
                                 'outcome': l['outcome'],
                                 'amount': (l['amount'] if l['outcome'] == 'lost'
                                            else -l['amount'])}
                                for l in h['lines']],
                })
                continue
            line = next((l for l in h['lines'] if l['player_id'] == pid), None)
            if line is None:
                continue
            grp = against.setdefault(h['banker_id'], {
                'banker_id': h['banker_id'],
                'banker'   : shorts.get(h['banker_id'], ''),
                'holes'    : [], 'subtotal': ZERO})
            amt = (line['amount'] if line['outcome'] == 'won'
                   else -line['amount'] if line['outcome'] == 'lost' else ZERO)
            grp['subtotal'] += amt
            # A zero line STAYS when the stake was large: a golfer who
            # remembers a $180 hole and cannot find it does not trust the
            # receipt.
            grp['holes'].append({'hole': h['hole'], 'chain': line['chain'],
                                 'outcome': line['outcome'], 'amount': amt,
                                 'stake': line['stake']})

        receipts.append({
            'player_id': pid, 'name': names[pid], 'short_name': p['short_name'],
            'banking': p['banking'], 'betting': p['betting'],
            'total': p['total'],
            'holes_banked': banked,
            'by_bank': sorted(against.values(), key=lambda g: g['banker']),
        })

    return {
        'players'   : receipts,
        'transfers' : summary['money']['transfers'],
        'bet_count' : sum(len(h['lines']) for h in summary['holes']
                          if h.get('resolved')),
    }
