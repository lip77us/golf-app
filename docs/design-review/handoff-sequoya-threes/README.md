# Handoff: Sequoya 3s

## Overview

**Sequoya 3s** is a four-golfer betting game: **six matches of three holes each**, 2 v. 2 best ball, net. Partners rotate so every golfer plays with every other golfer exactly twice over eighteen holes. Each match carries a base bet plus up to two **presses** — and a press here is *a new bet at the same amount over the holes that remain*, never a doubling of the original.

This bundle covers the complete game: setup, hole-by-hole play and score entry, the round leaderboard, settlement, and the iOS Live Activity / Dynamic Island.

## About the Design Files

The files in this bundle are **design references created in HTML** — prototypes showing intended look and behaviour. They are **not production code to copy**. Each one is a static page with a fake phone bezel, an annotation column of design rationale, and inline `<style>` blocks; none of it is componentised, none of it is wired to data.

The task is to **recreate these designs in the target codebase's existing environment** — Flutter, SwiftUI, React Native, whatever the Halved app is built in — using its established widgets, theme and navigation patterns. Where this document names a hex value or a pixel size, match it. Where the HTML does something structurally clumsy because it is a static mock (repeating a card twice to show two states, hard-coding a score into markup), use the codebase's idiomatic approach instead.

The one file that is closer to real logic is **`sequoya-threes-scorecard.js`**. It derives strokes, net scores, the counting cell and every hole winner from gross scores alone. Read it as a **specification of the derivation rules**, then reimplement in the target language — do not ship the JS.

## Fidelity

**High fidelity.** Colours, type, spacing and copy are final. Recreate the UI faithfully using the codebase's existing components. The annotation columns beside each phone frame are documentation for you, not part of the design — do not build them.

---

## Game rules — build these exactly

### Structure

Four golfers. Six matches of three holes: 1–3, 4–6, 7–9, 10–12, 13–15, 16–18. Each match is 2 v. 2 best ball, net.

Four golfers split into 2 v. 2 in exactly **three** ways, and there is no fourth way. So:

| Match | Holes | Pairing | How chosen |
|---|---|---|---|
| 1 | 1–3 | A | **The only thing set at setup** — the group assigns teams or spins to draw them |
| 2 | 4–6 | B | Derived — next pairing in rotation |
| 3 | 7–9 | C | Derived — the last one |
| 4 | 10–12 | A | Repeat of match 1's pairing |
| 5 | 13–15 | B | Repeat |
| 6 | 16–18 | C | Repeat |

Do **not** build this as six independent selections. Build it as: set match 1, derive 2 and 3 from the rotation, then modulo 3.

There are **no format options** — no Classic vs. High-Low, no handicap-allocation choice. The only handicap setting is Net / Gross / Strokes Off, allocated by full course stroke index.

### Handicap and stroke allocation

Full course allocation by stroke index. A golfer receiving *N* strokes gets one on every hole whose stroke index is ≤ *N*. A stroke falls where the card says it falls, whichever three-hole match that lands in. **Matches are not equal in difficulty and must not be normalised.**

### Money

- **$5 a man, every bet** (configurable). Not per pair.
- Lose a match bet and you are down $5; your partner is also down $5. Two winners each collect $5.
- **Nothing in the format assigns one loser's money to a specific winner.** Only the four nets are real. Settlement derives payments from nets.
- A halved bet pays nothing and **does not carry** — carryover across a pairing change would mean a wager owed by a pair that no longer exists.

### Presses — the core rule

**A press is a new bet at the same amount as the original, not a doubling.** It runs over the holes that remain in that match and settles on its own.

Three setup options:

| Option | Behaviour |
|---|---|
| **None** | No presses. Each match is one bet. |
| **Auto after 1st hole win** *(default)* | Win the first hole of a match and a second bet at the same amount opens over the holes that remain. Nobody calls it. |
| **Manual + Auto** | The above, plus the trailing side may call **one** press by hand from hole 2 of the match onward. It opens a bet on the holes remaining **after the call**. |

