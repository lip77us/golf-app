"""Field receipts — settle-up handoff §4, Group C.

Two documents that a per-round hook cannot produce:

* **the tournament receipt** — one receipt for the WHOLE field, with several
  pots, where the TD already holds the money;
* **the team receipt** — the same shape with one chip per TEAM rather than per
  golfer.

The third Group C item, the multi-game casual round, needs nothing here: §4
asks for ``combine``d ledgers, a title joined with " + ", a ``sub`` joining
each game's stake label and one row per game, and
:func:`services.receipt_build.build_round_receipt` has done all four since
step 3.

**Both read their engines and recompute no money.**
``services.tournament_settlement`` already resolves every pot, the carve-out
and the per-golfer net; ``services.team_play_scoring.settlement`` already
splits the tied blocks and lands the odd cents on the highest handicap.  §4
says to "run settlePool for each pot", which is how you build this where
nothing exists — doing it again here would be a second opinion about money.

**Neither is built while the money is provisional.**  ``can_settle`` is the
gate, and it is the same gate the existing field-summary send uses, for the
reason recorded there: a receipt is treated as final by everyone who gets it,
and a texted figure cannot be taken back.
"""
from __future__ import annotations

import logging

from django.db import transaction
from django.utils import timezone

from services.settle_up import classify_recipients
from services.settlement_receipt import money

logger = logging.getLogger(__name__)

#: §4: "imageNets keeps the top 3 and collapses the rest; imagePays does the
#: same."  The preview's own caps are 4 chips and 3 transfer lines, so the
#: collapse row is the fourth chip and the third line.
IMAGE_CHIPS, IMAGE_PAYS = 3, 2


def _cents(value) -> int:
    return int(round(float(value or 0) * 100))


def _collapse(rows: list, keep: int, label_fn, sum_fn):
    """Top ``keep`` verbatim, the rest as one row carrying their total.

    Never a truncation: a receipt that drops golfers without saying so is
    the thing §1's "13 more" exists to prevent.
    """
    if len(rows) <= keep + 1:
        return list(rows)
    head, tail = rows[:keep], rows[keep:]
    return head + [label_fn(tail, sum_fn(tail))]


def _scorer_block(scorer) -> dict:
    if not scorer:
        return {}
    name = getattr(scorer, 'name', '') or ''
    return {'name': name,
            'initials': ''.join(p[0] for p in name.split()[:2]).upper()}


def _td_name(tournament, scorer) -> str:
    if scorer and getattr(scorer, 'name', ''):
        return scorer.name
    creator = getattr(tournament, 'created_by', None)
    return getattr(creator, 'name', '') or tournament.account.name


def _existing(tournament):
    from tournament.models import Receipt
    return Receipt.objects.filter(tournament=tournament).first()


def _save(tournament, payload, scorer):
    from tournament.models import Receipt
    receipt = Receipt.objects.create(
        tournament=tournament, payload=payload, scorer=scorer,
        settled_at=timezone.now())
    receipt.payload['code'] = receipt.code
    receipt.save(update_fields=['payload'])
    return receipt


def _field_recipients(tournament, golfer_ids, names, scorer):
    from accounts.phone import normalize
    from core.models import Player
    from django.contrib.auth import get_user_model

    players = {p.id: p for p in Player.objects.filter(id__in=golfer_ids)}
    phones = {normalize(p.phone) for p in players.values() if p.phone}
    phones.discard(None)
    on_app = set(get_user_model().objects.filter(phone__in=phones)
                 .values_list('phone', flat=True))
    golfers = []
    for pid in golfer_ids:
        p = players.get(pid)
        if not p:
            continue
        phone = normalize(p.phone) if p.phone else None
        golfers.append({'id': pid, 'name': names.get(pid, ''),
                        'on_halved': bool(p.user_id)
                        or bool(phone and phone in on_app),
                        'mobile': p.phone or ''})
    return classify_recipients(golfers, scorer.id if scorer else None)


# ---------------------------------------------------------------------------
# Tournament
# ---------------------------------------------------------------------------

