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

# ── Palette (handoff-share-link-cards) ──────────────────────────────────────
# The gradient is three stops now, and dark at the top rather than the bright
# pine it used to open with: the card is read at thumbnail size inside a
# message bubble, where a light top edge fought the wordmark sitting on it.
GRAD_STOPS  = (
    (0.00, (0x07, 0x13, 0x0F)),
    (0.46, (0x0B, 0x1F, 0x1A)),
    (1.00, (0x0D, 0x33, 0x27)),
)
PINE_BOTTOM = (0x0B, 0x1F, 0x1A)   # ground behind the gradient
MINT        = (0x3B, 0xD8, 0x9A)
BONE        = (0xF3, 0xF1, 0xEA)   # wordmark, title
SUB_TEXT    = (0x9D, 0xBC, 0xAE)   # the line under the title
DOM_TEXT    = (0x7C, 0x9A, 0x8C)   # link.halved.golf

WIDTH, HEIGHT = 1200, 630
PAD           = 52     # .lp-top / .lp-mid / .lp-foot side padding
PAD_TOP       = 44     # .lp-top padding-top
# .lp-foot: 26px above the text, a 24px line, 30px below.
FOOTER_H      = 80

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


def _gradient(size, stops=GRAD_STOPS, angle_deg: int = 160):
    """
    Linear gradient over N colour stops at CSS angles (0deg points up, angles
    run clockwise), so 160deg is mostly top-to-bottom leaning left.

    Built small and scaled up -- exact enough at this size, and far cheaper
    than a per-pixel loop over 756,000 pixels.
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
            # Find the pair of stops t falls between and mix them.
            lo = stops[0]
            hi = stops[-1]
            for i in range(len(stops) - 1):
                if stops[i][0] <= t <= stops[i + 1][0]:
                    lo, hi = stops[i], stops[i + 1]
                    break
            span = (hi[0] - lo[0]) or 1.0
            k = (t - lo[0]) / span
            px[x, y] = tuple(
                int(lo[1][i] + (hi[1][i] - lo[1][i]) * k) for i in range(3)
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
    """Largest size at or below start_size whose text fits max_w on ONE line."""
    size = start_size
    while size > min_size:
        f = _font(path, size, weight)
        if draw.textlength(text, font=f) <= max_w:
            return f
        size -= 2
    return _font(path, min_size, weight)


def _wrap(draw, text, font, max_w) -> list:
    """Greedy word wrap. A single word longer than max_w is left to overflow —
    the caller shrinks or truncates, and a mid-word break reads as corruption."""
    words, lines, cur = (text or '').split(), [], ''
    for w in words:
        trial = f'{cur} {w}'.strip()
        if cur and draw.textlength(trial, font=font) > max_w:
            lines.append(cur)
            cur = w
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return lines or ['']


def _title_block(draw, text, max_lines=2, start=60, min_size=34):
    """
    The title, wrapped to at most `max_lines`.

    The design caps the h1 at `20ch` and wraps to two lines; a third overflows
    the block. The handoff's answer is to truncate the course name server-side,
    but a card that overflows because someone typed a long course name is a
    broken card, so this degrades instead: shrink first, and only ellipsise
    when even the smallest size will not fit.

    `ch` is the width of "0" in the face, so the wrap width is measured rather
    than assumed — it changes with the font and would silently drift if hard-coded.
    """
    # The box is measured ONCE, at the design's own size, and then held fixed.
    # `20ch` in CSS is computed at the h1's font-size; re-measuring it in the
    # shrinking font would keep it 20 characters wide at every size, so
    # shrinking would fit no more text and only make the title small.
    wrap_w = draw.textlength('0' * 20, font=_font(_DISPLAY, start, 'Bold'))
    size = start
    while True:
        f = _font(_DISPLAY, size, 'Bold')
        lines = _wrap(draw, text, f, wrap_w)
        if len(lines) <= max_lines or size <= min_size:
            break
        size -= 2
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        while lines[-1] and draw.textlength(lines[-1] + '…', font=f) > wrap_w:
            lines[-1] = lines[-1][:-1].rstrip()
        lines[-1] += '…'
    return f, lines


def render_card(ctx: dict) -> bytes:
    """
    Render the card. `ctx` comes from build_context() / build_invite_context()
    and carries only already-formatted strings — this function does no golf
    logic and makes no claims of its own.

    Keys: title, meta, pill (LIVE / FINAL / INVITE), is_live (drives the dot),
          action ("Watch live" / "Get the app"), domain.

    One template, two cards. The invite card is not tied to a round — no
    course, no format, no score — so nothing here may assume a round exists.
    """
    img = Image.new('RGB', (WIDTH, HEIGHT), PINE_BOTTOM)
    img.paste(_gradient((WIDTH, HEIGHT)), (0, 0))
    d = ImageDraw.Draw(img, 'RGBA')

    # ── Brand row ───────────────────────────────────────────────────────────
    mark = 40
    _draw_mark(img, PAD, PAD_TOP, mark)
    word_f = _font(_DISPLAY, 30, 'Bold')
    _tracked(d, (PAD + mark + 16, PAD_TOP + 6), 'HALVED', word_f, BONE,
             tracking=30 * 0.24)

    # ── Pill — what KIND of link this is ────────────────────────────────────
    # LIVE keeps its dot; FINAL and INVITE do not. A finished round still says
    # FINAL rather than LIVE: a card claiming a round from last Tuesday is
    # live is worse than no card at all.
    label = (ctx.get('pill') or '').upper()
    pill_bottom = PAD_TOP + mark
    if label:
        pf    = _font(_TEXT, 20, 'Bold')
        track = 20 * 0.1
        text_w = sum(d.textlength(c, font=pf) + track for c in label) - track
        dot_w  = 24 if ctx.get('is_live') else 0      # 14px dot + 10px gap
        pill_w = text_w + dot_w + 44                  # 22px padding each side
        pill_h = 45                                   # 11 + 20 + 11 + borders
        px1, py0 = WIDTH - PAD, PAD_TOP
        px0 = px1 - pill_w
        d.rounded_rectangle([px0, py0, px1, py0 + pill_h], radius=pill_h / 2,
                            fill=MINT + (36,),        # 14% mint
                            outline=MINT + (107,),    # 42% mint
                            width=2)
        tx = px0 + 22
        if ctx.get('is_live'):
            cy = py0 + pill_h / 2
            d.ellipse([tx, cy - 7, tx + 14, cy + 7], fill=MINT)
            tx += dot_w
        _tracked(d, (tx, py0 + 12), label, pf, MINT, tracking=track)
        pill_bottom = max(pill_bottom, py0 + pill_h)

    # ── Title + sub, centred in the space between the rows ──────────────────
    tf, lines = _title_block(d, ctx.get('title') or 'A round on Halved')
    line_h = int(tf.size * 1.08)
    sub    = ctx.get('meta') or ''
    sf     = _font(_TEXT, 28, 'Regular') if sub else None
    sub_h  = int(28 * 1.4) + 14 if sf else 0          # line-height + gap

    top    = pill_bottom
    bottom = HEIGHT - FOOTER_H
    block  = line_h * len(lines) + sub_h
    ty     = top + (bottom - top - block) // 2

    for i, line in enumerate(lines):
        d.text((PAD, ty + i * line_h), line, font=tf, fill=BONE)
    if sf:
        d.text((PAD, ty + line_h * len(lines) + 14), sub, font=sf,
               fill=SUB_TEXT)

    # ── Footer ──────────────────────────────────────────────────────────────
    # Translucent white over the gradient rather than its own solid colour, so
    # the gradient carries through and the card reads as one surface.
    fy = HEIGHT - FOOTER_H
    d.rectangle([0, fy, WIDTH, HEIGHT], fill=(255, 255, 255, 13))   # 5%
    d.line([0, fy, WIDTH, fy], fill=(255, 255, 255, 20), width=1)   # 8%
    dom_f = _font(_TEXT, 24, 'Regular')
    d.text((PAD, fy + 26), ctx.get('domain') or 'link.halved.golf',
           font=dom_f, fill=DOM_TEXT)

    cta   = ctx.get('action') or 'Watch live'
    cta_f = _font(_TEXT, 24, 'SemiBold')
    cw    = d.textlength(cta, font=cta_f)
    cx    = WIDTH - PAD - cw - 30
    d.text((cx, fy + 26), cta, font=cta_f, fill=MINT)
    ax, ay = cx + cw + 12, fy + 38
    d.line([ax, ay, ax + 16, ay], fill=MINT, width=3)
    d.line([ax + 9, ay - 7, ax + 16, ay], fill=MINT, width=3)
    d.line([ax + 9, ay + 7, ax + 16, ay], fill=MINT, width=3)

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
    # card, so a finished round shows its state instead. The handoff's rule
    # that the pill names the KIND of link only ever illustrates a live round;
    # it is not a licence to call a finished one live.
    if complete:
        pill, is_live = 'FINAL', False
    elif thru:
        pill, is_live = 'LIVE', True
    else:
        pill, is_live = '', False

    meta_bits = [b for b in (
        game,
        'Final' if complete else (f'Thru {thru}' if thru else ''),
    ) if b]

    return {
        'title'   : title,
        'meta'    : ' · '.join(meta_bits),
        'pill'    : pill,
        'is_live' : is_live,
        'thru'    : thru,
        # Same rule as the pill, one line down: "Watch live" on a round that
        # finished last Tuesday makes the same false promise LIVE would, and
        # the tap that follows it lands on a scorecard, not a live board.
        'action'  : 'See the result' if complete else 'Watch live',
        'domain'  : _domain(),
    }


def _domain() -> str:
    """The host as it should READ on the card — no scheme, no trailing slash."""
    from django.conf import settings
    base = (getattr(settings, 'PUBLIC_BASE_URL', '') or '').strip()
    return base.split('//')[-1].rstrip('/') or 'link.halved.golf'


def inviter_name(user) -> str:
    """The inviter's display name, or '' when there isn't one.

    Lives here, and is used by BOTH the card and the landing page, because the
    two used to resolve the name separately and disagreed: the page showed a
    first name and the card the full one, so the preview and the page it opened
    introduced the same person two different ways.

    `.name`, not `str()`: `Player.__str__` appends " (phantom)".
    """
    try:
        name = user.player_profile.name
    except Exception:
        name = user.get_full_name() or ''
    return (name or '').strip()


def build_invite_context(user) -> dict:
    """The invite card — the same template, no round behind it.

    The only variable is who is inviting. The RECIPIENT cannot appear here:
    `invite_code` is stable per user, so one link is shared with everybody and
    the card is rendered without knowing who will open it. The design's
    recipient line would need per-recipient links, which is a different
    feature; the pitch carries that slot instead.

    The pill says INVITE and takes no dot — there is nothing live about it.
    """
    name = inviter_name(user)
    return {
        'title'   : (f'{name} invited you to Halved' if name
                     else 'You have been invited to Halved'),
        'meta'    : 'Scored on the phone, settled to the dollar',
        'pill'    : 'INVITE',
        'is_live' : False,
        'action'  : 'Get the app',
        'domain'  : _domain(),
    }
