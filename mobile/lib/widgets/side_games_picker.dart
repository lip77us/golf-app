/// The per-round side games, drawn the same way everywhere they are chosen.
///
/// **One widget, three callers** — the tournament wizard's round-1 step,
/// `setup_round_players_screen` for every later round, and the round hub for
/// changing a round after it exists. They used to be two: the wizard
/// hardcoded seven cards with their own copy, and the later-round screen drew
/// bare chips from the catalog. The two drifted in BOTH directions — the
/// wizard never offered Stroke Play or Hot Spot, and the chips never carried
/// the blurb — which is how a TD came to see different games in round 1 and
/// round 2 and could not tell which scope he was setting.
///
/// The list is the catalog, so a new game appears in all three by being in
/// `kGameCatalog` with `tournament: true`. The copy is the catalog's too
/// (`GameMeta.blurb` / `moneyNote`), so the three cannot say different things
/// about the same game.
///
/// **Dream Round is NOT here, on purpose.** Its config is a `OneToOne` on the
/// TOURNAMENT, so it is one choice for the whole event and putting it in a
/// per-round list would make it look like a per-round choice. It keeps its own
/// block in the wizard.
///
/// **The day bet IS here, on the final round.** It is not an `active_games`
/// entry — it is its own config on the round — so it cannot live in
/// [selected], and for a while that was reason enough to leave it out. But the
/// question this screen answers is "which side games is this round playing",
/// the day bet is one of them, and leaving it out meant the only way to turn
/// one off was an action buried in its setup screen. A TD looking for a switch
/// looks here. See [dayBetOn].
library;

import 'package:flutter/material.dart';

import '../game_catalog.dart';
import '../widgets/inline_message.dart';
import '../widgets/section_card.dart';

/// Per-round side games, in catalog order, minus the two odd-scoped ones the
/// wizard owns.
List<GameMeta> perRoundSideGames({required bool multiFoursome}) =>
    tournamentRoundGames
        .where((g) => g.id != GameIds.dreamRound)
        .where((g) => !multiFoursome ? !g.requiresMultiFoursome : true)
        .toList();

class SideGamesPicker extends StatelessWidget {
  final Set<String> selected;
  final void Function(String id, bool on) onToggle;

  /// Some games rank groups against a field and need more than one group.
  /// The reason prints on the card rather than leaving a grey switch.
  final bool multiFoursome;

  /// Extra widget under a specific game's card — the wizard hangs the Mini
  /// Singles carve-out slider here.
  final Map<String, Widget> extras;

  /// Why a specific game cannot be turned on, when only the caller knows.
  /// The bracket's field gate is 9 to 16 golfers, which this widget has no
  /// way to work out. Nothing is disabled without saying why, so a reason
  /// here prints on the card rather than leaving a grey switch.
  final Map<String, String?> disabledReasons;

  /// Whether the final round's day bet is set up — or null when this round
  /// cannot have one (it is not the last round, or the event has only one),
  /// in which case no card is drawn at all. A struck-through row for
  /// something that can never apply here would be worse than its absence.
  final bool? dayBetOn;

  /// Turning it ON needs an entry fee and a prize table, so the caller opens
  /// the day bet's setup screen; turning it OFF deletes the config. Either
  /// way the caller acts at once — unlike the games above, whose switches are
  /// collected and saved together — because the day bet is its own resource
  /// with its own endpoint. [dayBetNote] is where the caller says so.
  final void Function(bool on)? onDayBetToggle;

  /// A line under the day bet's blurb — the fee and first prize once it is
  /// set up, and when the switch takes effect.
  final String? dayBetNote;

  const SideGamesPicker({
    super.key,
    required this.selected,
    required this.onToggle,
    this.multiFoursome = true,
    this.extras = const {},
    this.disabledReasons = const {},
    this.dayBetOn,
    this.onDayBetToggle,
    this.dayBetNote,
  });

  @override
  Widget build(BuildContext context) {
    final games = tournamentRoundGames
        .where((g) => g.id != GameIds.dreamRound)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < games.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _SideGameCard(
            title: games[i].displayName,
            blurb: games[i].blurb,
            moneyNote: games[i].moneyNote,
            on: selected.contains(games[i].id),
            disabledReason: disabledReasons[games[i].id] ??
                ((!multiFoursome && games[i].requiresMultiFoursome)
                    ? 'Needs more than one group — it ranks groups against '
                        'the field.'
                    : null),
            extra: extras[games[i].id],
            onToggle: (v) => onToggle(games[i].id, v),
          ),
        ],
        // Last, because it is the last round's — and because a TD scanning
        // for it knows it is the odd one.
        if (dayBetOn != null && onDayBetToggle != null) ...[
          const SizedBox(height: 12),
          _SideGameCard(
            title: 'Day bet',
            blurb: "The last day's 18-hole stroke play side bet — it pays a "
                'great single round from somebody out of contention. The '
                'championship money winners are shown but neither charged '
                'nor eligible, and the Mini Singles finalists are not in it '
                'at all.',
            moneyNote: dayBetNote,
            on: dayBetOn!,
            onToggle: onDayBetToggle!,
          ),
        ],
      ],
    );
  }
}

/// Takes its copy as strings rather than a [GameMeta], so the day bet — which
/// has no catalog entry, because it is not an `active_games` game — draws
/// through the same card as the games above it and cannot come to look
/// different from them.
class _SideGameCard extends StatelessWidget {
  final String title;
  final String? blurb;
  final String? moneyNote;
  final bool on;
  final String? disabledReason;
  final Widget? extra;
  final ValueChanged<bool> onToggle;

  const _SideGameCard({
    required this.title,
    required this.on,
    required this.onToggle,
    this.blurb,
    this.moneyNote,
    this.disabledReason,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final blocked = disabledReason != null;

    return SectionCard(
      title: title,
      trailing: Switch(
        value: on && !blocked,
        // Nothing is disabled without saying why.
        onChanged: blocked ? null : onToggle,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (blurb != null)
          Text(blurb!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: muted, height: 1.45)),
        if (blocked) ...[
          const SizedBox(height: 8),
          InlineMessage(kind: InlineMessageKind.warn, text: disabledReason!),
        ],
        if (on && !blocked && moneyNote != null) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.payments_outlined, size: 14, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(moneyNote!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: muted, height: 1.4)),
            ),
          ]),
        ],
        if (on && !blocked && extra != null) extra!,
      ]),
    );
  }
}
