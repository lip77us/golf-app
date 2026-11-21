# Website: what changed in the repo since your last export

**For Design, 20 Nov 2026.** We took `handoff-website-screens` and merged it
into the live site. We did **not** replace the files as the handoff asked,
because your export was built from an older copy of the pages. The new
screenshots, alt text, width/height and captions are in. The items below are
things the live pages already carry that your files do not. Please bring them
into your sources so the next export doesn't undo them.

The site is the source of truth for everything in this list. Your current
files are the source of truth for nothing else here: the new screens are
already live.

## What went in unchanged from your handoff

- All 29 PNGs in `games/img/` (1288 × 2877).
- Every `<img>` tag on the 10 guides (alt, `width="1288" height="2877"`).
- Every `<figcaption>` on the 10 guides.
- On the homepage, only `width`/`height` on the phone images and the alt text
  of the second hero phone. See "Homepage" below.

`wolf-leaderboard.png` and `vegas-leaderboard.png` still show the old screens,
as you asked. Send new ones when those boards are designed.

## Guide copy the repo has and your files do not

### Las Vegas (`/games/las-vegas/`) — a rule changed

On 8 Nov the engine changed: **when both teams go under par, the birdies
cancel and nothing flips.** It was "both numbers flip" before. Your file still
has the old rule. The live page has:

| Card | Live copy | Your file |
|---|---|---|
| Eagle | "Under Flip an eagle does exactly what a birdie does: one flip, not two, and the hole is not doubled…" | "Flip, then double the whole hole…" |
| Eagle value | **×3** | ×2 |
| Both under par | Title **"Both teams go under par"**: "They cancel, and nothing flips — two birdies, two eagles or one of each…" | Title "Both teams birdie": "Both numbers flip…" |
| Both under par value | **none** | both |

It says under par, not birdie, because two eagles cancel by the same rule.
The in-app note on the tray says the same ("both under par — no flip"). Also,
an eagle under Flip is one flip like a birdie; the ×3 is the Multiply mode,
where the winner's best ball counts ×2 for a birdie and ×3 for an eagle.

Please copy the live Las Vegas page's "Eagle" and "Both teams go under par"
cards into your source.

### Related-game cards

Your files drop a "Sixes" card from the "Related games" row on **Nassau,
Skins and Wolf**. The live pages have it:

> **Sixes** — New partners every six holes, so nobody is stuck in a bad match.
> (links to `/games/sixes/`)

### Rabbit — the extra-rabbit table

The live page's table of rabbit stakes has a "HOLES 13–18" cell ($5) beside
the "ONE-HOLE RABBIT" cell ($2.50). Yours has only the one-hole cell, so the
last full-length rabbit is missing. The live page follows the engine: a
rabbit that ends early rolls on, so the last leg can be six holes or a
one-hole leftover. Please take the live table (the "extra rabbit" card).

### Nassau — title

The live title is **"Nassau Golf Bet Rules: How to Play, Presses | Halved"**.
Yours adds ", Scoring". That runs past what Google shows (about 60 characters
for a title), so we kept the shorter one. The same limits are in
`docs/seo-copy-for-design.md`.

### `dateModified`

Your files carry old `dateModified` dates (28 Sep or 9 Oct). The live pages
are stamped 20 Nov. `build-seo.py` writes that block; it is regenerated on
every build, so please don't edit it by hand in your sources.

## Homepage

Your `index.html` is a different page from the live homepage. It has a
single hero phone with two float cards ("Press? Double it ↑" and another)
and a new stylesheet. **The live homepage doesn't have those float cards.**
Its hero is two overlapping phones (the Triple Cup leaderboard in front, the
Nassau score entry behind). It also carries two fixes yours predates:

- the closed mobile menu used to swallow every click (commit `71bf100b`);
- a CSS cascade conflict that broke the footer, plus the LipApps name in it
  (commit `6ad992e3`).

So we did not take your `index.html`. The Nassau screenshot already appears
in the hero, so the new screen shows up as it is.

**Decision for you:** if you want the single-phone hero with float cards, say
so and send it as a change against the live page, with the menu and footer
fixes carried over, so we apply it rather than replace the file. If you
don't, update your source to match the live hero.

## How to avoid this next time

1. Start from the live files. We can export the current `website/` folder on
   request.
2. Hand over only the pages that changed, or tell us which sections changed.
   We can merge image and caption changes exactly as we did here, so the
   screens are not held up by copy differences.
3. Don't edit the SEO block (`<!-- seo:begin -->` to `<!-- seo:end -->`).
   It is generated.

## Check before the next handoff

- [ ] Las Vegas: both-under-par and eagle cards match the live page.
- [ ] Nassau, Skins, Wolf: Sixes card is in "Related games".
- [ ] Rabbit: the extra-rabbit table matches the live page.
- [ ] Nassau title is the short form (or you've agreed a new one with us).
- [ ] Homepage: say whether you want the float-card hero.