def _best_finish(prizes: list) -> str:
    """§4's caption: the golfer's best finish, "Champ. 1st".

    The engine writes its details the other way round ("1st — Championship"),
    because that reads better in a list of one golfer's prizes.  On a chip
    the GAME comes first — the place alone is meaningless beside a name, and
    the chip is read across a grid of four.
    """
    if not prizes:
        return ''
    best = max(prizes, key=lambda p: float(p.get('amount') or 0))
    detail = str(best.get('detail') or '')
    if '—' in detail:
        place, _, game = detail.partition('—')
        return f'{game.strip()} {place.strip()}'.strip()
    return detail or str(best.get('game') or '')


def build_tournament_receipt(tournament, *, scorer=None):
    """One receipt for the whole field (§4 C).  ``None`` when it cannot be.

    Never raises: the TD's settlement screen must keep working whatever
    happens to the document.
    """
    from services.tournament_settlement import tournament_settlement
    try:
        existing = _existing(tournament)
        if existing:
            return existing

        s = tournament_settlement(tournament)
        if not s or not s.get('can_settle'):
            return None
        # §3: nets is EVERY golfer, sorted by net descending — a man who won
        # a prize exactly equal to his entry reads "$0", which §2.4 spells
        # out.  Filtering him out left him named in the games row and absent
        # from the chips, which is the receipt disagreeing with itself.
        golfers = list(s.get('golfers') or [])
        if not any(_cents(g.get('net')) for g in golfers):
            return None                   # nobody is up or down: no receipt

        # §4: "Assert that collected = paid out."  The engine answers it; a
        # receipt built over an unbalanced field would hand golfers figures
        # that do not come from one pot.
        if not s.get('sum_zero') or not s.get('balanced'):
            logger.error('receipt: tournament %s does not balance — '
                         'collected %s, paid %s', tournament.id,
                         s.get('total_collected'), s.get('total_paid'))
            return None

        golfers.sort(key=lambda g: -float(g.get('net') or 0))
        names = {g['player_id']: g.get('name', '') for g in golfers}
        td = _td_name(tournament, scorer)

        nets = [{'golferId': g['player_id'], 'name': g.get('name', ''),
                 'net': _cents(g.get('net')),
                 'caption': _best_finish(g.get('prizes') or [])}
                for g in golfers]

        # §4: the TD pays each golfer in profit, ordered by amount.  Nobody
        # hands money to anybody else — the entries were taken at signup, so
        # settling peer-to-peer would invent handovers.
        pays = [{'from': td, 'to': g.get('name', ''), 'amount': _cents(g['net'])}
                for g in golfers if float(g.get('net') or 0) > 0]
        pays.sort(key=lambda t: -t['amount'])

        pots = [p for p in (s.get('games') or [])
                if float(p.get('entries_in') or 0)
                or float(p.get('prizes_out') or 0)]
        # EVERY golfer, not just the ones with a non-zero net.  A golfer who
        # won a prize exactly equal to his entry nets zero and is not on the
        # chips, but he still won it — leaving him out made the row total
        # $120 of a $160 pot, which the pool line below contradicts.
        pot_rows = _pot_rows(s, s.get('golfers') or [])
        payload = {
            'title': tournament.name,
            'sub': _tournament_sub(tournament, len(s.get('golfers') or []),
                                   len(pots)),
            'nets': nets,
            'imageNets': _collapse(
                nets, IMAGE_CHIPS,
                lambda tail, total: {'name': f'{len(tail)} more',
                                     'net': total, 'caption': ''},
                lambda tail: sum(n['net'] for n in tail)),
            'pays': pays,
            'imagePays': _collapse(
                pays, IMAGE_PAYS,
                lambda tail, total: {'from': td, 'to': f'{len(tail)} more',
                                     'amount': total},
                lambda tail: sum(t['amount'] for t in tail)),
            'paysLabel': f'{td} pays out · entries taken at signup',
            'games': [{'label': 'The games', 'rows': pot_rows}],
            'webGames': [
                {'label': 'The games', 'rows': pot_rows},
                {'label': 'The pool', 'rows': _pool_rows(s)},
            ],
            'scorer': _scorer_block(scorer),
            'settledAt': timezone.now().isoformat(),
        }
        recipients = _field_recipients(
            tournament, [g['player_id'] for g in golfers], names, scorer)
        payload['recipients'] = {'push': recipients.push,
                                 'text': recipients.text,
                                 'none': recipients.none}
        payload['note'] = recipients.note
        return _save(tournament, payload, scorer)
    except Exception:
        logger.exception('receipt: tournament %s could not be built',
                         getattr(tournament, 'id', '?'))
        return None