- **Press amount = bet amount.** There is no separate press unit to configure.
- **Cap: one auto plus one manual** — a match carries at most three bets.
- A hand-called press must start on the **next** hole, not the current one. Two bets over the same hole range with the same label are unreadable at settlement.
- A match that closes early still pays its match bet; a press bet opened later can remain live on the last hole after the match itself is decided. This is the ordinary closing-hole press, and it is why presses are bets rather than multipliers: doubling a wager you have already lost is a donation nobody would tap.
- **A press can be halved while the match is won, and can be won by the side that lost the match.** Both are normal. Never fold a press result into a match total.

**Round exposure at a $5 stake:** $30 with no presses, **$60** with the auto press live in all six matches, **$90** at the Manual + Auto ceiling. Print these on the setup screen.

### Validation rule — non-negotiable

Bet results are **derived from hole scores, never entered.** A press over holes 5–6 and a match over holes 4–6 are decided by the same three holes, so the app must not allow a press result that contradicts the match it sits inside. Compute every bet from the same net-score table.

### Resolution order, per hole

1. Enter four gross scores.
2. Apply strokes by stroke index.
3. Best net per pair. Lower wins the hole; equal halves it.
4. Update every live bet's state (match bet and each press independently).
5. **Close a bet early** when a side is up by more than the holes remaining in that bet.
6. Evaluate press triggers.

---

## Screens / Views

### 1. Setup — `sequoya-threes-setup.html`

**Purpose:** the group sets match 1's teams and the money before the first tee.

**Layout:** 390 × 812 phone. Status bar 40px. App bar: back chevron, centred title "Sequoya 3s", 20px Schibsted Grotesk 600. Scrolling body, `padding: 0 14px`, height 634px. Fixed bottom bar, `padding: 12px 16px 18px`, with a gradient scrim `linear-gradient(transparent, #EEF3EE 26%)`, holding a full-width 52px primary button, radius 16px, "Start Match 1".

**Blocks, in order:**

1. **Intro card** — section card (see tokens). Title "Six matches, three holes each" in pine 14px. Body 11.5px, muted, line-height 1.5: explains only the first match is set here and partners rotate at the fourth tee.

2. **Team card** — white, 1px `#D3DED6` border, radius 8px, overflow hidden.
   - Header strip, background `#E1EAE2`, `padding: 10px`, centred: "Match 1 · Holes 1–3" 18px Schibsted Grotesk 700, then "Par 4, 5, 3 | 1,127 yds." 12px muted.
   - Team label "Team A" — 10.5px, 700, uppercase, letter-spacing .4px, blue `#1976D2`, margin `8px 12px 4px`.
   - Two draggable rows: `display:flex; align-items:center; gap:10px; padding:9px 14px`, 1px top border, **4px left border in the team colour**. Grip glyph muted, name 600, handicap index 12px muted tabular.
   - "Team B" label in orange `#EF6C00`, two more rows with orange left border.
   - **"🎲 Spin to assign teams"** — full-width tappable row inside the card, 1px border, radius 8px, `padding:10px`, centred, pine 600 13px. Opens the shared slot-reel draw sheet (see *Shared components*).
3. **Note line** — 12px muted, flex, gap 6px: drag to set teams by hand; convention is the two long drives against the two short ones; spinning opens the same reel Sixes uses.

4. **Handicap** — section card, title "Handicap", then a segmented control: pill, 1.5px pine border, radius 999px, three equal segments 12.5px 600 — **Net** (selected: pine fill, white text), Gross, Strokes Off. Explanatory paragraph below.

5. **Presses** — section card. Title "Presses". Paragraph establishing that a press is a new bet at the same amount, not a doubling. Then **chips**: 1.5px `#D3DED6` border, radius 999px, `padding:7px 12px`, 12.5px 600 pine; selected chip is pine fill with white text. Options: `None` | `Auto after 1st hole win` *(selected)* | `Manual + Auto`. Paragraph explaining both. Footer row, 1px top border `#F0F4F1`: "Bets a single match can carry" with **2** right-aligned in 15px Schibsted Grotesk 700.

