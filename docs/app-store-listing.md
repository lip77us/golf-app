# App Store listing copy — Halved (v2.7.1)

Reference for App Store Connect metadata. Keep gambling-trigger words OUT
(no "bet/wager/gambling/winnings/real money"); use "stakes/scoring/settle up".
Only list shipping, enabled games (Scramble is still hidden — `enabled:false`).

## Name
Halved Golf
(The standalone "Halved" was already taken on the App Store — names must be
globally unique. In-app name / home-screen CFBundleDisplayName stays "Halved".)

## Subtitle (30 max)
Skins, Nassau & golf games

## Privacy Policy URL
https://halved.golf/privacy

## Support URL (required on the version page)
https://halved.golf/support

## Primary category
Sports  (Secondary: optional, e.g. Utilities)

## Keywords (100 max) — refreshed for 2.6.0 (98 chars)
vegas,wolf,sixes,stableford,spots,handicap,foursome,matchplay,scorecard,tournament,settle,survivor
(Dropped `stakes` to fit `survivor` — the new game's name is worth more as a
search term, and `stakes` is a gambling-adjacent word we'd rather not lead on.)
(Skins/Nassau are already in the subtitle, so they're omitted here — Apple
indexes the subtitle words anyway; keywords spend the budget on new terms.)

## Promotional text (170 max, editable without review) — 162 chars
New: Survivor — worst score is knocked out, and the last two standing duel for
the hole. Plus fully developed tournaments for singles, pairs, foursomes and teams.

## Description (4000 max)
Halved keeps score for the games golfers really play. Set up a round, pick your
games, enter scores hole by hole, and Halved does the rest — live results,
handicaps, a shareable spectator web page, and an easy settle-up at the end.

GAMES YOU CAN PLAY
• Skins, with optional carryover
• Nassau — front, back, overall, with presses
• Las Vegas — 2v2 team game
• Sixes — 2v2 best ball with rotating partners
• Wolf
• Rabbit
• Survivor — three players, last one standing takes the hole
• Points 5-3-1
• Stableford, with a custom points table
• Spots — a side game for one-putts, sandies, barkies and more
• Match Play
• Stroke Play
• Multi-Group Skins across foursomes
• One-round team cup
• Scramble and Shamble team events
• Two-golfer teams — best ball, alternate shot, Scotch, Chapman

CASUAL ROUNDS
Playing with friends? Start a round, choose one or more games, and assign
players and tees. Halved tracks every hole and shows who's ahead in real time.

PLAY WITH FRIENDS
Add a golfer by phone number and send a text invite in one tap. When a friend
adds you to a round — or invites you to watch one — it shows up right on your own
Casual Rounds and Tournaments lists, clearly flagged so you know whether you're
playing or just following along.

GROUP CHAT & LIVE FEED
Every round has a group chat and a live feed that calls out birdies and key
moments as they happen — so the whole group can follow the action, even players
in other groups.

TOURNAMENTS
Running something bigger? Halved supports multiple foursomes, several games at
once, and multi-round events — with live leaderboards, team cup play, and
formats like Irish Rumble, Pink Ball, and Singles. Team events run small teams
or two-golfer pairs against the whole field on one board, each format with the
allowance it is actually played off.

FIND YOUR COURSE FAST
Just start typing a course name and pick it from one list — your own courses, a
shared catalog, and a full course database, all in a single search.

HANDICAPS YOUR WAY
Score net (with an adjustable handicap percentage), gross, or
strokes-off-the-low-player — set per game to match how your group plays. Every
scorecard shows exactly where each player gets a stroke, hole by hole, so the
handicap is never a mystery.

SETTLE UP
At the end of the round, the Settlement tab nets every game into one summary and
shows exactly who owes whom — plus the fewest payments to square up. Settle in
seconds, with no spreadsheets and no napkin math.

Halved is built for friendly play among friends. It tracks informal stakes for
scoring purposes only and does not process payments.

## What's New (v2.7.1)
Your lock screen keeps the match now.

• **The match on your lock screen** — Sixes, Skins, Nassau and Rabbit put a live
  board on your lock screen and Dynamic Island: the number that matters, who is
  up, and what the hole is worth. It updates as the group scores.

• **It reaches the whole group, not just the scorer.** Whoever is keeping the
  card already knows the state — everyone else was the one who needed it. The
  board now appears for every golfer in the round, and for anyone you have
  invited to watch, without them opening anything.

• **A rebuilt Skins board** — it names who is winning and how far back you are,
  in skins rather than a placing. When a carry finally breaks it leads with the
  golfer who took it. Pool games show what a skin is worth right now, and junk
  points count as what they are: an equal share of the same pot.

• **Sixes score entry is tidier** — shorter match cards, and the scorecard now
  sits under them so you can read the holes you just played without leaving the
  screen.

• **The draw stays a draw** — the leaderboard no longer shows the pairings for
  matches 2 and 3 before the group has spun for them.

• **Inviting a watcher is quicker** — search your golfers by name or number, and
  filter to the ones already on Halved.

Fixes

• Lock-screen boards could fail to register on some phones and never appear.

## What's New (v2.7.0)
Team tournaments, and a rebuilt tournament for individual play:

• Team tournaments — run a Saturday scramble or shamble with as many teams as
  you like, all on one leaderboard. Pick the format, decide whether every
  golfer has to give a drive, and Halved works each team's allowance from the
  tees you set and shows it applied to your own teams before you commit.
• Two-golfer teams — the same event for pairs, with five formats: scramble,
  best ball, alternate shot, Scotch and Chapman. Two pairs go off together on
  one tee time with one card, scored apart. Each format sets its own
  allowance, and every one is shown before you choose so you can see that the
  same two golfers get four strokes in a scramble and twelve in an alternate
  shot.
• Alternate shot keeps the order for you — the pair sets who tees on the odd
  holes before the first shot, and the card names the tee on every hole after
  that.
• Individual tournaments, rebuilt — a clearer eight-step setup, best-N-of-M
  scoring across rounds, a Mini Singles bracket in every group, an optional
  final-round day bet, and a settlement screen that shows exactly who owes whom
  and why, game by game.
• Survivor's Zombie Option — switch it on and a knocked-out golfer plays on as
  the Zombie. Beat the field on the next hole and you are back in.
• Better sharing — a shared round link now opens a real page with the scorecard
  on it, and previews with a proper card instead of a bare link.

Fixes

• A scramble round can be completed. One score per hole meant the round never
  read as finished, so it could not be closed out.
• Every stroke a team receives now shows on the card. A hole carrying three
  strokes was drawing the same single mark as a hole carrying one.
• Tee sheets name the event and list who is in each group.
• A new tournament starts as an individual event rather than a cup.

## What's New (v2.6.0) — previous
A brand-new game, and a cup that's easier to build:

• Survivor — a new game for three players. Everyone plays the hole and the
  worst score is knocked out; the two left standing then play the next hole
  head-to-head to take it. Win one and a fresh Survivor starts on the very next
  hole, so a full round can play out up to nine of them. Net, gross or
  strokes-off-the-low-player, and the group chat calls each result as it lands.
• A rebuilt cup setup — choose the games and points round by round, with a plan
  that shows what's still to fill in before you can start. Mixed formats in one
  cup are now the default, with the classic Triple Cup a one-tap preset.
• Clearer cup leaderboards — see where every stroke falls before you play the
  hole, with singles strokes anchored on the pairing you're actually against.
• Rabbit — handicap strokes now stay exactly where they were set at the start of
  the round; a leg that's already won is called out instead of looking live; and
  the leaderboard shows the full scorecard with each hole's winner highlighted.
• Sixes — corrected the stroke dots on holes handed from one match to the next.
• Bigger type, intact layouts — very large system font sizes no longer push
  screens out of shape.
• Fixes — the keyboard can always be dismissed when adding or searching for
  players, so the button underneath is never out of reach.

## What's New (v2.5.1) — previous
New games and a cleaner home screen:

• Triple Nassau — a brand-new game. Play three 1-on-1 Nassaus at once (you
  against each of the other three). One setup, per-pair handicaps, and a
  dedicated screen showing every match, its presses, and who owes whom.
• Sixes team draws — let the slot machine pick your partners. Draw the Segment 1
  teams at setup, watch the Segment 2 pairing reveal itself at the turn, and draw
  the teams for an extra match too. Prefer to choose? Just drag.
• A cleaner Rounds list — every round is now a tidy card with the game, live
  progress, your score, and the money you won or lost. A new filter keeps rounds
  you played separate from ones you're just watching.
• Rabbit improvements — extra "rabbits" when a leg ends early, fairer handicap
  allocation, and clearer wording when a hole is halved.
• Stroke Play, your way — view the leaderboard as Gross, Net, or Strokes-off.
• Polish & fixes — Cup match cards tinted by the leading team, more reliable
  course adds with clearer errors, and assorted layout fixes.

## What's New (v2.3.2) — previous
See where every stroke falls:

• Stroke dots, everywhere — every scorecard and score-entry screen now shows
  exactly which holes each player gets a handicap stroke on, across all your
  games: Vegas, Wolf, Rabbit, Sixes, Stableford, the Mini Singles Bracket and
  the one-round cup.
• The Stroke Play tab now lays out each player's full-round strokes hole by
  hole — all 18 — even before you tee off.
• Wolf: the tee shows who's getting a stroke before the Wolf picks a partner.
• Support for nine-hole play as well as shotgun starts.
• Set a home course once and it's ready every time you start a round.
• The leaderboard refreshes the moment you open it.
• Fixes: correct strokes when men and women play different tees, Strokes-Off-Low
  scoring in the Mini Singles Bracket, and the final match no longer starts
  before the semifinals are decided.

## What's New (v2.3.0) — previous
See exactly who owes whom:

• New Settlement tab — nets every game in your round into one who-owes-whom
  summary, and shows the fewest payments needed to settle up.
• Choose how each game splits the pot — Pool, Pay the leader, or Pay everyone
  above you — now consistent across Skins, Spots and Points 5-3-1, with an
  optional cap on losses.
• Cleaner, unified game-setup screens.
• Simpler Nassau setup — presses and variants tucked under Advanced.
• Fixes and polish across Nassau, Stableford and the scorecard.

## What's New (v2.2.0) — previous
A new side game and quicker setup:

• New: Spots — track one-putts, sandies, barkies, or whatever your group counts,
  as a separate side game. Add or subtract per hole; it never touches your main
  game. Play it alongside Nassau, Sixes, Points, Wolf, Rabbit and more.
• Suggest a Game — got a format we don't have yet? Send it to us from the app.
• Recent courses — your last courses are one tap away when you start a round.
• "18-Hole Match" is now "Singles Match."
• Stroke Play can ride along as a side game, with the same simple payout setup as
  Stableford.
• Various fixes and polish.
