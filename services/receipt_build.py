"""Finish round -> a frozen Receipt — settle-up handoff step 3.

Three things happen when the scorer taps Finish round: the money is FROZEN
into a :class:`tournament.models.Receipt`, the golfers who are on Halved get a
push, and the scorer is handed Round over.  This module does the first two.

**Casual rounds only, and that is the handoff's own division.**  §4 puts the
tournament receipt under Group C: "one receipt for the WHOLE FIELD, with
several pots", built when the TD settles rather than when a round ends, and it
says in as many words that foursome side bets "settle in the group and are not
on this receipt".  A per-round hook cannot produce that document, so a
tournament round is skipped here and waits for the Group C assembler.

**A round that settles to nothing gets no receipt.**  Everyone square, or a
game that ran and paid nobody, would produce four "+$0 to collect" lines and a
link saying nothing.  The casual receipt payload already refuses that case and
this keeps the rule in one place.

**One receipt per settling.**  Finish round is explicitly idempotent, so a
second tap must not mint a second code; the first receipt is returned
untouched.  A round REOPENED and re-settled is a different matter and gets a
new one — see the model, which keeps the old link saying what the golfers were
shown.

**The per-game rows are a seam, not a stub.**  §4 gives every game its own
summary language ("Kim 4 · Lipkin 2 · Reid 1"), which is steps 4 to 6.
:data:`GAME_SUMMARY` is where those land; until a game registers one it falls
back to naming who the money moved to, which is true and useful rather than a
placeholder that says nothing.
"""
from __future__ import annotations

import logging

from django.db import transaction
from django.utils import timezone

from services.settle_up import Transfer, classify_recipients, for_display, settle
from services.settlement import round_settlement
from services.settlement_receipt import money

logger = logging.getLogger(__name__)

#: ``{game_key: callable(round_obj, per_game_entry, names) -> (label, value)}``
#: Steps 4 to 6 fill this.  Registering one here is the ONLY thing a game has
#: to do to get its own language onto every receipt surface at once.
GAME_SUMMARY: dict = {}

#: ``{game_key: callable(round_obj) -> str}`` for §3's ``stakeLabel``
#: ("$10 a match", "$2 a skin"), which composes the ``sub`` line.
GAME_STAKE: dict = {}

#: How many golfers the unformatted fallback row names before collapsing.
#: Four is a full group, which is the common case it must not truncate.
_FALLBACK_MOVERS = 4


def _cents(dollars) -> int:
    """Money arrives from the engines in dollars and settles in cents (§2.1).

    ``round`` rather than ``int``: 26.0 is sometimes 25.999999 by the time a
    float has been through a payout split, and truncating it loses a cent that
    then fails the sum-to-zero assert with no explanation.
    """
    return int(round(float(dollars or 0) * 100))


def _date_label(round_obj) -> str:
    # "Nov 4", the handoff's own format.
    return round_obj.date.strftime('%b %-d') if round_obj.date else ''


def _sub(round_obj, games: list) -> str:
    """"Tilden Park GC · Nov 4 · $10 a match · $2 a skin" (§3)."""
    parts = [round_obj.course.name, _date_label(round_obj)]
    for entry in games:
        fn = GAME_STAKE.get(entry['game'])
        label = fn(round_obj) if fn else None
        if label:
            parts.append(label)
    if len(parts) == 2 and round_obj.bet_unit:
        # No game has registered a stake label, so the UNIT is not known here.
        # §3's labels name it ("$2 a skin", "$10 a match") and a generic
        # fallback that guessed would print "$5 a point" on a skins round —
        # true of the figure and false of the game.  The bare stake is the
        # most that can be said without a formatter.
        parts.append(f'{money(round_obj.bet_unit)} stake')
    return ' · '.join(p for p in parts if p)


def _summary_rows(round_obj, per_game: list, names: dict) -> list:
    rows = []
    for entry in per_game:
        fn = GAME_SUMMARY.get(entry['game'])
        if fn:
            rows.append(list(fn(round_obj, entry, names)))
            continue
        # Fallback: who the money moved to, biggest first. True, checkable,
        # and replaced the moment that game registers its own language.
        #
        # It COLLAPSES rather than truncating. Capping at three put "Tim +$32
        # · Paul +$8 · ST −$20" on a four-ball and dropped the fourth golfer
        # with nothing saying so, which reads as a bug rather than as a
        # summary — the same rule the preview's "13 more" follows.
        movers = sorted(((pid, net) for pid, net in entry['nets'].items()
                         if _cents(net)), key=lambda kv: -kv[1])
        shown, rest = movers[:_FALLBACK_MOVERS], movers[_FALLBACK_MOVERS:]
        value = ' · '.join(
            f'{_short(names, pid)} {money(net, sign=True)}'
            for pid, net in shown)
        if rest:
            value += f' · {len(rest)} more'
        rows.append([entry['label'], value or 'no money moved'])
    return rows


