/// screens/team_play_score_entry_screen.dart
/// -----------------------------------------
/// Foursome Play score entry — the same card every other game in the app uses
/// (docs/design-review/handoff-team-play/SPEC.md §10.1).
///
/// Shaped after Survivor / Rabbit / Points 5-3-1: a tinted hole header, the
/// players stacked as rows, and [InlineScorePicker] expanding INSIDE the
/// active row's bounding box. A golfer who has entered a score anywhere in
/// this app already knows how it works, and the two earlier attempts here — a
/// full-screen stepper, then per-row steppers — were both a fourth idiom for
/// no gain.
///
/// Two formats, and only the middle of the card differs:
///
///   * **Scramble** — four men make ONE number, so there is one row: TEAM.
///     Its picker is always open, because there is nothing to choose between.
///   * **Shamble** — four balls, so four rows. Tap one to aim the picker; the
///     counting scores tint and the rest grey as they land.
///
/// **The drive is its own question**, so it gets its own control above the
/// rows rather than being smuggled onto a golfer: a chip per man, the pips on
/// the chip, and the consequence stated beside it. It never blocks the tap —
/// the team may knowingly take the shortfall, and by default a shortfall costs
/// nothing.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/inline_score_picker.dart';

class TeamPlayScoreEntryScreen extends StatefulWidget {
  final int    foursomeId;
  final String teamName;
  final String colour;

  const TeamPlayScoreEntryScreen({
    super.key,
    required this.foursomeId,
    required this.teamName,
    required this.colour,
  });

  @override
  State<TeamPlayScoreEntryScreen> createState() =>
      _TeamPlayScoreEntryScreenState();
}

class _TeamPlayScoreEntryScreenState extends State<TeamPlayScoreEntryScreen> {
  /// Null until the first load: the server picks the opening hole — the first
  /// this group has not finished, IN ITS PLAY ORDER. A shotgun group starting
  /// on 9 must not open on 1.
  int? _hole;
  /// Shamble only: whose ball the picker is aimed at.
  int? _selected;
  TeamPlayCard? _card;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final card = await context.read<AuthProvider>().client
          .getTeamPlayCard(widget.foursomeId, _hole);
      if (!mounted) return;
      setState(() { _card = card; _hole = card.hole; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setTeamScore(int? gross) async {
    await context.read<AuthProvider>().client
        .postTeamPlayScore(widget.foursomeId, hole: _hole!, gross: gross);
    await _load();
  }

  /// A shamble keeps per-golfer scores — four balls, best N net count — so
  /// these are ordinary HoleScores through the ordinary endpoint. Only the
  /// reading of them is Foursome Play's.
  Future<void> _setGolferScore(int playerId, int? gross) async {
    await context.read<AuthProvider>().client.submitScores(
      foursomeId: widget.foursomeId,
      holeNumber: _hole!,
      scores    : [{'player_id': playerId, 'gross_score': gross}],
    );
    await _load();
  }

  Future<void> _setDrive(int? playerId) async {
    await context.read<AuthProvider>().client
        .postTeamPlayDrive(widget.foursomeId, hole: _hole!, playerId: playerId);
    await _load();
  }

  void _goto(int? hole) {
    if (hole == null) return;
    setState(() { _hole = hole; _selected = null; });
    _load();
  }

  /// The golfer the picker is aimed at: the tap, else the first man still
  /// without a score, else the first row. Auto-advancing to whoever is missing
  /// is what makes four entries four taps.
  int? _activeGolfer(TeamPlayCard card) {
    final rows = card.shamble?.rows ?? const <TeamPlayShambleRow>[];
    if (rows.isEmpty) return null;
    if (_selected != null && rows.any((r) => r.playerId == _selected)) {
      return _selected;
    }
    for (final r in rows) {
      if (r.gross == null) return r.playerId;
    }
    return rows.first.playerId;
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.teamName),
        actions: [
          if (card != null)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(child: Text(_formatChip(card),
                  style: Theme.of(context).textTheme.bodySmall)),
            ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: '$_error', onRetry: _load)
          : card == null
              ? const Center(child: CircularProgressIndicator())
              : _body(card),
      bottomNavigationBar: card == null ? null : _HoleNav(
        card : card,
        hole : _hole!,
        onGo : _goto,
      ),
    );
  }

  /// `Scramble · 6` / `Shamble · 2 of 4` — the allowance and the count are
  /// named in the header so neither is hidden, even though neither belongs on
  /// a row.
  String _formatChip(TeamPlayCard card) {
    if (card.isScramble) {
      final a = card.round.allowance;
      return a == null ? 'Scramble' : 'Scramble · plays off $a';
    }
    final n = card.shamble?.count;
    return n == null ? 'Shamble' : 'Shamble · $n of 4 count';
  }

  Widget _body(TeamPlayCard card) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _HoleHeader(card: card, hole: _hole!),
        const SizedBox(height: 12),

        if (!card.drive.isOff) ...[
          _DriveStrip(card: card, hole: _hole!, onPick: _setDrive),
          const SizedBox(height: 12),
        ],