6. **Stake** — section card. Title "Stake", paragraph "A man a match…", then a field: 1.5px border, radius 12px, `padding:11px 14px`, 16px 600, `$` prefix muted, value `5.00`, and right-aligned 11.5px muted "per man, per match".

7. **Exposure note** — 12px muted with a 🛡 glyph: "Most you can lose: **$60.00** — all six matches lost with the auto press live in each. No presses at all tops out at $30; Manual + Auto raises the ceiling to $90."

### 2. Play / score entry — `sequoya-threes-play.html`

**Purpose:** enter four gross scores per hole and see what every live bet is doing.

Two phone frames are drawn side by side: **(a)** hole 5 mid-entry, **(b)** the hand-called press offer on hole 6. They are the same screen in two states.

**Layout:** 390 × 812. App bar: ✕, centred "Sequoya 3s" 18px, then chat / stats / overflow icons. Body `padding: 0 12px`, height 636px. Bottom bar: two 48px buttons, gap 8px — outlined "‹ Hole 4" (1.5px pine border, transparent, pine text) and filled "Hole 6 ›" (pine, white). Both radius 12px, 14px 700.

**Blocks, in order:**

1. **Bet banner** — 1px `rgba(15,110,86,.4)` border, background `rgba(15,110,86,.08)`, radius 8px, `padding:10px 12px`.
   - Header row: "Match 2 of 6" — 10px 700 uppercase letter-spacing .4px pine — and right-aligned muted "$10 a man · 2 bets".
   - **One row per live bet**, 11.5px, `padding: 2px 0`: label (`Match 2 · **holes 4–6**`) flexing, then the amount 700 tabular, then a 74px right-aligned 10.5px 700 state in the leading side's colour. Rows read `Match 2 · holes 4–6 | $5 | D/L 1 UP` and `Press 1 · holes 5–6 | $5 | AS`.
   - **Do not show a multiplier.** Do not repeat the pairings here — the score cards below name both pairs.

2. **Press button** — amber, `#FDF3E7` fill, 1.5px `#E0C79C` border, radius 10px, `padding:9px 12px`, full width, flex with gap 9px. 22px rounded-square icon `#8A5216` with a white ↑, then a two-line label: "Call your press — hole 6" 13px 700 `#8A5216`, and a 10.5px 500 second line giving the reason ("You and Sam are 1 down. Yours until the 6th tee."), then the amount right.
   - **Lit whenever a manual press is legal** — after a halved first hole, or from the second hole of the match onward, for the trailing side only, when the group chose Manual + Auto.
   - **Unlit state** (`.pbtn.off`): border `#D3DED6`, fill `#F4F7F5`, icon `#C8D3CB`, text `#8B9990`. Used when the app has already put the offer on a card — the button dims and points at it. The same decision must never have two live controls.
   - It names **the hole it would cover, not the match**, and is called *your press*, so it can never be confused with the auto press already in the banner.

3. **Hole header** — background `#E1EAE2`, radius 8px, `padding:10px 44px`, centred. "Hole 5" 18px Schibsted Grotesk 700, then "Par 3 · 168 yds · SI 9" 12px muted. A pine `？` help glyph absolutely positioned top-right.

4. **Score entry, one card per pair.**
   - Team label above the card: 10px 700 uppercase, pair name in the side's colour, and right-aligned "best ball **4**" in 11px muted with the number in deep pine.
   - Card: white, 1px border, radius 8px, **4px left border in the side colour**.
   - Player row: name 14px 600 flexing; optional "gets 1" chip (10px 600 muted, `rgba(29,158,117,.12)` fill, 1px border, radius 8px, `padding:1px 6px`); net readout 11px muted 40px wide right-aligned with the counting value in pine bold; then the score box.
   - **Score box:** 40 × 36, radius 6px, 1px border, 700 tabular. The counting (best net) box is filled `#DCF2E4` with a `#B6DEC7` border and `#0B5B44` text. Above each box sits a row of 4px dots (one per stroke received), `#D32F2F`.
   - **Active row** — the golfer being entered: the row sits in a block with `rgba(15,110,86,.08)` background and a 1.5px pine top border, its box gets a 2px pine border, and an inline picker appears beneath: 4 options, each min 40px wide × 46px tall, radius 9px, 1px border, 17px 700, with an 8px uppercase muted caption (`bird` / `par` / `bog` / `dbl`). Under-par options are `#D32F2F`. The selected option gets a 2px pine border.

