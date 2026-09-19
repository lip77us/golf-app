# Halved 2.9.1 (builds 39–40) — Release notes

Version in `mobile/pubspec.yaml` → `2.9.1+40`. Previous public: `2.9.0+37`.
**Build 38 was never distributed** — it was replaced by 39 before it went out.
**Build 39 went out and the lock screens came back on a real phone.**

## Build 40 — the `&M` in "3&2", and one of them was points

**Three cards printed the wrong close-out margin on a shotgun, and one service
awarded the wrong cup points.** The `M` in "3&2" is holes LEFT, counted along
the group's own play order — and the clients were computing it by subtracting a
hole number. Off a shotgun on the 10th, a match clinched on hole 1 has eight
holes left; the card said "10&17".

- **Fourball** — the score-entry card and the leaderboard card. The engine had
  computed the right number all along and simply never put it on the payload.
- **Cup singles and Triple Cup** — the same sum in five more places, including
  the per-nine chips, where `9 - hole` and `18 - hole` are both wrong: a back
  nine begun on the 13th runs 13..18 then 10, 11, 12.
- **A Triple Cup segment can WRAP.** A third off the 8th is holes 14..1, where
  the last hole has the smallest number. Every "did it finish early?" test of
  the form `finished_on_hole < end_hole` — "17 < 1" — answered no, so the `&M`
  silently vanished and the card claimed the match ran to its scheduled end.
- **`services/ryder_cup.py` awards cup POINTS** from the same helper and was
  calling it without the play order. A leg went dormie a hole early: closed on
  16 with two left, when five of nine had been played with four to go. This is
  a scoreboard, not a label.
- **A margin read from a hole played nine holes ago.** Hole rows order by hole
  NUMBER in the model's Meta, so `rows[-1]` is the highest number and not the
  last hole played. A group that had turned showed a stale margin.

Every card now reads a `holes_to_play` field that the server counts. The two
Dart helpers that took an `endHole` argument solely to compute
`endHole - finishedOn` take the count instead, so the wrong sum is no longer
expressible at those call sites.

### Sixes — the slot machine stops interrupting the back nine

**Reopening a sixes round popped the Segment-2 draw on the 13th**, and
dismissing it sent the card back to the 7th to announce partners the group had
been playing with for six holes.

The spinner never changed anything: all three pairings are created at setup and
the draw screen's result is discarded. It is a REVEAL, which is exactly why its
timing is the whole feature. It fired off a device-local "have I shown this?"
flag — lost on a reinstall or a second phone — instead of the fact the payload
already carried: whether the group has played on. Now it needs Segment 1
settled, both pairings assigned, and no scored hole in Segment 2 or 3.

**No migration.** Build 40 is summary and display code plus one points fix;
nothing changed shape in the database.

---

## Build 39 — the lock screens come back

**2.9.0 turned off every lock screen, and nothing said so.** A single field in
the widget's shared contract — `var closed: Bool = false` — was added with the
new cards. Swift's synthesized decoder IGNORES a default value, so that is a
REQUIRED key, and no card sends it except the five closing frames. Every other
payload failed to decode.

The failure is invisible from every side: APNs accepts the push and reports
success, the server records the start as sent, the phone cannot decode the
content-state, and iOS drops it. No card, no error, and the server's own
records say it worked.

Five more fields had the same shape and would each have taken down the cards
that omit them. All six are Optional now, which is what the rest of the struct
already did.

Build 38 also carried a keyboard fix that did not survive the app's own widget
nesting — the Done bar was still covering the round-chat message field. It now
reserves its row in the layout instead, which nothing nested below can undo.

---

**A fix release, and all of it came out of one round.** Six commits: three
things reported from a tournament at Ranch Solano on 17 September, one
regression they exposed, the client half of flights, and a sweep for the
pattern behind the reported bugs.

One migration, additive: `games/0080` (the Sixes handicap-allocation default).
It applies automatically — `railway.toml`'s start command runs
`migrate --noinput` before gunicorn.

**Nothing is gated.** `UNSHIPPED_KINDS` has been empty since 2.9.0, so this
build carries no card that the server is waiting on.

**No `CLIENT_MIN_VERSION` bump.** It stays at `2.1.0`.

---

## The regression this fixes, and it is worth knowing about

**2.9.0's keyboard fix covered the message field.** The global Done bar added
in 2.9.0 drew a 44pt strip at exactly the keyboard's top edge — which is
exactly where a screen that PINS content to the keyboard puts that content. On
a form you scroll, so it only ever covered chrome and nobody noticed. The round
chat composer is pinned there by construction, so a golfer could type a reply
he could not read.

The bar now occupies its row rather than stealing it: the wrapper reports a
bottom inset 44 larger, every Scaffold resizes to leave the row free, and the
bar fills it. It was also covering the Save rows on Points 5-3-1 and Skins
setup — a control added to stop buttons being hidden was hiding buttons.

## Shotgun rounds — six fixes, one mistake

Three shotgun bugs turned up in a single round, so the rest were found by
sweeping for the pattern rather than by waiting. The play-order helpers are
correct; the code that SUMMARISES or SCORES a round kept reaching for the hole
NUMBER where it meant position in play order. On a round starting at the 1st
those are the same integer, which is why it survived.

- **"Through 18" six holes into a shotgun** — on the rounds list and on the
  share card. A round that looks finished.
- **Las Vegas lost a carried tie across the wrap.** The chips were ordered by
  play order and the carry was not, so the display half was right and the money
  half was wrong.
- **Cup singles scored nothing for its first six holes**, then scored the back
  of the round while ignoring them — and separately reported a match closed out
  that was not: six straight wins from the 13th read "4 up, finished on 16",
  because 18 − 16 = 2 while fourteen holes remained. **A cup point decided that
  was not.**
- **Quota Nassau** had the same walk, plus a quota pro-rated by hole number, so
  six holes ending on the 18th demanded 18/18 of it.

Cup singles and Quota Nassau are cup formats and a cup day is very often a
shotgun — those two had no test file at all. Both do now.

## Score entry

**"4 scores to go" now names its hole.** It counts PLAYERS still to score on
the hole in front of you, and with one or two missing it says "Waiting on Sam
and Dave" — unambiguous. The bare count dropped the only word saying what it
counted, and a golfer near the end of a shotgun read it as holes.

## New round

**Advanced moves under the course, above Games.** The starting hole sat at the
bottom of the step, below Games and below Side games, so a group playing no
side game never scrolled to it. Above Games is also the right order: the hole
count is what hides Nassau, Sixes, Triple Cup and the match brackets, so the
list now arrives already filtered instead of quietly dropping a chip.

## Sixes

**Handicap allocation defaults to Straight up (round-wide).** Per-segment was
the original rule and it surprises people: a golfer's strokes are re-spread
over each six-hole match, so where he gets them moves with the segment bounds
rather than following the stroke index on the card in his hand. Existing games
keep whatever they were created with; per-segment is still selectable.

## Flights — the client half

Real flight headers with each flight's own purse, the INDEX the cut was made on
in place of playing handicap on a flighted board, a `NOT PAID` marker for a
golfer who is ranked but excluded, and the `A · Paul L` name prefix deleted.

**The TD can now cut flights from the app** — count, live preview of the split,
naming whose index is a guess, on both championship setup screens. It is not in
the new-round wizard, which runs before the tournament exists and before
pairings are final; equal-sized flights are sized off the whole field, so the
cut has to happen once the field is.
