"""
services/share_card.py
----------------------
The Open Graph share card — the 1200x630 PNG that iMessage, WhatsApp, Signal
and the social clients render when someone shares a /watch/ link.

Why it exists: the link is an ACQUISITION surface, not a sharing feature. It
routinely lands with someone who has never heard of Halved, and until now it
arrived as a gray row with a compass glyph, because the page emitted no
og:image at all and the client fell back to the <title>. A current user's
verdict on that card was "More interesting to watch. Not really happening."

Design: handoff-share-round, turn 10 (#10a). The card is a snapshot; the page
behind it is live. Clients cache link previews aggressively and re-fetch
rarely, so this is deliberately a still image with a short TTL rather than
something that tries to stay current.

Fonts are bundled under core/share_assets/fonts (SIL OFL, licences beside
them). If they are missing the card still renders in a system font rather
than failing -- a plain card beats the gray one.
"""
from __future__ import annotations

import io
import os

from PIL import Image, ImageDraw, ImageFont

# ── Palette (handoff-share-round #10a) ──────────────────────────────────────
PINE_TOP    = (0x0F, 0x6E, 0x56)   # gradient start
PINE_BOTTOM = (0x0B, 0x1F, 0x1A)   # gradient end, and the teams-strip ground
MINT        = (0x3B, 0xD8, 0x9A)
BONE        = (0xF3, 0xF1, 0xEA)
SAGE        = (0x9B, 0xC7, 0xB7)   # meta line
MUTED       = (0x8F, 0xA7, 0x9B)   # team names
DIM         = (0x5F, 0x71, 0x69)   # "vs"
RULE        = (0x14, 0x32, 0x29)   # divider above the teams strip
FOOT_BG     = (0x08, 0x17, 0x12)
FOOT_TEXT   = (0x6D, 0x82, 0x7A)

WIDTH, HEIGHT = 1200, 630
PAD           = 68
FOOTER_H      = 78
STRIP_H       = 132

_FONT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'core', 'share_assets', 'fonts',
)
_DISPLAY = os.path.join(_FONT_DIR, 'SchibstedGrotesk-var.ttf')
_TEXT    = os.path.join(_FONT_DIR, 'SplineSans-var.ttf')


def _font(path: str, size: int, weight: str | None = None):
    """
    A font at a size and named weight, falling back to Pillow's default if the
    bundled file is missing. Both families are VARIABLE fonts, so the weight
    is an axis setting rather than a separate file.
    """
    try:
        f = ImageFont.truetype(path, size)
        if weight:
            try:
                f.set_variation_by_name(weight)
            except Exception:
                pass          # static build of the font — size is still right
        return f
    except OSError:
        return ImageFont.load_default(size)


def _gradient(size, top, bottom, angle_deg: int = 160):
    """
    Linear gradient. The design specifies 160deg (CSS convention: 0deg points
    up, angles run clockwise), which is mostly top-to-bottom leaning left.
    Built as a small image and scaled -- exact enough at this size and far
    cheaper than a per-pixel loop over 756,000 pixels.
    """
    import math
    w, h = size
    rad = math.radians(angle_deg - 90)
    dx, dy = math.cos(rad), math.sin(rad)
    small_w, small_h = 64, 64
    grad = Image.new('RGB', (small_w, small_h))
    px = grad.load()
    for y in range(small_h):
        for x in range(small_w):
            # Project onto the gradient direction, normalised to 0..1.
            t = ((x / small_w) * dx + (y / small_h) * dy + 1) / 2
            t = min(1.0, max(0.0, t))
            px[x, y] = tuple(
                int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)
            )
    return grad.resize((w, h), Image.BICUBIC)


def _draw_mark(img: Image.Image, x: int, y: int, box: int):
    """
    The Halved mark: flagstick, crossbar, pin and pennant over a mint ground
    ellipse. Coordinates are the design's 64x64 viewBox, scaled to `box`.
    """
    s = box / 64.0
    def P(*vals):
        return [v * s for v in vals]
    d = ImageDraw.Draw(img)
    ex, ey, rx, ry = P(32, 52, 15, 3.5)
    d.ellipse([x + ex - rx, y + ey - ry, x + ex + rx, y + ey + ry], fill=MINT)
    for rect in ((17, 15, 5, 37), (17, 30, 22, 5), (40, 11, 2.6, 41)):
        rx0, ry0, rw, rh = P(*rect)
        d.rounded_rectangle(
            [x + rx0, y + ry0, x + rx0 + rw, y + ry0 + rh],
            radius=max(1, 1.5 * s), fill=BONE,
        )
    a, b, c, e, f, g = P(42.6, 13, 53, 16.5, 42.6, 20)
    d.polygon([(x + a, y + b), (x + c, y + e), (x + f, y + g)], fill=BONE)


