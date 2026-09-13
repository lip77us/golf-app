#!/usr/bin/env python3
"""Convert the Claude Design .dc.html game-guide prototypes into static pages.

The design files render their markup at runtime behind a <x-dc> wrapper; the
published guides are SEO pages, so the content has to be in the initial HTML
response.  This lifts the markup out, resolves the design tooling away, and
rebuilds the FAQPage schema that the prototype assembled in the browser.

    ./build-guides.py ~/Downloads/<handoff>/design-reference

Out:  games/index.html          -> /games
      games/<slug>/index.html   -> /games/<slug>
"""
import html
import json
import os
import re
import sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'games')

# The slug comes from each file's own CANONICAL, not from its filename.
# Filenames do not agree with the URLs design specifies — Points531Guide is
# /games/points-5-3-1, VegasGuide is /games/las-vegas, SequoyaGuide is
# /games/sequoya-threes — and the canonical is the thing that has to be right,
# so it is the thing to read. A file with no canonical (MobileNav) is not a
# page and excludes itself.
def pages(src_dir):
    out = []
    for f in sorted(os.listdir(src_dir)):
        if not f.endswith('.dc.html'):
            continue
        raw = open(os.path.join(src_dir, f), encoding='utf-8').read()
        m = re.search(r'<link rel="canonical" href="https://halved\.golf/games/?([^"]*)"', raw)
        if not m:
            continue
        slug = m.group(1).strip('/')
        (out.insert(0, (f, slug)) if slug == '' else out.append((f, slug)))
    return out

# Guides that were cross-linked but never written.  Design: drop them rather
# than ship 404s on day one.
UNWRITTEN = ('sixes',)   # banker and rabbit shipped 2026-09-11


def slice_element(s, start):
    """Return (start, end) of the element opening at index `start`, by counting
    <div ...> / </div> pairs.  Only used on div subtrees."""
    depth = 0
    i = start
    while i < len(s):
        if s.startswith('<div', i) and (i + 4 < len(s) and s[i + 4] in ' >'):
            depth += 1
            i = s.index('>', i) + 1
        elif s.startswith('</div>', i):
            depth -= 1
            i += 6
            if depth == 0:
                return start, i
        else:
            i += 1
    raise ValueError('unbalanced div')


def drop_placeholder_screenshots(body):
    """Nassau, Wolf and Survivor draw dashed placeholder boxes where app
    screenshots go.  Only Skins has real captures, so drop the whole row."""
    needle = '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:32px">'
    i = body.find(needle)
    while i != -1:
        a, b = slice_element(body, i)
        chunk = body[a:b]
        if 'dashed' in chunk and 'role="img"' in chunk:
            return body[:a] + body[b:]
        i = body.find(needle, b)
    return body


# The formats Halved scores but has not written up yet. The design file lists
# four that are wrong for this project — Bingo bango bongo is not a game Halved
# scores at all — so the chips are replaced here rather than in the generated
# file, or the next rebuild would put them back.
COMING_SOON = ['Triple Nassau', 'Mini Single Bracket', 'Spots',
               'Honors', 'Irish Rumble', 'Pink Ball']


def retitle_coming_soon(body):
    """Swap the 'Guides on the way' chips for the real backlog."""
    i = body.find('Guides on the way')
    if i == -1:
        return body
    chip = re.compile(
        r'(<span style="border:1px solid #DCE5DD;border-radius:999px;'
        r'padding:6px 13px;font-size:13.5px;color:#5C6B62">)([^<]+)(</span>)')
    found = list(chip.finditer(body, i))
    if not found:
        return body
    tmpl = found[0]
    block = '\n'.join(tmpl.group(1) + name + tmpl.group(3) for name in COMING_SOON)
    return body[:found[0].start()] + block + body[found[-1].end():]


def drop_missing_screenshots(body, img_dir):
    """Remove a screenshot row whose images are not on disk.

    The design files reference captures by filename; the packet does not always
    ship the files. Left alone that renders as BROKEN IMAGES on a live page —
    worse than the dashed placeholder boxes it replaced, and worse than no row.

    Self-healing on purpose: drop the images into `games/img/` and the row comes
    back on the next build with no code change. Whole row, not the individual
    figures — a row with one of three present reads as broken too.
    """
    needle = '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:32px">'
    i = body.find(needle)
    while i != -1:
        a, b = slice_element(body, i)
        chunk = body[a:b]
        srcs = re.findall(r'src="/games/img/([^"]+)"', chunk)
        if srcs and any(not os.path.exists(os.path.join(img_dir, f)) for f in srcs):
            missing = [f for f in srcs if not os.path.exists(os.path.join(img_dir, f))]
            print('      dropped screenshot row — missing %s' % ', '.join(missing))
            return body[:a] + body[b:]
        i = body.find(needle, b)
    return body


