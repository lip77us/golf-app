# Halved — Brand Guidelines

> The wagering companion that tracks every game on your round and tells you who owes whom.

**Living document · v1.0 · Updated Jul 2026 · Reference for Claude Design**

---

## 01 — Foundation

| | |
|---|---|
| **Name** | Halved |
| **Tagline** | "Money won is twice as sweet as money earned." |
| **Personality** | Trustworthy, precise, quietly witty. Fintech-grade calm with a spark of fun at the settlement moment. |
| **Positioning** | Every game, every group, one honest settlement — no math, no arguments. |

### Voice — do / don't

**Say**
- "Settle up"
- "You've picked 1 so far"
- "Simplest way to settle"
- Plain, confident, short

**Don't**
- "Cash out" / "Payout"
- "Error: invalid player count"
- Gambling / hype language
- Slot-machine excitement

---

## 02 — Color

Core palette. The app runs on a **light sage surface** (not cream) with pine for structure; **bright mint is reserved for CTAs, live states, and the hole** — never decoration.

| Swatch | Name | Hex | Usage |
|---|---|---|---|
| ⬛ | Deep pine | `#0B1F1A` | Text · dark tile |
| 🟩 | Pine green | `#0F6E56` | Primary · structure |
| 🟩 | Mint | `#1D9E75` | Accent |
| 🟩 | Bright mint | `#3BD89A` | CTA · live · hole |
| ⬜ | App surface | `#EEF3EE` | Light sage background |
| ⬜ | Card | `#FFFFFF` | Card fill · border `#D3DED6` |
| ⬛ | Muted | `#5C6B62` | Secondary text |
| ⬜ | Cream | `#F3F1EA` | Text/mark on dark |
| ⬛ | Ink | `#06120E` | Deepest shadow |

### Surface strategy

Everyday screens use the light sage surface. The **dark-tile (deep pine) variant is reserved for signature moments** — the settlement receipt — where cream text and mint accents make it feel like a keepsake.

### Semantic & team colors

| Role | Hex | Notes |
|---|---|---|
| Collect / win | `#3BD89A` | |
| Owe | `#F0916E` | Provisional |
| Warning | `#B24225` | On `#F7E4DD` |
| Team A | `#2F6FD6` | |
| Team B | `#D9781C` | |

> Owe and warning hues are provisional — flagged for a final accessibility (WCAG AA) pass before locking.

---

## 03 — Typography

| Role | Face | Size · Weight |
|---|---|---|
| Screen title | Schibsted Grotesk | 19–21 / 600 |
| Section head | Schibsted Grotesk | 22 / 600 |
| Body | Spline Sans | 15–16 / 400–500 |
| Caption / label | Spline Sans | 12–13 / 500–600 |

- **Display / headings** — Schibsted Grotesk. Geometric grotesk, medium–bold. Headings, titles, numbers of note.
- **Body** — Spline Sans. Humanist sans. Body copy, labels, controls.
- **Tabular figures are mandatory** for money, scores, yardage, and index (`font-variant-numeric: tabular-nums`). Example: `$14 · +$18 · −$10 · CH 47 · 5778y · Index 11.1`

---

## 04 — Logo & mark

The mark is a **pin-in-hole**: a pennant flag on a pole rising from a mint hole/putting line.

**Variants**
- **Light tile** — pine mark on light sage.
- **Dark tile** — cream mark on deep pine.
- **Badge tile** — small mark in a rounded deep-pine tile for player rows and nav.

**Do**
- Keep the mint hole at the base
- Use it in nav, empty states, the FAB, and as a player badge
- Preserve crossbar-height clear space

**Don't**
- Clip the pennant or thin the crossbar
- Recolor the hole away from mint
- Add shadows/effects or stretch

---

## 05 — UI components

### Buttons
- **Primary / CTA** — bright mint (`#3BD89A`) fill, deep-pine text, radius 14–16.
- **Secondary** — pine outline (1.5px `#0F6E56`), pine text.
- **Ghost link** — pine text, no border.
- **Disabled** — `#D3DAD5` fill, `#93A099` text.

Rules: **one bright-mint CTA per screen**; everything else is pine outline or ghost. Nav/stepper actions use solid pine, not mint.

### Cards, chips & controls
- **Cards** — white, 1.5px `#D3DED6` border, radius 16–18.
- **Selected chip / segment** — pine fill (structural), never mint.
- **Unselected chip** — white, `#D3DED6` border.
- **Live / in-progress** — sage pill with a pulsing bright-mint dot.
- **Toggle (on)** — pine fill.

### The settlement receipt — signature moment
Deep-pine tile, cream text, mint figures, perforated edge with side notches, and tabular money. It closes with a **rotating golf quip** — one line pulled at random from `golf-sayings.js` every time the receipt is shown, so no two settlements read the same. (The brand tagline stays reserved for brand-level use; the receipt is where the wit lives.) This is the one place the dark variant lives inside the app.

---

## 06 — Motion

Reserve animation for genuinely live moments — a hole halved, a press won, the final settlement reveal. **Dollar figures never animate** — they settle in calmly, not like a slot machine. Everything else is quiet: 150–250ms ease, subtle scale/opacity only.

---

## 07 — Applications built

The reference implementation covers the full **create → play → settle** flow, all in this system:

- Casual Rounds list & empty state · Course & Game setup
- Players (with H-mark badges) · Set Tees
- Round home · Live scoring with team identity & Nassau progress
- Settlement receipt (the shareable, signature asset)

**Files**
- `Halved App.dc.html` — working screens
- `Halved Brand Guidelines.dc.html` — printable version of this doc
- `golf-sayings.js` — settlement quip repository (extensible)

**Open items for next session:** final font licensing, WCAG AA pass on semantic colors, and locking the shareable-receipt export layout.
