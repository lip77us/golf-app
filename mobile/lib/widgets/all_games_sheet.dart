/// The All games sheet — what **More games** opens on New Round.
///
/// `handoff-game-selection-more-games`. Every game the app offers as a
/// primary, searchable, in the catalog's own order, with the ones that do not
/// fit this group greyed underneath their own label.
///
/// The rows are built by [buildAllGamesRows], which is pure so the grouping
/// rules are testable without a sheet: the catalog supplies the names,
/// descriptions and player ranges (the handoff says the registry, not its own
/// table, is the source of truth) and the SCREEN supplies the two questions
/// only it can answer — does this fit the group, does it fit the round.
library;

import 'package:flutter/material.dart';

import '../game_catalog.dart';
import '../theme/halved_brand.dart';
import '../utils/game_suggestions.dart' show orderRank;

/// Why a game is where it is on the sheet.
enum AllGamesGroup {
  /// Plays with this group and this round: tappable, first.
  playable,

  /// Not for this group size: greyed under "Not for {n}".
  notForGroup,

  /// Fits the group but needs a full 18 holes and this round is shorter.
  needsFullRound,
}

class AllGamesRow {
  final String id;
  final String name;
  final String blurb;
  final String range;
  final AllGamesGroup group;

  const AllGamesRow({
    required this.id,
    required this.name,
    required this.blurb,
    required this.range,
    required this.group,
  });

  bool get playable => group == AllGamesGroup.playable;
}

/// `2–4`, `4`, `1–6` — the players a game takes, read off the catalog.
///
/// Counted over one to six, the largest card the app seats, so a game with
/// no upper limit reads `1–6` rather than something open-ended. A game across
/// groups says so instead of quoting a card size it is not played on.
String playerRangeLabel(GameMeta m) {
  if (m.acrossGroups) return 'Groups';
  final ns = [for (var n = 1; n <= 6; n++) if (m.supportsSize(n)) n];
  if (ns.isEmpty) return '';
  return ns.first == ns.last ? '${ns.first}' : '${ns.first}–${ns.last}';
}

/// The chip label for [gameId]: the short form where the sheet's name is long.
///
/// One catalogue id per game and a short label for the chip — the sheet says
/// Las Vegas, the chip says Vegas.
String gameChipLabel(String gameId) =>
    gameId == GameIds.vegas ? 'Vegas' : gameDisplayName(gameId);

/// The label over the greyed games: "Not for four", "Not for solo"…
String notForLabel(String sizeKey) {
  switch (sizeKey) {
    case 'solo':
      return 'Not for solo';
    case '2':
      return 'Not for two';
    case '3':
      return 'Not for three';
    case '4':
      return 'Not for four';
    case 'groups':
      return 'Not across groups';
    default:
      return 'Not for five or six';
  }
}

/// Every primary candidate, grouped for the sheet: the games that fit in the
/// best-known order, then the rest in catalog order.
///
/// [fitsSize] is the screen's group-size question and [fitsRound] its
/// partial-round one; both are asked rather than re-derived here.
///
/// Two things are left OFF the sheet on purpose, and both are about names:
///  * a one-golfer game outside Solo — "Match Play" there is a different
///    game from the one a foursome means, and it fits nobody on this screen;
///  * a game that does not fit but shares its name with one that does — Solo
///    Stroke Play and Stroke Play are one entry in a golfer's head, and two
///    rows with the same name is a list he cannot read.
List<AllGamesRow> buildAllGamesRows({
  required String sizeKey,
  required bool Function(GameMeta) fitsSize,
  required bool Function(GameMeta) fitsRound,
}) {
  final candidates = casualGames.where((m) => !m.sideGameOnly).toList();
  final playableNames = {
    for (final m in candidates)
      if (fitsSize(m) && fitsRound(m)) m.displayName,
  };
  final rows = <AllGamesRow>[];
  for (final m in candidates) {
    final oneGolferOnly = m.sizes != null && m.sizes!.length == 1 &&
        m.sizes!.first == 1;
    final group = !fitsSize(m)
        ? AllGamesGroup.notForGroup
        : (!fitsRound(m) ? AllGamesGroup.needsFullRound : AllGamesGroup.playable);
    if (group == AllGamesGroup.notForGroup) {
      if (oneGolferOnly && sizeKey != 'solo') continue;
      if (playableNames.contains(m.displayName)) continue;
    }
    rows.add(AllGamesRow(
      id: m.id,
      name: m.displayName,
      blurb: m.summary ?? '',
      range: playerRangeLabel(m),
      group: group,
    ));
  }
  // Playable first. Within the games that fit, the best-known first — the
  // same list the chips are filled from — then anything it does not name in
  // catalog order. The greyed games keep catalog order: they are not what the
  // golfer is choosing between.
  final indexed = [for (var i = 0; i < rows.length; i++) (i, rows[i])];
  indexed.sort((a, b) {
    final g = a.$2.group.index.compareTo(b.$2.group.index);
    if (g != 0) return g;
    if (a.$2.group == AllGamesGroup.notForGroup) return a.$1.compareTo(b.$1);
    return orderRank(sizeKey, a.$2.id, a.$1)
        .compareTo(orderRank(sizeKey, b.$2.id, b.$1));
  });
  return [for (final e in indexed) e.$2];
}

