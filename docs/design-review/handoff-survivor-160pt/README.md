# Handoff: Survivor Live Activity — fitting the 160pt lock-screen ceiling

## Overview

The Survivor and Survivor Zombie lock-screen Live Activities are over the iOS
lock-screen height limit and are being clipped on real devices. This package
specifies the layout that fits, documents the measurements behind it, and
defines two rules that came out of the work (a three-column track minimum and a
`TEE OFF` footer state).

It supersedes the card geometry in `design_handoff_survivor_zombie/` — the
content model, vocabulary, colour logic and push rules in that package are all
still current and are **not** repeated here. Read this one for **height and
layout**; read that one for **what the card says**.

## About the Design Files

The files in this bundle are **design references created in HTML** — prototypes
showing intended look and behaviour, not production code to copy directly. The
task is to recreate them in the target codebase's environment. For this feature
that means **SwiftUI + ActivityKit**, since Live Activities are iOS-only and
have no web equivalent. Treat the HTML as a specification of geometry, type and
colour, not as markup to port.

`live-activity-survivor-160.html` is the **argument**, not a screen. It is a
side-by-side measurement document explaining why the layout changed. Implement
from the "Protect the word" column and from the spec below.

## Fidelity

**High-fidelity.** Colours, type sizes, spacing and slot heights are final and
measured. The heights in this document were read off the built cards with
`getBoundingClientRect`, not estimated — build to them.

One caveat: the CSS pixel values here are treated as **points** 1:1. That
mapping held on the device we tested (iPhone, 3x). Verify the first build on
hardware against the 160pt cap rather than trusting the arithmetic.

---

## The constraint

The lock-screen Live Activity presentation is capped at approximately **160
points** of height. Past that, **iOS clips — it does not scale the card down or
reflow it.** Layout priority cannot rescue a row that is past the bottom edge.

### What was observed on device

Verified against the live payload first — every field was being sent correctly
in all three cases. None of this was a data bug.

1. **Both locked corners vanished.** The header (`SURVIVOR · ZOMBIE` /
   `HOLE 9 · PAR 4 · 353`) and the footer (`$5 a Survivor` / `THRU 8 · +5`)
   drew nothing at all.
2. **Pinning them brought back the header and nothing else.** The footer and
   the gold `POPPING` ribbon were still missing.
3. **The bottom lane of the track was cut mid-row** — the third golfer's lane
   sliced horizontally. See `screenshots/survivor-zombie-clipped-on-device.png`,
   which shows the ribbon reduced to a sliver, Paul's lane cut, and the footer
   absent, all at once.

### Measured overage

The card as originally drawn measured **~227pt**, or **~247pt** on a ribbon
state, against a ~160pt cap. This was never a shave — it was a block over
budget, which is why pinning the corners could not fix it.

| Slot | Height |
| --- | --- |
| Card padding | 27 |
| Header row (locked hole info) | 28 |
| Footer row (locked THRU) | 25 |
| **Locked chrome subtotal** | **80** |
| Who — the reader's name | 19 |
| Headline word | 34 |
| Sides line | 29 |
| Track (three lanes) | 65 |
| Gold ribbon | 20 |
| **Total as drawn** | **247** |

The locked corners consume 80pt before any Survivor content exists, leaving
~80. The headline block (who + word + sides = 82) spends all of it on its own.
The track is 65.

---

## The finding that decided the layout

**Shrinking the headline word recovers zero height.**

The headline sits in a flex row with the state slot (`2 IN` over
`SAM IS OUT`). That slot measures **34pt** — a 17px line, a 9px line, a 4px
gap and 2px of padding — and it is the tallest item in the row, so it sets the
row's floor.

Measured on the built cards: the headline row is **34pt whether the word is
36px or 26px**. `font-size` on the word changes only the word.

This matters because the emergency fix shipped one morning dropped the headline
36 → 26 to buy height. **It bought none.** It made the card's most distinctive
element smaller for free. Do not repeat that change, and do not treat headline
size as a height lever anywhere in this card family.

The consequence: the track cannot be bought by shrinking type. Its smallest
honest form — 9pt cells, sides line removed, ribbon suppressed — still measures
**167pt**. The only ways to fit a track on the lock screen are to cut the state
count or a locked corner, both of which cost more than moving it.

---

## Screens / Views

### 1. Lock-screen Live Activity — the fitted card

**Purpose.** Tell a golfer walking to his ball that his afternoon just changed:
whether he is still in the Survivor, how many are left, and what it is worth.

**Layout.** A single vertical stack, four rows, no track:

