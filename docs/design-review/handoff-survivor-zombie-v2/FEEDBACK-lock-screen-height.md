# The Survivor card is taller than iOS allows

Feedback on `live-activity-survivor-zombie.html`, raised from a live round on
4 September 2026 (builds 27–30).

---

## The constraint

The lock-screen Live Activity presentation is capped at roughly **160 points**
tall. Past that iOS **clips** — it does not scale the card down or reflow it.

More precisely, and this took three builds to establish: iOS **centres** the
content in a fixed-height window and trims **both ends**. On the last build the
header was cut off the top and the footer off the bottom simultaneously.

That has a consequence worth stating plainly, because it defeated two attempted
fixes: SwiftUI's `layoutPriority` cannot rescue a row that is simply past the
edge. There is no graceful degradation to lean on. The card either fits or
parts of it are invisible.

---

## What we observed, in order

Every field discussed here was verified present and correct in the server
payload **before** any layout was touched. None of this was a data bug.

1. **Both locked corners vanished.** The header (`SURVIVOR · ZOMBIE` /
   `HOLE 9 · PAR 4 · 353`) and the footer (`$5 a Survivor` / `THRU 8 · +5`)
   drew nothing at all.

2. **Pinning them brought the header back and nothing else.** The footer and
   the gold `POPPING ON HOLE 9` band were still missing.

3. **The bottom lane of the track was sliced mid-row**, and on the following
   build the card clipped at both ends at once — the header above and
   `Playing for nothing / THRU 1 · 1` below.

---

## Where the height goes

Estimated from the packet's own type scale, so treat the arithmetic as
directional. The clipping is not an estimate.

| Slot | Approx. |
| --- | ---: |
| Gold band (`POPPING ON HOLE n`) | 22 |
| Header — game name + locked hole corner | 14 |
| Who — the reader, named | 12 |
| Headline — 36px word | 34 |
| Sides — two rows | 32 |
| Track — ruler + three lanes | 51 |
| Footer — stake, money, locked `THRU` corner | 17 |
| Card padding + inter-block gaps | ~67 |
| **Total** | **~249** |
| **Budget** | **~160** |

Roughly **50% over**, and higher still when the gold band is showing.

---

## What shipped, and what it cost

To get every slot on screen: headline **36 → 22**, track cells **11 → 6**,
stack spacing **7 → 3**, who-line **9.5 → 9**.

The card also now uses SwiftUI's `ViewThatFits` to offer iOS two compositions —
the full card, and the same card **without the track** — and lets it choose.
The track is what gives way, on the packet's own reasoning that *"a long
Survivor should say how many holes rather than draw them"*. What never gives
way is the footer, because that is where the money and the locked `THRU` corner
live.

The price: the card's most distinctive element — the single word that *is* the
Survivor headline — is now materially smaller than drawn. That was the
least-bad call available mid-round, not a recommendation.

---

## The decision we need from design

**The 36px headline and the three-lane track do not both fit. Which do you
protect?**

**Option A — keep the headline, move the track.** Restore the word to 36px and
drop the track from the lock screen, keeping it in the expanded Dynamic Island
where there is room and no footer competing for the row. The packet already
half-concedes this. *This is the one we'd suggest.*

**Option B — keep the track, ratify a smaller word.** Make ~22px the real
specification and re-draw the card around it, rather than leaving the built
card silently off-spec.

---

## This is not only Survivor's problem

**The two locked corners cost every card in the set roughly 26 points**, and
they are going system-wide. Sixes, Nassau, Skins and Rabbit each gain a header
row and a footer row they do not have today.

Those four are simpler and have more headroom, but **none has been measured
against the ceiling**. Worth checking them before the sweep rather than
discovering it one phone at a time, which is how we found this.
