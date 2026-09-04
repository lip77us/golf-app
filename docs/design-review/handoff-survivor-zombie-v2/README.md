# Handoff: Survivor & Survivor Zombie

## Overview

**Survivor** is a casual golf side game for a three- or four-man group. The round is divided into consecutive multi-hole segments, each called a *Survivor*, each with its own pot. Inside a Survivor, the golfer with the worst net score on a hole is eliminated from that Survivor; the last man standing takes the pot. When a Survivor closes, a new one starts on the next tee.

**Survivor Zombie** is an option on the same game. An eliminated golfer keeps playing, and if he posts the outright low score on a later hole he is *back in* — and whoever loses that hole takes his place in Zombieville. The seat holds exactly one occupant at a time. A Zombie who takes the Survivor on the 18th kills that Survivor's pot (nobody is paid).

This bundle covers three surfaces:

1. **Score entry / play** — the hole-by-hole screen where scores are posted (`survivor-play.html`)
2. **Leaderboard** — the round summary with the Survivor rail and the by-hole grid (`leaderboard-survivor.html`)
3. **Live activities** — iOS lock screen and Dynamic Island cards, plain and Zombie (`live-activity-survivor.html`, `live-activity-survivor-zombie.html`)

`survivor-setup.html` is included for context on how a round is configured (handicap allocation, stake, Zombie toggle).

## About the Design Files

The files in this bundle are **design references created in HTML** — prototypes showing intended look and behaviour, not production code to copy directly. The task is to **recreate these designs in the target codebase's existing environment** (React Native, SwiftUI, Kotlin, whatever the app is built in), using its established components, tokens and patterns. If no environment exists yet, choose the most appropriate framework and implement there.

Each HTML file is a *specimen sheet*: it renders several states of the same screen side by side, in phone frames, with a written argument for each design decision beside them. Do not build the sheet. Build the phone content, and use the written notes as the specification for behaviour.

The live-activity files also render Dynamic Island compact and expanded states as separate labelled blocks below the phones.

## Fidelity

**High-fidelity.** Colours, typography, spacing and radii are final and exact. Recreate pixel-for-pixel using the codebase's existing libraries. Every hex value, font size and border radius in these files is intentional.

Two caveats:

- Phone frames (`.phone`, `.lock`, `.island`, `.torch`, `.bar`, `.clock`, `.status`) are **presentation chrome for the specimen sheet**. Do not build them. On the live activities, the system supplies the lock screen; you build only the `.la` card. On the play and leaderboard screens, the frame is the device.
- The `.notes`, `.own`, `.cap`, `.di` blocks are documentation, not UI.

---

# Design tokens

Both light screens (play, leaderboard) share this palette:

```
--deepPine    #0B1F1A   primary text, device bezel
--pine        #0F6E56   section headings, primary action, links
--brightMint  #3BD89A   brand mark
--surface     #EEF3EE   screen background inside the frame
--card        #FFFFFF   card fill
--cardBorder  #D3DED6   hairline
--muted       #5C6B62   secondary text
--under       #D32F2F   stroke dots (handicap)
--win         #388E3C   won it / money positive
--warn        #B24225   money negative
--out         #C62828   eliminated
--amber       #B07A22   "stroking" chip
--zombie      #6E4B8E   Zombieville
```

Page background outside the frame: `#DDE6DE`.

Live activity cards are dark and use a separate set:

```
--deepPine  #0B1F1A   Dynamic Island block background
--pine      #0F6E56   sheet headings
--mint      #3BD89A   the reader's figure, brand mark
--muted     #5C6B62   sheet body text
--blue      #5AA7F5   (unused on Survivor; the reader's side in team games)
--orange    #F3A059   OUT
plum        #C9A6E8   Zombieville, lifted for a dark background
```

