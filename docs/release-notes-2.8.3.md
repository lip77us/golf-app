# Halved 2.8.3 (build 35) — Release notes

Version in `mobile/pubspec.yaml` → `2.8.3+35`.

**This is a new-version App Store submission, and it is a big one.** The public
build is 2.7.x; 2.8.0, 2.8.1 and 2.8.2 were TestFlight only. So everything
below ships to the public at once: **two whole new games**, a rebuilt Survivor,
lock-screen cards for six formats, and a favourites shortlist in the golfer
picker.

Backend is already deployed and backward-compatible. **No `CLIENT_MIN_VERSION`
bump** — it stays at `2.1.0`, so nobody is forced to update.

Thirteen migrations across the span, all additive and all already live:
`core/0016`, `tournament/0064`–`0068`, `games/0071`–`0077`.

---

## What is different about this one

The usual "one thing that must ship with this build" is **already shipped**.
`UNSHIPPED_KINDS` is empty, and both cards it held this cycle — `sequoya` and
`banker` — came off it in the TestFlight builds that draw them (+32 and +35).
Nothing is waiting on the App Store release.

The consequence runs the other way instead, and it is worth knowing rather than
fixing: **the server already sends card kinds that a 2.7.x phone cannot draw.**
A public user cannot start a Banker or Sequoya round — those games do not exist
in their build — but a 2.7.x user *watching* somebody else's will get the
Swift's "Update Halved to follow this round here". That is the designed
fallback, it points at an update that will exist the moment this release lands,
and it resolves itself on update.

---

## App Store Connect — what to paste where

| Field | Value |
|---|---|
| Version | `2.8.3` |
| Build | `35` |
| What's New | the block below |
| Promotional text | worth refreshing — **Banker** is the headline |
| Description | **needs editing** — two new games to list, see below |
| Keywords | consider adding `banker` |
| **Age Rating** | Gambling = **Yes**, already set — the 2026-09-02 rejection under 2.3.6 was fixed and a version has shipped since |
| Screenshots | refreshing — see the note at the end |

### What's New

```
Two new games.

BANKER — one golfer banks the hole and the other three bet against him,
each in their own match. Set a maximum on the tee, take the bets, double
on your own shot, and counter all three at once if you fancy it. Strokes
come off inside each match, so the banker can be giving a shot in one bet
and taking one in another on the same hole. Full receipt at the end, hole
by hole.

SEQUOYA 3s — six three-hole matches, partners rotating every third hole,
so you play with everybody twice. Presses, an auto press, and a settle-up
that shows every match that made your money.

Both games run on the lock screen while you play.

ALSO IN THIS RELEASE
• Favourites in the golfer picker — flag the people you always play with
  and find them first
• Survivor rebuilt: clearer score entry, a fitted lock-screen card, and
  Zombie mode on the board
• Lock-screen cards for singles matches and fourballs
• Force a playing handicap when the group is scoring off an external card
• Faster scorecards, and the label column stays put when you scroll
```

### Description — the paragraph to update

The description lists the games. Add **Banker** and **Sequoya 3s** to that
list. Nothing else in it has gone stale.

---

## What is in the span

`git log v2.7.1..v2.8.3 --oneline` — 59 commits. The shape of it:

| Version | Carried |
|---|---|
| 2.8.0 (+27–31) | Survivor rebuilt to a new packet; the `match` and `survivor` lock-screen cards; forced playing handicaps for externally-managed cards; the fitted 160pt card after three builds of clipping |
| 2.8.1 (+32) | **Sequoya 3s** — engine, API, setup, play, presses, leaderboard, settlement, lock screen. Select Players: All / Favorites / On Halved, and the pin flag that sets a favourite |
| 2.8.2 (+33) | **Banker** — engine, API, setup, play, leaderboard, score entry, settlement receipt, lock screen. Per-golfer loss caps and a per-hole ceiling |
| 2.8.3 (+34–35) | The shared frame's locked `THRU 12 · +7` corner, which every card had been sending and none but Survivor's drew; the catalog switch that actually starts a Banker activity |

---

## Screenshots

Shoot on the **iPhone 17 Pro Max simulator** — the 6.9" class App Store Connect
requires; the smaller sizes derive from it.

**Not the debug build.** A debug build against localhost wears a green `LOCAL`
ribbon in the corner and it will go straight into the store listing. This has
happened before and is finding #1 in `docs/design-review/README.md`. Build
release against production first:

```
flutter build ios --simulator --release
```

Worth shooting, given what is new: a Banker hole mid-declaration (bets in, one
doubled, the counter live), the Banker receipt, a Sequoya press card, and the
golfer picker with Favorites active.
