/// screens/pink_ball_screen.dart
///
/// Score-entry screen for tournament rounds that include the Pink Ball game.
///
/// Layout:
///   • AppBar: "Pink Ball — Group N"  |  scorecard icon
///   • Carrier banner: "Hole N — [PlayerName] carries the [Pink] Ball"
///   • Player score rows (one per real player)
///   • Ball-lost toggle: "Lost the Pink Ball on this hole"
///   • Bottom nav: ← Prev  |  Next →
///
/// Scores are submitted via RoundProvider.submitHole() which persists offline
/// and syncs automatically (same path as all other entry screens).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/net_score_button.dart';

// Reasonable range of gross scores to show in the picker
const _minScore = 1;
const _maxScore = 12;

class PinkBallScreen extends StatefulWidget {
  final int foursomeId;
  const PinkBallScreen({super.key, required this.foursomeId});

  @override
  State<PinkBallScreen> createState() => _PinkBallScreenState();
}

class _PinkBallScreenState extends State<PinkBallScreen> {
  int  _holeIndex = 0;          // 0-based; displayed as hole _holeIndex+1
  bool _ballLost  = false;
  bool _saving    = false;

  String _ballColor = 'Pink';
  List<int> _order  = [];       // 18 player PKs (carrier per hole)
  bool _configLoaded = false;