def _tracked(draw, xy, text, font, fill, tracking: float = 0.0):
    """Draw text with letter-spacing; returns the width drawn."""
    x, y = xy
    start = x
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += draw.textlength(ch, font=font) + tracking
    return x - start - (tracking if text else 0)


def _fit(draw, text, path, max_w, start_size, weight, min_size=28):
    """Largest size at or below start_size whose text fits max_w."""
    size = start_size
    while size > min_size:
        f = _font(path, size, weight)
        if draw.textlength(text, font=f) <= max_w:
            return f
        size -= 2
    return _font(path, min_size, weight)


def render_card(ctx: dict) -> bytes:
    """
    Render the card. `ctx` comes from build_context() and carries only
    already-formatted strings — this function does no golf logic and makes no
    claims of its own about the round.

    Keys: title, meta, state_label (LIVE / FINAL / ...), is_live,
          left_name, left_score, right_name, right_score, leader ('left' |
          'right' | None). The teams strip is skipped entirely when
          left_name is empty, which is the branded-fallback case.
    """
    img  = Image.new('RGB', (WIDTH, HEIGHT), PINE_BOTTOM)
    hero_h = HEIGHT - FOOTER_H - (STRIP_H if ctx.get('left_name') else 0)
    img.paste(_gradient((WIDTH, hero_h), PINE_TOP, PINE_BOTTOM), (0, 0))
    d = ImageDraw.Draw(img, 'RGBA')

    # ── Brand row ───────────────────────────────────────────────────────────
    mark = 60
    _draw_mark(img, PAD, PAD - 6, mark)
    word_f = _font(_DISPLAY, 42, 'SemiBold')
    _tracked(d, (PAD + mark + 20, PAD + 4), 'HALVED', word_f, BONE,
             tracking=42 * 0.14)

    # ── State pill (LIVE, or the final result) ──────────────────────────────
    label   = (ctx.get('state_label') or '').upper()
    is_live = bool(ctx.get('is_live'))
    if label:
        pill_f = _font(_DISPLAY, 30, 'Bold')
        track  = 30 * 0.06
        text_w = sum(d.textlength(c, font=pill_f) + track for c in label) - track
        dot_w  = 34 if is_live else 0
        pill_w = text_w + dot_w + 56
        pill_h = 56
        px1    = WIDTH - PAD
        px0    = px1 - pill_w
        py0    = PAD - 2
        d.rounded_rectangle([px0, py0, px1, py0 + pill_h], radius=pill_h / 2,
                            fill=MINT + (41,),        # 16% mint fill
                            outline=MINT + (128,),    # 50% mint border
                            width=2)
        tx = px0 + 28
        if is_live:
            cy = py0 + pill_h / 2
            d.ellipse([tx - 4, cy - 16, tx + 28, cy + 16], fill=MINT + (64,))
            d.ellipse([tx + 3, cy - 9, tx + 21, cy + 9], fill=MINT)
            tx += dot_w
        _tracked(d, (tx, py0 + 13), label, pill_f, MINT, tracking=track)

    # ── Title + meta ────────────────────────────────────────────────────────
    # Anchored to the BOTTOM of the gradient, not hung off the brand row.
    # The design's hero is sized to its content; ours is a fixed 630-tall
    # canvas, so hanging the title from the top left a slab of empty pine
    # under it and made the card look like it was still loading.
    title = ctx.get('title') or 'A round on Halved'
    tf   = _fit(d, title, _DISPLAY, WIDTH - PAD * 2, 62, 'Bold')
    meta = ctx.get('meta') or ''
    mf   = _fit(d, meta, _TEXT, WIDTH - PAD * 2, 38, 'Regular', min_size=24) \
           if meta else None
    meta_h = (mf.size + 20) if mf else 0
    block_h = tf.size + meta_h
    if ctx.get('left_name'):
        # With a teams strip the hero is short, so the block sits just above
        # the rule -- the design's own arrangement.
        ty = hero_h - 52 - meta_h - tf.size
    else:
        # Without one the hero owns most of the card. Bottom-anchoring left a
        # third of the card as empty pine; centre it in the space below the
        # brand row instead.
        top_of_space = PAD + mark + 40
        ty = top_of_space + (hero_h - top_of_space - block_h) // 2
    d.text((PAD, ty), title, font=tf, fill=(255, 255, 255))
    if mf:
        d.text((PAD, ty + tf.size + 20), meta, font=mf, fill=SAGE)

    # ── Teams strip ─────────────────────────────────────────────────────────
    if ctx.get('left_name'):
        top = hero_h
        d.rectangle([0, top, WIDTH, top + STRIP_H], fill=PINE_BOTTOM)
        d.line([0, top, WIDTH, top], fill=RULE, width=2)
        name_f  = _font(_TEXT, 32, 'Regular')
        score_f = _font(_DISPLAY, 54, 'Bold')
        leader  = ctx.get('leader')

        d.text((PAD, top + 26), ctx['left_name'], font=name_f, fill=MUTED)
        d.text((PAD, top + 66), ctx.get('left_score') or '',
               font=score_f, fill=MINT if leader == 'left' else BONE)

        vs_f = _font(_TEXT, 30, 'SemiBold')
        vs_w = d.textlength('vs', font=vs_f)
        d.text(((WIDTH - vs_w) / 2, top + 52), 'vs', font=vs_f, fill=DIM)

        rn = ctx.get('right_name') or ''
        rs = ctx.get('right_score') or ''
        d.text((WIDTH - PAD - d.textlength(rn, font=name_f), top + 26),
               rn, font=name_f, fill=MUTED)
        d.text((WIDTH - PAD - d.textlength(rs, font=score_f), top + 66),
               rs, font=score_f, fill=MINT if leader == 'right' else BONE)

    # ── Footer ──────────────────────────────────────────────────────────────
    fy = HEIGHT - FOOTER_H
    d.rectangle([0, fy, WIDTH, HEIGHT], fill=FOOT_BG)
    ff = _font(_TEXT, 30, 'Regular')
    d.text((PAD, fy + 22), 'link.halved.golf', font=ff, fill=FOOT_TEXT)
    cta   = 'Watch live'
    cta_f = _font(_TEXT, 30, 'SemiBold')
    cw    = d.textlength(cta, font=cta_f)
    cx    = WIDTH - PAD - cw - 34
    d.text((cx, fy + 22), cta, font=cta_f, fill=MINT)
    ax, ay = cx + cw + 12, fy + 38
    d.line([ax, ay, ax + 18, ay], fill=MINT, width=3)
    d.line([ax + 10, ay - 8, ax + 18, ay], fill=MINT, width=3)
    d.line([ax + 10, ay + 8, ax + 18, ay], fill=MINT, width=3)

    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Context — turning a Round into the strings the card draws
