/// widgets/spots_capture.dart
/// --------------------------
/// Shared Spots capture used by every score-entry screen (the universal one
/// and the dedicated Wolf / Rabbit / Nassau / Points / Quota screens).
///
/// **Option D** of the five the design compared: one line per golfer — name,
/// a `+ Spots` button, score box — and the button opens a tick sheet of the
/// types in play. As lean on the hole as the old stepper, and the receipt
/// still names the type, which is the whole argument for it.
///
/// Three things are deliberately NOT in the sheet:
///   * **greenie** has its own pick at the foot of the hole card, because
///     only one golfer can win it and the app works out what it is worth;
///   * **birdie** and **eagle** are read off the entered scores and never
///     appear on the hole at all.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';

/// The one-line description for each type. **Copy, so it lives here** — the
/// server owns the slug, the label and the arithmetic, the way the game
/// catalogue owns a game's blurb while `GameType` owns its name.
String spotTypeBlurb(String type) {
  switch (type) {
    case 'greenie':
      return 'Par 3s only. On the green in one and closest to the pin.';
    case 'sandy':
      return 'Par or better after being in a bunker.';
    case 'poley':
      return 'Putt holed from longer than the flagstick.';
    case 'birdie':
      return 'Counted from the scores. Not entered on the hole.';
    case 'eagle':
      return 'Worth 2 spots, not added to a birdie. Counted from the scores.';
    case 'chippy':
      return 'Holed from off the green.';
    case 'barky':
      return 'Par or better after hitting a tree.';
    case 'hogan':
      return 'Fairway, green, two putts. A par 5 adds a second fairway.';
    case 'snake':
      return 'Three-putt. Pays the other way — the snake pays everyone else.';
    case 'other':
      return 'Anything else the group agrees on: long drive, first to par.';
    default:
      return '';
  }
}

/// The button on a golfer's line. Empty it reads `+ Spots`; with picks it
/// reads the count and the type names, which is what the stepper could not
/// say. Long lists ellipsise and **the count always survives** — losing the
/// badge to a long name would leave the row saying nothing.
class SpotsButton extends StatelessWidget {
  final List<SpotTypeInfo> types;
  final VoidCallback       onTap;
  /// Drawn while this golfer's sheet is open, so the row the sheet belongs to
  /// is obvious on a card of four.
  final bool               focused;

  const SpotsButton({
    super.key,
    required this.types,
    required this.onTap,
    this.focused = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = types.isEmpty;
    final count = types.fold<int>(0, (a, t) => a + t.worth);
    final line  = types.map((t) => t.label).join(', ');

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: empty ? null : theme.colorScheme.primary.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: focused
                ? theme.colorScheme.primary
                : (empty
                    ? theme.colorScheme.outlineVariant
                    : theme.colorScheme.primary.withValues(alpha: .45)),
            width: focused ? 2 : 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (empty) ...[
            Icon(Icons.add, size: 15, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 3),
            Text('Spots',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ] else ...[
            // The badge is laid out first and never shrinks, so a long type
            // list eats into the names and not into the number.
            Text('$count',
                style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.primary)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The greenie pick, at the foot of a par 3's hole card.
///
/// **Nobody is an answer**, not a missing one: it is what rolls the worth to
/// the next par 3, so it sits in the same single-select row as the golfers
/// rather than being an absence of a choice.
class GreenieCard extends StatelessWidget {
  final SpotsGreenieHole        hole;
  final List<({int id, String short})> players;
  final ValueChanged<int?>      onPick;
  /// Tapping the current answer again un-answers the hole — back to
  /// undecided, which adds nothing to the next par 3.
  final VoidCallback?           onClear;

  const GreenieCard({
    super.key,
    required this.hole,
    required this.players,
    required this.onPick,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = hole.decided;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Greenie · worth ${hole.worth}',
              style: theme.textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (hole.carriedFrom != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Halved.roleFill,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Halved.roleLine),
              ),
              child: Text('Carried from the ${_ordinal(hole.carriedFrom!)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: Halved.role, fontWeight: FontWeight.bold)),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in players)
            ChoiceChip(
              label: Text(p.short),
              selected: hole.winnerId == p.id,
              onSelected: (on) => on
                  ? onPick(p.id)
                  : (onClear == null ? onPick(p.id) : onClear!()),
            ),
          ChoiceChip(
            label: const Text('Nobody'),
            selected: picked && hole.winnerId == null,
            onSelected: (on) => on
                ? onPick(null)
                : (onClear == null ? onPick(null) : onClear!()),
          ),
        ]),
      ]),
    );
  }
}

String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  switch (n % 10) {
    case 1:  return '${n}st';
    case 2:  return '${n}nd';
    case 3:  return '${n}rd';
    default: return '${n}th';
  }
}

