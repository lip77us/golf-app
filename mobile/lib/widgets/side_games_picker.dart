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
/// **What is NOT here, on purpose.** Dream Round's config is a `OneToOne` on
/// the TOURNAMENT and the day bet is the final round only — neither is a
/// per-round side game, and putting them in this list would make them look
/// like one. They keep their own blocks in the wizard, which is the honest
/// place for a choice made once for the whole event.
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

  const SideGamesPicker({
    super.key,
    required this.selected,
    required this.onToggle,
    this.multiFoursome = true,
    this.extras = const {},
    this.disabledReasons = const {},
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
            meta: games[i],
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
      ],
    );
  }
}

class _SideGameCard extends StatelessWidget {
  final GameMeta meta;
  final bool on;
  final String? disabledReason;
  final Widget? extra;
  final ValueChanged<bool> onToggle;

  const _SideGameCard({
    required this.meta,
    required this.on,
    required this.onToggle,
    this.disabledReason,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final blocked = disabledReason != null;

    return SectionCard(
      title: meta.displayName,
      trailing: Switch(
        value: on && !blocked,
        // Nothing is disabled without saying why.
        onChanged: blocked ? null : onToggle,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (meta.blurb != null)
          Text(meta.blurb!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: muted, height: 1.45)),
        if (blocked) ...[
          const SizedBox(height: 8),
          InlineMessage(kind: InlineMessageKind.warn, text: disabledReason!),
        ],
        if (on && !blocked && meta.moneyNote != null) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.payments_outlined, size: 14, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(meta.moneyNote!,
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