def drop_unwritten_cards(body):
    """Remove the 'if you like X' cards pointing at guides that don't exist."""
    for slug in UNWRITTEN:
        pat = re.compile(r'<a href="/games/%s/?"[^>]*>.*?</a>\n?' % slug, re.S)
        body = pat.sub('', body)
    return body


def unlink_unwritten_inline(body):
    """Inline prose links to unwritten guides become plain text."""
    for slug in UNWRITTEN:
        pat = re.compile(r'<a href="/games/%s/?"[^>]*>(.*?)</a>' % slug, re.S)
        body = pat.sub(r'\1', body)
    return body


def faq_jsonld(body):
    """Rebuild, at build time, the FAQPage schema the design file assembled in
    the browser.  Nassau and Skins tag their cards `data-faq`; Wolf and Survivor
    never got the attribute, so key off the FAQ section instead — the card
    markup is identical in all four."""
    m = re.search(r'<h2[^>]*>Questions people ask</h2>(.*?)</section>', body, re.S)
    if not m:
        return '', 0
    strip = lambda t: html.unescape(re.sub(r'<[^>]+>', '', t)).strip()
    pairs = [(strip(q), strip(a)) for q, a in re.findall(
        r'<h3[^>]*>(.*?)</h3>\s*<div[^>]*>((?:(?!</div>).)*)</div>', m.group(1), re.S)]
    if not pairs:
        return '', 0
    doc = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": [
            {"@type": "Question", "name": n,
             "acceptedAnswer": {"@type": "Answer", "text": t}}
            for n, t in pairs
        ],
    }
    return ('<script type="application/ld+json">\n'
            + json.dumps(doc, indent=2, ensure_ascii=False)
            + '\n</script>'), len(pairs)


STICKY_JS = """<script>
  // The download bar rides in once you're past the intro and gets out of the
  // way at the foot of the page, where the closing CTA already does the job.
  (function () {
    var bar = document.getElementById('sticky-cta');
    if (!bar) return;
    function onScroll() {
      var doc = document.documentElement;
      var y = window.scrollY || doc.scrollTop || 0;
      var atEnd = y + window.innerHeight > doc.scrollHeight - 160;
      bar.style.transform = (y > 520 && !atEnd) ? 'translateY(0)' : 'translateY(110%)';
    }
    window.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  })();
</script>"""