/// Per-hole Spots capture for a score-entry screen. Owns the tick sheet, the
/// greenie pick, and the writes behind both. Call [disposeSpots] from the
/// State's dispose().
mixin SpotsCaptureMixin<T extends StatefulWidget> on State<T> {
  /// Which golfer's sheet is open, for the focused ring on his button.
  int? _spotsOpenFor;

  /// True when Spots is on for this round, so the controls should show.
  bool spotsActive(RoundProvider rp) {
    final games = rp.round?.activeGames ?? const <String>[];
    return games.contains('spots') &&
        (rp.spotsSummary?.players.isNotEmpty ?? false);
  }

  /// The SHEET types a golfer has on a hole — what his button reads.
  List<SpotTypeInfo> spotsTypesFor(int pid, int hole, SpotsSummary? s) =>
      s?.sheetTypesFor(pid, hole) ?? const [];

  bool spotsSheetOpenFor(int pid) => _spotsOpenFor == pid;

  /// Everything Spots adds at the foot of a hole card: the greenie pick on a
  /// par 3, and a line saying what each golfer has on the hole.
  ///
  /// Null when there is nothing to draw. **The server decides which holes are
  /// par 3s** — it has the pars and it is the one walking the carry, so a
  /// client deriving them would be a second answer to the same question.
  Widget? spotsFooter(RoundProvider rp, int foursomeId, int hole) {
    final s = rp.spotsSummary;
    if (s == null || !spotsActive(rp)) return null;
    final fs = rp.round?.foursomes.where((f) => f.id == foursomeId).firstOrNull;
    if (fs == null) return null;
    final members =
        fs.memberships.where((m) => !m.player.isPhantom).toList();

    final g = s.greenieInPlay ? s.greenie.forHole(hole) : null;
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

    // **The only place a DERIVED spot is visible on the hole.** A birdie is
    // read off the score and never appears on a button, so without this line
    // it adds money with nothing on the card saying so — and the greenie's
    // worth is only legible beside it ("Greenie 2 + birdie = 3").
    final rows = <({String name, String detail, int total})>[];
    for (final m in members) {
      final got = s.allTypesFor(m.player.id, hole);
      if (got.isEmpty) continue;
      final total = got.fold<int>(0, (a, t) => a + t.worth);
      rows.add((
        name: m.player.shortName.isNotEmpty
            ? m.player.shortName
            : m.player.name,
        detail: got
            .map((t) => t.worth == 1 ? t.label : '${t.label} ${t.worth}')
            .join(' + '),
        total: total,
      ));
    }

    if (greenie == null && rows.isEmpty) return null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (greenie != null) greenie,
      if (rows.isNotEmpty) _SpotsThisHole(rows: rows),
    ]);
  }

  /// `spotsFooter` as a spread, for a `children:` list that cannot hold a
  /// local. Empty when the hole has nothing of Spots on it.
  List<Widget> greenieCards(RoundProvider rp, int foursomeId, int hole) {
    final w = spotsFooter(rp, foursomeId, hole);
    return w == null ? const [] : [w];
  }

  Future<void> _pickGreenie(int foursomeId, int hole, int? pid) async {
    final rp     = context.read<RoundProvider>();
    final client = context.read<AuthProvider>().client;
    try {
      rp.setSpotsSummary(await client.postSpotsGreenie(
          foursomeId, holeNumber: hole, playerId: pid));
    } catch (_) {
      _moan('Could not save the greenie. Tap again to retry.');
    }
  }

  Future<void> _clearGreenie(int foursomeId, int hole) async {
    final rp     = context.read<RoundProvider>();
    final client = context.read<AuthProvider>().client;
    try {
      rp.setSpotsSummary(
          await client.deleteSpotsGreenie(foursomeId, holeNumber: hole));
    } catch (_) {
      _moan('Could not clear the greenie. Tap again to retry.');
    }
  }

  /// Open the tick sheet for one golfer on one hole.
  ///
  /// The golfer's NAME is resolved here rather than passed in: eight score
  /// screens call this and each had its own way of reaching a short name, so
  /// taking it as an argument would have been eight chances to pass the wrong
  /// one. The sheet uses the full name — it asks which of four men this is
  /// before anybody has hit a shot, and `P Lip` over `P Lee` is a coin toss,
  /// the same reasoning as Hot Seat's order sheet.
  Future<void> openSpotsSheet(int foursomeId, int pid, int hole) async {
    final rp = context.read<RoundProvider>();
    final s  = rp.spotsSummary;
    if (s == null) return;
    final fs = rp.round?.foursomes.where((f) => f.id == foursomeId).firstOrNull;
    final name = fs?.memberships
            .where((m) => m.player.id == pid)
            .map((m) => m.player.name)
            .firstOrNull ??
        'Spots';
    final offered = s.sheetTypes;
    if (offered.isEmpty) {
      _moan('No spots are being ticked on the hole in this round.');
      return;
    }
    setState(() => _spotsOpenFor = pid);
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SpotsSheet(
        title: '$name · hole $hole',
        offered: offered,
        initial: {for (final t in spotsTypesFor(pid, hole, s)) t.type},
      ),
    );
    if (mounted) setState(() => _spotsOpenFor = null);
    if (picked == null || !mounted) return;
    await _saveTicks(foursomeId, pid, hole, picked);
  }

  Future<void> _saveTicks(
      int foursomeId, int pid, int hole, List<String> types) async {
    final rp     = context.read<RoundProvider>();
    final client = context.read<AuthProvider>().client;
    try {
      // **Only the golfer who was edited is sent.** The endpoint leaves
      // golfers it was not given alone, so posting the whole foursome would
      // make one scorer's save overwrite another's on the same hole.
      rp.setSpotsSummary(await client.postSpotsTally(
        foursomeId,
        holeNumber: hole,
        entries: [{'player_id': pid, 'types': types}],
      ));
    } catch (_) {
      _moan('Could not save spots. Tap again to retry.');
    }
  }

  void _moan(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void disposeSpots() {}
}