/// Rows that match [query] on name or description, case-insensitive.
List<AllGamesRow> filterAllGames(List<AllGamesRow> rows, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return rows;
  return rows
      .where((r) =>
          r.name.toLowerCase().contains(q) || r.blurb.toLowerCase().contains(q))
      .toList();
}

/// Open the sheet. Returns the picked game id, or null for Done / the scrim —
/// which closes without a change and drops the search with the sheet.
Future<String?> showAllGamesSheet(
  BuildContext context, {
  required List<AllGamesRow> rows,
  required String? current,
  required String sizeKey,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x730B1F1A), // rgba(11,31,26,.45)
    builder: (_) =>
        AllGamesSheet(rows: rows, current: current, sizeKey: sizeKey),
  );
}

class AllGamesSheet extends StatefulWidget {
  final List<AllGamesRow> rows;
  final String? current;
  final String sizeKey;

  const AllGamesSheet({
    super.key,
    required this.rows,
    required this.current,
    required this.sizeKey,
  });

  @override
  State<AllGamesSheet> createState() => _AllGamesSheetState();
}

class _AllGamesSheetState extends State<AllGamesSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final shown = filterAllGames(widget.rows, _query);
    final height = MediaQuery.of(context).size.height * 0.86;

    // Section labels go in front of the first row of a group that has a
    // label (the playable group has none).
    final items = <Widget>[];
    AllGamesGroup? lastGroup;
    for (final r in shown) {
      if (r.group != lastGroup && r.group != AllGamesGroup.playable) {
        items.add(_SectionLabel(r.group == AllGamesGroup.notForGroup
            ? notForLabel(widget.sizeKey)
            : 'Needs 18 holes'));
      }
      lastGroup = r.group;
      items.add(_GameRow(
        row: r,
        current: r.id == widget.current,
        onTap: r.playable ? () => Navigator.of(context).pop(r.id) : null,
      ));
    }

    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: Halved.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 14, 16, MediaQuery.of(context).viewInsets.bottom + 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('All games',
                style: Halved.sectionHead()
                    .copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Done',
                style: Halved.body(color: Halved.pine, weight: FontWeight.w600)
                    .copyWith(fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 6),
        TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: 'Search games',
            prefixIcon: const Icon(Icons.search, size: 20),
            filled: true,
            fillColor: Colors.white,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Halved.cardBorder, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Halved.pine, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: _SectionLabel('No game called "${_query.trim()}"'),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 7),
                  itemBuilder: (_, i) => items[i],
                ),
        ),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, left: 2),
        child: Text(
          text.toUpperCase(),
          style: Halved.label(color: Halved.muted, weight: FontWeight.w700)
              .copyWith(fontSize: 10.5, letterSpacing: 0.8),
        ),
      );
}

class _GameRow extends StatelessWidget {
  final AllGamesRow row;
  final bool current;
  final VoidCallback? onTap;

  const _GameRow({required this.row, required this.current, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: current ? Halved.pine : const Color(0xFFE7EDE8),
            width: current ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.name,
                          style: Halved.body(
                                  color: Halved.deepPine,
                                  weight: FontWeight.w600)
                              .copyWith(fontSize: 14.5)),
                      if (row.blurb.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(row.blurb,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Halved.body(color: Halved.muted)
                                .copyWith(fontSize: 12)),
                      ],
                    ]),
              ),
              const SizedBox(width: 10),
              Text(row.range,
                  style: Halved.body(color: Halved.muted)
                      .copyWith(fontSize: 11.5)),
            ]),
          ),
        ),
      ),
    );
  }
}
