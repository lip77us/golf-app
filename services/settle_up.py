"""Settle up — the shared money logic behind every receipt.

Built from ``~/Downloads/design_handoff_settle_up`` §2, whose first instruction
is the one that shapes this module: **build once.**  It was not greenfield.

**Three copies of the greedy settle already existed** — ``settlement.py``
``_who_owes_whom``, ``banker.py`` ``_transfers`` and ``sequoya_threes.py``
``_transfers`` — the same shape this codebase has collected scars from before
(four ``gross_total`` traversals; three ``gross_to_par``, one of which guessed
the wrong key and failed *invisibly*).  Before writing a line of this, all
three were run against the handoff's own reference case and against each
other: **they agree, and they agree with the handoff.**  So replacing them
with this is a refactor that does not move anybody's money, which is the thing
to establish BEFORE touching code that pays people.  The test that pins it is
``test_the_three_old_copies_agree_with_this_one``; delete those copies and
that test is what says it was safe.

**Integer cents, and the sum is asserted** (§2.1).  That is not pedantry: the
three old copies carried *three different* answers to "how close to zero is
zero" — ``<= 0.005``, ``<= 0.001``, and exact ``Decimal`` — because floats made
the question unavoidable.  In cents it does not arise.  A ledger that does not
sum to zero is a bug in the game that produced it, and it surfaces here rather
than as a transfer line nobody can explain.

**What this module does NOT do is format or render.**  ``money()`` lives in
``settlement_receipt`` and keeps living there; the receipt's leading ``+`` is a
flag on it, not a second formatter.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Mapping, Sequence

Cents = int
Id = object


# ---------------------------------------------------------------------------
# §2.1  settle(nets) -> Transfer[]
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Transfer:
    """One handover.  ``frm`` pays ``to``.

    ``frm``/``to`` are golfer ids; the receipt attaches names, because a name
    is a presentation choice and two surfaces spell them differently (the
    ticket uses full names, the SMS falls back to surnames only when a surname
    is shared).
    """
    frm: Id
    to: Id
    amount: Cents


def settle(nets: Mapping[Id, Cents],
           order: Sequence[Id] | None = None) -> list[Transfer]:
    """The fewest handovers that clear the table.  At most ``n - 1`` lines.

    Greedy, per §2.1: pay the largest debtor to the largest creditor, for the
    smaller of the two, until everyone is level.

    ``order`` is **display order**, and it is a real argument rather than a
    convenience.  §2.1 says to break ties by it, and a tie is not rare — two
    golfers down the same amount is the ordinary ending of a four-ball.  The
    three old copies relied on a stable sort falling back to *dict insertion
    order*, which happened to be display order at every call site and said so
    nowhere.  Passing it makes the promise checkable; omitting it keeps the old
    behaviour.

    Emission order is the greedy order, NOT the order a receipt shows.  The
    handoff's own reference lists the same three transfers largest-first, and
    §4 states it outright for tournaments ("ordered by amount"), so sorting for
    display belongs to the receipt — see :func:`for_display`.
    """
    total = sum(nets.values())
    if total != 0:
        raise ValueError(
            f'nets must sum to zero, got {total} cents. A ledger that does '
            f'not balance is a bug in the game that produced it; settling it '
            f'would invent or lose money.')
    for who, net in nets.items():
        if not isinstance(net, int) or isinstance(net, bool):
            raise TypeError(
                f'nets must be integer cents; {who!r} has {net!r} '
                f'({type(net).__name__}).')

    rank = {pid: i for i, pid in enumerate(order or list(nets))}
    def key(pair):
        pid, amount = pair
        return (-amount, rank.get(pid, len(rank)))

    owed = sorted(((p, -n) for p, n in nets.items() if n < 0), key=key)
    due  = sorted(((p,  n) for p, n in nets.items() if n > 0), key=key)

    out: list[Transfer] = []
    i = j = 0
    while i < len(owed) and j < len(due):
        (fp, fv), (tp, tv) = owed[i], due[j]
        amount = min(fv, tv)
        if amount > 0:
            out.append(Transfer(frm=fp, to=tp, amount=amount))
        owed[i] = (fp, fv - amount)
        due[j]  = (tp, tv - amount)
        if owed[i][1] == 0:
            i += 1
        if due[j][1] == 0:
            j += 1
    return out


def for_display(transfers: Iterable[Transfer]) -> list[Transfer]:
    """Largest first — what a receipt shows.

    Separate from :func:`settle` because they answer different questions: the
    algorithm's order is how the table clears, and this is what reads well on
    a ticket.  Stable, so two equal handovers keep their greedy order.
    """
    return sorted(transfers, key=lambda t: -t.amount)


# ---------------------------------------------------------------------------
# §2.2  combine(results[]) -> nets
# ---------------------------------------------------------------------------

def combine(ledgers: Iterable[Mapping[Id, Cents]]) -> dict[Id, Cents]:
    """Add per-game ledgers into one net per golfer (§2.2).

    A round playing Nassau + Skins settles ONCE, on the sum — otherwise the
    group hands money round twice for one afternoon.  Each game still
    contributes its own ``games`` rows to the receipt; this only touches the
    money.

    A golfer absent from a ledger scores nothing in that game rather than
    breaking the sum, which is what makes a side game somebody sat out work.
    Every input must balance on its own, so a single bad game is named instead
    of being hidden by another game's rounding.
    """
    out: dict[Id, Cents] = {}
    for n, ledger in enumerate(ledgers):
        total = sum(ledger.values())
        if total != 0:
            raise ValueError(
                f'ledger {n} does not sum to zero ({total} cents); combining '
                f'it would hide the imbalance in the total.')
        for pid, net in ledger.items():
            out[pid] = out.get(pid, 0) + net
    return out


# ---------------------------------------------------------------------------
# §2.3  settlePool(pool) -> {nets, payouts}
# ---------------------------------------------------------------------------

def split_cents(total: Cents, n: int) -> list[Cents]:
    """Divide a prize into exact cents, remainder to the FIRST recipient.

    The integer-cents primitive behind every pool share.  ``payout
    .split_to_cents`` is the float-returning form of the SAME rule, kept for
    its six existing callers; ``test_split_cents_agrees_with_split_to_cents``
    holds the two together so this is one rule with a checked equivalence
    rather than a seventh silent copy.

    Why not ``total / n`` rounded: $287.50 over four is $71.875, and four
    roundings make $287.56 — six cents from nowhere.  Paul's stated priority
    on this is "I am more concerned that the numbers add up".
    """
    if n <= 0:
        return []
    base, remainder = divmod(total, n)
    shares = [base] * n
    shares[0] += remainder
    return shares


@dataclass(frozen=True)
class PoolResult:
    nets: dict[Id, Cents]          # payout − entry, per entrant
    payouts: dict[Id, Cents]       # what each entrant collects (0 for most)
    pot: Cents
    transfers: list[Transfer]      # peer-to-peer, or TD → winner
    pays_label: str | None         # §2.3 overrides the default when the TD pays


def settle_pool(*, entry: Cents,
                ranks: Mapping[Id, int],
                payouts_by_place: Mapping[int, Cents],
                handicaps: Mapping[Id, float] | None = None,
                order: Sequence[Id] | None = None,
                entries_at_signup: bool = False,
                td: Id | None = None,
                td_name: str = '') -> PoolResult:
    """A pot game, per §2.3.

    ``ranks`` is every entrant's finishing rank, **ties repeating the rank** —
    the shape ``payout.split_tied_places`` already uses.  Golfers sharing rank
    *r* occupy places *r … r+n−1* and pool those prizes, which is what stops a
    tied pair taking half of 1st while 2nd sits unclaimed, and stops three tied
    for 2nd being paid 2nd each out of a pot that holds one of them.

    **The odd cent goes to the higher handicap**, so a tie group is ordered by
    handicap descending before the split.  Not a new rule: Team Play
    established it and states it on screen, and this promotes it to every pool.
    With no handicaps given it falls back to ``order``, which is arbitrary but
    deterministic — the actual requirement.

    **Who pays is the one structural fork**, and it is not cosmetic:

    * ``entries_at_signup=False`` (casual) — nobody holds the money, so the
      nets go to :func:`settle` and golfers square up between themselves.
    * ``entries_at_signup=True`` (a TD event) — the entries are already
      collected, so there is nothing to settle peer-to-peer and the transfers
      are the TD paying each winner.  Running :func:`settle` here would invent
      handovers between golfers who have already paid.
    """
    entrants = list(ranks)
    pot = entry * len(entrants)

    hcap = handicaps or {}
    rank_pos = {pid: i for i, pid in enumerate(order or entrants)}
    groups: dict[int, list[Id]] = {}
    for pid in entrants:
        groups.setdefault(ranks[pid], []).append(pid)

    payout: dict[Id, Cents] = {pid: 0 for pid in entrants}
    for rank, tied in groups.items():
        prize = sum(payouts_by_place.get(rank + j, 0) for j in range(len(tied)))
        if not prize:
            continue
        # Higher handicap first, so the remainder lands there (§2.3).
        tied_sorted = sorted(
            tied, key=lambda p: (-hcap.get(p, 0.0), rank_pos.get(p, 0)))
        for pid, share in zip(tied_sorted, split_cents(prize, len(tied))):
            payout[pid] = share

    paid = sum(payout.values())
    if paid > pot:
        raise ValueError(
            f'the payout table pays {paid} cents out of a {pot}-cent pot. A '
            f'board must never promise more than was collected.')

    nets = {pid: payout[pid] - entry for pid in entrants}

    if entries_at_signup:
        transfers = for_display([
            Transfer(frm=td, to=pid, amount=amount)
            for pid, amount in payout.items() if amount > 0])
        label = (f'{td_name} pays out · entries taken at signup'
                 if td_name else 'Entries taken at signup')
        return PoolResult(nets=nets, payouts=payout, pot=pot,
                          transfers=transfers, pays_label=label)

    # Casual: the unpaid remainder of the pot is nobody's, so the nets already
    # balance only when the table pays the pot out in full. Say so here rather
    # than letting settle() raise about a sum the caller cannot interpret.
    if paid != pot:
        raise ValueError(
            f'with entries uncollected the table must pay the whole pot: '
            f'{paid} of {pot} cents. The shortfall belongs to nobody, so '
            f'there is no set of transfers that clears it.')
    return PoolResult(nets=nets, payouts=payout, pot=pot,
                      transfers=for_display(settle(nets, order=order)),
                      pays_label=None)


# ---------------------------------------------------------------------------
# §2.5  Recipient classification
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Recipients:
    push: list[Id]
    text: list[Id]
    none: list[Id]
    note: str


def classify_recipients(golfers: Sequence[Mapping], scorer_id: Id) -> Recipients:
    """Who gets a push, who gets a text, and who gets named in the note (§2.5).

    Each golfer is ``{'id', 'name', 'on_halved', 'mobile'}``.

    **The scorer is excluded**, because the scorer is holding the phone that
    sends them.

    This is also where the handoff resolves the question that stopped the
    personal receipt being built at all.  ``CLAUDE.md`` records it: Halved
    deliberately never sends golfer-facing SMS from the server, so "send 14
    receipts" was app-initiated bulk SMS to people who never opted in, and the
    share sheet cannot open fourteen threads.  §1 answers it — **one text, from
    the scorer's own phone, through the system composer, body just the link** —
    which is the mechanism the invite flow already uses for the same TCPA and
    App Store reasons.  So ``text`` is one composer call with every recipient
    prefilled, never a per-golfer send.
    """
    push: list[Id] = []
    text: list[Id] = []
    none: list[Id] = []
    names = {'push': [], 'text': [], 'none': []}
    for g in golfers:
        if g['id'] == scorer_id:
            continue
        if g.get('on_halved'):
            push.append(g['id']); names['push'].append(g['name'])
        elif g.get('mobile'):
            text.append(g['id']); names['text'].append(g['name'])
        else:
            none.append(g['id']); names['none'].append(g['name'])
    return Recipients(push=push, text=text, none=none,
                      note=_note(names['push'], names['text'], names['none']))


def _join(names: Sequence[str]) -> str:
    """§2.5: ", " at three or more names, " and " below that.

    Written as the handoff writes it, which means three names read "A, B, C"
    with no conjunction.  Copy is declared final, so it is not second-guessed
    here — but it is the one line in §2.5 that reads like a simplification
    rather than a decision, and it is worth a look on a real four-ball.
    """
    if not names:
        return ''
    if len(names) >= 3:
        return ', '.join(names)
    return ' and '.join(names)


def _note(on_halved: Sequence[str], texted: Sequence[str],
          no_mobile: Sequence[str]) -> str:
    """The Round over note.  Empty when there is nothing to say."""
    parts = []
    if on_halved:
        parts.append(f'{_join(on_halved)} '
                     f'{"have" if len(on_halved) > 1 else "has"} it in Halved.')
    if texted:
        parts.append(f'{_join(texted)} '
                     f'{"get" if len(texted) > 1 else "gets"} a text.')
    if no_mobile:
        parts.append(f'{_join(no_mobile)} '
                     f'{"have" if len(no_mobile) > 1 else "has"} '
                     f'no mobile on file.')
    return ' '.join(parts)
