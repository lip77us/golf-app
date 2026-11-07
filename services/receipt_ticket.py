"""The D1 receipt ticket — ``~/Downloads/design_handoff_settle_up`` §1 and §3.

**One data object, three surfaces.**  That is the handoff's actual promise, and
it is worth stating precisely because "one renderer" is not literally
achievable here: the web page is HTML, the link-preview card is a PNG drawn
with Pillow, and Round over is a Flutter screen.  Three languages.  What they
share is the :class:`Receipt` payload (§3) and the decisions below, so the
place to change the ticket is here and in nothing else.

This module owns the HTML half — the ticket markup and the web page at
``/r/<code>``.  ``services.receipt_card`` draws the same payload as the
1080x1350 image.

**The phone frame is not part of the page.**  ``patterns/receipt-ticket.js``
wraps every surface in ``.hr-ph`` with a status bar and a fake address bar
reading "halved.golf", because it is a prototype showing a phone.  Rendering
those on the real page would draw a picture of a browser inside a browser.
The page is what is inside ``.hr-wb``: the ticket, the scorecard link, the
dark CTA and the stamp.

**Amounts that are already strings pass through verbatim.**  §3 types
``Transfer.amount`` as ``Cents | string`` for rows like "4 x $71.87" and the
image's collapsed "14 more", and those carry their own formatting — including
the thousands separator in the mock's ``$1,114``, which ``money()`` does not
add.  Whether separators belong on ordinary amounts too is a live question;
it is deliberately NOT answered by quietly changing a formatter with thirty
callers.
"""
from __future__ import annotations

from html import escape

from services.settlement_receipt import money

# --------------------------------------------------------------------------
# Tokens, from the handoff's "Design tokens" and patterns/receipt-ticket.js.
# --------------------------------------------------------------------------
INK          = '#0B1F1A'     # ticket
TICKET_TEXT  = '#F3F1EA'
MUTED        = '#9BAAA0'
MUTED_DEEP   = '#7C8C82'
MINT         = '#3BD89A'
CORAL        = '#F0916E'
PINE         = '#0F6E56'
GROUND       = '#EEF3EE'

#: The notch colour has to MATCH the surface behind the ticket, because a
#: perforation notch is a hole punched in the ticket showing the page through
#: it.  The prototype threads it as ``--hrbg``; the page sets it once.
NOTCH_VAR = '--hrbg'

TICKET_CSS = f"""
.hr-tk{{position:relative;background:{INK};border-radius:24px;
  padding:18px 20px 16px;color:{TICKET_TEXT};
  box-shadow:0 24px 50px -20px rgba(11,31,26,.6);overflow:hidden;
  font-variant-numeric:tabular-nums}}
.hr-hd{{display:flex;align-items:center;justify-content:space-between}}
.hr-hd span{{display:flex;align-items:center;gap:8px;
  font:600 14px/1 var(--f-display);letter-spacing:.16em}}
.hr-hd em{{font-style:normal;font-size:11px;font-weight:600;
  letter-spacing:.18em;color:{MUTED_DEEP}}}
.hr-tk h5{{margin:12px 0 0;font:700 23px/1.1 var(--f-display);
  letter-spacing:-.01em}}
.hr-sb{{font-size:12.5px;color:{MUTED};margin-top:4px}}
.hr-nc{{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:12px}}
.hr-nc div{{display:grid;grid-template-columns:minmax(0,1fr) auto;
  align-items:center;gap:6px;background:rgba(59,216,154,.12);
  border:1px solid rgba(59,216,154,.35);border-radius:12px;padding:8px 12px}}
.hr-nc div.dn{{background:rgba(240,145,110,.1);border-color:rgba(240,145,110,.32)}}
.hr-nc div.ev{{background:rgba(243,241,234,.06);border-color:rgba(243,241,234,.18)}}
.hr-nc span{{font-size:14px;font-weight:500;min-width:0}}
.hr-nc small{{display:block;overflow:hidden;text-overflow:ellipsis;
  white-space:nowrap;font-size:10.5px;color:{MUTED};margin-top:1px}}
.hr-nc b{{font-size:15px;font-weight:700;color:{MINT}}}
.hr-nc .dn b{{color:{CORAL}}}
.hr-nc .ev b{{color:{TICKET_TEXT}}}
.hr-pf{{position:relative;margin:14px -20px;height:0;
  border-top:2px dashed rgba(243,241,234,.22)}}
.hr-pf:before,.hr-pf:after{{content:"";position:absolute;top:-11px;width:22px;
  height:22px;border-radius:999px;background:var({NOTCH_VAR},{GROUND})}}
.hr-pf:before{{left:-11px}}
.hr-pf:after{{right:-11px}}
.hr-k{{font-size:10.5px;font-weight:600;letter-spacing:.16em;
  color:{MUTED_DEEP};margin-bottom:9px;text-transform:uppercase}}
.hr-tf{{display:flex;flex-direction:column;gap:9px}}
.hr-tf div{{display:flex;align-items:center;justify-content:space-between;
  gap:10px;font-size:15.5px;font-weight:600}}
.hr-tf div span{{display:inline-flex;align-items:center;gap:9px}}
.hr-tf div span i{{font-style:normal}}
.hr-tf div b{{font-size:17px;color:{MINT};flex:none}}
.hr-gr{{display:grid;grid-template-columns:auto minmax(0,1fr);gap:7px 14px;
  font-size:13px}}
.hr-gr span{{color:{MUTED}}}
.hr-gr b{{font-weight:600;text-align:right}}
"""

