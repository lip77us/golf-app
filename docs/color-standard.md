# Halved color standard

One palette across every casual game so color carries consistent meaning.
Source of truth in code: `mobile/lib/game_colors.dart` (`GameColors`) and the
watch CSS vars in `api/templates/watch/base.html`.

## The rule

**Sides are pine, clay and slate.** Green / red / grey still mean *meaning*
(win, loss, neutral); a side is a bar down a row, a header, a name on the tray —
never a result figure.

| Color | Meaning | Hex (mobile) |
|---|---|---|
| 🟩 **Green** | win · you're up · +money | `Colors.green.shade700` |
| 🟥 **Red** | loss · you're down · −money | `Colors.red.shade700` |
| ⬜ **Grey** | halved · push · neutral · not started | `Colors.grey.shade600` |
| 🌲 **Pine** | **Side 1** / Wolf-side | `Halved.pine` `#0F6E56` (on the dark tray `#3BD89A`) |
| 🟤 **Clay** | **Side 2** / Opponents | `Halved.teamClay` `#B45309` (on the dark tray `#F2A86E`) |
| 🩶 **Slate** | a third side (Annandale Friday) | `Halved.teamSlate` `#475569` (on the dark tray `#8FB4FF`) |

**Changed 14 Nov 2026** (`handoff-score-entry-template`; Paul): this used to be
blue and orange, on the argument that green is a win and must never be a team.
That argument gave Sixes, Las Vegas, Fourball and Nassau colours of their own
for no reason particular to them, and the template draws every game's sides the
same. One set of sides across every game is worth more than the collision it
risked; the two are kept apart by shape (a bar and a header vs. a figure).

- **Individual games** (Skins, Points 5-3-1, Rabbit, Stableford): no side colour
  — just the green/red money semantics.
- **Two-side casual games** (Nassau, Singles Match, Match Play, Triple Cup,
  Sixes, Las Vegas, Fourball): pine (1) / clay (2). Casual Triple Cup's default
  colour names are now "Pine" and "Clay".
- **Wolf**: Wolf + partner = **pine**, Opponents = **clay**.
- **Lock screens (17 Nov 2026):** the widget draws pine (`#3BD89A`) and clay
  (`#F2A86E`) wherever the server says `blue` / `orange`. The wire keys keep
  their old names so installed builds still decode them; the Vegas card says
  `PINE` / `CLAY` in its text. Mint now also means a side on these cards, so
  "leads" is carried by the figure and the state word, not by mint alone.
- **Slate on the dark tray is `#8FB4FF`, not the template's `#AFC0D8`**: that
  pale blue-grey is indistinguishable from the tray's own label grey.

## Deliberate deviations (with reason)

- **Cup games keep the TD's configured team colours** (red/blue/green/gold/
  purple/…). Those are real, named teams a tournament director chose — the
  pine/clay default only applies to *casual* games with anonymous sides.
- **Solo** keeps its own palette (the golfer against par): there is no side.
- **Sixes** has **no fixed team colours** in its leaderboard card because the
  2-v-2 partnerships rotate every 6-hole segment; on score entry its sides are
  pine and clay like every other game.

Where the server names or colours a team (a cup's configured colours, and the
casual Triple Cup team names it returns) the app shows what the server sent; the
pine/clay defaults here apply when it sends none.

## Migration note

Before this standard, "Team 1" was variously blue, orange, green, deep-orange,
or burgundy depending on the screen; Sixes/Wolf used **green as a team** (which
clashed with green = win); and mobile vs. web were inverted. All casual games
were unified onto the table above; see `GameColors` + the watch CSS vars.
