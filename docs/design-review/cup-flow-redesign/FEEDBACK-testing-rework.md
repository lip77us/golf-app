# Cup leaderboard — reworked during live testing (Aug 2026)

**Engineering → Design.** After the Phase 1–3 handoff, a live-testing pass on a
real 8-group cup (Tilden) drove a round of changes to the **Cup leaderboard**.
All are **built, verified on device, and merged to `main`** — so this is a
*confirm-or-redraw* list, not a build request. Each item says what it **was** in
the mocks, what it is **now**, and the **call** we need from design.

> Companion: the full "Notes back to design" list (original handoff items 1–8 +
> these as 9–15) lives in `docs/cup-flow-redesign-plan.md`.

---

## 1 · Collapsed to a single "Cup Detail" tab
- **Was:** separate cup views — an *Overview* (big pill scores), a *Details*
  segment view, and a *My Foursome* tab.
- **Now:** one **Cup Detail** tab — the two-panel cup scoreboard (big team
  numbers + the even-line bar) on top, then a card per group. Overview read as
  "more space showing less data"; My Foursome just duplicated a group card.
- **Confirm:** the one-tab consolidation reads right for a many-group cup.

## 2 · Your group floats to the top; header carries the tee time
- **Now:** the viewer's own group sorts first (this replaces My Foursome); the
  rest follow in **tee-time order**. Header reads `Group 4 (my group) · 8:30 AM`.
- **Confirm:** "(my group)" + start-time-on-the-header is the right way to orient
  a player.

## 3 · Full names once up top, initials in the four rows
- **Now:** each side is named in full once ("Brian Kerss & Alan Petersen" vs …),
  then the four segment rows use initials (`BK / AP vs RS / RW`) to stay compact.
  A solo side's **Phantom** is named in the header, real golfer first
  ("Charlie Wicke & Phantom"), so the lone "P" in the Fourball row is explained.
- **Confirm:** name-once-then-abbreviate, and how the Phantom is surfaced.

## 4 · Group cards no longer drill in
- **Was:** tapping a group opened a standalone per-group cup-standings screen.
- **Now:** the cards are non-interactive — a Triple Cup has no per-foursome bet,
  so the drill-in was noise; the segment detail already lives on the card.
- **Confirm:** no per-group drill-in is wanted.

## 5 · The bar marker is the even line, not "to win"
- **Was:** the marker sat at to-win (16.5 of 32 → ~1.5% right of centre), so a
  tie didn't line up with the divider between the team blocks.
- **Now:** the marker is the **even/tied line** — dead centre, aligned with the
  white divider; whoever's fill crosses it leads. "16.5 to win" stays in the text.
- **Confirm:** the marker means "balance," not "clinch threshold."

## 6 · "Points decided," not "points played"
- **Now:** reads `0 of 32 points decided` — a cup point isn't earned until its
  match is decided, even while holes are being played.
- **Confirm:** the term.

## 7 · New surface — live tee-time editing under Round setup
- **Gap:** the tee-time pencil lived only in initial setup (saves via a full
  re-setup), so there was no way to nudge one group's time on a running cup.
- **Added:** an **Edit tee times** item under Round setup — a list of groups, tap
  a time to change it (saves immediately). After a change it offers to **shift
  the later groups by the same amount**, so a TD doesn't move seven by hand.
- **Needs:** a surface the mocks don't cover — design may want to style the list
  + the shift prompt.

---

*Also fixed in passing (not design-relevant): Triple Cup segment "thru N" was
counting the segment's full hole range instead of scored holes, so every Fourball
read "thru 6"; now counts only decided holes.*