5. **Three-hole strip** — one row, not a card. 1px border, radius 8px, `padding:7px 10px`. Left: "Match 2" 10px 700 uppercase pine, with "best ball, net" 10px muted beneath. Right: three 44px cells, gap 4px, radius 6px, 1px border, each with a tiny hole number (8.5px 700 `#8B9990`) over a 12px Schibsted Grotesk 700 result. Won cells take the winner's colour at 7% fill; the hole in play gets a 2px pine border.

6. **The six matches** — white card. Header "The six matches" 10px 700 uppercase pine. Six rows, 12px, 1px top borders: match number and hole range (52px, 11px 700 muted), pairing with the leading pair bold, an optional bet-count chip (10px 700 `#0B5B44` on `#DCF2E4`), then a 46px right-aligned money value — green `#388E3C` for a win, `#8A5216` for a loss, `#B6C4BB` dash for pending. Footer row with a 1.5px top border: "Yours, settled" and the running total in 16px Schibsted Grotesk.

7. **The scorecard** — see *Shared components*. Rendered with `played` set to the number of **completed** holes; the hole in progress stays blank.

**The press-offer card** (frame b), shown when the app is asking rather than the golfer deciding:
- Amber: `#FDF3E7` fill, 1px `#E8D6BC` border, radius 8px, `padding:11px 12px`.
- Header: "PRESS OFFERED" 10px 700 uppercase `#8A5216`, right-aligned "until the 6th tee".
- Question: "Your press on hole 6 — $5?" 15px Schibsted Grotesk 700.
- Body 11.5px `#6B5330`: states the position, that the match bet is gone and pays $5, and that a press is a third bet on hole 6 alone.
- Two buttons, gap 8px, radius 9px, `padding:10px`, 13px 700: "Press hole 6" (`#8A5216` fill, white) and "Let it go" (1.5px `#DCC9A9` border, `#8A5216` text).
- Footer 10.5px: only the eligible pair can act; the other pair sees the card and cannot decline it; available because the group chose Manual + Auto.
- **It expires.** It is the only object in the game that does, and the only one addressed to two of the four golfers. Both facts are printed on the card. State the window as a tee, never a countdown.

### 3. Leaderboard — `sequoya-threes-leaderboard.html`

**Purpose:** what happened in this round, for all four golfers. **Nothing on this screen is per-viewer** — four phones show the same thing.

**Layout:** 390 × 844. App bar with back chevron, "Leaderboard" 17px 700, overflow. Tab row: pills, 1.5px border, radius 999px, `padding:7px 13px`, 12.5px 600 — selected is `#E4F2EA` fill with a pine border and pine text. Tabs: Sequoya 3s / Skins / Scorecard. Body `padding: 0 12px 26px`, height 735px.

**Blocks:**

1. **Chips line** — 11.5px muted: "Stake **$5 a man, every bet**" and right-aligned "Round complete".

2. **Section head** — 10px 700 uppercase letter-spacing .5px muted: "The six matches", right-aligned "13 bets · $65 a man on the line".

3. **Six match blocks, in chronological order.** Each is a white card, 1px border, radius 10px, margin-bottom 6px, containing **one line per bet and nothing else** — no match header, no pairing row. A match without a press is one line; with a press, two or three.
   - Row: `padding: 6px 0`, 11.5px, 1px top border `#F2F6F3`. Label flexes: bet name in deep pine 600, then hole range, then the tail — margin for a match bet, cause **and** result for a press. Then `$5` 700. Then a 66px right-aligned 10.5px 700 winner in that side's colour, or "Halved" in `#B6C4BB`.
   - Press rows are tinted `#FDF9F2` and bleed to the card edges.
   - Example block:
     ```
     Match 2 · 4–6 · won 2 & 1                      $5   Dave & Lee
     Press 1 · 5–6 · auto · halved                  $5   Halved
     Press 2 · 6 · called by Paul · won the hole    $5   Paul & Sam
     ```
   - **Press cause goes inline** so nothing wraps: `auto` has no author; `called by Paul` does.

