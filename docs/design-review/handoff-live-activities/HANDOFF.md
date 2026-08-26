# Handoff — Live Activities (Sixes · Nassau · Skins · Rabbit)

**One frame, four games, four shipping surfaces.** This is the umbrella packet. Read this document first for the shared frame and the cross-game rules, then the per-game document for whichever card you are building.

| Game | Doc | Card in the design system |
| --- | --- | --- |
| Sixes | `sixes-HANDOFF.md` | **Sixes — lock screen** · `screens/live-activity-sixes.html` |
| Nassau | `nassau-HANDOFF.md` | **Nassau — lock screen** · `screens/live-activity-nassau.html` |
| Skins | `skins-HANDOFF.md` | **Skins — lock screen** · `screens/live-activity-skins.html` |
| Rabbit | `rabbit-HANDOFF.md` | **Rabbit — lock screen** · `screens/live-activity-rabbit.html` |

Generalised pattern card: `live-activity-pattern.html` (**The pattern** — the five slots, which games earn an activity, which earn a push).

Sixes is the reference implementation. Each of the other three documents is written as a set of departures from it.

---

## What ships

An iOS Live Activity per round, read-only. **No buttons, no CTA, no tap targets on any of the four.** A lock-screen control over group state strands the other three golfers, and a mis-tap on money is expensive.

**One activity per round, owned by the primary game named at setup.** There is no ranking of games by newsworthiness and nothing to arbitrate at runtime — the group already answered it. A Nassau with a skins side game gets the Nassau card and no skins card.

## The five slots

Every card is the same panel: `rgba(255,255,255,.13)` + `blur(20px)`, radius 24px, 14px side margins, five slots in the same order.

| Slot | Job | Sixes | Nassau | Skins | Rabbit |
| --- | --- | --- | --- | --- | --- |
| **Header** | Game + where you are | `MATCH 1 · HOLES 1–6` | `HOLE 12` | `HOLE 12 · PAR 4` | `RABBIT 2 · HOLES 7–12` |
| **Big number** | The one thing worth a glance | `2 UP` 36px | **two rows at 25px** | `$18` 36px | `+2` 36px |
| **Sides** | Who | both pairings, restated every match | named once, at the top | **empty — the field is the opponent** | holder + two chasers |
| **State** | The word that changes the next tee shot | `DORMIE` | per-row `n TO PLAY` | `PROVISIONAL` / `ALL IN` | `HELD` / `LOOSE` / `LOCKED` |
| **Footer** | Gross · stake, money right | settled money | **exposure range** | settled net | settled money |

Two rules hold across all four: **gross leads the footer** (the number a golfer checks without meaning to, and the one personal figure a neutral board can afford), and **the money slot is settled money only** — empty, not `$0`, until something has actually paid.

## The neutral-board rule, and its one exception

A lock screen is a **neutral board** two golfers should be able to read off one phone. That is why the sides are named rather than the reader's perspective assumed, and why personal money sits in the footer rather than the headline.

**Skins is the exception**, and only because the pot is not personal — everyone on the tee is playing for the same $18. No other card may put money in the headline.

## Colour

Deep pine `#0B1F1A`, pine `#0F6E56`, mint `#3BD89A`, blue `#5AA7F5`, orange `#F3A059`. Schibsted Grotesk for numbers, Spline Sans for everything else.

- **Blue / orange = the two sides.** Fixed for the round in Nassau; re-assigned per match in Sixes.
- **Mint is the app's colour, so it cannot name a side.** Sixes' `ALL SQ` and Nassau's are white at 90%. Mint is only free to carry meaning where there are no sides: **Rabbit** (mint = held) and **Skins** (mint = the pot is final).
- **Orange also carries "someone did this / this is not standard":** a Nassau press chip, a Rabbit extra.

## The push rule

The activity is **ambient** and the notification is **punctual**, and they never both announce the same thing — the activity is already showing the answer the push carried.

The test for a push: **could the reader have known this from the hole they are standing on?** If yes, it does not push.

| Game | Pushes on | Never pushes |
| --- | --- | --- |
| Sixes | a new pairing (drawn, so unknowable) | anything else |
| Nassau | a press; a nine closing out | holes, scores |
| Skins | a skin settling **behind you** and changing your carry | a hole carrying — that is normal and already on the card |
| Rabbit | a new rabbit starting (end of a six, or an early lock moving the next one) | catches, escapes, halved holes — you were there |

Three to four pushes a round each. Anything more and the activity is doing the notification's job badly.

## Provisional money

Only Skins has it — a skin is not decided until every group has played that hole — and it is marked structurally: white number, `PROVISIONAL`, `n GROUPS OUT`, turning mint and `ALL IN` when the field is through. The other three games settle inside the group that played them, so nothing on their cards is a forecast.

## Lifecycle (identical on all four)

- **Starts on the first score posted.** Buys back the car park and the range against the 8-hour iOS ceiling, and an abandoned round leaves no ghost on the lock screen.
- **Always-on is the same composition, held back.** No separate layout; iOS pulls brightness and refresh rate. The test before adding any line: would it survive there? If it needs a second glance, it fails.
- **Final state on round sign** — the one moment the board stops being neutral: what you won and who to see. Holds ~5 minutes, then dismisses itself.
- **A quiet treatment is drawn for each** (dark slab, numbers pulled back). Ship the loud one and watch. The failure mode is a glanceable thing nobody glances at, not a thing that is slightly too bright.

## Dynamic Island

All four: minimal is mark + mint dot; compact holds **one** number; expanded is the lock card with room for one extra thing (Sixes' pips, Nassau's range, Rabbit's run strip). Compact is what people actually see all round — it sits beside the clock. Nassau's compact shows the current nine only, because compact cannot hold two.

**Keep expanded in step with the lock card.** It drifted once already during this work.

## Cross-game open questions

Per-game questions are in the per-game docs. These affect more than one card:

- **Halved / voided stakes.** Sixes halves pay nothing and do not carry; Rabbit's default zeroes a loose rabbit; Nassau's halved nine is unresolved. Confirm the money slot never banks a stake that was voided, on any card.
- **Loss caps.** `nassau-setup.html` has one. A cap truncates Nassau's exposure floor, which is most of that slot's value, and would clamp Rabbit's worst case too.
- **Team variants.** Nassau 2v2 is drawn; Sixes is inherently 2v2; Rabbit is 3-player only and Skins is field-wide. Triple Nassau (3 pairings) is **not designed** and will not fit two rows.
- **Automatic stake changes.** An auto-press has no person behind it, and `Dave pressed` is wrong copy for it. Whatever the answer, it applies to any future auto-anything: a silent stake change is the thing these footers exist to prevent.
- **Which figure is the reader's in a team game.** Gross and money are personal, the board is neutral. Confirm the data layer returns the reader's own share rather than the team's.