```
┌─────────────────────────────────────────────┐
│ [H] SURVIVOR            HOLE 4 · PAR 3 · 176│  header    26pt
│                                             │
│ ALIVE                                  3 IN │  headline  34pt
│                                   SURVIVOR 2│
│ Nobody out yet · Paul, Dave, Sam            │  sides     27pt
│                                             │
│ $5 a Survivor  +$10           THRU 3     +1 │  footer    24pt
└─────────────────────────────────────────────┘
   padding 12 top / 12 bottom                     padding   24pt
                                                            ────
                                                            135pt
```

**Measured heights.** Build to these.

| State | Height | Headroom under 160 |
| --- | --- | --- |
| Running | **135pt** | 25 |
| Out | **135pt** | 25 |
| Running + gold ribbon | **153pt** | 7 |

The ribbon adds **18pt**. The ribbon state is the tightest in the set — any
future slot addition has 7pt to work with, which is to say none.

**The `who` line is deleted.** The original card spent 19pt printing
`PAUL LIPKIN` on the reader's own lock screen. The sides line already names
people. This is the one cut in the whole exercise with no cost, and it is what
buys the ribbon state its headroom without touching the 36px word.

**The sides line absorbs the group.** Where the old card had a lead phrase and
a separate names line, the fitted card carries both in one 27pt row:
`Nobody out yet · Paul, Dave, Sam` — lead phrase at full opacity, names at 0.6.

#### Slot specification

**Container**
- `border-radius: 24px`
- `background: rgba(255,255,255,0.13)`, `backdrop-filter: blur(20px)`
- `border: 0.5px solid rgba(255,255,255,0.14)`
- `padding: 12px 15px`

**Header row** — 26pt (17px content + 9px bottom margin)
- Flex row, `gap: 7px`, `align-items: center`
- Mark: 17×17px, `border-radius: 5px`, `background: #3BD89A`, glyph `H` in
  Schibsted Grotesk 700 10px, colour `#06231A`
- Game name: Spline Sans 700, 11.5px, `letter-spacing: 0.3px`, `nowrap`
- Hole info: `margin-left: auto`, 10.5px, weight 600, `opacity: 0.62`, `nowrap`
- Format is locked: `HOLE X · PAR Y · ZZZ`. This corner wins any collision with
  game-variant labelling.

**Headline row** — 34pt, set by the state slot, not the word
- Flex row, `align-items: flex-end`, `column-gap: 11px`
- Word: Schibsted Grotesk 700, **36px**, `line-height: 0.94`,
  `letter-spacing: -1px`, `nowrap`. Mint `#3BD89A` for `ALIVE` / `BACK IN`,
  orange `#F3A059` for `OUT`, plum `#C9A6E8` for `ZOMBIE`.
- State slot: `margin-left: auto`, right-aligned, `padding-bottom: 2px`
  - Count: Schibsted Grotesk 700, 17px, `line-height: 1`,
    `letter-spacing: 0.2px`, colour-matched to the headline
  - Qualifier: 9px, weight 700, `letter-spacing: 0.4px`, `opacity: 0.55`,
    `margin-top: 4px`

**Sides row** — 27pt (8px top margin + 19px line)
- Full width, 12.5px, `line-height: 1.5`, `opacity: 0.8`, `nowrap`
- Lead phrase weight 700 at full opacity; trailing names `opacity: 0.6`

**Footer row** — 24pt (9px top margin + 15px line)
- Flex row, `gap: 8px`, 11px
- Stake: `opacity: 0.6`
- Money: weight 600, **full opacity**. Omit the element entirely when there is
  no money yet — never render `$0`.
- Right group: `margin-left: auto`, `align-items: baseline`, `gap: 7px`
  - Label `THRU X`: `opacity: 0.55`, weight 600
  - Gross to par: Schibsted Grotesk 700, 14px, `letter-spacing: -0.3px`,
    **full opacity**
- Format is locked: `THRU X · ±Y`, gross to par.

