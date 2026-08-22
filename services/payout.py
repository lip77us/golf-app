"""
services/payout.py
------------------
The money rules every tournament pot shares
(docs/design-review/handoff-individual-play/SPEC.md §3).

Three of them were being re-implemented per game with quietly different
behaviour, which is exactly how a payout table ends up not balancing:

1. **Ties split the money for the places they occupy.** Two groups tied for
   1st share 1st *and* 2nd, not 1st halved with 2nd left in the pot. There are
   no countbacks anywhere in this spec — plenty of bets run on a given day, so
   a tie can be no action, and an arbitrary tiebreak decides real money on a
   rule nobody agreed to.

2. **A place that pays a GROUP splits among that group's real golfers.** The
   borrowed 4th is not a person and cannot be paid, so a levelled group's three
   golfers take $23.33 each where four would have taken $17.50.

3. **The last paying championship place must clear day-bet 1st.** Winning
   36-hole money disqualifies a golfer from the day bet, so a smaller last
   place would mean finishing in the championship money actively costs him
   money. Checked at the payout step, and here rather than only in the UI so an
   API caller cannot post a table that fails it.

Money is a **projection until the round closes** — that is a rendering rule
(muted italic, one line under the table), so it lives in the clients; the flag
they read is on each game's summary.
"""
from collections import Counter


# ---------------------------------------------------------------------------
# 1. Tie splitting
# ---------------------------------------------------------------------------

def payouts_by_place(payouts_list) -> dict:
    """``[{'place': 1, 'amount': 60}, …]`` → ``{1: 60.0, …}``."""
    out = {}
    for p in (payouts_list or []):
        try:
            out[int(p['place'])] = float(p['amount'])
        except (KeyError, TypeError, ValueError):
            continue
    return out


def split_tied_places(places: dict, ranks) -> dict:
    """
    Return ``{rank: amount each competitor at that rank receives}``.

    ``places``  {place → prize}, from :func:`payouts_by_place`.
    ``ranks``   every competitor's rank, ties repeating the same rank and
                unranked competitors passing None.

    Competitors sharing rank *r* occupy places *r … r+n−1*, so they pool those
    prizes and divide. This is what stops a T1 pair from taking half of 1st
    while 2nd sits unclaimed in the pot, and what stops three golfers tied for
    2nd from taking 2nd each and overpaying it.
    """
    counts = Counter(r for r in ranks if r is not None)
    out = {}
    for rank, n in counts.items():
        total = sum(places.get(rank + j, 0.0) for j in range(n))
        out[rank] = round(total / n, 2) if total else 0.0
    return out


def per_person_share(group_payout: float, real_player_count: int) -> float:
    """
    A group prize divided among the golfers who can actually be paid.

    Counting the borrowed 4th here would hand a share to a player who is not in
    the group — the whole point of rule 2. A levelled group therefore pays MORE
    each, which is accepted: its fourth score came from a stranger it did not
    pick.
    """
    if not real_player_count:
        return 0.0
    return round(group_payout / real_player_count, 2)


# ---------------------------------------------------------------------------
# 2. Table validation — stated in the balance line, never enforced silently
# ---------------------------------------------------------------------------

def validate_payout_table(pool: float, amounts, *, label: str = 'places') -> list:
    """
    Return a list of human-readable problems with a payout table, empty when it
    balances. ``amounts`` is the per-place list in place order.

    Both guards are stated in the balance line rather than blocking a keystroke,
    so a TD can type 1st before 2nd without being told off mid-edit.
    """
    vals = [float(a or 0) for a in amounts]
    paid = [v for v in vals if v > 0]
    problems = []

    total = round(sum(vals), 2)
    pool  = round(float(pool or 0), 2)
    if paid and total != pool:
        diff = round(total - pool, 2)
        over = 'over' if diff > 0 else 'under'
        problems.append(
            f'The {label} add to ${total:,.2f} — ${abs(diff):,.2f} {over} '
            f'the ${pool:,.2f} pot.'
        )

    for i in range(1, len(vals)):
        if vals[i] > 0 and vals[i - 1] > 0 and vals[i] > vals[i - 1]:
            problems.append(
                f'Place {i + 1} pays more than place {i}. Each place has to pay '
                f'less than the one above it.'
            )
            break

    return problems