def _captions(round_obj, player_ids) -> dict:
    """§3's default caption, "{gross} · net {net}".

    Read from the stored scorecard rather than recomputed: this is a frozen
    document, and a caption that disagreed with the card it was taken from
    would be the one thing a golfer checks it against.
    """
    from django.db.models import Count, Sum
    from scoring.models import HoleScore
    rows = (HoleScore.objects
            .filter(foursome__round=round_obj, player_id__in=player_ids,
                    gross_score__isnull=False)
            .values('player_id')
            .annotate(gross=Sum('gross_score'), net=Sum('net_score'),
                      holes=Count('id')))
    out = {}
    for r in rows:
        if not r['holes']:
            continue
        out[r['player_id']] = (f'{r["gross"]} · net {r["net"]}'
                               if r['net'] is not None else f'{r["gross"]}')
    return out


def build_round_receipt(round_obj, *, scorer=None):
    """Freeze this round's money into a Receipt.  ``None`` when there is none.

    Never raises: Finish round must close the round whatever happens to the
    receipt.  A golfer whose round would not finish because a document could
    not be composed is a worse failure than a missing link.
    """
    from tournament.models import Receipt
    try:
        if round_obj.tournament_id:
            return None                       # Group C, at tournament settle
        existing = Receipt.objects.filter(round=round_obj).first()
        if existing:
            return existing

        data = round_settlement(round_obj, min_games=1)
        if not data:
            return None
        per_game = data.get('per_game') or []
        players = data.get('players') or []
        if not per_game or not players:
            return None

        names = {p['player_id']: p for p in players}
        order = [p['player_id'] for p in players]

        # §2.2: a round playing more than one game settles ONCE, on the sum.
        nets = {pid: 0 for pid in order}
        for entry in per_game:
            for pid, net in entry['nets'].items():
                if pid in nets:
                    nets[pid] += _cents(net)

        if not any(nets.values()):
            return None                       # everyone square — no receipt

        drift = sum(nets.values())
        if drift:
            # The engines round per game in dollars, so a multi-game round can
            # land a cent out. Absorb it on the biggest winner rather than
            # failing the settle: a receipt that cannot be built is worse than
            # one cent, and it is visible in the chips either way.
            nets[order[0]] -= drift

        transfers = for_display(settle(nets, order=order))
        captions = _captions(round_obj, order)

        payload = {
            'title': ' + '.join(e['label'] for e in per_game),
            'sub': _sub(round_obj, per_game),
            'nets': [
                {'golferId': pid,
                 'name': names[pid].get('short_name') or names[pid]['name'],
                 'net': nets[pid],
                 'caption': captions.get(pid, '')}
                for pid in sorted(order, key=lambda p: -nets[p])
            ],
            'pays': [{'from': _short(names, t.frm), 'to': _short(names, t.to),
                      'amount': t.amount} for t in transfers],
            'games': [{'label': 'The games',
                       'rows': _summary_rows(round_obj, per_game, names)}],
            'scorer': _scorer_block(scorer),
            'settledAt': timezone.now().isoformat(),
        }
        recipients = _recipients(round_obj, order, names, scorer)
        payload['recipients'] = {'push': recipients.push,
                                 'text': recipients.text,
                                 'none': recipients.none}
        payload['note'] = recipients.note

        receipt = Receipt.objects.create(
            round=round_obj, payload=payload, scorer=scorer,
            settled_at=timezone.now())
        receipt.payload['code'] = receipt.code
        receipt.save(update_fields=['payload'])
        return receipt
    except Exception:
        logger.exception('receipt: could not build for round %s', round_obj.id)
        return None


def _short(names: dict, pid) -> str:
    entry = names.get(pid) or {}
    return entry.get('short_name') or entry.get('name') or ''


def _scorer_block(scorer) -> dict:
    if not scorer:
        return {}
    name = scorer.name or ''
    initials = ''.join(part[0] for part in name.split()[:2]).upper()
    return {'name': name, 'initials': initials}


