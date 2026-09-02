"""
services/settlement_receipt.py
------------------------------
The golfer's receipt, and the text that carries it (handoff-settlement-receipt).

Settlement answers the TD's question — do the pools balance. The receipt
answers the golfer's: what do I owe, to whom, and what for. Same data one
level down, addressed to one man, and built to leave the app.

Composition is a PURE FUNCTION of settled data: same input, same string. The
receipt view and the message are both built from here, so they cannot disagree
— nothing composes from a rendered screen.
"""
from __future__ import annotations

from decimal import Decimal

from core.models import RoundStatus

# ---------------------------------------------------------------------------
# Money — formatted once, in one place (rule 2)
# ---------------------------------------------------------------------------

def money(value, plain: bool = False) -> str:
    """
    The one money formatter. Two formatters means two answers.

    `plain=False` is for the screen and uses a real minus sign (U+2212), which
    aligns under a proportional font. `plain=True` is for SMS and uses ASCII
    '-' / '+' — see sms_segments() for why an SMS must stay inside GSM-7.
    """
    v = Decimal(str(value or 0))
    neg = v < 0
    amt = abs(v).quantize(Decimal('0.01'))
    body = f'{amt:.2f}'
    if body.endswith('.00'):
        body = body[:-3]
    if plain:
        return ('-$' if neg else '+$') + body
    return ('−$' if neg else '$') + body


# ---------------------------------------------------------------------------
# Length — shown as messages, not characters (rule 4)
# ---------------------------------------------------------------------------

# The GSM 03.38 basic set plus its extension table. Anything outside this
# forces the whole message to UCS-2, which cuts a segment from 160 characters
# to 70 — so one curly apostrophe or en dash can double the message count.
_GSM_BASIC = (
    '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?'
    '¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà'
)
_GSM_EXT = '^{}\\[~]|€'