**Gold ribbon** — +18pt when present
- `margin: -12px -15px 9px` (replaces the container's top padding)
- `padding: 5px 15px`, `border-radius: 24px 24px 0 0`
- `background: linear-gradient(180deg, #E9C063 0%, #D9A63F 100%)`
- Text `#3A2703`, 9.5px, weight 700, `letter-spacing: 0.5px`

### 2. Expanded Dynamic Island — where the track goes

**Purpose.** The per-Survivor hole-by-hole track, at full size, on the surface
that has room for it.

**Why here.** The expanded island has no locked footer competing for the row,
so the track arrives at **11pt cells** — larger than what shipped on the lock
screen during the emergency fix. The design packet already half-conceded this:
*"a long Survivor should say how many holes rather than draw them."*

**Layout.** `background: #000`, `border-radius: 24px`,
`padding: 13px 15px 14px`.

- Top row: mark, `SURVIVOR 2 · PAUL LIPKIN`, hole info right-aligned at
  `opacity: 0.75`. 11px, weight 700, `opacity: 0.6`, `letter-spacing: 0.3px`.
- Mid row: headline word (Schibsted Grotesk 700, 29px, `line-height: 0.95`,
  mint), a two-line 11.5px detail block at `opacity: 0.72`, and the count
  right-aligned (Schibsted Grotesk 700, 17px, `opacity: 0.75`).
- Track: `display: grid`, `grid-template-columns: 36px repeat(N, 1fr)`,
  `column-gap: 3px`, `row-gap: 2px`, `align-items: center`, `margin-top: 12px`.

**Compact states are unchanged** from the previous handoff — the word and the
count, readable as a sentence (*alive, 3 in*).

### 3. Leaderboard and play screens

**No change.** Their tracks are round-length nine-column grids (`g9` / `r9`),
so no lane is ever one cell wide and no height ceiling applies.

---

## The track, and the three-column minimum

One row per golfer, one cell per hole **of the Survivor being played** — not
the round.

### Cell states

| State | Treatment |
| --- | --- |
| Survived the hole | `background: rgba(255,255,255,0.17)` |
| Hole in play | `background: rgba(255,255,255,0.34)`, `inset 0 0 0 1px rgba(255,255,255,0.55)` |
| Not yet reached | transparent, `inset 0 0 0 1px rgba(255,255,255,0.12)` |
| Went out on this hole | `background: #F3A059` |
| After going out | transparent, no border |
| Sent to Zombieville | `background: #C9A6E8` (solid plum) |
| Playing from the seat | transparent, `inset 0 0 0 1px #C9A6E8` |
| Returned | `background: #3BD89A` |

Cell geometry: `height: 11px` (island) or `9px` (compressed contexts),
`border-radius: 2.5–3px`. Name column 34–36px, 9.5px weight 700 at
`opacity: 0.55`; the reader's own row goes to `0.95`. Hole numbers across the
top at 9.5px, weight 700, `opacity: 0.55`, `tabular-nums`.

### Three-column minimum — **new rule**

On the **first hole** of a Survivor there is one cell per lane, so each bar runs
the full width of the card and the track stops reading as a track. It reads as
three progress bars.

**Rule:** hold the grid at a minimum of three columns.
`grid-template-columns: <name> repeat(max(3, holesInSurvivor), 1fr)`.

The current hole draws as *in play*; the holes ahead draw as *not yet reached* —
which is vocabulary the track already has, so this needs no new cell state. Dim
the look-ahead hole numbers to `opacity: 0.28` to distinguish them from real
hole numbers.

Applies to **holes 1 and 2 only**. From three cells the grid grows normally, up
to a practical ceiling of five columns at this width. It **costs no height** —
the same three lanes either way.

---

## Interactions & Behavior

Push behaviour, the money model, the Zombie colour logic and the state
vocabulary are all specified in `design_handoff_survivor_zombie/README.md` and
unchanged. Two additions:

### The `TEE OFF` footer state — **new rule**

Before any hole of the round is complete there is no `THRU` count and no gross
to par. The footer's right corner renders **`TEE OFF`** with no number, styled
as the dim label (`opacity: 0.55`, weight 600) with no bold figure beside it.

Rationale: the locked corner stays occupied without inventing a score, and
`THRU 0 · E` would assert an even-par round that has not been played.

### Ribbon suppression

Do **not** suppress the gold ribbon to gain height. It fits (153pt), and the
states it appears on — the reader stroking on the hole in play — are exactly
where it carries the most information.

---

## State Management

The lock-screen card needs, per update:

| Field | Type | Notes |
| --- | --- | --- |
| `holeNumber`, `par`, `yardage` | Int | Header corner. Always present. |
| `holesComplete` | Int | Footer. `0` triggers `TEE OFF`. |
| `grossToPar` | Int? | Footer. `nil` while `holesComplete == 0`. |
| `readerStatus` | enum | `alive`, `out`, `zombie`, `backIn` — drives the word and its colour. |
| `survivorsRemaining` | Int | State-slot count. |
| `stateQualifier` | String | `SURVIVOR 2`, `SAM IS OUT`, `YOU BACK IN`, `SEAT IS EMPTY`. |
| `leadPhrase` | String | Sides row, full opacity. |
| `groupNames` | [String] | Sides row, dimmed. Ceiling is four golfers. |
| `stakeLabel` | String | `$5 a Survivor`. |
| `runningMoney` | Int? | `nil` before the first Survivor closes — render nothing. |
| `isStroking` | Bool | Gold ribbon. |
| `survivorHoles` | [HoleCell] | Island track only. Apply the three-column minimum at render. |

`backIn` holds for one hole and then reverts to `alive`.

---

## Design Tokens

### Colour

| Token | Hex | Use |
| --- | --- | --- |
| `deepPine` | `#0B1F1A` | Dark surfaces |
| `pine` | `#0F6E56` | Links, section labels |
| `mint` | `#3BD89A` | Alive, back in, returned cell, app mark |
| `orange` | `#F3A059` | Out — headline and the hole a golfer went out on |
| `plum` | `#C9A6E8` | Zombieville, lightened for dark surfaces |
| `markInk` | `#06231A` | Glyph on the mint mark |
| `ribbonFrom` | `#E9C063` | Gold ribbon gradient start |
| `ribbonTo` | `#D9A63F` | Gold ribbon gradient end |
| `ribbonInk` | `#3A2703` | Ribbon text |

Card surfaces are alpha on the wallpaper, not solid colours:
`rgba(255,255,255,0.13)` fill, `rgba(255,255,255,0.14)` hairline. Quiet /
always-on states use `rgba(10,22,18,0.55)` with a `rgba(255,255,255,0.1)`
hairline.

### Opacity scale

`1.0` gross score and locked footer figures · `0.8` sides row · `0.62` header
hole info · `0.6` stake and dimmed names · `0.55` footer labels, track names
and hole numbers · `0.28` look-ahead hole numbers.

### Typography

- **Schibsted Grotesk** 600/700 — numerals and the headline word
- **Spline Sans** 400/500/600/700 — everything else

Scale in use on the card: 36 (headline) · 17 (state count) · 14 (gross) ·
12.5 (sides) · 11.5 (game name) · 11 (footer) · 10.5 (hole info) ·
9.5 (track, ribbon) · 9 (state qualifier).

### Spacing and radii

Vertical rhythm is 9px between rows, 8px above the sides row, 12px container
padding. Radii: 24px card · 24px 24px 0 0 ribbon · 5px app mark ·
2.5–3px track cells.

---

## Assets

No images. The `H` app mark is a text glyph on a mint rounded square. Fonts are
Google Fonts (Schibsted Grotesk, Spline Sans) — use the codebase's existing
font loading. `screenshots/survivor-zombie-clipped-on-device.png` is a device
capture included as evidence of the clipping, not an asset to ship.

### Screenshots

| File | What it shows |
| --- | --- |
| `fitted-01-running-135pt.png` | The fitted running state against the 160pt line, 25pt of headroom. |
| `fitted-02-ribbon-153pt.png` | The gold-ribbon state, 7pt of headroom — the tightest card in the set. |
| `fitted-03-out-135pt.png` | The out state, orange headline and the count re-personed to `2 PLAYING`. |
| `fitted-04-island-track.png` | The track in the expanded island at full 11pt cells. |
| `fitted-05-hole-1-track-minimum.png` | Hole 1 drawn both ways — one full-width cell per lane, then the three-column minimum. |
| `survivor-zombie-clipped-on-device.png` | The clipped card on an iPhone. Evidence, not a target. |

---

## Files

| File | What it is |
| --- | --- |
| `live-activity-survivor-160.html` | The measurement document. Two columns: the layout that fits and the one that does not, both drawn against a 160pt line, with the overage hatched. Read the left column as the spec. |
| `live-activity-survivor.html` | Survivor lock-screen packet — all states including the new hole-1 card. Design rationale in the left-hand notes. |
| `live-activity-survivor-zombie.html` | Survivor Zombie packet — same, plus the seat colour logic. |
| `screenshots/` | Captures of the fitted states, the island track, the hole-1 comparison, and the clipped card on device. Listed under **Assets** above. |

Source lives in `screens/` in the design project. The full content model,
vocabulary and push rules are in `design_handoff_survivor_zombie/README.md`.

---

## Open questions

Carried forward, still unresolved:

1. **A Survivor that reaches 18 unresolved.** No blood, nothing carried. There
   is no card state for it, and the final must not read like a loss.
2. **A Zombie win on 18** kills that Survivor's payment. Money going to nobody
   has no state, and it cannot read like a loss for the winner.
3. **Plum marks whoever opened the seat**, not whoever currently holds it. That
   is literal and permanent today; whether it should track the current occupant
   is undecided.
4. **Groups larger than four.** The sides row is the ceiling. Five or more
   wants a count and no names, which changes the card's character — and its
   height, which now has 7pt of slack on the ribbon state.