LOGO_SVG = (
    '<svg width="18" height="18" viewBox="0 0 1024 1024" aria-hidden="true" '
    f'style="color:{TICKET_TEXT}">'
    f'<ellipse cx="702" cy="838" rx="120" ry="42" fill="{MINT}"></ellipse>'
    f'<ellipse cx="702" cy="828" rx="112" ry="36" fill="{INK}"></ellipse>'
    '<rect x="288" y="262" width="118" height="600" rx="22" fill="currentColor"></rect>'
    '<rect x="676" y="210" width="52" height="640" rx="24" fill="currentColor"></rect>'
    '<rect x="406" y="486" width="270" height="96" fill="currentColor"></rect>'
    '<path d="M728 224 L956 314 L728 404 Z" fill="currentColor"></path></svg>'
)

ARROW_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true" '
    f'stroke="{MINT}" stroke-width="2" stroke-linecap="round" '
    'stroke-linejoin="round"><path d="M4 12h15M13 6l6 6-6 6"></path></svg>'
)

DEFAULT_PAYS_LABEL = 'Simplest way to settle'

#: §1's caps for the preview: four chips, three transfer lines, and
#: the first section's first two rows.
MAX_IMAGE_CHIPS, MAX_IMAGE_PAYS, MAX_IMAGE_ROWS = 4, 3, 2


def _amount(value, *, sign: bool = False) -> str:
    """Cents through the one formatter; a string through untouched (§3)."""
    if isinstance(value, str):
        return value
    return money((value or 0) / 100, sign=sign)


def _chip(net: dict, *, image: bool) -> str:
    value = net.get('net', 0)
    cls = '' if (isinstance(value, str) or value > 0) \
        else (' class="dn"' if value < 0 else ' class="ev"')
    caption = net.get('imageCaption' if image else 'caption') or (
        '' if image else net.get('caption', ''))
    small = f'<small>{escape(str(caption))}</small>' if caption else ''
    return (f'<div{cls}><span>{escape(str(net.get("name", "")))}{small}</span>'
            f'<b>{_amount(value, sign=True)}</b></div>')


def _transfer(row: dict) -> str:
    return (f'<div><span><i>{escape(str(row.get("from", "")))}</i>{ARROW_SVG}'
            f'<i>{escape(str(row.get("to", "")))}</i></span>'
            f'<b>{_amount(row.get("amount", 0))}</b></div>')


def _section(sec: dict) -> str:
    rows = ''.join(
        f'<span>{escape(str(label))}</span><b>{escape(str(value))}</b>'
        for label, value in sec.get('rows', []))
    return (f'<div class="hr-pf"></div>'
            f'<div class="hr-k">{escape(str(sec.get("label", "")))}</div>'
            f'<div class="hr-gr">{rows}</div>')


def ticket_html(receipt: dict, mode: str = 'web') -> str:
    """The ticket itself — §1's anatomy, in order.

    ``mode`` picks which of the payload's parallel lists to draw.  The
    collapsing is the IMAGE's alone: a link preview has one screen's worth of
    room and no scroll, so §1 caps it at four chips, three transfer lines and
    the first section's first two rows.  The web receipt shows everything,
    which is the reason the link exists.
    """
    image = mode == 'image'
    nets = (receipt.get('imageNets') if image else None) or receipt.get('nets', [])
    pays = (receipt.get('imagePays') if image else None) or receipt.get('pays', [])

    if image:
        # The cap is enforced here, not merely preferred.  ``imageNets`` /
        # ``imagePays`` are optional (§3), and a payload that omits them on a
        # sixteen-golfer field would otherwise run off a surface that has one
        # screen and no scroll.  Supplying them is what makes the last row
        # MEANINGFUL ("13 more  −$570"); the cap is what stops it overflowing
        # either way, and the web receipt is where nothing is dropped.
        nets = nets[:MAX_IMAGE_CHIPS]
        pays = pays[:MAX_IMAGE_PAYS]
        sections = (receipt.get('games') or [])[:1]
        sections = [{'label': s.get('label', ''),
                     'rows': s.get('rows', [])[:MAX_IMAGE_ROWS]}
                    for s in sections]
    else:
        # §1: the web receipt uses webGames WHEN PRESENT and falls back to the
        # short form, so a game that never wrote a long form still renders.
        sections = receipt.get('webGames') or receipt.get('games') or []

    return (
        '<div class="hr-tk">'
        f'<div class="hr-hd"><span>{LOGO_SVG}HALVED</span><em>RECEIPT</em></div>'
        f'<h5>{escape(str(receipt.get("title", "")))}</h5>'
        f'<div class="hr-sb">{escape(str(receipt.get("sub", "")))}</div>'
        f'<div class="hr-nc">{"".join(_chip(n, image=image) for n in nets)}</div>'
        '<div class="hr-pf"></div>'
        f'<div class="hr-k">'
        f'{escape(str(receipt.get("paysLabel") or DEFAULT_PAYS_LABEL))}</div>'
        f'<div class="hr-tf">{"".join(_transfer(p) for p in pays)}</div>'
        f'{"".join(_section(s) for s in sections)}'
        '</div>'
    )


