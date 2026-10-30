# Annandale Friday as built — 30 Oct 2026

Built from `handoff-annandale-friday`. These screenshots are from an iPhone 13 mini
simulator (375pt, the narrowest phone we support), on a real six-golfer round
against a local server. Nothing is mocked.

Most of the packet went in as drawn. This note covers **where the build
departs from it**, and **what Paul changed after playing it on a phone**. The
second list is longer. Each item gives the reason, so you can push back on any
of them.

---

## 00 · Create round — `00-create-5-6.png`

Built as drawn: the **5–6** segment, Annandale Friday as the only primary
game, and your line under it. The side games offered are Skins, Spots and
Stroke Play.

One rule the screen doesn't show: a game is listed under 5–6 only if it seats
5 or 6 golfers **on one card**. Stroke Play and Stableford accept any number
of players, so a plain player-count check would have offered them here as
primaries. Six golfers would then have been split into two groups, which is a
different round.

## 01 · Setup — `01-setup-teams.png`, `01b-…`, `01c-…`

Three steps, as drawn. The Teams step and its matches box are exactly as
drawn: if the teams don't fit, the box shows the refusal sentence and Next
stays off.

**Departure: presses.** The reference presses on the *latest* bet, which is
where its "press 2 starts on 8" example comes from. We use the rule every
other Nassau in the app uses instead: a press when **the nine** reaches 2, 4,
6 or 8 down. Paul chose this so there is one press rule across the app.
Manual press is allowed at **1 down or level** (wider than a plain Nassau),
because that is how the game is played.

**Added: "Cap losses."** The cap is per side, per Nassau. The engine already
supported it, so the setup screen exposes it.

**Teams lock after the first 3 holes.** That is the app-wide edit ceiling.
After it, the Teams step shows a refusal instead of letting a played match be
redrawn.

## 02 · Score entry — `02-score-keypad.png`, `02b-score-tray.png`

The keypad and team headers are as drawn. Two things changed in the tray after
playing it:

- **The pill says "Wins hole", not "Won".** "Won" read as *won the match*.
  What happened is the hole, so the pill says so, in the winning team's
  colour.
- **Each match line shows the bets after the hole.** For example: `Front 4&2 ·
  P1 3&1 · P2 1 UP · 18 5 UP`. Once a nine or a press closes, it shows its
  result (`4&2`), not a margin. A live press shows `1 UP · 1 to play` or
  `1 UP · dormie`, never "live".

**Team colours on the dark tray.** The light golfer tints made pine and slate
the same grey on the dark background. The tray uses your dark variants for
pine and clay (`#3BD89A` / `#F2A86E`). Slate needed a change: your `#AFC0D8`
matched the tray's label grey, so we moved it to `#8FB4FF`. Labels are neutral
white at 55%, so only the team names carry colour. **Please confirm the slate,
or give us a better one.**

**Not built:** the hole header's `2 skins · 1 carried from 6`. The tray's
SKINS line reports the skin instead.

## 03 · Leaderboard — `03-board-match-box.png`, `04-net-position.png`

This screen changed the most, in three ways. All three came from Paul reading
it mid-round and saying the numbers were confusing.

**1. One place for money.** Paul's words: *"Paul and Jim are +40 but net
position now is +70, and the bet is 10 and the press $10. A lot of numbers
that are confusing."* Every figure was right, but nothing showed how they
related: +$40 was one match, +$70 was both of Paul's matches, and "$10 /
$10" were stakes sitting next to winnings. So:

- The board inside the box shows **no money**: it shows the bets only.
- **Net position** is the only place money appears. Each total is broken into
  its matches (`+$40 v Sean & TYLaw · +$30 v Larry & RyanL`), so the parts add
  up to the total.
- **The stakes moved into the settings strip** as chips: `$10 a bet`, `$10 a
  press`.

**2. The 18, without money, is a light card that names the leader:** `18 ·
Paul & Jim 4 UP · thru 9`. The dark money card (from your Nassau board) held
only a status line once the money was removed. That made it the loudest thing
on the board while naming nobody: a swatch was the only way to see whose lead
it was. This change is in the **shared** Nassau board, so the cup match board
gets it too.

**3. A box around what the pick changes.** This was Paul's question: *"Should
we put a box around the front, back and 18 to show that they are related and
that is what is changing when you click a match?"* Front, Back and the 18 now
sit in one panel that opens with the match's name (`Paul & Jim v. Larry &
RyanL`). The selected pill has the **same 2px outline**, so the pill and the
panel read as one control. The settings strip and Net position stay outside,
because they cover every match and don't change when you tap one.

- The outline is **deep pine (`deepPine`), not pine**. Pine is team 1's
  colour, and a finished nine has a border in its winner's colour. A pine box
  around Paul & Jim's match read as "Paul & Jim lead", not "this is the one
  you picked".
- **Triple Nassau uses the same panel.** It has the same picker over the same
  board, so the panel is one shared widget, `MatchPanel`.

**Questions for you:**
1. The panel's tint is deep pine at 4%. Does it compete with the settled
   Front card's own border inside it?
2. The match pills show `front · final` and `18` under the two figures. Is
   that the right pair for a pill, or should the pill show the overall alone
   once the front has settled?

## Still to do from the packet

- `2 skins · 1 carried from 6` in the hole header (see 02).
- The Skins settings summary on setup step 3.
- The watch page and the Live Activity card.
- The web guide moves from `/preview/` to `/games/annandale-friday/` last,
  once the app version that has the game is live.
