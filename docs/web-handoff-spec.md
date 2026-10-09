# What a web page handoff needs to contain

Companion to `docs/seo-copy-for-design.md`, which carries search copy the
other way. This is what Design sends US so a page can be published without
being rewritten first.

Every rule below is here because it cost real work on 9 Oct 2026, when eight
pages came over in four packets. None of them is a preference.

---

## The shape

A folder in `~/Downloads`, named `handoff-<thing>`, containing:

- **finished static HTML, one file per page.** Not `.dc.html` design-tool
  source — that goes through `build-guides.py`, which a finished-HTML packet
  bypasses entirely (see below).
- **a README** naming, for each file, where it publishes — and, when the
  packet UPDATES existing pages rather than adding new ones, **which pages
  changed**. Without that list the only way to find out is to diff all 28
  pages against the repo.

---

## The seven rules

### 1 · No design-tool residue
No `{{ … }}` bindings, no `<sc-*>` tags, no script blocks whose `src` is a
bare UUID.

*Four pages were live with visible `{{ x.net }}` in the body text when this
batch started. That is what prompted the whole re-delivery.*

### 2 · Links relative, with a trailing slash
`/games/skins/` — not `https://halved.golf/games/skins`.

Absolute is merely verbose; **unslashed is wrong**, because Cloudflare Pages
answers the slashless form with a redirect. Three packets arrived with eight
or nine such anchors each.

The exceptions stay absolute and must NOT be rewritten: `<link rel="canonical">`
and `og:image`. On a page's own self-link the canonical and the anchor are the
same string, so a careless pass turns the canonical relative and breaks it.

### 3 · Images at `/games/img/<name>.png`
Not `./img/<name>.png`. From `/games/las-vegas/` the relative form resolves to
`/games/las-vegas/img/`, which does not exist. The site serves every guide
image from one folder.

### 4 · Fonts via the Google Fonts `<link>`
Not an inline `@font-face` block with UUID filenames.

*The games hub shipped with that block and was rendering in system-ui — the
only page on the site doing so — while every guide around it loaded Schibsted
Grotesk. It went unnoticed because the page still looked fine.*

### 5 · Do not link a page that is not live
Flag it instead and we will unlink the mention.

`build-guides.py` holds an `UNWRITTEN` list for exactly this, but **it only
protects pages built from a `.dc.html` source** — a finished-HTML packet never
goes through that module, so its dead links reach the published page. That is
how `/games/sixes` got onto the live Sequoya guide.

And when a slug comes OFF that list, check the pages that mentioned it:
removing a link can take the link's TEXT with it. Wolf shipped reading
*"No, though they get confused. In &nbsp;the partnerships are fixed for six
holes"* — subject missing — in the visible copy **and** in the FAQ JSON-LD,
so Google's rich result served it too.

### 6 · Titles under 60 characters, descriptions 50–165
Longer and `build-seo.py`'s `OVERRIDES` has to carry a shorter version, which
is then a second copy of the words to keep in step.

**Measure, do not count.** Google truncates on pixel width, about 600px in
Arial 20px. Triple Cup at 61 characters is 553px; Nassau at 65 was exactly
600 — no margin at all, so any variance cut it. Character count is a proxy
that fails in both directions.

### 8 · Title and description in the page's OWN `<head>`
Outside the `<!-- seo:begin … seo:end -->` block.

`build-seo.py` REGENERATES everything between those markers on every run. A
page whose `<title>` lives inside the block therefore has no title of its own
— the build has nothing to copy forward, and the audit fails with
`no <title>`, which aborts the zip.

*This bites when Design builds from an already-published page, which is the
normal way to deliver an edit. On 9 Oct the new Nassau title arrived inside
the block; the entry in `OVERRIDES` was the only thing supplying it, so
retiring that entry — which the workflow in `seo-copy-for-design.md` says to
do once the source carries the copy — broke the build instead of handing the
copy back.*

Until a packet does this, `OVERRIDES` **is** the source for those two fields
and its entry must stay.

### 7 · One H1, alt text on every image
`build-seo.py`'s audit treats both as errors and **aborts the zip**, so a page
that breaks either cannot be deployed at all.

---

## What we do at our end

`build-seo.py` generates the `<head>` block, the sitemap and `_redirects`, and
runs an audit that aborts the build on a broken internal link, a missing
canonical, a duplicate title or a page absent from the sitemap. So a packet
that follows the rules above publishes with no hand-editing.

## The paste-able version

> Please send the updated pages as a folder in Downloads — finished static
> HTML, one file per page, plus a README saying which pages changed and where
> each publishes. Links relative with a trailing slash (`/games/skins/`),
> images as `/games/img/<name>.png`, fonts via the Google Fonts `<link>`
> rather than an inline `@font-face`, and no template bindings or design-tool
> tags left in the markup. Titles under 60 characters and descriptions
> 50–165. Don't link a page that isn't live yet — flag it instead.
