"""The 1080x1350 link-preview card — settle-up handoff §1, "image".

The third surface of the same ``Receipt`` payload.  ``receipt_ticket`` draws
it as HTML; this draws it as a PNG, because a text message unfurls an image
and not a web page.

**Drawn with Pillow, not headless Chrome**, following
``services/share_card.py`` and for the reason recorded there: Chromium on the
Railway deploy is ~300MB of buildpack plus cold-start and per-request memory,
against a renderer that already draws this in milliseconds with both fonts
bundled.  The CSS in ``patterns/receipt-ticket.js`` is the spec; this is the
port.

**Designed at 360x450 and rendered at 3x**, which is §1's own instruction, so
every number below is the CSS value times :data:`S`.  Keeping the scale
factor explicit rather than baking 3x numbers in is what lets the design be
checked against the stylesheet it came from.

**The image is the one surface that collapses.**  A preview has one screen and
no scroll, so §1 caps it at four chips, three transfer lines and the first
section's first two rows — and the payload supplies ``imageNets`` /
``imagePays`` with the remainder already summed into a "13 more" row, because
the collapse is a money decision and does not belong in a renderer.
"""
from __future__ import annotations

import io

from PIL import Image, ImageDraw

from services.share_card import _draw_mark, _font, _tracked, _DISPLAY, _TEXT
from services.receipt_ticket import label_for
from services.settlement_receipt import money

S = 3                                  # §1: designed at 360x450, render at 3x
WIDTH, HEIGHT = 360 * S, 450 * S

GROUND      = (0xEE, 0xF3, 0xEE)
INK         = (0x0B, 0x1F, 0x1A)
TICKET_TEXT = (0xF3, 0xF1, 0xEA)
MUTED       = (0x9B, 0xAA, 0xA0)
MUTED_DEEP  = (0x7C, 0x8C, 0x82)
MINT        = (0x3B, 0xD8, 0x9A)
CORAL       = (0xF0, 0x91, 0x6E)
PINE        = (0x0F, 0x6E, 0x56)
FOOT_TEXT   = (0x5C, 0x6B, 0x62)

UP_FILL,   UP_LINE   = (*MINT, 31),        (*MINT, 89)      # .12 / .35
DOWN_FILL, DOWN_LINE = (*CORAL, 26),       (*CORAL, 82)     # .10 / .32
EVEN_FILL, EVEN_LINE = (*TICKET_TEXT, 15), (*TICKET_TEXT, 46)
PERF_LINE = (*TICKET_TEXT, 56)                               # .22

MAX_CHIPS, MAX_PAYS, MAX_ROWS = 4, 3, 2
#: The arrow is DRAWN, not typed: the bundled Spline Sans has no U+2192
#: and Pillow renders a missing glyph as a tofu box, which on a link
#: preview reads as a broken card rather than as a missing character.
FOOTER_CTA = 'Run the next game yourself'


def _amount(value, *, sign=False) -> str:
    if isinstance(value, str):
        return value
    return money((value or 0) / 100, sign=sign)


def _text(d, xy, s, font, fill):
    d.text(xy, s, font=font, fill=fill)
    return d.textlength(s, font=font)


def _ellipsise(d, s, font, max_w):
    """Trim to fit.  A caption is a detail; losing its tail beats pushing the
    amount off the chip, which is the number the chip exists for."""
    if d.textlength(s, font=font) <= max_w:
        return s
    while s and d.textlength(s + '…', font=font) > max_w:
        s = s[:-1]
    return (s + '…') if s else ''


def _perforation(d, x0, x1, y, notch_bg):
    """A dashed rule with a round notch punched through each end.

    The notches are filled in the GROUND colour because they are holes: they
    show the page behind the ticket.  Get that wrong and they read as two grey
    dots sitting on it.
    """
    dash, gap, r = 7 * S, 6 * S, 11 * S
    x = x0
    while x < x1:
        d.line([(x, y), (min(x + dash, x1), y)], fill=PERF_LINE, width=2 * S)
        x += dash + gap
    for cx in (x0 - 0, x1):
        d.ellipse([cx - r, y - r, cx + r, y + r], fill=notch_bg)


def _arrow(d, x, y, size, fill):
    """The mint arrow between two names — the SVG's own path, scaled."""
    u = size / 24.0
    d.line([(x + 4 * u, y + 12 * u), (x + 19 * u, y + 12 * u)],
           fill=fill, width=max(2, int(2 * u)))
    for dy in (-6 * u, 6 * u):
        d.line([(x + 13 * u, y + 12 * u + dy), (x + 19 * u, y + 12 * u)],
               fill=fill, width=max(2, int(2 * u)))