4. **Money table** — white card, `padding:9px 10px 10px`, radius 12px. CSS grid, `56px repeat(4, 1fr)`, gap 2px. Header row: "Match" 9.5px 700 uppercase muted, then four golfer names 10px 700 uppercase muted, right-aligned. Six rows labelled "Match 1"–"Match 6" (11px 700 muted, **no hole numbers**), each with four signed values right-aligned 700 tabular — `#388E3C` positive, `#8A5216` negative, `#C3CFC6` dash for a match that paid nothing. Total row: 1.5px top border, label "Net" 11px, values in 16px Schibsted Grotesk 700. Then a footer line: "Sums to zero ✓".
   - **Rows must sum to zero across, and the screen must say so.** A foursome will check.
   - Partners are visible without being labelled — in any row two columns carry the same number.
   - Mid-round: **closed bets only.** A match in progress is dashes.

5. **The scorecard** — full 18 columns. See *Shared components*.

6. **Footer paragraph** — 11px muted: the rotation, best ball net, the auto press rule, "A press is a new bet, never a doubling", halved bets pay nothing.

### 4. Settlement — `sequoya-threes-settlement.html`

**Purpose:** four men in a car park working out who hands cash to whom.

Two frames: the settle-up screen and one golfer's receipt.

**Layout:** 390 × 844, surface `#EAF0EA`. App bar: back chevron 23px, "Settle up" 17px Schibsted Grotesk 700, right-aligned ••• muted. Body `padding: 0 14px 26px`, height 690px. Bottom CTA bar with a 60px ghost square button (⇧ share) and a full-width 52px pine button, both radius 15px: "Text the group" / "Text this receipt".

**Blocks — settle up:**

1. **Nets block** — white, 1px `#DCE5DD` border, radius 16px, `padding:14px 15px 12px`. Heading "Sequoya 3s" 12.5px Schibsted Grotesk 700 with right-aligned "$5 a man, every bet" 10.5px 600 muted. Sub-paragraph 11px muted: bets, presses, how many halved.
   - Four rows, 13px, 1px top divider `#F2F6F3`: name 600 with a 10.5px muted second line (`3–2–1 · best with Lee`), then gross (11px 600 muted tabular), then the net in 17px Schibsted Grotesk 700 — `#388E3C` positive, `#8A5216` negative, 56px right-aligned.
   - Footer: "Balances to zero ✓" with a 1.5px top border.

2. **Payments block** — same shell. Heading "Two payments" with "fewest handovers" right. Paragraph stating it is derived, **not** a record of who beat whom. Then one row per payment: 34px rounded-square initials avatar (`#E4F2EA` fill, pine text, radius 11px), "**Dave** pays **Paul**" 13.5px with a 10.5px muted second line, the amount in 18px Schibsted Grotesk 700, and a 22px checkbox (radius 7px, 1.5px `#C3CFC6` border; checked = pine fill, white tick).
   - Then a hint tile: `#F4FAF6` fill, `#C9E3D4` border, radius 11px, 11px text — ticking marks it done **in the app only**; no money moves.
   - **Only the four nets are real.** Nothing in the format assigns one loser's money to a specific winner, so the app must not imply it. Payments are the fewest transfers that clear the nets — for four golfers, almost always two.

**Blocks — receipt:** eyebrow, date/course line, golfer name with handicap sub-line, then the hero: 38px Schibsted Grotesk 700 pine amount with a 12.5px muted "to collect" beside it, then a one-line summary of who owes what. Then:
- **"The six matches"** — six lines: description with a muted second line giving opponents, margin, what the press did, and the hole range; a bet-count chip; the money.
- **"Presses called by hand — 2"** — one line each, tinted chip, naming **who called it, when, which holes it covered and the outcome**. Auto presses are *not* itemised — they have no author and are counted in the match line as a second bet.
- **Net** summary row, 1.5px top border, 16px value.
- **Agreement stamp** — `#F4FAF6` tile: "Agreed by all four at 2:47 PM. Thirteen bets closed, both hand-called presses recorded when they were called."
- **Exclusion footnote** 11px muted explaining the auto-press omission.

