import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/round_provider.dart';

class ScorecardScreen extends StatefulWidget {
  final int foursomeId;
  const ScorecardScreen({super.key, required this.foursomeId});

  @override
  State<ScorecardScreen> createState() => _ScorecardScreenState();
}

class _ScorecardScreenState extends State<ScorecardScreen> {
  // Pending edits: hole → player_id → gross score (before submission)
  final Map<int, Map<int, int>> _pending = {};
  int _selectedHole = 1;
  bool _pinkBallLost = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rp = context.read<RoundProvider>();
      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      }
    });
  }

  bool get _hasPinkBall {
    final rp = context.read<RoundProvider>();
    return rp.round?.activeGames.contains('pink_ball') ?? false;
  }

  List<Membership> _realPlayers(Scorecard sc, Round? round) {
    final foursome = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (foursome != null) return foursome.realPlayers;
    // Fallback: derive from scorecard first hole
    if (sc.holes.isEmpty) return [];
    return sc.holes.first.scores
        .map((s) => Membership(
              id: s.playerId,
              player: PlayerProfile(
                id: s.playerId,
                name: s.playerName,
                handicapIndex: '0',
                isPhantom: false,
                email: '',
              ),
              courseHandicap: 0,
              playingHandicap: s.handicapStrokes,
            ))
        .toList();
  }

  void _setScore(int hole, int playerId, int? gross) {
    setState(() {
      _pending.putIfAbsent(hole, () => {});
      if (gross == null) {
        _pending[hole]!.remove(playerId);
      } else {
        _pending[hole]![playerId] = gross;
      }
    });
  }

  Future<void> _submitHole(BuildContext context) async {
    final edits = _pending[_selectedHole];
    if (edits == null || edits.isEmpty) return;

    final scores = edits.entries
        .map((e) => {'player_id': e.key, 'gross_score': e.value})
        .toList();

    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
      foursomeId: widget.foursomeId,
      holeNumber: _selectedHole,
      scores: scores,
      pinkBallLost: _pinkBallLost,
    );

    if (!ok && mounted) {
      final msg = context.read<RoundProvider>().error ?? 'Failed to save hole.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Theme.of(context).colorScheme.error,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Theme.of(context).colorScheme.onError,
            onPressed: () => _submitHole(context),
          ),
        ),
      );
    }

    if (ok && mounted) {
      setState(() {
        _pending.remove(_selectedHole);
        _pinkBallLost = false;
        // Auto-advance to next hole
        if (_selectedHole < 18) _selectedHole++;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scores saved ✓'),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text('Scorecard — Group ${rp.scorecard?.groupNumber ?? ""}'),
        actions: [
          if (rp.scorecard != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => rp.loadScorecard(widget.foursomeId),
            ),
        ],
      ),
      body: _buildBody(context, rp),
    );
  }

  Widget _buildBody(BuildContext context, RoundProvider rp) {
    if (rp.loadingScorecard) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.scorecard == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(rp.error!, style: const TextStyle(color: Colors.red)),
          FilledButton(
            onPressed: () => rp.loadScorecard(widget.foursomeId),
            child: const Text('Retry'),
          ),
        ]),
      );
    }
    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final players = _realPlayers(sc, rp.round);

    return Column(
      children: [
        // Hole selector
        _HoleSelector(
          selectedHole: _selectedHole,
          scorecard: sc,
          onHoleSelected: (h) => setState(() => _selectedHole = h),
        ),
        const Divider(height: 1),

        // Scrollable scorecard grid
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                _ScorecardGrid(
                  scorecard: sc,
                  players: players,
                  pendingScores: _pending,
                  selectedHole: _selectedHole,
                  onScoreChanged: _setScore,
                ),
                // Totals
                if (sc.totals.isNotEmpty)
                  _TotalsTable(totals: sc.totals),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),

        // Entry panel for selected hole
        _HoleEntryPanel(
          hole: sc.holeData(_selectedHole),
          players: players,
          pending: _pending[_selectedHole] ?? {},
          hasPinkBall: _hasPinkBall,
          pinkBallLost: _pinkBallLost,
          submitting: rp.submitting,
          onScoreChanged: (pid, gross) => _setScore(_selectedHole, pid, gross),
          onPinkBallLostChanged: (v) => setState(() => _pinkBallLost = v),
          onSubmit: () => _submitHole(context),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Hole selector row
// ---------------------------------------------------------------------------

class _HoleSelector extends StatelessWidget {
  final int selectedHole;
  final Scorecard scorecard;
  final void Function(int) onHoleSelected;

  const _HoleSelector({
    required this.selectedHole,
    required this.scorecard,
    required this.onHoleSelected,
  });

  bool _isComplete(int hole) {
    final h = scorecard.holeData(hole);
    if (h == null) return false;
    return h.scores.every((s) => s.grossScore != null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: 18,
        itemBuilder: (_, i) {
          final hole     = i + 1;
          final selected = hole == selectedHole;
          final done     = _isComplete(hole);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            child: GestureDetector(
              onTap: () => onHoleSelected(hole),
              child: Container(
                width: 36,
                decoration: BoxDecoration(
                  color: selected
                      ? theme.colorScheme.primary
                      : done
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$hole',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: selected ? Colors.white : null,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scorecard grid (horizontally scrollable)
// ---------------------------------------------------------------------------

class _ScorecardGrid extends StatelessWidget {
  final Scorecard scorecard;
  final List<Membership> players;
  final Map<int, Map<int, int>> pendingScores;
  final int selectedHole;
  final void Function(int hole, int playerId, int? gross) onScoreChanged;

  const _ScorecardGrid({
    required this.scorecard,
    required this.players,
    required this.pendingScores,
    required this.selectedHole,
    required this.onScoreChanged,
  });

  @override
  Widget build(BuildContext context) {
    const colW   = 44.0;
    const nameW  = 120.0;
    const hdrH   = 36.0;
    const rowH   = 52.0;
    final theme  = Theme.of(context);

    final holes = List.generate(18, (i) => i + 1);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const FixedColumnWidth(colW),
        columnWidths: {0: const FixedColumnWidth(nameW)},
        border: TableBorder.all(
            color: theme.colorScheme.outlineVariant, width: 0.5),
        children: [
          // Header row: hole numbers
          TableRow(
            decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest),
            children: [
              _cell('Hole', height: hdrH, bold: true),
              ...holes.map((h) => _cell('$h',
                  height: hdrH,
                  bold: true,
                  highlight: h == selectedHole
                      ? theme.colorScheme.primaryContainer
                      : null)),
            ],
          ),
          // Par row
          TableRow(
            decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow),
            children: [
              _cell('Par', height: hdrH, italic: true),
              ...holes.map((h) {
                final hd = scorecard.holeData(h);
                return _cell(hd != null ? '${hd.par}' : '-', height: hdrH);
              }),
            ],
          ),
          // SI row
          TableRow(
            decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow),
            children: [
              _cell('SI', height: hdrH, italic: true),
              ...holes.map((h) {
                final hd = scorecard.holeData(h);
                return _cell(
                    hd != null ? '${hd.strokeIndex}' : '-', height: hdrH);
              }),
            ],
          ),
          // Player rows
          ...players.map((m) {
            return TableRow(
              children: [
                _nameCell(m.player.name, m.playingHandicap, height: rowH),
                ...holes.map((h) {
                  final saved   = scorecard.holeData(h)?.scoreFor(m.player.id);
                  final pending = pendingScores[h]?[m.player.id];
                  final gross   = pending ?? saved?.grossScore;
                  final net     = saved?.netScore;
                  final hd      = scorecard.holeData(h);
                  final par     = hd?.par ?? 4;
                  final isSelected = h == selectedHole;

                  Color? bg;
                  if (isSelected)       bg = theme.colorScheme.primaryContainer.withOpacity(0.25);
                  if (gross != null && net != null) {
                    final diff = gross - par;
                    if (diff <= -2)      bg = Colors.yellow.shade100;
                    else if (diff == -1) bg = Colors.green.shade100;
                    else if (diff == 1)  bg = Colors.orange.shade50;
                    else if (diff >= 2)  bg = Colors.red.shade50;
                  }
                  if (pending != null)  bg = theme.colorScheme.tertiaryContainer.withOpacity(0.4);

                  return TableCell(
                    child: Container(
                      height: rowH,
                      color: bg,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            gross != null ? '$gross' : '—',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          if (net != null && pending == null)
                            Text('($net)',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: theme.textTheme.bodySmall?.color)),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _cell(String text,
      {required double height,
      bool bold = false,
      bool italic = false,
      Color? highlight}) {
    return TableCell(
      child: Container(
        height: height,
        color: highlight,
        alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : null,
            fontStyle: italic ? FontStyle.italic : null,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _nameCell(String name, int hcp, {required double height}) {
    return TableCell(
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
            Text('Hcp $hcp', style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Totals table
// ---------------------------------------------------------------------------

class _TotalsTable extends StatelessWidget {
  final List<PlayerTotals> totals;
  const _TotalsTable({required this.totals});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Text('Totals',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 32,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 36,
                columnSpacing: 16,
                columns: const [
                  DataColumn(label: Text('Player')),
                  DataColumn(label: Text('F'), numeric: true),
                  DataColumn(label: Text('B'), numeric: true),
                  DataColumn(label: Text('Gross'), numeric: true),
                  DataColumn(label: Text('Net'), numeric: true),
                  DataColumn(label: Text('Pts'), numeric: true),
                ],
                rows: totals.map((t) => DataRow(cells: [
                      DataCell(Text(t.name)),
                      DataCell(Text('${t.frontGross}')),
                      DataCell(Text('${t.backGross}')),
                      DataCell(Text('${t.totalGross}',
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                      DataCell(Text('${t.totalNet}',
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                      DataCell(Text('${t.totalStableford}')),
                    ])).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Entry panel — bottom sheet for current hole
// ---------------------------------------------------------------------------

class _HoleEntryPanel extends StatelessWidget {
  final ScorecardHole? hole;
  final List<Membership> players;
  final Map<int, int> pending;
  final bool hasPinkBall;
  final bool pinkBallLost;
  final bool submitting;
  final void Function(int playerId, int? gross) onScoreChanged;
  final void Function(bool) onPinkBallLostChanged;
  final VoidCallback onSubmit;

  const _HoleEntryPanel({
    required this.hole,
    required this.players,
    required this.pending,
    required this.hasPinkBall,
    required this.pinkBallLost,
    required this.submitting,
    required this.onScoreChanged,
    required this.onPinkBallLostChanged,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
              color: Colors.black12,
              blurRadius: 8,
              offset: const Offset(0, -2))
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hole != null)
            Row(children: [
              Text('Hole ${hole!.holeNumber}',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              Text('Par ${hole!.par} • SI ${hole!.strokeIndex}',
                  style: theme.textTheme.bodySmall),
              if (hole!.yards != null) ...[
                const SizedBox(width: 12),
                Text('${hole!.yards}y',
                    style: theme.textTheme.bodySmall),
              ],
            ]),
          const SizedBox(height: 8),
          ...players.map((m) => _ScoreRow(
                player: m,
                currentValue: pending[m.player.id],
                onChanged: (v) => onScoreChanged(m.player.id, v),
              )),
          if (hasPinkBall) ...[
            const SizedBox(height: 4),
            Row(children: [
              Checkbox(
                value: pinkBallLost,
                onChanged: (v) => onPinkBallLostChanged(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
              const Text('🔴 Pink ball lost on this hole'),
            ]),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton.icon(
              onPressed: (submitting || pending.isEmpty) ? null : onSubmit,
              icon: submitting
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check, size: 18),
              label: Text(submitting ? 'Saving…' : 'Save Hole'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  final Membership player;
  final int?       currentValue;
  final void Function(int?) onChanged;

  const _ScoreRow({
    required this.player,
    required this.currentValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(player.player.name)),
        // quick-tap score buttons: par-2 through par+4
        ...List.generate(7, (i) {
          final score = 2 + i; // 2..8
          final sel   = currentValue == score;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: GestureDetector(
              onTap: () => onChanged(sel ? null : score),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: sel
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$score',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: sel ? Colors.white : null,
                  ),
                ),
              ),
            ),
          );
        }),
      ]),
    );
  }
}