def _tournament_sub(tournament, n_golfers: int, n_pots: int) -> str:
    """"Pine Valley GC · Nov 8-9 · 16 golfers · 7 pots"."""
    rounds = list(tournament.rounds.select_related('course').order_by('date'))
    course = rounds[0].course.name if rounds else ''
    dates = [r.date for r in rounds if r.date]
    when = ''
    if dates:
        first, last = min(dates), max(dates)
        when = (first.strftime('%b %-d') if first == last else
                f'{first.strftime("%b %-d")}–{last.strftime("%-d")}'
                if first.month == last.month else
                f'{first.strftime("%b %-d")}–{last.strftime("%b %-d")}')
    parts = [course, when,
             f'{n_golfers} golfer{"s" if n_golfers != 1 else ""}',
             f'{n_pots} pot{"s" if n_pots != 1 else ""}' if n_pots else '']
    return ' · '.join(p for p in parts if p)


def _pool_rows(settlement: dict) -> list:
    """§4's "The pool": Collected, then "Paid out · balances".

    **The POT, not the cash that moves.**  ``total_collected`` and
    ``total_paid`` are the sum of the positive and negative NETS — $45 on a
    field that put $160 in — because the entries were taken at signup and only
    the difference changes hands.  Both are true facts and only one is "the
    pool"; labelling the settlement figure "Collected" put $45 under a row of
    prizes totalling $160.

    §4's "assert that collected = paid out" holds either way, which is exactly
    why the wrong one was not caught by the balance check.
    """
    collected = round(sum(float(p.get('entries_in') or 0)
                          for p in settlement.get('games') or []), 2)
    paid = round(sum(float(p.get('prizes_out') or 0)
                     for p in settlement.get('games') or []), 2)
    return [
        ['Collected', money(collected)],
        ['Paid out', f'{money(paid)}'
                     f'{" · balances" if abs(collected - paid) < 0.005 else ""}'],
    ]


def _pot_rows(settlement: dict, golfers: list) -> list:
    """§4: one row per pot with its winners and amounts."""
    won = {}
    for g in golfers:
        for prize in g.get('prizes') or []:
            won.setdefault(prize.get('game', ''), []).append(
                (g.get('name', ''), float(prize.get('amount') or 0)))
    rows = []
    for pot in settlement.get('games') or []:
        label = pot.get('label', '')
        winners = sorted(won.get(label, []), key=lambda kv: -kv[1])
        if not winners:
            continue
        rows.append([label, ' · '.join(f'{n} {money(a)}' for n, a in winners)])
    return rows


# ---------------------------------------------------------------------------
# Team net
# ---------------------------------------------------------------------------