def render_receipt_card(receipt: dict) -> bytes:
    """The payload as a 1080x1350 PNG."""
    img = Image.new('RGB', (WIDTH, HEIGHT), GROUND)
    # 'RGBA' so the translucent chip fills BLEND. Pillow only blends when the
    # target image is RGB, which is why the canvas above is not RGBA.
    d = ImageDraw.Draw(img, 'RGBA')

    pad_x, pad_top = 16 * S, 12 * S
    tx0, tx1 = pad_x, WIDTH - pad_x
    ty0 = pad_top
    inner = 18 * S                       # .hr-img .hr-tk padding-left/right
    x, right = tx0 + inner, tx1 - inner

    f_foot  = _font(_TEXT, 12 * S, 'Medium')
    f_title = _font(_DISPLAY, 20 * S, 'Bold')
    f_sub   = _font(_TEXT, 10 * S, 'Regular')
    f_name  = _font(_TEXT, 12 * S, 'Medium')
    f_cap   = _font(_TEXT, 9 * S, 'Regular')
    f_amt   = _font(_TEXT, 13 * S, 'Bold')
    f_k     = _font(_DISPLAY, 9 * S, 'SemiBold')
    f_pay   = _font(_TEXT, 13 * S, 'SemiBold')
    f_pamt  = _font(_TEXT, 15 * S, 'Bold')
    f_lab   = _font(_TEXT, 11 * S, 'Regular')
    f_val   = _font(_TEXT, 11 * S, 'SemiBold')


    # ── Height first, so the ticket HUGS its content ───────────────────────
    # Stretching it to the footer leaves a slab of dead ink under the last
    # row, which is what the design's ground showing through is for.  Every
    # part below is a named height that the layout then spends, so the two
    # cannot drift into disagreeing about where the bottom is.
    nets = (receipt.get('imageNets') or receipt.get('nets') or [])[:MAX_CHIPS]
    pays = (receipt.get('imagePays') or receipt.get('pays') or [])[:MAX_PAYS]
    sections = receipt.get('games') or []
    # Chip height is the CSS, not a guess: 6px padding top and bottom, a
    # 12.5px name at normal leading and a 9.5px caption 1px under it.
    gap, ch = 6 * S, 39 * S
    cw = (right - x - gap) / 2
    h_head  = 14 * S + 13 * S
    h_title = 10 * S + int(f_title.size * 1.1) + 4 * S + int(f_sub.size * 1.3)
    chip_rows = (len(nets) + 1) // 2
    h_chips = (10 * S + chip_rows * (ch + gap) - gap) if nets else 0
    # §"Play for fun": no transfers, no block — and so no height.  Leaving
    # it in reserved space for a heading that is never drawn, which on a
    # ticket sized to hug its content is a slab of dead ink.
    h_pays  = ((10 * S + 10 * S + int(f_k.size * 1.1) + 7 * S
                + len(pays) * (int(f_pay.size * 1.15) + 7 * S)) if pays else 0)
    h_games = ((3 * S + 10 * S + int(f_k.size * 1.1) + 7 * S
                + len((sections[0].get('rows') or [])[:MAX_ROWS])
                * (int(f_val.size * 1.15) + 5 * S)) if sections else 0)
    ty1 = ty0 + h_head + h_title + h_chips + h_pays + h_games + 12 * S

    d.rounded_rectangle([tx0, ty0, tx1, ty1], radius=20 * S, fill=INK)

    y = ty0 + 14 * S

    # ── Header ────────────────────────────────────────────────────────────
    _draw_mark(img, x, y, 13 * S)
    _tracked(d, (x + 17 * S, y + 1 * S), 'HALVED',
             _font(_DISPLAY, 11 * S, 'SemiBold'), TICKET_TEXT, 1.6 * S)
    f_rec = _font(_DISPLAY, 9 * S, 'SemiBold')
    word = label_for(receipt)
    w_rec = sum(d.textlength(c, font=f_rec) + 1.6 * S for c in word)
    _tracked(d, (right - w_rec, y + 2 * S), word, f_rec, MUTED_DEEP, 1.6 * S)
    y += 13 * S

    # ── Title and sub ─────────────────────────────────────────────────────
    y += 10 * S
    _text(d, (x, y), _ellipsise(d, str(receipt.get('title', '')), f_title,
                                right - x), f_title, TICKET_TEXT)
    y += int(f_title.size * 1.1)
    y += 4 * S
    _text(d, (x, y), _ellipsise(d, str(receipt.get('sub', '')), f_sub,
                                right - x), f_sub, MUTED)
    y += int(f_sub.size * 1.3)

    # ── Net chips: 2 x 2, four at most ────────────────────────────────────
    y += 10 * S
    for i, net in enumerate(nets):
        cx = x + (i % 2) * (cw + gap)
        cy = y + (i // 2) * (ch + gap)
        value = net.get('net', 0)
        tone = net.get('tone')
        if tone:
            # A result: the GAME said which way it goes (§"Play for fun").
            up, down = tone == 'up', tone == 'dn'
        elif isinstance(value, str):
            up, down = True, False
        else:
            up, down = value > 0, value < 0
        fill, line = ((UP_FILL, UP_LINE) if up else
                      (DOWN_FILL, DOWN_LINE) if down else
                      (EVEN_FILL, EVEN_LINE))
        d.rounded_rectangle([cx, cy, cx + cw, cy + ch], radius=12 * S,
                            fill=fill, outline=line, width=max(1, S // 2))
        amt = _amount(value, sign=True)
        amt_w = d.textlength(amt, font=f_amt)
        colour = MINT if up else (CORAL if down else TICKET_TEXT)
        d.text((cx + cw - 10 * S - amt_w, cy + ch / 2 - f_amt.size * 0.62),
               amt, font=f_amt, fill=colour)
        name_w = cw - 20 * S - amt_w - 6 * S
        caption = net.get('imageCaption') or ''
        ny = cy + (6 * S if caption else ch / 2 - f_name.size * 0.62)
        _text(d, (cx + 10 * S, ny),
              _ellipsise(d, str(net.get('name', '')), f_name, name_w),
              f_name, TICKET_TEXT)
        if caption:
            _text(d, (cx + 10 * S, ny + f_name.size * 1.15),
                  _ellipsise(d, str(caption), f_cap, name_w), f_cap, MUTED)
    if nets:
        y += ((len(nets) + 1) // 2) * (ch + gap) - gap

    # ── Pays ──────────────────────────────────────────────────────────────
    if pays:
        y += 10 * S
        _perforation(d, tx0, tx1, y, GROUND)
        y += 10 * S
        label = str(receipt.get('paysLabel') or 'Simplest way to settle').upper()
        _tracked(d, (x, y), _ellipsise(d, label, f_k, right - x), f_k,
                 MUTED_DEEP, 1.5 * S)
        y += int(f_k.size * 1.1) + 7 * S

    for row in pays:
        amt = _amount(row.get('amount', 0))
        amt_w = d.textlength(amt, font=f_pamt)
        d.text((right - amt_w, y - 1 * S), amt, font=f_pamt, fill=MINT)
        cx = x + _text(d, (x, y), str(row.get('from', '')), f_pay, TICKET_TEXT)
        _arrow(d, cx + 5 * S, y - 1 * S, 14 * S, MINT)
        _text(d, (cx + 24 * S, y), str(row.get('to', '')), f_pay, TICKET_TEXT)
        y += int(f_pay.size * 1.15) + 7 * S

    # ── One section, two rows ─────────────────────────────────────────────
    if sections:
        sec = sections[0]
        y += 3 * S
        _perforation(d, tx0, tx1, y, GROUND)
        y += 10 * S
        _tracked(d, (x, y), str(sec.get('label', '')).upper(), f_k,
                 MUTED_DEEP, 1.5 * S)
        y += int(f_k.size * 1.1) + 7 * S
        for lab, val in (sec.get('rows') or [])[:MAX_ROWS]:
            _text(d, (x, y), str(lab), f_lab, MUTED)
            vw = d.textlength(str(val), font=f_val)
            _text(d, (right - vw, y), str(val), f_val, TICKET_TEXT)
            y += int(f_val.size * 1.15) + 5 * S

    # ── Footer, pinned to the card's bottom edge ──────────────────────────
    # `.hr-ic { margin-top: auto }`: the ticket is content-sized and the
    # footer sits on the bottom edge, so the ground between them grows with a
    # shorter receipt rather than the footer floating up under the ticket.
    fy = HEIGHT - 10 * S - int(f_foot.size * 1.2)
    _text(d, (tx0 + 4 * S, fy), str(receipt.get('url', '')), f_foot, FOOT_TEXT)
    f_cta = _font(_TEXT, 12 * S, 'SemiBold')
    cta_w = d.textlength(FOOTER_CTA, font=f_cta)
    arrow = 13 * S
    ax = tx1 - 4 * S - arrow
    _text(d, (ax - 5 * S - cta_w, fy), FOOTER_CTA, f_cta, PINE)
    _arrow(d, ax, fy + 1 * S, arrow, PINE)

    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    return buf.getvalue()