**On the plum.** Zombieville is `--zombie` (#6E4B8E) on every light surface. That token is too dark to read against the lock-screen glass, so the live activities use `#C9A6E8` — same meaning, same position in the vocabulary, lifted for contrast. Treat them as one semantic colour with two renderings.

## Typography

Two families, from Google Fonts:

- **Schibsted Grotesk** (600, 700) — numerals, headline figures, screen titles, clock. Every large number in the system.
- **Spline Sans** (400, 500, 600, 700) — all body text, labels, chips, buttons.

Type scale in use:

| Role | Size / weight | Notes |
|---|---|---|
| Screen title (app bar) | 18px / 600 Schibsted | centred |
| Live activity headline | 36px / 700 Schibsted, `line-height:.94`, `letter-spacing:-1px` | 22px in the always-on state |
| Round-complete money | 42px / 700 Schibsted | |
| Round-complete gross | 34px / 700 Schibsted | |
| Live activity state slot | 17px / 700 Schibsted over 9px / 700 uppercase, `letter-spacing:.4px`, `opacity:.55` | |
| Section heading (light) | 12px / 700 uppercase, `letter-spacing:.3px`, pine | |
| Body / player name | 13px / 600 | |
| Chip / badge | 9–10px / 700, `letter-spacing:.4px` | |
| Micro label (live activity) | 9.5px / 700, `letter-spacing:.5px`, `opacity:.52` | never below 9.5px |
| Table cell | 11px, `font-variant-numeric:tabular-nums` | |

All numeric columns and rulers use `font-variant-numeric: tabular-nums`.

## Spacing & shape

Radii: `3px` track cells and grid marks · `4px` badges · `6px` score box, outcome strip · `8px` cards, banners, chips · `9px` score picker option · `12px` action buttons · `20–26px` live activity card · `999px` pills and the segmented control.

Card padding: `10px` (light cards), `13px 15px 14px` (live activity), `12px 15px` (always-on live activity). Gaps: `2–3px` inside grids and tracks, `6–8px` between chips, `8px` between cards, `12px` between blocks.

---

# Screen 1 — Survivor score entry (`survivor-play.html`)

## Purpose

Post the group's scores for the hole in play, and read the state of the current Survivor without leaving the screen.

## Layout

Single scrolling column, `390 × 812` device, `.body` scroll region `636px` tall with `0 12px` padding, fixed bottom action bar. Top to bottom:

1. **Status bar** — 40px, time left, indicators right, 12px/600.
2. **App bar** — back chevron, centred title "Survivor", trailing icon. `6px 14px 10px`.
3. **Phase banner** — states what stage the Survivor is at ("Decider — Sam is out, low score takes it"). Background `rgba(56,142,60,.10)`, border `1px solid rgba(56,142,60,.45)`, radius 8. Icon + bold line in `--win` 14px Schibsted, explanatory `small` in `--muted` 12px beneath.
4. **Hole header** — `#E1EAE2`, radius 8, centred. Hole number and par 18px/700 Schibsted, yardage and stroke index 12px `--muted`. Help affordance top-right in pine.
5. **Player rows card** — one `.prow` per golfer, 9px/12px padding, hairline between. Each row: name (flex 1, 600), optional `stroking` chip, then the score cell.
6. **Active row** — the golfer being entered is lifted out of the card: `4px` pine left border, 1.5px pine on the other three sides, `rgba(15,110,86,.10)` fill, and the **score picker** below it.
7. **Score picker** — horizontal row of `.opt` buttons, `min-width:40px × 46px`, radius 9, white on hairline. Selected: `2px solid var(--pine)`. Under-par options render the numeral in `--under`. Each carries a `small` uppercase caption (birdie / par / bogey).
8. **Outcome strip** — appears once the hole resolves: "Sam is out — highest net 5". `rgba(56,142,60,.08)` on a `rgba(56,142,60,.4)` hairline, `--win` text, radius 6.
9. **Survivors rail (R5)** — see *The Survivor rail* below.
10. **By-hole grid** — see *The by-hole grid* below.
11. **Money row** — running per-player totals, 12px/600, `--win` positive and `--warn` negative.
12. **Collapsed note** — a `<details>` labelled "How the marks work", pine 10.5px/700 with a rotating caret. Closed by default.
13. **Bottom bar** — Previous (outline pine) and Next (filled pine), both `48px` tall, radius 12, `flex:1`, over a `linear-gradient(transparent, var(--surface) 26%)` scrim.

## Row states

| State | Treatment |
|---|---|
| Alive | Plain row, name in `--deepPine`. |
| Eliminated | `rgba(92,107,98,.10)` wash, name `--muted`, `OUT` badge, score box `.dim`. His score no longer counts. |
| Zombie | `rgba(110,75,142,.08)` wash, name `--zombie`, `ZOMBIE` badge in `rgba(110,75,142,.16)`, score box border `rgba(110,75,142,.55)`. **He is still posting a score, and that score can bring him back** — this is the whole mechanic. |
| Won the hole | Score box numeral in `--win`. |

## The `stroking` chip — a locked rule

The chip reads **`stroking`**, in `--amber` on `rgba(176,122,34,.12)` with a `rgba(176,122,34,.34)` hairline, radius 8.

It appears **only on the holes where that golfer actually gets a stroke** — never as a running allocation total ("gets 3"). A golfer with no stroke on the hole in play has no chip. The stroke dots above his score box (`4px` circles in `--under`) say the same thing; the chip and the dots are one fact stated twice, and neither appears anywhere else. A total allocation belongs on the setup screen.

## Interactions

- Tapping a player row makes it active and shows the picker beneath it.
- Tapping a picker option writes the score, closes the picker, and advances to the next player who is still posting (including Zombies).
- Once every score is in, the outcome strip appears and Next becomes the primary path.
- Next / Previous move by hole. Entering the first hole of a new Survivor resets the banner and the rail.
- The note is a native disclosure — no animation beyond the caret's `.15s` rotation.

## State needed

`holeInPlay`, `players[] {name, handicapStrokes[], scores[], status: alive|out|zombie}`, `currentSurvivor {index, startHole, endHole|null, pot}`, `activePlayerId`, `zombieOption`, `zombieSeatHolder`.

---

# Screen 2 — Survivor leaderboard (`leaderboard-survivor.html`)

## Purpose

The round summary. Two tabs: the game itself, and the money.

## Layout

Same phone frame and app bar. Inside one card:

1. **Card header** — "Survivor", a `🧟 Zombie` chip when the option is on, "Strokes Off", "Through 8".
2. **Segmented control** — `Survivors` / `Standings`, `flex`, `1.5px solid var(--pine)` ring, radius 999, `8px 0` per side, 12.5px/600. Active side filled pine with white text. *Reuse the project's existing `.seg` component; the leaderboard names it `.gseg` locally only to avoid colliding with the rail's own `.seg` class.*
3. **Pane: Survivors** — the R5 rail, then a 10px gap band in `--surface` with a top hairline, then the by-hole grid.
4. **Pane: Standings** — a "Standings" heading, one row per player (name, handicap note, trophy count, money), then a line noting the figures are *settled rather than projected* — nobody is paid until a Survivor closes.

Survivors is the default pane: the rail carries the story, the money is one tap away.

## The Survivor rail (R5)

The rail appears on both the play screen and the leaderboard, and it is the primary artefact of this design. Two stacked parts over one shared hole ruler:

**Top: the winner bar.** One bar per Survivor, spanning exactly the holes that Survivor covered. Fill `#DFF0E2` on a `1px solid #7CC48A` border, radius 6, `26px` tall, containing the winner's name (11.5px/700, `#1B5E20`) and the pot (9.5px/600 `--win`, `opacity:.85`). The Survivor still running is an `idle` bar: `#F1F5F1`, `1px dashed #C3D0C6`, `--muted`, reading `IN PLAY`.

**Bottom: survival lanes.** One row per golfer, one cell per hole, `15px` tall, radius 3:

| Lane cell | Value | Meaning |
|---|---|---|
| `alive` | `#E4EDE6` | survived the hole |
| `won` | `#DFF0E2` + `1px solid #7CC48A` | took that Survivor |
| `knock` | `#FADBDB` + `1px solid #E39494` | eliminated on this hole |
| `gone` | transparent | after elimination, ordinary Survivor |
| `zomb` | `color-mix(in srgb, var(--zombie) 20%, #fff)` + `1px solid var(--zombie)` | **first man out of the round — Zombieville opens** |
| `zback` | `color-mix(in srgb, var(--zombie) 9%, #fff)` + `1px solid color-mix(in srgb, var(--zombie) 45%, #fff)` | came back in from Zombieville |
| `np` | `repeating-linear-gradient(135deg,#F4F7F4 0 3px,#EAEFEB 3px 6px)` | hole not played yet |

Row labels are 10.5px/700 `--deepPine`; the first man out gets `--zombie`.

Grid: `grid-template-columns: 30px repeat(9, 1fr)`, `gap: 2px`. Ruler above in 9.5px/600 `--muted`.

**Why this shape.** The bar's *length* answers how long a Survivor ran and its *label* answers who took it; the lanes answer how long each golfer lasted. Earlier drafts spent a row per golfer and never drew the game itself, or drew the game and flattened the golfers into initials. Four rows carry both readings.

A legend sits beneath: took the hole · out · first out — Zombieville · back in.

## The by-hole grid

A scrolling table, holes across the top, players down the side, net score in each cell, plus an italic pine `svrow` marking Survivor boundaries. Cell marks:

| Class | Treatment | Meaning |
|---|---|---|
| `gwin` | `--win` on `rgba(56,142,60,.13)` | took the hole |
| `gout` | `--out` on `rgba(198,40,40,.13)` | went out |
| `gzom` | `--zombie` on `rgba(110,75,142,.15)` | back in from Zombieville |
| `gz1` | `--zombie` on `rgba(110,75,142,.28)` + `inset 0 0 0 1px var(--zombie)` | **first out of the round** |

`gz1` and the rail's `zomb` are the same fact in two blocks and must agree. `td.lbl` is sticky-left on the card background.

Legend: `green = won it · red = out · solid plum = first out, Zombieville opens · pale plum = back in`.

The screen's closing note names the man who opened Zombieville — that sentence is what reconciles the rail against the grid.

---

# Screen 3 — Live activities (`live-activity-survivor.html`, `live-activity-survivor-zombie.html`)

## Purpose

Survivor is the strongest case for a live activity in the whole app: **you can be knocked out by a shot you did not see.** Three golfers play one hole; the moment the last card is in, one of them is out of the Survivor and out of the money on it. Nothing about that is visible to a man walking to his ball. The card carries news, not arithmetic.

## The card frame — six slots, in order

Both files follow the project's locked live-activity frame. Build only the `.la` element; iOS supplies everything around it.

Card: `border-radius: 24px`, `background: rgba(255,255,255,.13)`, `backdrop-filter: blur(20px)`, `border: .5px solid rgba(255,255,255,.14)`, padding `13px 15px 14px`.

| Slot | Content | Style |
|---|---|---|
| **Header** | Mint mark (17px, radius 5, `#06231A` glyph), game name — `SURVIVOR` or `SURVIVOR · ZOMBIE` — then the locked corner | name 11.5px/700 `letter-spacing:.3px`, `nowrap` |
| **Upper right (LOCKED)** | `HOLE 13 · PAR 4 · 412` | 10.5px/600, `opacity:.62`, `nowrap`, `margin-left:auto` |
| **Who** | The reader, named | 9.5px/700 `letter-spacing:.5px` `opacity:.52` |
| **Headline** | A word, not a number — see below | 36px/700 Schibsted, mint |
| **State** | Two lines, right-aligned: standing over qualifier | 17px/700 over 9px/700 `opacity:.55` |
| **Sides** | Who is in, who is out | 12.5px, `.lead` full weight / `.dim` `opacity:.6` |
| **Track** | The current Survivor — see below | |
| **Footer + lower right (LOCKED)** | Stake terms (`opacity:.6`), money (`.mny`, full opacity), then `THRU 12 · +7` | `.par b` is 14px/700 Schibsted |

### Locked rule 1 — upper right

Always `HOLE n · PAR n · yardage`, in that order. **The yardage is from the tee that golfer is playing**, not the card's scratch tee, so two players in the same group can see different numbers on the same hole. The slot is not available to anything else; a game segment belongs beside the game name on the left. The one exception is round complete, where the slot reads `ROUND COMPLETE`.

It is always **the reader's own hole**, never a hole being watched.

### Locked rule 2 — lower right

Always `THRU n · <gross to par>`. Thru is the last hole **finished**, which is why it trails the hole in play above it by one. The figure beside it is the round against **gross** par — not net, not the game's own unit.

The two corners read as a pair: upper right is the hole you are standing on, lower right is the round behind you.

Rule 2 **survives the always-on state**, where the stake half of the footer goes and this half stays. Both slots carry `white-space: nowrap` and neither may wrap or give way; any header chip yields to them.

### Money

Never a `$0`. The slot is empty until the first Survivor closes. Each Survivor is its own pot, so money lands two or three times a round rather than once at the end. At three players and $5 a Survivor, a win is `+$10` and a loss is `−$5`, so the figure only moves in those steps and never falls back.

Footer opacity is applied to the **stake terms only** (`.foot > span { opacity:.6 }`), with the money a full-opacity sibling — do not nest them, which multiplies the fade.

### The stroke ribbon

When the reader gets a stroke on the hole in play, a gold ribbon runs across the **top** of the card, reading `POPPING ON HOLE 13`.

```
margin: -13px -15px 11px;  padding: 5px 15px 6px;
border-radius: 24px 24px 0 0;
background: linear-gradient(180deg,#E9C063 0%,#D9A63F 100%);
color: #3A2703;  font: 700 9.5px/1;  letter-spacing: .5px;
```

It must be the **first child of the card** — placed after the header, its negative top margin pulls it over the header instead of filling the card's top edge. Gold appears nowhere else in the system, so the ribbon cannot be mistaken for a state. Running states only: the always-on state drops it, and a watcher never has one.

## The headline is a word

Every other game's card opens with a value, because every other game is measured in something — holes, points, skins, dollars. Survivor is measured in **whether you are still in it**, and that is a word.

| Game | Words |
|---|---|
| Survivor | `ALIVE` (mint) · `OUT` (orange) |
| Survivor Zombie | `ALIVE` (mint) · `ZOMBIE` (plum) · `BACK IN` (mint) |

In a Zombie round `OUT` is never used — nobody is out while the Survivor runs; they are in the seat.

`BACK IN` is the only headline in the set that reports an **event** rather than a standing state. It holds for one hole and then reverts to `ALIVE`.

The headline is the reader's own state and nothing else. A count of survivors is a group fact and belongs in the state slot.

## The state slot

| Situation | Slot |
|---|---|
| Reader alive, plain | `3 IN` / `SURVIVOR 2` |
| Reader out, plain | `2 PLAYING` / `FOR SURVIVOR 2` — he is no longer one of them |
| Down to two | `2 IN` / `SAM IS OUT` |
| Reader in the seat | `LOW GETS` / `YOU BACK IN` |
| Reader returns | `2 IN` / `SAM TO ZOMBIEVILLE` |
| Someone else in the seat | `2 IN` / `SAM IS THE ZOMBIE` |
| Round complete | finished gross over `PAR 72` |

`LOW GETS / YOU BACK IN` states the rule, not a probability — it is not a forecast, and it is the only actionable line on any card in the set. A return names who paid for it; a return that did not would read as a gift.

## The track

A grid scoped to **the Survivor being played** — not the round. One row per golfer, one cell per hole, hole numbers across the top tying it to the locked corner above.

```
grid-template-columns: 34px repeat(n, 1fr);
column-gap: 3px;  row-gap: 3px;
cell height 11px;  border-radius 3px;
ruler + row label: 9.5px / 700, opacity .55  (reader's row .95)
```

| Cell | Value | Meaning |
|---|---|---|
| default | `rgba(255,255,255,.17)` | survived the hole |
| `now` | `rgba(255,255,255,.34)` + `inset 0 0 0 1px rgba(255,255,255,.55)` | the hole in play |
| `fut` | transparent + `inset 0 0 0 1px rgba(255,255,255,.12)` | not reached yet |
| `out` | `--orange` | went out here (plain Survivor only) |
| `gone` | transparent | after elimination |
| `zom` | `#C9A6E8` | the hole that sent him to the seat |
| `zplay` | transparent + `inset 0 0 0 1px #C9A6E8` | a hole played from the seat |
| `back` | `#fff` + `inset 0 0 0 1px rgba(255,255,255,.9)` | **came back in** |

The reader's row is marked by the brighter **name**, not a colour — the accent belongs to the headline.

**Why scoped to one Survivor.** A round-length track is the leaderboard's job, where all the Survivors sit side by side. On a lock screen the only Survivor that can still cost you money is the one you are in. Two-hole Survivors need no picture at all; a five-hole Survivor is the case the track exists for, because it has usually changed hands and no single sentence can reconstruct that. **Five cells is the practical ceiling** at this width — beyond that the cells fall under 40px and the ruler crowds, and the card should say *how many* holes rather than draw them.

**Why a Zombie needs two extra states.** Plain Survivor empties a golfer's row after he goes out. Here it cannot, because a Zombie is still hitting shots — that is the entire mechanic. Solid plum is the hole that sent him there, plum outline is every hole he plays from the seat, and read together they answer what the headline cannot: how many swings he has had at getting out of it.

**Why a return is white, not green.** Mint is the reader's colour on this card — `ALIVE`, `BACK IN`, his own good news. A return lands on whichever row it happened to, so mint would mean the reader's good fortune on one row and his opponent's on the next. White says *the round turned here* and leaves who it turned for to the row it sits in. It is the brightest mark on the track and the only one that is not a shade of something else.

## States to build

Both files draw these:

1. **Running** — reader alive, everyone in.
2. **Out** (plain) / **In the seat** (Zombie) — the eliminated view. Plain Survivor's count changes person; Zombie's slot carries the offer.
3. **Down to two** (plain) / **Back in** (Zombie) — plus one card showing someone else in the seat.
4. **Long Survivor** (Zombie only) — five holes, seat changed hands once.
5. **Always-on** — `filter: brightness(.74) saturate(.82)` on the device; card is `rgba(10,22,18,.55)` on `rgba(255,255,255,.1)`, padding `12px 15px`, headline drops to 22px, sides line to 12px at `opacity:.6`, track and stake terms dropped, **locked lower-right retained**.
6. **No stake** — a normal-brightness card whose sides line reads "Playing for nothing" and whose footer carries only the locked corner. Never a `$0`.
7. **Round complete** — money becomes the headline at 42px mint, finished gross takes the state slot at 34px over `PAR 72`, sides line names the result and who to settle with, footer reads "Dismisses in 5 min" plus `THRU 18 · +11`.

## Dynamic Island

**Compact** — mark, headline word, one qualifier. `alive · 3 in`, `out · 2 playing`, `zombie · low gets you in`, `back in · 2 in`. This is the one card in the set whose compact state reads as a sentence, which is what a glance at Survivor is for. For a Zombie, compact keeps the **offer** rather than the count, because for him the offer *is* the state — the only compact island in the set carrying an instruction.

**Expanded** — top line `SURVIVOR · PAUL LIPKIN` with the locked hole slot right-aligned; below it the headline word at 29px mint (plum for `ZOMBIE`), a two-line context block (`thru 7 · $5 a Survivor` over the sides line at `opacity:.6`), and the state on the right.

## Pushes

| Event | Push? | Why |
|---|---|---|
| Out | Yes | The reader lost money on a hole he may not have seen finish. |
| Survivor won | Yes | A pot closed in his favour. |
| Down to two | Yes | The next hole can end it. |
| To Zombieville | Yes | The moment the offer opens. |
| Back in | Yes — the loudest in the set | |
| Zombie wins it | Yes | It kills that Survivor's pot; everyone needs to know. |
| New Survivor | No | He is standing on the tee it starts from. |
| Still the Zombie | No | Nothing changed. |

The test throughout: **could the reader have known this from the hole he is standing on?** If yes, no push.

---

# Cross-cutting rules

These hold across all three surfaces and are worth encoding once:

1. **Never a `$0`.** Money that has not resolved leaves the slot empty rather than printing nothing owed.
2. **No forecasts.** Projected finishes, needed-to-win figures and pace-against-par are all out. Gross-to-par is not a forecast — it is the round already played.
3. **Gaps and money agree in sign.**
4. **One accent per card**, on the reader's own figure. Survivor's plum is a bounded exception: mint for alive, plum for the seat, and orange never appears in a Zombie round.
5. **Plum means Zombieville** on every surface, at two strengths — strong is going in, pale is coming back.
6. **Purple tracks who *opened* the seat**, currently, not who occupies it. This is a live tension worth a decision: the play-screen banners talk about who *holds* the seat right now while the colour marks who opened it. If you'd rather the colour follow the current occupant, that is a one-place change in the rail and the grid.
7. **Locked corners never wrap** and never yield to another element.

## Open questions

Carried forward, unresolved in the design:

- **A Survivor that reaches the 18th unresolved.** No blood, nothing carried. No state exists for it, and the final card must not read like a loss.
- **A Zombie winning on the 18th.** The rule kills that Survivor's pot. Money going to nobody has no treatment yet.
- **Two men in Zombieville.** Larger groups can send more than one. The seat is drawn as singular everywhere — headline word, handover line, plum square.
- **Groups larger than four.** The sides line naming everyone is the ceiling. Five or more wants a count and no names, which changes the card's character.

## Assets

No image assets. The Halved mark is rendered as a rounded square containing the letter `H` in Schibsted Grotesk 700 — mint fill, `#06231A` glyph. Fonts load from Google Fonts; substitute the codebase's own if these are already licensed there.

## Files

| File | Contains |
|---|---|
| `survivor-play.html` | Score entry: phase banner, hole header, player rows with all four states, score picker, outcome strip, R5 rail, by-hole grid, money row |
| `leaderboard-survivor.html` | Leaderboard: segmented control, Survivors pane (rail + grid), Standings pane |
| `live-activity-survivor.html` | Plain Survivor: five lock-screen states, compact and expanded island, full design argument |
| `live-activity-survivor-zombie.html` | Zombie: six lock-screen states including the five-hole Survivor, compact and expanded island, full design argument |
| `survivor-setup.html` | Context: handicap allocation, stake, Zombie toggle |

Each file opens standalone in a browser. The written notes beside the phones are the behavioural spec — read them alongside this README.

## Screenshots

In `screenshots/`, for the two surfaces where the scroll position matters:

| File | Shows |
|---|---|
| `01-survivor-score-entry.png` | Top of the score-entry screen — phase banner, hole header, player rows, active row with picker |
| `02-survivor-score-entry.png` | Scrolled — outcome strip, R5 rail, by-hole grid, money row |
| `01-survivor-leaderboard.png` | Survivors pane — rail, gap band, by-hole grid |
| `02-survivor-leaderboard.png` | Standings pane — the second tab |

The live-activity states are all visible at once in their own HTML files, so they are not captured separately.
