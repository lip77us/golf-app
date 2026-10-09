# Search copy to carry back into Claude Design

`website/build-seo.py` overrides these titles and descriptions because the
Design originals run past what Google shows (about 60 characters for a title,
160 for a description) and get cut mid-phrase. The overrides survive guide
rebuilds, but the Design files are the source of truth for the pages: once a
guide's `.dc.html` carries this copy, delete its entry from `OVERRIDES` in
`build-seo.py`.

**Also for Design — "Ryder Cup" is still in body copy.** The app scrubbed the
PGA-owned mark from every user-visible string; the site still uses it on the
Triple Cup guide ("A Ryder Cup compressed into one round", "a Ryder Cup needs
three sessions…", "borrow the Ryder Cup answer…") and on the guides hub card
("A one-round Ryder Cup"). The Triple Cup meta tags are already fixed by the
override.

## `/`

- **description** (142 chars): Halved is the scorecard for your group's golf games. Track Nassau, Skins, presses and whole tournaments, with handicaps applied automatically.

## `/games/`

- **description** (137 chars): How to play the games your group bets on: Nassau, Skins, Wolf, Banker, Las Vegas, Survivor and more. Full rules and the money worked out.

## `/games/40-balls/`

- **title** (50 chars): 40 Balls Golf Game: Rules and How to Play | Halved
- **description** (134 chars): 40 Balls is a foursome team game: after each hole the group picks which net scores count, and over the round it must count exactly 40.

## `/games/banker/`

- **title** (56 chars): Banker Golf Game Rules: Doubles and the Counter | Halved
- **description** (137 chars): Banker is a golf game where one golfer plays the whole group, one bet at a time. Setting the bet, doubles, the counter and par 3 triples.

## `/games/dream-round/`

- **title** (54 chars): Dream Round Golf Game Rules: Best Score Per Hole | Halved
- **description** (132 chars): Dream Round keeps your best score on each hole across every round of an event, and the lowest eighteen wins. Full rules, gross and net.

## `/games/honors/`

Not overridden, but the tightest title on the site at 592px — 8px of margin.
Worth a look next time it is edited: "Score a Point" instead of "Score the
Hole" is both 12px shorter and closer to the rule, since a point comes from
holding the honor rather than from scoring the hole.


- **description** (125 chars): Honors is a group game with one token: low score on a hole takes the honor, and you score a point for every hole you hold it.

## `/games/irish-rumble/`

- **title** (51 chars): Irish Rumble Golf Game: Rules and Variants | Halved
- **description** (134 chars): Irish Rumble is a tournament team game: each foursome counts its best net scores, and the number that counts climbs through the round.

## `/games/las-vegas/`

- **title** (56 chars): Las Vegas Golf Game Rules: The Flip and Scoring | Halved
- **description** (132 chars): Las Vegas is a 2v2 golf game: each team's scores form a two-digit number and the low number wins the difference. Rules and the flip.

## `/games/mini-singles-bracket/`

- **title** (51 chars): Mini Singles Bracket: Match Play Side Game | Halved
- **description** (129 chars): A two-day match play side game: each group plays a four-man knockout on day 1, and the group winners play for the title on day 2.

## `/games/nassau/`

Shortened by Design on 9 Oct from 61 characters to 52 — the old one measured
exactly 600px, Google's desktop cut, with no margin. Kept here because the
delivered page carries its copy INSIDE the generated `seo` block, so this
entry is the only source the build has.

- **title** (52 chars): Nassau Golf Bet Rules: How to Play, Presses | Halved
- **description** (134 chars): A Nassau is three bets in one round: front nine, back nine and all eighteen. Full rules, when a press fires, and the money worked out.

## `/games/pink-ball/`

- **title** (54 chars): Pink Ball Golf Game Rules: One Ball Per Group | Halved
- **description** (125 chars): Pink Ball is a tournament side game: one ball per group, played by each golfer in turn. The last group still holding it wins.

## `/games/points-5-3-1/`

- **title** (53 chars): Points 5-3-1 Golf Game: Rules for Threesomes | Halved
- **description** (133 chars): Points 5-3-1 is a three-player golf game: 5 points for low score on a hole, 3 for second, 1 for third. Full rules and how ties split.

## `/games/rabbit/`

- **title** (52 chars): Rabbit Golf Game Rules: Catching the Rabbit | Halved
- **description** (124 chars): Rabbit is a three-golfer chase: win a hole outright to catch the rabbit, and hold it to the end of the match to win the pot.

## `/games/road-trip/`

Design's pair is the longest in the set — an 80-character title and a
219-character description. "Across a Golf Trip" went because "Road Trip" and
"Golf Tournament" already carry the query, and the trip is the first thing the
description says.

- **title** (59 chars): Road Trip Golf Tournament Rules: Best Rounds Count | Halved
- **description** (160 chars): Road Trip is a championship for a golf trip: several rounds on different courses, and your best rounds to par count. Net and gross titles, ties and eligibility.

## `/games/sequoya-threes/`

- **title** (54 chars): Sequoya 3s Golf Game: Rules, Presses, Scoring | Halved
- **description** (128 chars): Sequoya 3s splits a foursome into six three-hole 2v2 matches, rotating partners every third hole. Full rules, presses and money.

## `/games/skins/`

- **title** (55 chars): Skins Golf Game Rules: How to Play, Carryovers | Halved
- **description** (137 chars): Skins makes every hole its own bet: low score wins the skin, and a tie carries it to the next hole. Full rules and carryovers worked out.

## `/games/spots/`

- **title** (59 chars): Spots Golf Game Rules: One-Putts, Sandies, Barkies | Halved
- **description** (127 chars): Spots is a side bet on whatever your group agrees to count: one-putts, sandies, barkies. Tally them hole by hole and settle up.

## `/games/survivor/`

- **title** (55 chars): Survivor Golf Game Rules: Elimination, Zombies | Halved
- **description** (137 chars): Survivor is a three-player golf game: the worst score on each hole is knocked out and the last two play for the pot. The Zombie rule too.

## `/games/triple-cup/`

- **title** (61 chars): Triple Cup Golf Format: Fourball, Foursomes, Singles | Halved
- **description** (131 chars): The Triple Cup is a one-round team match for four golfers: six holes each of fourball, foursomes and singles, four points at stake.
- **og:title** (46 chars): Triple Cup: How to Play a One-Round Team Match

## `/games/triple-nassau/`

- **title** (53 chars): Triple Nassau Golf Rules: A Nassau for Three | Halved
- **description** (130 chars): Triple Nassau is three one-on-one Nassaus in a threesome: front, back and overall in every match. Full rules, strokes and presses.

## `/games/wolf/`

- **title** (53 chars): Wolf Golf Game Rules: How to Play, Lone Wolf | Halved
- **description** (125 chars): Wolf is a four-player golf game where a different golfer picks a partner off the tee each hole, or goes Lone Wolf for triple.