Sharing leaves the app as **plain text** — label, en dash, amount. No columns, no links.

### 5. Live Activity / Dynamic Island — `live-activity-sequoya-threes.html`

**Purpose:** the lock-screen card and island presentations.

**Hard constraints, shared across every Halved Live Activity:**
- Panel height budget ~**135pt**; three rows maximum. Do not add a fourth.
- **Upper right is locked to `HOLE X · PAR Y · YDS`.** Lower right is locked to `THRU X · ±Y`. Both are fixed across the whole set of games.
- The headline slot belongs to the match state. The 36px number is protected.

**Card anatomy:** container radius 24px, `rgba(255,255,255,.13)` fill, `backdrop-filter: blur(20px)`, .5px `rgba(255,255,255,.14)` border, `padding:12px 15px`, margin `26px 14px 0`.
- **Header row:** 17px mint rounded-square mark with "H" in `#06231A`; game/match string 11.5px 700 letter-spacing .3px; then the locked hole/par/yardage at 10.5px 600, opacity .62.
- **Headline row:** state number 36px Schibsted Grotesk 700, letter-spacing -1px, in the leading side's lock-screen colour (blue `#5AA7F5` / orange `#F3A059`, mint `#3BD89A` when neutral); right-aligned state block with 17px 700 label (`DORMIE`, `CLOSED`) over a 9px 700 uppercase caption at opacity .55; then a full-width 12.5px sub-line naming both pairs, leader at full weight, trailer at .6 opacity, each with a 7px colour chip.
- **Footer row:** 11px. Total at risk, then a **press chip** — `rgba(59,216,154,.2)` fill, mint text, radius 4px, 9.5px 700 uppercase (`+ AUTO PRESS`, `3 BETS`); amber variant `rgba(240,192,112,.2)` / `#F0C070` for `PRESS OFFERED`. Then the running money. Then the locked `THRU X · ±Y` right-aligned.

**Push discipline — five pairing changes and up to six press offers a round, so it must be tight:**

| Event | Count/round | Colour | Notes |
|---|---|---|---|
| New pairing | 5 | mint | On the 4th, 7th, 10th, 13th, 16th tees. Names both new sides. |
| Press offered | 0–6 | amber | Manual + Auto only. The only push that expires. Sent to all four; says which two can act. |
| Auto press | **none** | — | No decision in it. Rides the activity update and the footer chip. |

The auto-press exclusion is deliberate: it fires on most matches, and a notification arriving six times a round to report a rule the group already agreed to is noise. **The chip is the receipt; the push is for decisions.**

**Dynamic Island:** minimal = mark + mint dot. Compact = mark, match state in the side's colour, and the money at .55 opacity. Compact (press open) = mark, amber `PRESS?`, the amount. Expanded = header with match number, then state / both pairs / DORMIE, then a **six-pip strip** (blue / orange / white for halved, current pip ringed). The pips ship **only** in the expanded island — the lock card has no room for a fourth row.

**A state word appears only when it is true of the position.** `DORMIE` means up by exactly the holes remaining — one up with one to play, two up with two. `CLOSED` when a bet is decided early, with the headline holding the margin (`2 & 1`). Anything else takes an em dash over the holes left. **1 UP with 2 to play is not dormie and must never be labelled it** — a state word that is not true of the position is worse than no word.

