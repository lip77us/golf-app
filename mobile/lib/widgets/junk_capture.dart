/// widgets/junk_capture.dart
/// ------------------------
/// Skins junk, captured exactly like Spots.
///
/// **The widgets are Spots'** — the same `+ Junk` button, the same tick
/// sheet, the same greenie card — with a different noun and a different
/// endpoint behind them. `handoff-skins-junk` says to build them on the same
/// code, and the reason is that they ARE the same thing to a golfer: tick
/// what he made, pick who took the greenie. Only the pot differs, and the pot
/// is not something a hole card mentions.
///
/// What is junk's own is the arithmetic, and that lives on the server: a junk
/// is worth a SKIN, one share of the same pot, where a spot is worth a spot.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import 'spots_capture.dart';

/// Per-hole junk capture for a score-entry screen. Mirrors
/// `SpotsCaptureMixin`; the two never run together, because Spots excludes
/// Skins in the catalogue and always has.
mixin JunkCaptureMixin<T extends StatefulWidget> on State<T> {
  int? _junkOpenFor;

  /// True when junk is on for this round's Skins game.
  bool junkActive(RoundProvider rp) {
    final s = rp.skinsSummary;
    return s != null && s.allowJunk && s.junkSheetTypes.isNotEmpty;
  }

  List<SpotTypeInfo> junkTypesFor(int pid, int hole, SkinsSummary? s) =>
      s?.junkSheetTypesFor(pid, hole) ?? const [];

  bool junkSheetOpenFor(int pid) => _junkOpenFor == pid;

  /// The greenie pick and the hole's own junk line, for the foot of the card.
  /// Null when there is nothing to draw.
  Widget? junkFooter(RoundProvider rp, int foursomeId, int hole) {
    final s = rp.skinsSummary;
    if (s == null || !s.allowJunk) return null;
    final fs = rp.round?.foursomes.where((f) => f.id == foursomeId).firstOrNull;
    if (fs == null) return null;
    final members = fs.memberships.where((m) => !m.player.isPhantom).toList();

    final g = s.junkGreenieInPlay ? s.junkGreenie.forHole(hole) : null;
    final greenie = g == null
        ? null
        : GreenieCard(
            hole: g,
            players: [
              for (final m in members)
                (id: m.player.id,
                 short: m.player.shortName.isNotEmpty
                     ? m.player.shortName
                     : m.player.name),
            ],
            onPick: (pid) => _pickGreenie(foursomeId, hole, pid),
            onClear: g.decided ? () => _clearGreenie(foursomeId, hole) : null,
          );

    // The only place a DERIVED junk is visible on the hole: a birdie is read
    // off the score and never appears on a button, so without this line it
    // takes a share of the pot with nothing on the card saying so.
    final rows = <({String name, String detail, int total})>[];
    for (final m in members) {
      final got = s.junkTypesFor(m.player.id, hole);
      if (got.isEmpty) continue;
      rows.add((
        name: m.player.shortName.isNotEmpty
            ? m.player.shortName
            : m.player.name,
        detail: got
            .map((t) => t.worth == 1 ? t.label : '${t.label} ${t.worth}')
            .join(' + '),
        total: got.fold<int>(0, (a, t) => a + t.worth),
      ));
    }

    if (greenie == null && rows.isEmpty) return null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (greenie != null) greenie,
      if (rows.isNotEmpty)
        extrasThisHole(rows: rows, heading: 'JUNK · THIS HOLE'),
    ]);
  }

  List<Widget> junkFooters(RoundProvider rp, int foursomeId, int hole) {
    final w = junkFooter(rp, foursomeId, hole);
    return w == null ? const [] : [w];
  }

  /// Open the tick sheet for one golfer on one hole.
  Future<void> openJunkSheet(int foursomeId, int pid, int hole) async {
    final rp = context.read<RoundProvider>();
    final s  = rp.skinsSummary;
    if (s == null) return;
    if (s.junkSheetTypes.isEmpty) {
      _moan('No junk is being ticked on the hole in this round.');
      return;
    }
    final fs = rp.round?.foursomes.where((f) => f.id == foursomeId).firstOrNull;
    final name = fs?.memberships
            .where((m) => m.player.id == pid)
            .map((m) => m.player.name)
            .firstOrNull ??
        'Junk';
    setState(() => _junkOpenFor = pid);
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => buildExtrasSheet(
        title: '$name · hole $hole',
        offered: s.junkSheetTypes,
        initial: {for (final t in junkTypesFor(pid, hole, s)) t.type},
        greenieOnThisHole:
            s.junkGreenieInPlay && s.junkGreenie.forHole(hole) != null,
        // Junk has no plural: "3 junk", never "3 junks".
        noun: 'junk',
        nounPlural: 'junk',
      ),
    );
    if (mounted) setState(() => _junkOpenFor = null);
    if (picked == null || !mounted) return;
    await _save(foursomeId, pid, hole, picked);
  }

  Future<void> _save(
      int foursomeId, int pid, int hole, List<String> types) async {
    final rp     = context.read<RoundProvider>();
    final client = context.read<AuthProvider>().client;
    try {
      // Only the golfer who was edited: the endpoint leaves others alone, so
      // posting the whole foursome would let one scorer overwrite another on
      // the same hole.
      rp.setSkinsSummary(await client.postSkinsJunk(
        foursomeId,
        holeNumber: hole,
        junkEntries: [{'player_id': pid, 'types': types}],
      ));
    } catch (_) {
      _moan('Could not save junk. Tap again to retry.');
    }
  }

  Future<void> _pickGreenie(int foursomeId, int hole, int? pid) async {
    final rp     = context.read<RoundProvider>();
    final client = context.read<AuthProvider>().client;
    try {
      rp.setSkinsSummary(await client.postSkinsGreenie(
          foursomeId, holeNumber: hole, playerId: pid));
    } catch (_) {
      _moan('Could not save the greenie. Tap again to retry.');
    }
  }

  Future<void> _clearGreenie(int foursomeId, int hole) async {
    final rp     = context.read<RoundProvider>();
    final client = context.read<AuthProvider>().client;
    try {
      rp.setSkinsSummary(
          await client.deleteSkinsGreenie(foursomeId, holeNumber: hole));
    } catch (_) {
      _moan('Could not clear the greenie. Tap again to retry.');
    }
  }

  void _moan(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