def convert(src_dir, name, slug):
    src = open(os.path.join(src_dir, name), encoding='utf-8').read()

    helmet = re.search(r'<helmet>(.*?)</helmet>', src, re.S).group(1)
    body = src.split('</helmet>', 1)[1].split('</x-dc>', 1)[0]

    # --- head -------------------------------------------------------------
    helmet = re.sub(r'<script src="\./ds-base\.js"></script>\s*', '', helmet)
    canonical = re.search(r'<link rel="canonical" href="([^"]+)"', helmet).group(1)
    # **Trailing slash.** Cloudflare Pages serves these from games/<slug>/index.html
    # at `/games/<slug>/` and 307s the bare form to it. The design files declare
    # the bare form, so every canonical — and the og:url derived from it — pointed
    # one redirect away from the page carrying it. Declare what is actually served.
    if not canonical.endswith('/'):
        canonical += '/'
    head = helmet.strip()
    head = re.sub(r'<link rel="canonical" href="[^"]+"',
                  '<link rel="canonical" href="%s"' % canonical, head, count=1)
    # og:url is missing from the design helmets; the canonical is the value.
    head = head.replace(
        '<meta property="og:type"',
        '<meta property="og:url" content="%s">\n<meta property="og:type"' % canonical)

    # The site-wide share card. The design files carry no og:image, so a shared
    # guide link previewed as a bare grey row — the same gap the homepage had.
    # There are no per-guide cards, so the site card stands in for all of them.
    # Width and height are declared because some clients decide whether to render
    # the card large BEFORE fetching the image; the file is a 2x export and the
    # numbers below are the 1:1 ones.
    #
    # The design files now declare these themselves, with their own alt text.
    # Only top up what a helmet is missing — appending unconditionally gave every
    # page TWO og:image blocks with two different alt strings.
    if 'property="og:image"' not in head:
        head += ('\n<meta property="og:image" content="https://halved.golf/og.png">'
                 '\n<meta property="og:image:width" content="1200">'
                 '\n<meta property="og:image:height" content="630">'
                 '\n<meta property="og:image:alt" content="Halved — every game on '
                 'your round, scored live and settled to the dollar.">')
    if 'name="twitter:card"' not in head:
        head += '\n<meta name="twitter:card" content="summary_large_image">'
    if 'name="twitter:image"' not in head:
        head += '\n<meta name="twitter:image" content="https://halved.golf/og.png">'

    # 820 matches the homepage's single header breakpoint, and is comfortably
    # above the width at which the two-column row wraps.
    head += ('\n<style>'
             '@media(min-width:821px){.guide-toc{position:sticky;top:28px;padding-top:56px}}'
             '@media(max-width:820px){.guide-toc{flex-basis:100%;margin-bottom:8px}}'
             '</style>')

    # --- body -------------------------------------------------------------
    # Design-tool furniture.
    body = re.sub(r'<a href="\.\./\.\./index-contents\.html".*?</a>\n?', '', body, flags=re.S)
    body = re.sub(r'<sc-if [^>]*>\n?', '', body)
    body = body.replace('</sc-if>\n', '').replace('</sc-if>', '')
    body = body.replace('ref="{{ barRef }}"', 'id="sticky-cta"')

    # **The in-page nav must stop being sticky once it stops being a sidebar.**
    # It lives in a `flex-wrap:wrap` row as a 168px column beside the article.
    # On a phone that row wraps, so the nav becomes a full-width block ABOVE the
    # body — and `position:sticky` then pins it to the top while the article
    # scrolls underneath, printing the contents list straight through the prose.
    # Reported from a real phone; it affects every guide identically.
    # The stickiness is LIFTED OUT of the inline style, not overridden in CSS —
    # an inline `style` attribute beats any stylesheet rule short of !important,
    # so a media query here is simply ignored. The rule below re-applies it at
    # desktop widths, where the nav really is a sidebar.
    body = body.replace(
        '<nav style="flex:0 1 168px;min-width:150px;position:sticky;top:28px;padding-top:56px">',
        '<nav class="guide-toc" style="flex:0 1 168px;min-width:150px">')

    # Links: absolute design URLs -> root-relative, so the pages work on a
    # Cloudflare Pages preview deploy as well as on halved.golf. The TRAILING
    # SLASH is the form Pages actually serves; without it every internal click
    # takes a 307 on the way.
    body = body.replace('href="https://halved.golf/games"', 'href="/games/"')
    body = re.sub(r'href="https://halved\.golf/games/([a-z0-9-]+)/?"',
                  r'href="/games/\1/"', body)
    body = body.replace('href="https://halved.golf"', 'href="/"')
    # Nassau's related cards point at sibling design files.
    for f, sl in (('WolfGuide', 'wolf'), ('SkinsGuide', 'skins'),
                  ('NassauGuide', 'nassau'), ('SurvivorGuide', 'survivor'),
                  ('BankerGuide', 'banker'), ('RabbitGuide', 'rabbit'),
                  ('VegasGuide', 'las-vegas'), ('TripleCupGuide', 'triple-cup'),
                  ('SequoyaGuide', 'sequoya-threes'),
                  ('Points531Guide', 'points-5-3-1')):
        body = body.replace('href="%s.dc.html"' % f, 'href="/games/%s/"' % sl)
    body = body.replace('src="./img/', 'src="/games/img/')

    if slug:
        body = drop_placeholder_screenshots(body)
    body = drop_missing_screenshots(body, os.path.join(OUT, 'img'))
    if not slug:
        body = retitle_coming_soon(body)
    body = drop_unwritten_cards(body)
    body = unlink_unwritten_inline(body)

    schema, n_faq = faq_jsonld(body)
    if schema:
        head += '\n' + schema

    page = ('<!DOCTYPE html>\n<html lang="en">\n<head>\n'
            '<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            + head + '\n</head>\n<body>\n'
            + body.strip() + '\n'
            + (STICKY_JS + '\n' if 'id="sticky-cta"' in body else '')
            + '</body>\n</html>\n')

    dest = os.path.join(OUT, slug, 'index.html') if slug else os.path.join(OUT, 'index.html')
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, 'w', encoding='utf-8').write(page)
    print('%-22s -> %-40s %6d bytes  faq:%d' %
          (name, dest.replace('/Users/paullipkin/code/golf-app/', ''), len(page), n_faq))
    return page


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: build-guides.py <design-reference dir>\n'
                 '  e.g. build-guides.py ~/Downloads/handoff-games-index/design-reference')
    src_dir = os.path.expanduser(sys.argv[1])
    found = pages(src_dir)
    if not found:
        sys.exit('no .dc.html files in %s' % src_dir)
    for name, slug in found:
        convert(src_dir, name, slug)
    print('\nCopy any new img/ assets into website/games/img/, add the new URLs to\n'
          'sitemap.xml, and add the format to the homepage marquee.')