# --------------------------------------------------------------------------
# The web page — §1's "web" surface
# --------------------------------------------------------------------------

PAGE_CSS = f"""
:root{{{NOTCH_VAR}:{GROUND};
  --f-display:"Schibsted Grotesk",system-ui,sans-serif;
  --f-text:"Spline Sans",system-ui,sans-serif}}
*{{box-sizing:border-box}}
body{{margin:0;background:{GROUND};color:{INK};font-family:var(--f-text);
  -webkit-font-smoothing:antialiased}}
.hr-wb{{max-width:430px;margin:0 auto;padding:14px 16px 30px;
  display:flex;flex-direction:column;gap:12px}}
.hr-lnk{{font-size:13px;font-weight:600;text-align:center;color:{PINE};
  text-decoration:none;display:block;padding:4px}}
.hr-cta{{background:{INK};color:#fff;border-radius:18px;padding:18px 16px 16px;
  display:flex;flex-direction:column;gap:10px}}
.hr-cta h4{{margin:0;font:700 22px/1.15 var(--f-display)}}
.hr-cta p{{margin:0;font-size:13px;line-height:1.45;color:#B9CCC3}}
.hr-btn{{display:block;width:100%;height:48px;border-radius:999px;
  text-align:center;font:700 15px/48px var(--f-text);background:{MINT};
  color:{INK};text-decoration:none}}
.hr-stamp{{font-size:11.5px;color:#5C6B62;text-align:center;line-height:1.5;
  margin:0}}
"""

CTA_HEAD = 'Run the next game yourself'
CTA_BODY = ('Halved keeps the score, plays the games as you go, and settles '
            'it like this at the end.')


def stamp(receipt: dict) -> str:
    """"Final · settled 2:58 PM by Paul Kelly" (§1).

    **"Final" is a claim, so it is only made when the payload backs it.**  A
    receipt with no ``settledAt`` has not been settled, and stamping it anyway
    would be the card telling a golfer the money is done on the strength of a
    missing field.
    """
    when = receipt.get('settledAt')
    who = (receipt.get('scorer') or {}).get('name', '')
    if not when:
        return ''
    from datetime import datetime
    try:
        dt = datetime.fromisoformat(str(when).replace('Z', '+00:00'))
    except ValueError:
        return ''
    # %-I is platform-specific; strip the pad by hand so this holds anywhere.
    clock = dt.strftime('%I:%M %p').lstrip('0')
    return f'Final · settled {clock} by {who}' if who \
        else f'Final · settled {clock}'


def receipt_page_html(receipt: dict, *, page_url: str = '',
                      card_url: str = '', download_url: str = '#',
                      scorecard_url: str = '') -> str:
    """The whole page at ``/r/<code>``.

    **The scorecard link is drawn only when there is one to draw.**  §1 lists
    it unconditionally, but a receipt for a round whose card is not public
    would otherwise offer a link to nothing — worse than its absence, because
    it reads as broken rather than as not offered.

    **No Venmo or Cash App buttons**, per §1 and the handoff's own open note:
    payment is not tracked and the handoff defers the handoff.
    """
    title = str(receipt.get('title') or 'Receipt')
    sub = str(receipt.get('sub') or '')
    og_desc = sub or 'Settled with Halved.'
    og_image = (f'<meta property="og:image" content="{escape(card_url)}">\n'
                f'  <meta property="og:image:width" content="1080">\n'
                f'  <meta property="og:image:height" content="1350">\n'
                f'  <meta name="twitter:card" content="summary_large_image">'
                if card_url else '<meta name="twitter:card" content="summary">')
    link = (f'<a class="hr-lnk" href="{escape(scorecard_url)}">'
            f'Hole-by-hole scorecard ›</a>' if scorecard_url else '')
    mark = stamp(receipt)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{escape(title)} · Halved</title>
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Halved">
  <meta property="og:title" content="{escape(title)}">
  <meta property="og:description" content="{escape(og_desc)}">
  <meta property="og:url" content="{escape(page_url)}">
  {og_image}
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Schibsted+Grotesk:wght@400;500;600;700&family=Spline+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>{TICKET_CSS}{PAGE_CSS}</style>
</head>
<body>
  <main class="hr-wb">
    {ticket_html(receipt, 'web')}
    {link}
    <section class="hr-cta">
      <h4>{CTA_HEAD}</h4>
      <p>{CTA_BODY}</p>
      <a class="hr-btn" href="{escape(download_url)}">Get Halved</a>
    </section>
    <p class="hr-stamp">{escape(mark)}</p>
  </main>
</body>
</html>"""
