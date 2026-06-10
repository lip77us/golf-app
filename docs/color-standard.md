# Halved color standard

One palette across every casual game so color carries consistent meaning.
Source of truth in code: `mobile/lib/game_colors.dart` (`GameColors`) and the
watch CSS vars in `api/templates/watch/base.html`.

## The rule

**Green / red / grey mean *meaning*. Blue / orange mean *teams*. Never mix.**

| Color | Meaning | Hex (mobile) |
|---|---|---|
| 🟩 **Green** | win · you're up · +money | `Colors.green.shade700` |
| 🟥 **Red** | loss · you're down · −money | `Colors.red.shade700` |
| ⬜ **Grey** | halved · push · neutral · not started | `Colors.grey.shade600` |
| 🔵 **Blue** | **Team 1** / Wolf-side | `Colors.blue.shade700` |
| 🟠 **Orange** | **Team 2** / Opponents | `Colors.orange.shade800` |

- **Individual games** (Skins, Points 5-3-1, Rabbit, Stableford): no team color
  — just the green/red money semantics.
- **Two-side casual games** (Nassau 2-v-2, 18-Hole Match, Match Play): the two
  sides are blue (1) / orange (2), used consistently for names, badges, and the
  header banner.
- **Wolf**: per hole, Wolf + partner = **blue**, Opponents = **orange**; who won
  the hole / the points uses green/red as usual.
- (Sixes and Triple Cup deviate on purpose — see below.)

## Why blue/orange (not the classic blue/red)

1. **Red is already "loss / −money"** all over the leaderboard. If Team 2 were
   also red, a red name sitting next to a red dollar figure is ambiguous. Blue +
   orange never collide with the win/loss semantics.
2. **Color-blind friendlier** and higher contrast than red/green or red/blue.
3. Sidesteps the **political read** of red-vs-blue.

## Deliberate deviations (with reason)

- **Cup games keep the TD's configured team colours** (red/blue/green/gold/
  purple/…). Those are real, named teams a tournament director chose — the
  blue/orange default only applies to *casual* games with anonymous sides.
- **Triple Cup (casual)** names its two teams literally **"Red" vs "Blue"** (a
  casual mini-cup), so it keeps red/blue — the colour *is* the team name. Forcing
  blue/orange here would show a team called "Red" in blue.
- **Sixes** has **no fixed team colours** on purpose: the 2-v-2 partnerships
  rotate every 6-hole segment, so there's no stable "Team 1." It shows the
  pairings as name-pairs with the leading side emphasized — not a two-colour
  scheme.

Everything else (Nassau, 18-Hole Match, Wolf, Match Play) uses the table above.

## Migration note

Before this standard, "Team 1" was variously blue, orange, green, deep-orange,
or burgundy depending on the screen; Sixes/Wolf used **green as a team** (which
clashed with green = win); and mobile vs. web were inverted. All casual games
were unified onto the table above; see `GameColors` + the watch CSS vars.