def build_team_receipt(tournament, *, scorer=None):
    """Team net (§4 C).  ``None`` when it cannot be built.

    **The chips are one per TEAM, not one per golfer**, which is the whole
    difference from the tournament receipt: a team of three divides its share
    three ways and takes MORE each, so four golfer chips reading different
    figures for one prize would hide that it was one prize.  The caption
    carries the size for exactly that reason.

    **The transfer amount is a STRING** — "4 x $71.87" — which §3 types for
    precisely this: the TD hands one team one prize, and writing the total
    would lose the per-man figure the golfers actually collect.
    """
    from services.team_play_scoring import settlement as team_settlement
    try:
        existing = _existing(tournament)
        if existing:
            return existing

        s = team_settlement(tournament)
        if not s or not s.get('can_settle'):
            return None
        blocks = s.get('blocks') or []
        out_of_money = s.get('out_of_money') or []
        if not blocks:
            return None
        if _cents(s.get('balance')):
            logger.error('receipt: team play on %s is out by %s',
                         tournament.id, s.get('balance'))
            return None

        entry = float(s.get('entry_fee') or 0)
        td = _td_name(tournament, scorer)
        chips, pays, golfer_ids, names = [], [], [], {}

        for block in blocks:
            for team in block.get('teams') or []:
                golfers = team.get('golfers') or []
                k = len(golfers)
                if not k:
                    continue
                each = float(golfers[0].get('amount') or 0)
                chips.append({
                    'golferId': team.get('foursome_id'),
                    'name': team.get('name', ''),
                    'net': _cents(each - entry),
                    'caption': f'{_place_of(block)} · net {team.get("net")} '
                               f'· {k} m{"e" if k != 1 else "a"}n',
                })
                # "4 x $71.87" — one prize, and the figure each man collects.
                pays.append({'from': td, 'to': team.get('name', ''),
                             'amount': f'{k} × {money(each)}'})
                for g in golfers:
                    golfer_ids.append(g['player_id'])
                    names[g['player_id']] = g.get('name', '')

        for row in out_of_money:
            chips.append({
                'golferId': row.get('foursome_id'),
                'name': row.get('name', ''),
                'net': _cents(row.get('per_man')),
                'caption': f'net {row.get("net")}',
            })

        chips.sort(key=lambda c: -c['net'])
        payload = {
            'title': tournament.name,
            'sub': _tournament_sub(tournament, s.get('golfers') or 0,
                                   0) + f' · {money(entry)} in',
            'nets': chips,
            'imageNets': _collapse(
                chips, IMAGE_CHIPS,
                lambda tail, total: {'name': f'{len(tail)} more',
                                     'net': total, 'caption': ''},
                lambda tail: sum(c['net'] for c in tail)),
            'pays': pays,
            'imagePays': pays[:IMAGE_PAYS + 1],
            'paysLabel': f'{td} pays out · entries taken at signup',
            'games': [{'label': 'The pool', 'rows': _team_pool_rows(s)}],
            'scorer': _scorer_block(scorer),
            'settledAt': timezone.now().isoformat(),
        }
        recipients = _field_recipients(tournament, golfer_ids, names, scorer)
        payload['recipients'] = {'push': recipients.push,
                                 'text': recipients.text,
                                 'none': recipients.none}
        payload['note'] = recipients.note
        return _save(tournament, payload, scorer)
    except Exception:
        logger.exception('receipt: team play on %s could not be built',
                         getattr(tournament, 'id', '?'))
        return None


def _place_of(block: dict) -> str:
    """A tied block occupies several places and shares what they pay, so the
    caption names the block's own places rather than inventing a single one."""
    places = block.get('places') or []
    if not places:
        return ''
    from services.receipt_games import _place
    if len(places) == 1:
        return _place(places[0])
    return f'T{places[0]}'


def _team_pool_rows(s: dict) -> list:
    """§4: "In, the places, and 'Odd cents · to the high handicap'"."""
    rows = [['In', f'{money(s.get("entry_fee"))} × '
                   f'{s.get("golfers")} = {money(s.get("pool"))}']]
    for block in s.get('blocks') or []:
        rows.append([_place_of(block) or 'Paid', money(block.get('total'))])
    # The rule is stated because it is arbitrary-but-deterministic, and a
    # golfer handed $71.89 beside three $71.87s otherwise has no explanation.
    rows.append(['Odd cents', 'to the high handicap'])
    return rows


# ---------------------------------------------------------------------------
# Which document a tournament gets
# ---------------------------------------------------------------------------

def build_field_receipt(tournament, *, scorer=None):
    """The tournament's receipt, whichever kind it is.

    **Team play is a different DOCUMENT, not a different section**: its chips
    are teams and its transfers are one prize split several ways, so the two
    cannot be merged into one assembler without the team case reading as a
    tournament whose golfers all won the same odd figure.  A tournament has
    one or the other, so the config decides.
    """
    if getattr(tournament, 'team_play_config', None):
        return build_team_receipt(tournament, scorer=scorer)
    return build_tournament_receipt(tournament, scorer=scorer)