def sms_segments(text: str) -> dict:
    """
    How many SMS messages `text` will actually cost, and why.

    Returns {'segments': int, 'encoding': 'GSM-7'|'UCS-2', 'units': int,
             'non_gsm': [chars]}.

    306 characters means nothing; "3 messages each" means something, and on a
    metered plan it means money. The non_gsm list exists because the usual
    cause of a surprise is a single typographic character — an em dash or a
    curly quote — dragging an otherwise short message into UCS-2.
    """
    text = text or ''
    non_gsm = sorted({c for c in text if c not in _GSM_BASIC and c not in _GSM_EXT})
    if non_gsm:
        units = len(text)
        single, multi, enc = 70, 67, 'UCS-2'
    else:
        # Extension-table characters occupy two units each.
        units = sum(2 if c in _GSM_EXT else 1 for c in text)
        single, multi, enc = 160, 153, 'GSM-7'
    if units == 0:
        segments = 0
    elif units <= single:
        segments = 1
    else:
        segments = -(-units // multi)      # ceil
    return {'segments': segments, 'encoding': enc, 'units': units,
            'non_gsm': non_gsm}


# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------

def _surname(full: str) -> str:
    parts = (full or '').strip().split()
    return parts[-1] if parts else ''


def _field_labels(players: list) -> dict:
    """Names for the field summary — surnames, unless surnames don't separate.

    A surname is the right label for a group thread: "Wu +$5" reads the way
    the group talks. But a family four-ball is a real casual round, and four
    Lipkins produce four identical lines, which is not a shorter receipt, it
    is an unreadable one. Where a surname is shared, everyone sharing it falls
    back to the full name — only the ambiguous ones, so one repeated surname
    does not make the whole message longer.
    """
    counts: dict = {}
    for p in players:
        counts[_surname(p.get('name', ''))] = \
            counts.get(_surname(p.get('name', '')), 0) + 1
    return {
        p.get('player_id'): (p.get('name', '').strip()
                             if counts.get(_surname(p.get('name', ''))) > 1
                             else _surname(p.get('name', '')))
        for p in players
    }


def compose_personal(*, event_name: str, golfer_name: str, entries: list,
                     prizes: list, net, note: str = '') -> str:
    """
    One golfer's lines, addressed to him alone.

    Plain text only, no formatting, and no link back into the app: the message
    has to be readable by a man who has not installed it.

    Entries arrive as a count and a total rather than one line each. That is
    the design's own trade against message length -- the count is what answers
    "why did I stake less than him". Prizes DO travel individually, with the
    group and the number of ways, because the share is the part he can check.
    """
    staked = sum(Decimal(str(e.get('amount') or 0)) for e in entries)
    lines = [
        f'{event_name} - settled.',
        f'{golfer_name} - {money(net, plain=True)} '
        f'{"to collect" if Decimal(str(net or 0)) >= 0 else "to pay"}',
        '',
        f'Entries ({len(entries)}) {money(-abs(staked), plain=True)}',
    ]
    for p in prizes:
        detail = (p.get('detail') or '').strip()
        label  = p.get('label') or 'Prize'
        suffix = f' ({detail})' if detail else ''
        lines.append(f'{label}{suffix} {money(p.get("amount"), plain=True)}')
    lines.append(f'Net {money(net, plain=True)}')
    if note:
        lines += ['', note]
    return '\n'.join(lines)


def compose_field(*, event_name: str, golfers: list, pots: int = 0,
                  note: str = '') -> str:
    """
    Every net, sorted, collectors first, no itemisation — one group thread.

    A man's itemised card in a sixteen-man thread is the wrong default; a field
    summary sent privately sixteen times is sixteen copies of one thing.
    """
    rows = sorted(golfers, key=lambda g: Decimal(str(g.get('net') or 0)),
                  reverse=True)
    collecting = [g for g in rows if Decimal(str(g.get('net') or 0)) >= 0]
    paying     = [g for g in rows if Decimal(str(g.get('net') or 0)) < 0]

    head = f'{event_name} - settled.'
    if golfers:
        head += f' {len(golfers)} golfers'
        if pots:
            head += f', {pots} pots'
        head += '.'
    out = [head]
    for title, group in (('Collecting', collecting), ('Paying', paying)):
        if not group:
            continue
        out += ['', title]
        out += [f'{_surname(g.get("name", ""))} {money(g.get("net"), plain=True)}'
                for g in group]
    if note:
        out += ['', note]
    return '\n'.join(out)


# ---------------------------------------------------------------------------
# The payload the receipt screen and the send flow both read
# ---------------------------------------------------------------------------

def receipt_payload(tournament, *, note: str = '') -> dict:
    """Everything a receipt screen and a field send need, composed here.

    Deliberately assembled server-side rather than in the client: rule 1 says
    composition is a pure function of settled data, and the surest way to keep
    the receipt view and the message agreeing is that neither of them builds
    the other. The client renders this and shares the string; it never writes
    one.

    Nothing here recomputes money. `tournament_settlement` is the single source
    of the numbers, including the `blocking` list — so the send gate is the
    SAME condition as Settle, which is what rule 6 asks for: provisional money
    must not leave the app.
    """
    from services.tournament_settlement import tournament_settlement

    settled = tournament_settlement(tournament)
    golfers = settled['golfers']
    event   = tournament.name or 'Tournament'

    for g in golfers:
        # Composed per golfer even though only the field summary can be sent
        # today: the receipt screen shows a man exactly what would go to him,
        # and the personal-send flow is the only thing still missing.
        g['message'] = compose_personal(
            event_name=event, golfer_name=g['name'], entries=g['entries'],
            prizes=g['prizes'], net=g['net'], note=note)
        g['segments'] = sms_segments(g['message'])

    field_message = compose_field(
        event_name=event, golfers=golfers,
        pots=len(settled.get('games') or []), note=note)

    last = tournament.settlement_sends.first()
    return {
        'event_name'   : event,
        'note'         : note,
        'golfers'      : golfers,
        'field_summary': {
            'message' : field_message,
            'segments': sms_segments(field_message),
            'recipients': len(golfers),
        },
        # The gate, and why — shown as a condition, not an invisible disable.
        'can_send'     : settled['can_settle'],
        'blocking'     : settled['blocking'],
        'excluded_note': settled['excluded_note'],
        'totals'       : {
            'collected': settled['total_collected'],
            'paid'     : settled['total_paid'],
        },
        'last_send'    : _send_stamp(last),
    }


# ---------------------------------------------------------------------------
# Casual rounds — a different document, because there is no pot
# ---------------------------------------------------------------------------
#
# A tournament receipt says "collect $84": a TD held the money and hands it
# back. A casual round has no TD and no pot — four golfers settle among
# themselves — so the useful sentence is not the net at all, it is "Ben owes
# you $12". The net is still the headline, because it is what a man checks
# first, but the transfers are what he acts on, and they are what belong in a
# group thread.
#
# The lines are per GAME rather than per entry, because that is what a casual
# golfer disputes: not "why did I stake that" but "I thought I won the skin on
# 7".

def compose_casual_personal(*, event_name: str, golfer_name: str, games: list,
                            transfers: list, net, note: str = '') -> str:
    """One golfer's round, addressed to him alone.

    `games` are ``{'label', 'amount'}`` — his signed net in each game.
    `transfers` are only the ones he is IN, already phrased from his side as
    ``{'other', 'amount', 'owes_me'}``.
    """
    n = Decimal(str(net or 0))
    lines = [
        f'{event_name}',
        f'{golfer_name} - {money(n, plain=True)} '
        f'{"to collect" if n >= 0 else "to pay"}',
    ]
    if games:
        lines.append('')
        lines += [f'{g.get("label", "")} {money(g.get("amount"), plain=True)}'
                  for g in games]
    if transfers:
        # The instruction, not the arithmetic.  Names, not ids — this is read
        # by someone standing in a car park.
        lines.append('')
        lines.append('Settle up')
        for t in transfers:
            amt = money(abs(Decimal(str(t.get('amount') or 0))), plain=True).lstrip('+')
            lines.append(f'{t["other"]} pays you {amt}' if t.get('owes_me')
                         else f'You pay {t["other"]} {amt}')
    if note:
        lines += ['', note]
    return '\n'.join(lines)


def compose_casual_field(*, event_name: str, players: list, transfers: list,
                         note: str = '') -> str:
    """Every net, then who pays whom — one message to the group thread.

    For a casual round this is the MORE useful of the two payloads: four
    people in one thread, and the thing they actually need is the list of
    payments, not each other's itemisation.
    """
    rows = sorted(players, key=lambda p: Decimal(str(p.get('net') or 0)),
                  reverse=True)
    labels = _field_labels(rows)
    out = [f'{event_name} - settled.']
    if rows:
        out.append('')
        out += [f'{labels.get(p.get("player_id")) or _surname(p.get("name", ""))} '
                f'{money(p.get("net"), plain=True)}'
                for p in rows]
    if transfers:
        out += ['', 'Settle up']
        for t in transfers:
            amt = money(abs(Decimal(str(t.get('amount') or 0))),
                        plain=True).lstrip('+')
            out.append(f'{t.get("from_name") or "?"} pays '
                       f'{t.get("to_name") or "?"} {amt}')
    if note:
        out += ['', note]
    return '\n'.join(out)


def _send_stamp(send) -> dict | None:
    """One send, serialised the same way everywhere it is reported."""
    if send is None:
        return None
    return {
        'mode'      : send.mode,
        'recipients': send.recipients,
        'sent_at'   : send.sent_at.isoformat(),
        'sent_by'   : (send.sent_by.get_full_name()
                       or send.sent_by.username) if send.sent_by else '',
    }


def casual_receipt_payload(round_obj, *, note: str = '') -> dict:
    """The casual equivalent of `receipt_payload`.

    Reads `round_settlement` and recomputes no money. Returns ``None`` when the
    round has nothing nettable — a round with no money in it has no receipt,
    and inventing an empty one would be worse than saying so.
    """
    from services.settlement import round_settlement
    from tournament.models import SettlementSend

    # min_games=1: the 2+ rule is the Settlement TAB's, and a one-game round
    # still owes somebody money.
    settled = round_settlement(round_obj, min_games=1)
    if settled is None:
        return None

    # A round can settle cleanly to nothing — everyone squared, or a game that
    # ran but paid nobody. There is no receipt for that. Texting four people
    # "+$0 to collect" is not a smaller receipt, it is a wrong one, and the
    # same rule that refuses an invented empty receipt refuses this.
    if all(round(float(p.get('net') or 0), 2) == 0 for p in settled['players']):
        return None

    players   = settled['players']
    transfers = settled['transfers']
    event     = _casual_event_name(round_obj)

    # Invert per_game so each golfer carries his own lines.
    by_pid: dict = {p['player_id']: [] for p in players}
    for game in settled['per_game']:
        for pid, amount in (game.get('nets') or {}).items():
            pid = int(pid)
            if pid in by_pid and round(float(amount or 0), 2) != 0:
                by_pid[pid].append({'label': game.get('label') or game.get('game'),
                                    'amount': round(float(amount), 2)})

    golfers = []
    for p in players:
        pid  = p['player_id']
        mine = [
            {'other': t['to_name'], 'amount': t['amount'], 'owes_me': False}
            if t['from'] == pid else
            {'other': t['from_name'], 'amount': t['amount'], 'owes_me': True}
            for t in transfers if pid in (t['from'], t['to'])
        ]
        message = compose_casual_personal(
            event_name=event, golfer_name=p['name'], games=by_pid.get(pid, []),
            transfers=mine, net=p['net'], note=note)
        golfers.append({**p, 'games': by_pid.get(pid, []), 'transfers': mine,
                        'message': message, 'segments': sms_segments(message)})

    field_message = compose_casual_field(
        event_name=event, players=players, transfers=transfers, note=note)

    # A round still being played can still be netted, but the numbers move.
    # Same principle as the tournament gate: a texted receipt is treated as
    # final, so it waits for the round to be finished.
    #   The status VALUE is 'complete', not 'completed' — compare against the
    #   enum rather than a literal so a rename can't silently wedge the gate
    #   shut again.
    complete = round_obj.status == RoundStatus.COMPLETE
    blocking = [] if complete else [
        'This round is not finished, so the money can still move. A texted '
        'receipt is treated as final by everyone who gets one.'
    ]
    # Games that are active but that nothing knows how to net yet. Named,
    # because the omission would otherwise read as a bug.
    uncovered = settled.get('uncovered_games') or []

    # "The last send" is not one fact.  A field summary going out says nothing
    # about whether Ben has had his own, and a stamp that conflates them tells
    # the sender he has done something he has not — which is exactly the
    # double-send the record exists to prevent (rule 8).
    sends = list(round_obj.settlement_sends.all())
    last  = sends[0] if sends else None
    last_field = next((x for x in sends if x.mode == SettlementSend.MODE_FIELD),
                      None)
    last_personal: dict = {}
    for x in sends:
        if x.mode == SettlementSend.MODE_PERSONAL and x.player_id is not None:
            last_personal.setdefault(x.player_id, x)

    for g in golfers:
        g['last_send'] = _send_stamp(last_personal.get(g['player_id']))

    return {
        'event_name'   : event,
        'note'         : note,
        'golfers'      : golfers,
        'transfers'    : transfers,
        'field_summary': {
            'message'   : field_message,
            'segments'  : sms_segments(field_message),
            'recipients': len(players),
            'last_send' : _send_stamp(last_field),
        },
        'can_send'     : not blocking,
        'blocking'     : blocking,
        'excluded_note': (
            'Not netted here: ' + ', '.join(uncovered) +
            ' — settle those among yourselves.'
        ) if uncovered else '',
        # "The most recent send of any kind", for the timeline. The screen
        # renders the two stamps above instead — the field one and each
        # golfer's own — because those are the ones that answer "have I
        # already sent this".
        'last_send'    : _send_stamp(last),
    }


def _casual_event_name(round_obj) -> str:
    """`Tilden Park, 30 Aug` — a casual round has no name of its own, and a
    receipt headed "Round 412" tells the reader nothing."""
    course = getattr(getattr(round_obj, 'course', None), 'name', '') or 'Round'
    date = getattr(round_obj, 'date', None)
    return f'{course}, {date:%-d %b}' if date else course