        IgnorePointer(
          // Nothing is tappable while a save is in flight — two taps on one
          // hole would race each other's reload.
          ignoring: _busy,
          child: card.isScramble
              ? _TeamScoreRow(card: card, onSet: _setTeamScore)
              : _ShambleRows(
                  card    : card,
                  selected: _activeGolfer(card),
                  onSelect: (id) => setState(() => _selected = id),
                  onSet   : _setGolferScore,
                ),
        ),

        const SizedBox(height: 14),
        // Gross on the card, net on the leaderboard. A whole-number team
        // figure applied to the round is not a stroke on a hole, and showing
        // it per hole would invite subtracting it there.
        Text(
          card.isScramble && card.round.allowance != null
              ? 'Gross on the card. The team\'s ${card.round.allowance} '
                'strokes come off the total on the leaderboard.'
              : 'Gross on the card, net on the leaderboard.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

// ── Hole header ─────────────────────────────────────────────────────────────

class _HoleHeader extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  const _HoleHeader({required this.card, required this.hole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bits = <String>[
      if (card.par != null) 'Par ${card.par}',
      if (card.yards != null) '${card.yards} yds',
      if (card.strokeIndex != null) 'SI ${card.strokeIndex}',
      // On a shotgun start the hole number is not the position in the round,
      // so say both rather than leaving a group on 9 wondering whether it is
      // on its first hole or its ninth.
      if (card.playOrder.isNotEmpty && card.playOrder.first != 1)
        '${card.positionOf(hole)} of ${card.playOrder.length}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text('Hole $hole',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        if (bits.isNotEmpty)
          Text(bits.join('  ·  '),
              textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

// ── The drive ───────────────────────────────────────────────────────────────

/// A chip per golfer, the pips on the chip, and the consequence stated beside
/// it. Its own control because it is its own question — the score belongs to
/// the team, and hanging it off a man's row would say otherwise.
class _DriveStrip extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  final Future<void> Function(int?) onPick;

  const _DriveStrip({
    required this.card, required this.hole, required this.onPick,
  });

  TeamPlayDriveWindow? get _window {
    for (final w in card.drive.windows) {
      if (hole >= w.start && hole <= w.end) return w;
    }
    return card.drive.windows.isEmpty ? null : card.drive.windows.first;
  }

  int? get _driver {
    for (final g in _window?.golfers ?? const <TeamPlayDriveGolfer>[]) {
      if (g.holes.contains(hole)) return g.playerId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A schedule needs one line on the tee, not a tracker.
    if (card.drive.isAlternating) {
      final rota = card.drive.rotaFor(hole);
      return _Panel(
        label: 'WHOSE TEE SHOT',
        child: Text(
          rota == null || rota.upLabel.isEmpty
              ? 'The team sets the pairs on the 1st tee.'
              : rota.upLabel +
                  (rota.phantomCoverName.isEmpty
                      ? ''
                      : '  ·  ${rota.phantomCoverName} → phantom'),
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
    }

    final w = _window;
    if (w == null) return const SizedBox.shrink();
    final driver = _driver;

    return _Panel(
      label   : 'WHOSE DRIVE',
      trailing: w.owed == 0
          ? Text('all square', style: theme.textTheme.labelSmall)
          : Text(
              '${w.owed} owed, ${w.holesLeft} left',
              style: theme.textTheme.labelSmall?.copyWith(
                color: w.tight || w.impossible
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in w.golfers)
                _DriveChip(
                  golfer  : g,
                  selected: g.playerId == driver,
                  onTap   : () => onPick(
                      g.playerId == driver ? null : g.playerId),
                ),
            ],
          ),
          if (w.owed > 0 && (w.tight || w.impossible)) ...[
            const SizedBox(height: 8),
            // The consequence in a sentence, on the tee — the moment a quota
            // becomes unsatisfiable is invisible to four men who have had a
            // few. It never blocks the tap.
            Text(
              w.impossible
                  ? '${w.label} cannot be satisfied now. Play on — a shortfall '
                    'is recorded, not blocked.'
                  : 'It still works, but only if every remaining hole goes to '
                    'a man who owes one.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _DriveChip extends StatelessWidget {
  final TeamPlayDriveGolfer golfer;
  final bool selected;
  final VoidCallback onTap;

  const _DriveChip({
    required this.golfer, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owes  = golfer.owes > 0;
    // Last name only — four full names do not fit a phone, and the group knows
    // who Maiolini is.
    final short = golfer.name.split(' ').last;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : null,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : (owes ? theme.colorScheme.error.withValues(alpha: 0.5)
                        : theme.colorScheme.outlineVariant),
            width: 1.5,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(short,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : null,
              )),
          const SizedBox(width: 6),
          Text(
            golfer.holes.isEmpty ? 'owes ${golfer.owes}'
                                 : golfer.holes.map((h) => 'h$h').join(' '),
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected
                  ? Colors.white70
                  : (owes ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final String  label;
  final Widget  child;
  final Widget? trailing;
  const _Panel({required this.label, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(label,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6))),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

// ── Scramble: one row, one number ───────────────────────────────────────────

class _TeamScoreRow extends StatelessWidget {
  final TeamPlayCard card;
  final Future<void> Function(int?) onSet;
  const _TeamScoreRow({required this.card, required this.onSet});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final box   = theme.colorScheme.primary;
    final par   = card.par ?? 4;

    // Always open: four men make one number, so there is nothing to choose
    // between and no reason to make the TD tap a row first.
    return Container(
      decoration: BoxDecoration(
        color: box.withValues(alpha: 0.10),
        border: Border(
          top:    BorderSide(color: box, width: 1.5),
          bottom: BorderSide(color: box, width: 1.5),
          right:  BorderSide(color: box, width: 1.5),
          left:   BorderSide(color: box, width: 4.0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(children: [
              Expanded(
                child: Text('Team score',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Text('one ball',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          InlineScorePicker(
            // Gross par, no strokes: the allowance is a whole-number team
            // figure off the round total, not a stroke on a hole, so feeding
            // it in would centre the strip on a net par nobody plays to.
            par            : par,
            strokes        : 0,
            currentScore   : card.teamScore,
            boxBorderColor : box,
            boxFillColor   : Colors.white,
            onScoreSelected: (v) => onSet(v == -1 ? null : v),
          ),
        ],
      ),
    );
  }
}

// ── Shamble: four rows, the active one open ─────────────────────────────────

class _ShambleRows extends StatelessWidget {
  final TeamPlayCard card;
  final int? selected;
  final ValueChanged<int> onSelect;
  final Future<void> Function(int playerId, int? gross) onSet;

  const _ShambleRows({
    required this.card, required this.selected,
    required this.onSelect, required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = card.shamble;
    if (h == null) return const SizedBox.shrink();
    final box = theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in h.rows)
          if (row.playerId == selected)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: box.withValues(alpha: 0.10),
                border: Border(
                  top:    BorderSide(color: box, width: 1.5),
                  bottom: BorderSide(color: box, width: 1.5),
                  right:  BorderSide(color: box, width: 1.5),
                  left:   BorderSide(color: box, width: 4.0),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _GolferLine(row: row, onTap: null),
                  InlineScorePicker(
                    par            : card.par ?? h.par ?? 4,
                    strokes        : row.strokes,
                    currentScore   : row.gross,
                    boxBorderColor : box,
                    boxFillColor   : Colors.white,
                    onScoreSelected: (v) =>
                        onSet(row.playerId, v == -1 ? null : v),
                  ),
                ],
              ),
            )
          else
            _GolferLine(row: row, onTap: () => onSelect(row.playerId)),
        const Divider(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(
              child: Text('Hole total',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            Text(
              h.teamNet == null
                  ? 'waiting on ${h.rows.where((r) => r.gross == null).length}'
                  : '${h.teamNet}',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ]),
        ),
      ],
    );
  }
}

/// One golfer's line: name, his strokes, his gross, and whether it counted.
///
/// The counting scores tint and the rest grey, live, as they are entered —
/// two men's cards do nothing on a given hole, and a man who shot 5 needs to
/// see instantly that his 5 was not used or the total looks wrong and someone
/// re-enters it.
class _GolferLine extends StatelessWidget {
  final TeamPlayShambleRow row;
  final VoidCallback? onTap;
  const _GolferLine({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final counts  = row.counts;
    final scored  = row.gross != null;
    final subdued = scored && !counts;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(
                  row.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontStyle: row.isPhantom
                        ? FontStyle.italic : FontStyle.normal,
                    color: subdued ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ),
              if (row.strokes > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('gets ${row.strokes}',
                      style: theme.textTheme.labelSmall),
                ),
              ],
              if (counts && scored) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle,
                     size: 15, color: theme.colorScheme.primary),
              ],
            ]),
          ),
          // The score box, same as every other card: the value, or an empty
          // slot inviting the tap.
          Container(
            width: 46, height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: subdued
                    ? theme.colorScheme.outlineVariant
                    : theme.colorScheme.outline,
              ),
            ),
            child: Text(
              row.gross?.toString() ?? '',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: subdued ? theme.colorScheme.onSurfaceVariant : null,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Hole navigation ─────────────────────────────────────────────────────────

/// Prev / next in PLAY order, so a shotgun group walks its own round rather
/// than the course's numbering.
class _HoleNav extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  final ValueChanged<int?> onGo;

  const _HoleNav({required this.card, required this.hole, required this.onGo});

  @override
  Widget build(BuildContext context) {
    final prev = card.prevBefore(hole);
    final next = card.nextAfter(hole);
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: prev == null ? null : () => onGo(prev),
            icon: const Icon(Icons.chevron_left, size: 20),
            label: Text(prev == null ? 'First hole' : 'Hole $prev'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: next == null ? null : () => onGo(next),
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.chevron_right, size: 20),
            label: Text(next == null ? 'Last hole' : 'Hole $next'),
          ),
        ),
      ]),
    );
  }
}