def check_day_bet_floor(championship_payouts, day_bet_payouts) -> str | None:
    """
    Rule 3. Return the blocking reason, or None when the two pots are sized
    safely against each other.

    Nobody should be worse off for playing better: if the last paying
    championship place is worth less than day-bet 1st, the placing that
    disqualifies a golfer from the day bet costs him money.
    """
    champ = [v for _p, v in sorted(payouts_by_place(championship_payouts).items())
             if v > 0]
    day   = payouts_by_place(day_bet_payouts).get(1, 0.0)
    if not champ or day <= 0:
        return None
    last = champ[-1]
    if last < day:
        return (
            f'The last paying championship place (${last:,.2f}) pays less than '
            f'day bet 1st (${day:,.2f}). Winning 36-hole money disqualifies a '
            f'golfer from the day bet, so finishing in the money would cost him '
            f'${day - last:,.2f}. Raise the championship place or lower the day bet.'
        )
    return None


# ---------------------------------------------------------------------------
# 3. The pool line — scope is never left to be counted off the screen
# ---------------------------------------------------------------------------

SCOPE_FIELD    = 'field'
SCOPE_FOURSOME = 'foursome'


def pool_line(entry_fee: float, count: int, scope: str) -> str:
    """
    ``$10 × 4 in this foursome = $40`` vs ``$10 × 8 in the field = $80``.

    Mini Singles and Irish Rumble draw identical money cards over completely
    different pots, so the scope and the count belong in the sentence rather
    than being inferred from a total.
    """
    fee   = float(entry_fee or 0)
    total = round(fee * (count or 0), 2)
    where = 'in this foursome' if scope == SCOPE_FOURSOME else 'in the field'
    return f'${fee:,.0f} × {count} {where} = ${total:,.0f}'


def carve_out(pool: float, pct: int) -> tuple:
    """
    Split a championship pool into ``(carved, remaining)``.

    Mini Singles day 2 is funded by a percentage off the TOP of the
    championship pool — there is no separate day-2 entry — so the championship
    shows the full pool in and the full pool out, with part of it leaving for
    another game's table.
    """
    pool = round(float(pool or 0), 2)
    if not pct:
        return 0.0, pool
    carved = round(pool * int(pct) / 100.0, 2)
    return carved, round(pool - carved, 2)


# ---------------------------------------------------------------------------
# 5. Cents — a settlement that does not balance is worse than one that is
#    slightly arbitrary
# ---------------------------------------------------------------------------

def split_to_cents(total, recipient_count: int) -> list:
    """
    Divide a prize into exact cents, the remainder going to the FIRST
    recipient (docs/design-review/handoff-team-play/SPEC.md §10.4).

    ``round(total / n, 2)`` — what the rest of this module does — silently
    loses or invents money: $287.50 over four is $71.875, and four roundings
    of that make $287.56. So every figure a golfer is actually handed goes
    through here instead, and the pool balances to zero.

    Team Play states the rule on the screen and orders its recipients by
    **course handicap, descending**, so the odd cents land on the team's
    highest handicap. Arbitrary, but stated and deterministic, which is the
    whole requirement — and it is written under the split rather than left as
    an unexplained $71.89 next to three $71.87s.

        >>> split_to_cents(287.50, 4)
        [71.89, 71.87, 71.87, 71.87]
        >>> split_to_cents(143.75, 3)       # a three-man team, more each
        [47.93, 47.91, 47.91]
        >>> sum(split_to_cents(143.75, 3))
        143.75
    """
    if recipient_count <= 0:
        return []
    cents = int(round(float(total or 0) * 100))
    base, remainder = divmod(cents, recipient_count)
    shares = [base] * recipient_count
    shares[0] += remainder
    return [c / 100.0 for c in shares]