def _recipients(round_obj, order, names, scorer):
    """§2.5, against this round's real roster."""
    from accounts.phone import normalize
    from core.models import Player
    from django.contrib.auth import get_user_model

    players = {p.id: p for p in Player.objects.filter(id__in=order)}
    phones = {normalize(p.phone) for p in players.values() if p.phone}
    phones.discard(None)
    on_app = set(get_user_model().objects
                 .filter(phone__in=phones)
                 .values_list('phone', flat=True))
    golfers = []
    for pid in order:
        p = players.get(pid)
        if not p:
            continue
        phone = normalize(p.phone) if p.phone else None
        golfers.append({
            'id': pid,
            'name': _short(names, pid),
            'on_halved': bool(p.user_id) or bool(phone and phone in on_app),
            'mobile': p.phone or '',
        })
    return classify_recipients(golfers, scorer.id if scorer else None)


# --------------------------------------------------------------------------
# §1 — the push, for the golfers who are on Halved
# --------------------------------------------------------------------------

def receipt_url(code: str) -> str:
    base = (getattr(__import__('django.conf', fromlist=['settings']).settings,
                    'PUBLIC_BASE_URL', '') or '').rstrip('/')
    return f'{base}/r/{code}/'


def notify_receipt(receipt) -> int:
    """One push each, per §1.  Returns how many golfers were reached.

    **The body is per golfer, which is why this is not
    ``notify_round_event``.**  That helper sends one title and body to every
    follower of a round; §1 tells a winner what he won ("You won $26 · View
    receipt") and everybody else only where it was ("Tilden Park GC · View
    receipt").  A shared body would have to pick one of those and be wrong for
    somebody.

    **Only golfers on the receipt, never watchers.**  A spectator did not play
    for anything, so a push about money is addressed to the wrong person — and
    ``users_for_round`` deliberately includes watchers.

    **Its own category.**  Muting round-complete should not mute the money:
    they are different facts, and this is the one a golfer is waiting for.

    Best-effort and never raises: the round is already closed by the time this
    runs, and a notification problem must not undo that.
    """
    try:
        from accounts.models import DeviceToken, SentNotification
        from core.models import Player
        from services.push import send_push, tokens_for_users

        payload = receipt.payload or {}
        push_ids = (payload.get('recipients') or {}).get('push') or []
        if not push_ids:
            return 0
        by_id = {n['golferId']: n for n in payload.get('nets') or []}
        course = (receipt.round.course.name if receipt.round_id else '')
        url = receipt_url(receipt.code)

        sent = 0
        for player in Player.objects.filter(id__in=push_ids).select_related('user'):
            user = player.user or _user_for_phone(player.phone)
            if not user:
                continue
            key = f'receipt:{receipt.code}:player={player.id}'
            _, created = SentNotification.objects.get_or_create(
                dedup_key=key, defaults={'event_type': 'receipt'})
            if not created:
                continue
            net = (by_id.get(player.id) or {}).get('net', 0) or 0
            # §1: won -> name the figure; lost or level -> name the place.
            # Telling a man who lost $18 that he "won −$18" is the obvious
            # trap, and naming the course is what makes the other push useful
            # to somebody who played two rounds this week.
            body = (f'You won {money(net / 100)} · View receipt' if net > 0
                    else f'{course} · View receipt')
            tokens = tokens_for_users([user], 'receipt')
            if not tokens:
                continue
            dead = send_push(tokens, 'Settled', body, {
                'type': 'receipt', 'code': receipt.code, 'url': url,
                'round_id': str(receipt.round_id or ''),
            })
            if dead:
                DeviceToken.objects.filter(token__in=dead).delete()
            sent += 1
        return sent
    except Exception:  # pragma: no cover - defensive
        logger.exception('receipt: push failed for %s', receipt.code)
        return 0


def _user_for_phone(phone):
    if not phone:
        return None
    from accounts.phone import normalize
    from django.contrib.auth import get_user_model
    norm = normalize(phone)
    if not norm:
        return None
    return get_user_model().objects.filter(phone=norm).first()


def settle_round(round_obj, *, scorer=None):
    """The whole Finish round hook: freeze, then push after the commit.

    The push is deferred to ``on_commit`` so a rolled-back completion cannot
    tell four golfers the money is settled — the same rule the activity feed
    follows, and for the same reason.
    """
    receipt = build_round_receipt(round_obj, scorer=scorer)
    if receipt:
        transaction.on_commit(lambda: notify_receipt(receipt))
    return receipt