**Observers.** A golfer invited to follow the round gets the leaderboard and, optionally, this activity. **There is no separate observer card** — the neutral-scoreboard rule already did the work, since the three rows name both pairs and never say *you*. Two slots come out: the **running money** (an observer has no position; the total at risk and the press chip stay, because what the hole is worth is part of the match) and the **±Y** half of the locked corner (keep `THRU X` alone — that is the round's position, not a personal one). The final state reads the match record and who won the round rather than who to collect from. Pairing-change pushes still go out — they are the one thing an observer cannot infer — but **the press offer must not push to observers**: it is a decision addressed to two golfers.

**Final state** replaces the neutral board with the one personal thing: the money, gross, `Won 3, lost 2, halved 1 · best with Lee`, and who to collect from. Holds ~5 minutes and dismisses itself.

---

## Shared components

### The scorecard — `sequoya-threes-scorecard.js`

Used at the bottom of the play screen and on the leaderboard. **Gross scores are the source of truth**; everything else is derived.

- **Columns:** always all **18** holes, regardless of progress. The table scrolls sideways; the name column is sticky-left. Player cells are blank (`–`, `#C3CFC6`) past the holes played. A separate `played` count drives the footer's "Thru N". Do not truncate the table — eighteen legible columns do not fit a phone, and a card you cannot read is worse than one you have to push.
- **Header block** (tinted): `Hole` row on `#E1EAE2`, 11px 700; `Par` row italic and `Index` row 10.5px `#8B9990`, both on `#EEF3EF`; a 1px `#DCE5DD` rule under Index.
- **Cells:** 26 × 23 rounded 5px, 12.5px 600 tabular, in 30px rows.
- **Strokes:** a 4px pine dot at the cell's top-right, one per stroke received, placed by stroke index (`si <= gets`).
- **The boxed cell:** `#DCF2E4` fill, 1px `#7FC79F` border, `#0B5B44` 700. It marks **the score that won the hole for its side**.
  - A **halved** hole boxes **nothing**.
  - The losing side's counting net is **never** boxed.
  - If **two golfers on the winning side tie** for the low net, **both** are boxed.
  - Never both members of a side otherwise.
- **Legend footer:** the box swatch → "won the hole"; the dot → "stroke"; right-aligned "Thru N".

The same component serves Sixes with six-hole segments instead of three-hole matches (`screens/sixes-scorecard.js` in the design system). **In code this is one widget parameterised by the segment map** — the two files exist only so each prototype page loads standalone.

### The slot-reel draw

Sequoya's "Spin to assign teams" opens the **same draw sheet Sixes uses** — `patterns/sixes-segment-draw.html` in the design system. Three candidate pairings, one drawn, re-spinnable. Key rules: the window shows only "Spin to select next partners" while idle (candidates are **not** listed beforehand — the reveal is the point); **the winner is picked before the animation starts**, so the reel is a reveal and never the randomness; 2.55s `cubic-bezier(.12,.62,.15,1)`, no bounce past the winner; tap to skip; reduce-motion lands instantly.

---

## Interactions & Behavior

- **Score entry** — tap a player row to make it active; the inline picker appears centred on net par. Posting the fourth score on a hole resolves every live bet for that hole and advances.
- **The press button** appears/lights the moment a manual press becomes legal and disappears when it does not. It dims (never disappears) while the app's own offer card is showing the same decision.
- **The press offer expires** when a score is posted on the closing hole of its window. It cannot be reopened later — an offer that expires on the tee must not be revivable at the bar.
- **All four golfers see the press offer**; only the eligible side can act. Being pressed without being told is worse than one extra buzz.
- **Early close** — when a bet can no longer be won, mark it closed and pay it; leave any other live bet running. The screen must be able to show a paid match bet above a live press.
- **No animations beyond the draw reel.** Score entry, bet resolution and money updates are immediate.

## State Management

Per round:
- `players[4]` — name, handicap index, course handicap, strokes received, tee.
- `holes[18]` — number, par, yardage, stroke index.
- `gross[player][hole]` — the only entered data.
- `settings` — handicap mode, press option, stake.
- `matchOneTeams` — the single pairing choice; matches 2–6 derive from it.
- `bets[]` — each with: owning match, hole range, amount, kind (`match` | `auto` | `manual`), caller (nullable), state (`live` | `won` | `lost` | `halved`), and the hole it closed on.

Everything else is computed: net scores, counting cells, hole winners, bet states, per-golfer nets, the payment plan, the leaderboard, the receipt. **Do not persist derived values** — the whole reason a press cannot contradict its match is that both come from one table.

## Design Tokens

**Colour**

| Token | Hex | Use |
|---|---|---|
| deepPine | `#0B1F1A` | ink, phone bezel |
| pine | `#0F6E56` | primary, section titles, CTAs |
| brightMint | `#3BD89A` | lock-screen mark, reel accents |
| surface | `#EEF3EE` | in-app background (settlement / leaderboard use `#EAF0EA`) |
| card | `#FFFFFF` | card fill |
| cardBorder | `#D3DED6` | borders (`#DCE5DD` on the darker surfaces) |
| muted | `#5C6B62` | secondary text |
| blue | `#1976D2` | side A, in-app |
| orange | `#EF6C00` | side B, in-app |
| blue (lock) | `#5AA7F5` | side A on the lock screen |
| orange (lock) | `#F3A059` | side B on the lock screen |
| win | `#388E3C` | money won |
| loss / warn | `#8A5216` | money lost, amber ink |
| under | `#D32F2F` | under-par, stroke dots in entry |
| amber fill | `#FDF3E7` | press surfaces |
| amber border | `#E8D6BC` | press surfaces |
| amber (lock) | `#F0C070` | press chip on the lock screen |
| counted fill | `#DCF2E4` | boxed score |
| counted border | `#7FC79F` | boxed score |
| counted ink | `#0B5B44` | boxed score |
| press row tint | `#FDF9F2` | press lines in the ledger |

**Side colour follows the pairing, fixed when the pairing is set, never recomputed per hole.**

**Type** — Schibsted Grotesk 600/700 for numbers and headings; Spline Sans 400–700 for everything else. Tabular figures on all money and scores.

| Role | Size / weight |
|---|---|
| Lock-screen headline | 36 / 700, ls -1 |
| Screen title (app bar) | 17–20 / 600–700 |
| Hero money (receipt) | 38 / 700, ls -1 |
| Hole number | 18 / 700 |
| Section-card title | 14 / 600, pine |
| Body | 13 / 400 |
| Card body / notes | 11.5–12.5 / 400, lh 1.5 |
| Row label | 12–14 / 600 |
| Eyebrow / section head | 10 / 700, uppercase, ls .4–.5 |
| Chip | 9.5–10.5 / 700, uppercase |

**Radius** — 40 phone; 26 lock card; 16 primary button, nets block; 15 CTA; 12–13 field / table card; 10 press button, ledger card; 8 section card, hole header, strip; 6 score box; 5 scorecard cell; 999 pills and segments.

**Spacing** — 4pt scale. Card padding `12–14px` horizontal. Body gutter `12–14px`. Card gap `6–16px`. Row rhythm `9px`.

**Elevation** — phone `0 24px 60px rgba(6,18,14,.34)`. Cards are flat; borders do the work.

## Screenshots

`screenshots/` holds a full-page capture of each design file, in the same order as the table below. They are for orientation — **the HTML files are authoritative** for colour, spacing and type; a capture is lossy and the annotation column is baked into it.

## Assets

No images or icons are required. Every glyph in the prototypes is a Unicode character standing in for the real icon set — `🎲` for the draw, `↑` for press, `？` for help, `🛡` for the exposure note, `⇧` for share, `✓` for confirmation, `⣿` for the drag grip. **Substitute the codebase's own icon set.** Fonts are Google Fonts (Schibsted Grotesk, Spline Sans).

## Files

Design references in this bundle:

| File | What it shows |
|---|---|
| `sequoya-threes-setup.html` | Setup — teams, handicap, presses, stake, exposure |
| `sequoya-threes-play.html` | Score entry — live bets, press button, press offer, scorecard |
| `sequoya-threes-leaderboard.html` | The round as a ledger — bets in order, money table, scorecard |
| `sequoya-threes-settlement.html` | Nets, payment plan, one golfer's receipt |
| `live-activity-sequoya-threes.html` | Lock screen and Dynamic Island, all states |
| `sequoya-threes-scorecard.js` | **Derivation rules** for strokes, nets and the boxed cell |
| `HANDOFF.md` | The original design-decision log, including what is still open |

Each HTML file opens standalone in a browser. The annotation column beside each phone frame is design rationale — read it, don't build it.
