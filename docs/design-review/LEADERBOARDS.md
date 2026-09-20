# Leaderboards — as built

**Ten games, one screen, four different shapes.** This is the umbrella
document. Each game's own `AS-BUILT.md` now carries a `# Leaderboard` section
after its Setup and Play parts; this one is the cross-game read — what they
share, where they drift, and the three findings that are not about any single
game.

Screen: `mobile/lib/screens/leaderboard_screen.dart` (11,374 lines).
Payload: `_build_leaderboard()` in `api/views.py`.
Web: `api/watch_views.py`.

| Game | Key | Card | Web | Lock screen |
|---|---|---|:-:|:-:|
| Las Vegas | `vegas` | `_VegasGroupCard` | ✓ | ✓ |
| Points 5-3-1 | `points_531` | `_Points531GroupCard` | ✓ | ✓ |
| Wolf | `wolf` | `_WolfGroupCard` | ✓ | ✓ |
| Stableford | `stableford` | `_StablefordView` | ✓ | ✓ |
| Fourball | `fourball` | `_FourballGroupCard` | — | ✓ |
| Mini Singles Bracket | `match_play` | `_MatchPlayGroupCard` → `MatchPlayDetailView` | ✓ | — |
| Spots | `spots` | `_SpotsGroupCard` | — | — |
| Singles Match | `match_18` | `_NassauGroupCard` | — | ✓ |
| Honors | `honors` | `_HonorsGroupCard` | — | — |
| Nassau Nine | `nassau_nine` | `_NassauGroupCard` | — | — |

Nothing is gated — `UNSHIPPED_KINDS` is empty, so every registered lock-screen
card ships today.

Mini Singles has two unrelated implementations. The **standalone** one — a
bracket inside one foursome, 2 semis on the front and a final plus consolation
on the back — is the `match_play` game and is what this document covers. The
**tournament** one (`MiniSinglesConfig`, a bracket in every group on day 1 and
a winners' foursome on day 2) is a different object with its own carve-out
economics and does not appear on the round leaderboard at all.

---

## 1. The three findings

> **1 — Three of the ten exist only inside the app.** Spots, Honors and Nassau
> Nine have no web view and no lock-screen card: the only way to see them is to
> open the app and go to the leaderboard. Fourball and Singles Match have no web
> view but do have a lock screen; Mini Singles has the reverse. `api/watch_views.py` has a
> `_has_casual_*` gate for skins, stableford, multi-skins, points 5-3-1,
> nassau, wolf, vegas, triple cup, match play, sixes, pink ball and irish
> rumble — and for nothing else. The watch link is how a group shares a round
> with someone not playing, so a game without one is a game nobody can be shown.
> `_has_casual_nassau` tests the literal string `'nassau'`, which is why the
> two Nassau variants are excluded while the parent is not — that one looks
> like an oversight rather than a decision.

> **2 — Zero money is written three different ways.** Vegas prints `—`, Spots
> prints `$0.00`, Honors prints `+$0.00`. All three are on the same screen in a
> round running all three, and the reader has to work out that they mean the
> same thing. There is no rule; each card made its own call.

> **3 — A tab is built from `active_games`, its contents from the server
> block.** `leaderboard_screen.dart:138` adds a tab for every active game; the
> body then looks up `lb.games[gameKey]` and renders **"No data yet."** when it
> misses. Every game in this set currently builds its block, so nothing is
> broken today — but the failure mode is a permanently empty named tab rather
> than no tab, and it is silent. A new game gets a tab whether or not anyone
> wrote its payload.

---

## 2. Two shapes, and when each is used

**Per-group cards** (`_ByGroupView`) — eight of the ten. The board is a list of
group cards, one per foursome, each headed `Group N`. This is right for a game
settled inside the group: Vegas, Wolf, Points, Spots, Honors, Fourball, the
Nassau family, Mini Singles.

**One whole-round view** — Stableford and Low Net. The field is the unit, so
there are no group cards and the view ranks everybody together.

`group['_single_group'] == true` suppresses the `Group N` header, so a casual
round with one foursome does not label the only group there is. Points, Wolf
and Mini Singles honour it; **Spots, Honors and Vegas do not** and print
`Group 1` on a one-group round.

## 3. What the cards share

| Component | Used by |
|---|---|
| `HoleGridScorecard` — hole / par / SI rows, stroke dots, OUT-IN-TOT | Vegas, Wolf, Stableford, Fourball, Mini Singles |
| A per-hole strip or grid | Vegas, Wolf, Spots, Honors, Fourball, Nassau |
| `GameColors.team1` / `team2` (blue / orange) | Vegas, Fourball, Mini Singles, Nassau |
| `GameColors.win` / `loss` on money | Vegas, Honors |
| Handicap chip (`Gross` / `Net n%` / `SO`) | Points, Wolf, Stableford, Spots, Honors |
| Payout-style chip (`Pool` / `Pay leader` / `vs Average` / `Above you`) | Points, Wolf, Stableford, Spots, Honors |

The handicap-and-payout chip pair is the closest thing to a standard header
this screen has — five games draw it, in the same words, in the same place. It
is worth naming as a component rather than leaving it copied five times.

## 4. Drift worth a rule

| # | Drift | Where |
|---|---|---|
| 1 | Zero money: `—` vs `$0.00` vs `+$0.00` | Vegas / Spots / Honors |
| 2 | `Group 1` on a single-group round | Spots, Honors, Vegas ignore `_single_group` |
| 3 | Money decimals: Vegas is the only card showing cents on points-based money | Vegas `toStringAsFixed(2)` |
| 4 | Status is a raw slug with underscores swapped for spaces — `in progress`, not `In progress` | Spots, Honors, Points, Wolf |
| 5 | Scorecard name column mixes edited short names with initials — `Glenn` above `GL` | Every card using `HoleGridScorecard` |

Number 5 is not a layout bug. `Player.short_name` defaults to the first letters
of the first two words (`core/models.py:336`) and is then editable, so a group
where one golfer's short name was edited and another's was not renders one
first name above one pair of initials. The design system has no rule for which
the scorecard should use, and the card cannot tell the two apart.

## 5. Still open

- **A rule for zero money**, then apply it to all ten (finding 2).
- **Web views for the five that lack them** — Spots, Honors, Fourball, Nassau
  Nine and Singles Match (finding 1) — or a decision that they are app-only,
  which is defensible but should be deliberate. The two Nassau variants are one
  string check away.
- **The handicap + payout chip pair as a named component** (§3).
- **`_single_group` honoured everywhere** (drift 2).
- **A short-name rule for scorecards** (drift 5) — first name, surname or
  initials, picked once rather than inherited from whatever was typed at setup.
