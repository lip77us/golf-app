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