# ---------------------------------------------------------------------------

def _first_name(full: str) -> str:
    return (full or '').strip().split(' ')[0]


def holes_played(round_obj) -> int:
    """
    The round's 'thru' — the highest hole number anyone in it has a gross
    score for. Deliberately the MAX rather than a per-group figure: the card
    answers "is something happening right now", and the furthest group along
    is the truest answer to that.
    """
    from scoring.models import HoleScore
    return HoleScore.objects.filter(
        foursome__round=round_obj, gross_score__isnull=False,
    ).order_by('-hole_number').values_list('hole_number', flat=True).first() or 0


def build_context(round_obj) -> dict:
    """
    Build the card's strings for a round. Never raises on thin data — a round
    with no scores yet still gets a branded card with a real title, which is
    the whole point: the fallback is never "no image".

    The teams strip is left empty for now (see render_card): stating who is
    ahead needs the per-game summary, and a card that guesses is worse than a
    card that doesn't say. Title, stakes and thru are already the difference
    between a gray compass row and something that looks like a live match.
    """
    from services.game_names import public_game_name

    course = ''
    if getattr(round_obj, 'course_id', None):
        course = round_obj.course.name or ''

    slug = round_obj.primary_game or ''
    if not slug:
        games = round_obj.active_games or []
        slug = games[0] if games else ''
    game = public_game_name(slug)

    host = ''
    if getattr(round_obj, 'created_by_id', None):
        # .name, not str(): Player.__str__ appends " (phantom)", which would
        # have put "Paul (phantom)'s Nassau" on a card.
        host = _first_name(round_obj.created_by.name)

    # "Paul's Nassau at Corica Park — South", degrading a clause at a time
    # rather than printing an empty possessive or a dangling "at".
    if host and game and course:
        title = f'{host}’s {game} at {course}'
    elif host and course:
        title = f'{host}’s round at {course}'
    elif game and course:
        title = f'{game} at {course}'
    elif course:
        title = f'A round at {course}'
    else:
        title = 'A round on Halved'

    complete = getattr(round_obj, 'status', '') == 'complete'
    thru     = holes_played(round_obj)

    # A card that says LIVE on a round from last Tuesday is worse than no
    # card, so a finished round shows its state instead of the pill.
    if complete:
        state_label, is_live = 'FINAL', False
    elif thru:
        state_label, is_live = 'LIVE', True
    else:
        state_label, is_live = '', False

    meta_bits = [b for b in (
        game,
        'Final' if complete else (f'Thru {thru}' if thru else ''),
    ) if b]

    return {
        'title'       : title,
        'meta'        : ' · '.join(meta_bits),
        'state_label' : state_label,
        'is_live'     : is_live,
        'thru'        : thru,
        'left_name'   : '',      # teams strip: see docstring
        'left_score'  : '',
        'right_name'  : '',
        'right_score' : '',
        'leader'      : None,
    }