  // Per-player gross score edits for the current hole.
  // Null = not yet entered this session (uses stored value from scorecard).
  final Map<int, int?> _pendingScores = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initScreen();
    });
  }

  Future<void> _initScreen() async {
    final rp = context.read<RoundProvider>();
    if (rp.scorecard == null) {
      await rp.loadScorecard(widget.foursomeId);
    }
    // Jump to first unplayed hole
    final sc = rp.scorecard;
    if (sc != null) {
      final firstEmpty = sc.holes.indexWhere(
          (h) => h.scores.any((s) => s.grossScore == null));
      if (firstEmpty >= 0) {
        setState(() => _holeIndex = firstEmpty);
      }
    }
    // Load pink ball config (ball colour + order)
    await _loadConfig();
  }

  Future<void> _loadConfig() async {
    final rp      = context.read<RoundProvider>();
    final roundId = rp.round?.id;
    if (roundId == null) return;
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getPinkBallSetup(roundId);
      final foursomeData = (data['foursomes'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (f) => (f['foursome_id'] as int?) == widget.foursomeId,
            orElse: () => <String, dynamic>{},
          );
      final rawOrder = foursomeData['order'] as List? ?? [];
      final order   = rawOrder.isEmpty
          ? <int>[]
          : List<int>.from(rawOrder.map((v) => v as int));
      setState(() {
        _ballColor    = data['ball_color'] as String? ?? 'Pink';
        _order        = order;
        _configLoaded = true;
      });
    } catch (_) {
      final fs = rp.round?.foursomes
          .firstWhere((f) => f.id == widget.foursomeId,
              orElse: () => rp.round!.foursomes.first);
      setState(() {
        _order        = fs?.pinkBallOrder ?? [];
        _configLoaded = true;
      });
    }
    // If the foursome hasn't set an order yet, prompt them to do so now.
    if (_order.isEmpty && mounted) {
      await _promptSetOrder();
    }
  }

  /// Show a bottom sheet letting the foursome drag-to-reorder their players
  /// for the ball rotation.  Generates a round-robin 18-hole order on confirm.
  Future<void> _promptSetOrder() async {
    final rp = context.read<RoundProvider>();
    final foursome = rp.round?.foursomes.firstWhere(
        (f) => f.id == widget.foursomeId,
        orElse: () => rp.round!.foursomes.first);
    final members = foursome?.memberships
            .where((m) => !m.player.isPhantom)
            .toList() ??
        [];
    if (members.isEmpty) return;

    // Start with current membership order
    final orderedMembers = List.of(members);

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,   // must confirm before continuing
      enableDrag: false,
      isScrollControlled: true,
      builder: (ctx) => _OrderSetupSheet(
        ballColor: _ballColor,
        members:   orderedMembers,
        onConfirm: (List<int> playerOrder) async {
          // Round-robin over 18 holes
          final fullOrder = List.generate(
              18, (i) => playerOrder[i % playerOrder.length]);
          try {
            final client = context.read<AuthProvider>().client;
            await client.postPinkBallOrder(
                widget.foursomeId, order: fullOrder);
            setState(() => _order = fullOrder);
          } catch (_) {
            // Non-fatal — the order stays empty; they can retry
          }
        },
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  int get _holeNumber => _holeIndex + 1;

  /// Player PK who carries the ball on the current hole.
  int? get _carrierId {
    if (_order.isEmpty) return null;
    return _order[_holeIndex % _order.length];
  }

  ScorecardHole? _currentHole(Scorecard sc) {
    if (_holeIndex >= sc.holes.length) return null;
    return sc.holes[_holeIndex];
  }

  /// Gross score to SHOW for a player on the current hole:
  /// 1. Session-pending edit (_pendingScores)
  /// 2. Stored gross from scorecard
  int? _displayScore(int playerId, ScorecardHole hole) {
    if (_pendingScores.containsKey(playerId)) return _pendingScores[playerId];
    return hole.scores
        .where((s) => s.playerId == playerId)
        .firstOrNull
        ?.grossScore;
  }

  bool _holeIsComplete(ScorecardHole hole, List<Membership> realMembers) {
    for (final m in realMembers) {
      final score = _displayScore(m.player.id, hole);
      if (score == null) return false;
    }
    return true;
  }

  // ── Score submission ──────────────────────────────────────────────────────

  Future<void> _save({bool advance = true}) async {
    final rp = context.read<RoundProvider>();
    final sc = rp.scorecard;
    if (sc == null) return;

    final hole        = _currentHole(sc);
    final realMembers = rp.round?.foursomes
        .firstWhere((f) => f.id == widget.foursomeId,
            orElse: () => rp.round!.foursomes.first)
        .memberships
        .where((m) => !m.player.isPhantom)
        .toList() ?? [];

    // Build score list from pending edits + existing stored scores
    final scoreList = <Map<String, int>>[];
    for (final m in realMembers) {
      final gross = _pendingScores.containsKey(m.player.id)
          ? _pendingScores[m.player.id]
          : hole?.scores
              .where((s) => s.playerId == m.player.id)
              .firstOrNull
              ?.grossScore;
      if (gross != null) {
        scoreList.add({'player_id': m.player.id, 'gross_score': gross});
      }
    }

    if (scoreList.isEmpty) return;

    setState(() => _saving = true);
    final ok = await rp.submitHole(
      foursomeId:   widget.foursomeId,
      holeNumber:   _holeNumber,
      scores:       scoreList,
      pinkBallLost: _ballLost,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok && advance && _holeIndex < 17) {
      setState(() {
        _holeIndex++;
        _ballLost = false;
        _pendingScores.clear();
      });
    } else if (ok && advance && _holeIndex == 17) {
      // Finished hole 18
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All 18 holes saved!')),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp    = context.watch<RoundProvider>();
    final sc    = rp.scorecard;
    final round = rp.round;

    if (rp.loadingScorecard || sc == null || !_configLoaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pink Ball')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final foursome = round?.foursomes.firstWhere(
        (f) => f.id == widget.foursomeId,
        orElse: () => round!.foursomes.first);
    final realMembers = foursome?.memberships
            .where((m) => !m.player.isPhantom)
            .toList() ??
        [];

    final hole = _currentHole(sc);
    final par  = hole?.par ?? 4;

    // carrier name
    final cid          = _carrierId;
    final carrierMem   = cid == null
        ? null
        : realMembers.firstWhere((m) => m.player.id == cid,
            orElse: () => realMembers.first);
    final carrierName  = carrierMem?.player.name ?? '—';

    final complete = hole != null && _holeIsComplete(hole, realMembers);
    final groupNum = foursome?.groupNumber ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('$_ballColor Ball — Group $groupNum'),
        actions: [
          IconButton(
            icon: const Icon(Icons.table_chart_outlined),
            tooltip: 'View scorecard',
            onPressed: () {
              context.read<RoundProvider>().loadScorecard(widget.foursomeId);
              Navigator.of(context).pushNamed('/scorecard', arguments: {
                'foursomeId': widget.foursomeId,
                'readOnly': true,
              });
            },
          ),
        ],
      ),
      body: Column(children: [
        // ── Hole chip strip ───────────────────────────────────────────────
        _HoleChipStrip(
          holeIndex:    _holeIndex,
          scorecard:    sc,
          realMembers:  realMembers,
          onTap:        (i) => setState(() {
            _holeIndex = i;
            _ballLost  = false;
            _pendingScores.clear();
          }),
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              // ── Carrier banner ────────────────────────────────────────
              _CarrierBanner(
                holeNumber:  _holeNumber,
                par:         par,
                yards:       hole?.yards,
                si:          hole?.strokeIndex,
                carrierName: carrierName,
                ballColor:   _ballColor,
              ),
              const SizedBox(height: 12),

              // ── Player score rows ─────────────────────────────────────
              ...realMembers.map((m) {
                final isCarrier = m.player.id == cid;
                final entry = hole?.scores
                    .where((s) => s.playerId == m.player.id)
                    .firstOrNull;
                final stored   = entry?.grossScore;
                final strokes  = entry?.handicapStrokes ?? 0;
                final pending  = _pendingScores[m.player.id];
                final displayed = pending ?? stored;
                return _PlayerScoreRow(
                  member:          m,
                  isCarrier:       isCarrier,
                  ballColor:       _ballColor,
                  par:             par,
                  grossScore:      displayed,
                  handicapStrokes: strokes,
                  onScoreSelected: (score) {
                    setState(() => _pendingScores[m.player.id] = score);
                  },
                );
              }),

              const SizedBox(height: 16),

              // ── Lost ball toggle ──────────────────────────────────────
              _BallLostCard(
                ballColor: _ballColor,
                lost:      _ballLost,
                onChanged: (v) => setState(() => _ballLost = v),
              ),
            ],
          ),
        ),
      ]),

      // ── Bottom navigation ──────────────────────────────────────────────────
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            OutlinedButton.icon(
              onPressed: _holeIndex == 0
                  ? null
                  : () => setState(() {
                        _holeIndex--;
                        _ballLost = false;
                        _pendingScores.clear();
                      }),
              icon: const Icon(Icons.chevron_left),
              label: Text('Hole $_holeIndex'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: (!complete || _saving)
                  ? null
                  : () => _save(advance: true),
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Icon(_holeIndex == 17
                      ? Icons.check
                      : Icons.chevron_right),
              label: Text(_saving
                  ? 'Saving…'
                  : _holeIndex == 17
                      ? 'Finish'
                      : 'Hole ${_holeNumber + 1}'),
              iconAlignment: IconAlignment.end,
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hole chip strip
// ---------------------------------------------------------------------------

class _HoleChipStrip extends StatelessWidget {
  final int              holeIndex;
  final Scorecard        scorecard;
  final List<Membership> realMembers;
  final void Function(int) onTap;

  const _HoleChipStrip({
    required this.holeIndex,
    required this.scorecard,
    required this.realMembers,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: scorecard.holes.length,
        itemBuilder: (_, i) {
          final h        = scorecard.holes[i];
          final complete = h.scores.every((s) => s.grossScore != null);
          final isCurrent = i == holeIndex;
          return GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isCurrent
                    ? theme.colorScheme.primary
                    : complete
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Center(
                child: Text(
                  '${h.holeNumber}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: isCurrent
                        ? theme.colorScheme.onPrimary
                        : complete
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
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
// Carrier banner
// ---------------------------------------------------------------------------

class _CarrierBanner extends StatelessWidget {
  final int     holeNumber;
  final int     par;
  final int?    yards;
  final int?    si;
  final String  carrierName;
  final String  ballColor;

  const _CarrierBanner({
    required this.holeNumber,
    required this.par,
    this.yards,
    this.si,
    required this.carrierName,
    required this.ballColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Hole $holeNumber',
                style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer)),
            const Spacer(),
            _InfoChip('Par $par'),
            if (yards != null) ...[
              const SizedBox(width: 6),
              _InfoChip('${yards}y'),
            ],
            if (si != null) ...[
              const SizedBox(width: 6),
              _InfoChip('SI $si'),
            ],
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.sports_golf,
                size: 18,
                color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer),
                  children: [
                    TextSpan(
                      text: carrierName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(text: ' carries the $ballColor Ball'),
                  ],
                ),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  const _InfoChip(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer)),
    );
  }
}

// ---------------------------------------------------------------------------
// Player score row
// ---------------------------------------------------------------------------

class _PlayerScoreRow extends StatelessWidget {
  final Membership              member;
  final bool                    isCarrier;
  final String                  ballColor;
  final int                     par;
  final int?                    grossScore;
  final int                     handicapStrokes; // strokes on this hole
  final void Function(int)      onScoreSelected;

  const _PlayerScoreRow({
    required this.member,
    required this.isCarrier,
    required this.ballColor,
    required this.par,
    required this.grossScore,
    required this.handicapStrokes,
    required this.onScoreSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final player = member.player;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isCarrier
          ? theme.colorScheme.secondaryContainer.withOpacity(0.5)
          : null,
      shape: isCarrier
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: theme.colorScheme.secondary, width: 1.5),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(player.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (isCarrier) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$ballColor Ball',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSecondary,
                          ),
                        ),
                      ),
                    ],
                  ]),
                  Text('HCP ${member.playingHandicap}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (grossScore != null)
              _ScoreChip(gross: grossScore!, par: par,
                  strokes: handicapStrokes),
          ]),
          const SizedBox(height: 8),
          // Horizontal score picker
          SizedBox(
            height: 48,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _maxScore - _minScore + 1,
              itemBuilder: (_, i) {
                final s = _minScore + i;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: NetScoreButton(
                    score:    s,
                    par:      par,
                    strokes:  handicapStrokes,
                    selected: s == grossScore,
                    width:    40,
                    height:   40,
                    onTap:    () => onScoreSelected(s),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _ScoreChip extends StatelessWidget {
  final int gross;
  final int par;
  final int strokes;
  const _ScoreChip({required this.gross, required this.par,
      required this.strokes});

  @override
  Widget build(BuildContext context) {
    final net  = gross - strokes;
    final diff = net - par;
    Color bg;
    if (diff < 0) bg = Colors.green.shade200;
    else if (diff > 0) bg = Colors.red.shade200;
    else bg = Colors.grey.shade200;
    return CircleAvatar(
      radius: 16,
      backgroundColor: bg,
      child: Text('$gross',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
              color: Colors.black87)),
    );
  }
}

// ---------------------------------------------------------------------------
// Order setup bottom sheet  (shown once per foursome before scoring starts)
// ---------------------------------------------------------------------------

class _OrderSetupSheet extends StatefulWidget {
  final String         ballColor;
  final List<Membership> members;
  final Future<void> Function(List<int>) onConfirm;

  const _OrderSetupSheet({
    required this.ballColor,
    required this.members,
    required this.onConfirm,
  });

  @override
  State<_OrderSetupSheet> createState() => _OrderSetupSheetState();
}

class _OrderSetupSheetState extends State<_OrderSetupSheet> {
  late final List<Membership> _ordered;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ordered = List.of(widget.members);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: MediaQuery.of(context).viewInsets,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Set Ball Rotation',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    'Drag to set the order your group will carry the '
                    '${widget.ballColor} Ball. The rotation repeats across all 18 holes.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // Reorderable player list
            SizedBox(
              height: _ordered.length * 64.0,
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final item = _ordered.removeAt(oldIndex);
                    _ordered.insert(newIndex, item);
                  });
                },
                children: _ordered.asMap().entries.map((e) {
                  final idx = e.key;
                  final m   = e.value;
                  return Card(
                    key: ValueKey(m.player.id),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _posColor(idx),
                        radius: 16,
                        child: Text(
                          '${idx + 1}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                        ),
                      ),
                      title: Text(m.player.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('HCP ${m.playingHandicap}',
                          style: theme.textTheme.bodySmall),
                      trailing: const Icon(Icons.drag_handle),
                    ),
                  );
                }).toList(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          setState(() => _saving = true);
                          final playerOrder =
                              _ordered.map((m) => m.player.id).toList();
                          await widget.onConfirm(playerOrder);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                  child: _saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Confirm Rotation'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _posColor(int index) {
    const colors = [Colors.blue, Colors.orange, Colors.green, Colors.purple];
    return colors[index % colors.length];
  }
}

// ---------------------------------------------------------------------------
// Ball-lost toggle card
// ---------------------------------------------------------------------------

class _BallLostCard extends StatelessWidget {
  final String  ballColor;
  final bool    lost;
  final void Function(bool) onChanged;

  const _BallLostCard({
    required this.ballColor,
    required this.lost,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: lost ? theme.colorScheme.errorContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!lost),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Icon(
              lost ? Icons.cancel : Icons.circle_outlined,
              color: lost
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Lost the $ballColor Ball on this hole',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: lost
                      ? theme.colorScheme.onErrorContainer
                      : null,
                ),
              ),
            ),
            Switch(
              value: lost,
              onChanged: onChanged,
              activeColor: theme.colorScheme.error,
            ),
          ]),
        ),
      ),
    );
  }
}