class _SpotsThisHole extends StatelessWidget {
  final List<({String name, String detail, int total})> rows;
  const _SpotsThisHole({required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SPOTS · THIS HOLE',
            style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10, letterSpacing: .5, fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(children: [
              SizedBox(
                width: 56,
                child: Text(r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: Text(r.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              const SizedBox(width: 6),
              Text('= ${r.total}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: r.total < 0
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary)),
            ]),
          ),
      ]),
    );
  }
}

class _SpotsSheet extends StatefulWidget {
  final String             title;
  final List<SpotTypeInfo> offered;
  final Set<String>        initial;

  const _SpotsSheet({
    required this.title,
    required this.offered,
    required this.initial,
  });

  @override
  State<_SpotsSheet> createState() => _SpotsSheetState();
}

class _SpotsSheetState extends State<_SpotsSheet> {
  late final Set<String> _picked = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The count is the SUM OF WORTHS, not the number of ticks: a snake takes
    // one away, so "Done · 0 spots" after ticking a sandy and a snake is the
    // honest number and the button has to be able to say it.
    final n = widget.offered
        .where((t) => _picked.contains(t.type))
        .fold<int>(0, (a, t) => a + t.worth);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text('Tick each spot he made. One of each per hole.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final t in widget.offered)
                CheckboxListTile(
                  value: _picked.contains(t.type),
                  onChanged: (on) => setState(() => on == true
                      ? _picked.add(t.type)
                      : _picked.remove(t.type)),
                  title: Text(t.label),
                  subtitle: Text(spotTypeBlurb(t.type),
                      style: theme.textTheme.bodySmall),
                  controlAffinity: ListTileControlAffinity.trailing,
                  dense: true,
                ),
            ]),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_picked.toList()),
              child: Text('Done · $n spot${n.abs() == 1 ? '' : 's'}'),
            ),
          ),
        ]),
    );
  }
}
