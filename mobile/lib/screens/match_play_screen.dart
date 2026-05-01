/// match_play_screen.dart
/// ----------------------
/// Live bracket view for a foursome's match play contest.
///
/// Layout
/// ~~~~~~
///   Status banner (overall winner / in progress)
///   ── Front 9 — Semis ──────────────────────────
///   Semi 1 match card
///   Semi 2 match card
///   ── Back 9 — Final & 3rd Place ───────────────
///   Final match card       (dimmed until both semis finish)
///   3rd Place match card   (dimmed until both semis finish)
///   Money / payouts card
///
/// Each match card shows:
///   • Player names with colour swatches
///   • Live score summary  ("Paul 2 Up thru 7"  /  "Paul wins 3&2")
///   • Hole-by-hole strip: coloured squares for each of the 9 holes
///
/// Pull-to-refresh or the AppBar icon reloads from the server.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

// Colours used for Player-1 and Player-2 holes across all match cards.
const _kP1Color = Color(0xFF2E7D32); // deep green
const _kP2Color = Color(0xFF1565C0); // deep blue

class MatchPlayScreen extends StatefulWidget {
  final int foursomeId;
  const MatchPlayScreen({super.key, required this.foursomeId});

  @override
  State<MatchPlayScreen> createState() => _MatchPlayScreenState();
}

class _MatchPlayScreenState extends State<MatchPlayScreen> {
  Map<String, dynamic>? _data;
  bool    _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = _data == null; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getMatchPlay(widget.foursomeId);
      if (mounted) setState(() { _data = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  // ── Data helpers ──────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _matchesForRound(int round) =>
      (_data?['matches'] as List? ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .where((m) => (m['round'] as int) == round)
          .toList();

  /// Derive the appropriate pending note for a back-9 match card.
  /// Returns null when no note is needed (semis complete, players confirmed).
  String? _r2PendingNote(Map<String, dynamic> match) {
    if (match['players_tbd'] == true) {
      return 'Players set once both semis finish';
    }
    if (match['players_tentative'] == true) {
      return 'Tracking live — matchup confirmed when SD resolves';
    }
    return null;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Match Play'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message:   friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry:   _load,
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _buildContent(),
                ),
    );
  }

  Widget _buildContent() {
    final theme   = Theme.of(context);
    final status  = _data?['status'] as String? ?? 'pending';
    final winner  = _data?['winner'] as String?;
    final r1      = _matchesForRound(1);
    final r2      = _matchesForRound(2);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // ── Status banner ─────────────────────────────────────────────────
        _StatusBanner(status: status, winner: winner),
        const SizedBox(height: 20),

        // ── Front 9 — Semis ───────────────────────────────────────────────
        _sectionHeader(theme, 'Front 9 — Semis',
            subtitle: 'Holes 1–9 · Seed 1 vs 4  ·  Seed 2 vs 3'),
        const SizedBox(height: 8),
        for (final m in r1) ...[
          _MatchCard(match: m),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),

        // ── Back 9 — Final & 3rd Place ────────────────────────────────────
        _sectionHeader(theme, 'Back 9 — Final & 3rd Place',
            subtitle: 'Holes 10–18 · begins after both semis resolve'),
        const SizedBox(height: 8),
        for (final m in r2) ...[
          _MatchCard(match: m, pendingNote: _r2PendingNote(m)),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),

        // ── Money ─────────────────────────────────────────────────────────
        if (_data?['money'] != null) ...[
          _MoneyCard(money: _data!['money'] as Map<String, dynamic>),
        ],
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, String title, {String? subtitle}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (subtitle != null)
            Text(subtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      );
}

// ── Status banner ─────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final String  status;
  final String? winner;
  const _StatusBanner({required this.status, this.winner});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (status == 'complete' && winner != null) {
      return Card(
        color: theme.colorScheme.primaryContainer,
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Icon(Icons.emoji_events,
                color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$winner wins the match play bracket!',
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
          ]),
        ),
      );
    }

    if (status == 'in_progress') {
      return Card(
        color: theme.colorScheme.tertiaryContainer,
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Icon(Icons.sports_golf,
                color: theme.colorScheme.onTertiaryContainer, size: 20),
            const SizedBox(width: 10),
            Text('Match play in progress — pull to refresh',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer)),
          ]),
        ),
      );
    }

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text('Waiting for scores to be entered.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

// ── Match card ────────────────────────────────────────────────────────────────

class _MatchCard extends StatelessWidget {
  final Map<String, dynamic> match;
  final String?              pendingNote; // overlay msg when back-9 not started

  const _MatchCard({required this.match, this.pendingNote});

  // ── Score summary ─────────────────────────────────────────────────────────

  String get _summary {
    final status      = match['status'] as String;
    final result      = match['result'] as String?;
    final holes       = (match['holes'] as List? ?? [])
        .map((h) => Map<String, dynamic>.from(h as Map))
        .toList();
    final p1          = match['player1'] as String;
    final p2          = match['player2'] as String;
    final winnerName  = match['winner_name'] as String?;
    final finishedOn  = match['finished_hole'] as int?;
    final tieBreak    = match['tie_break'] as String?;
    final round       = match['round'] as int;

    if (status == 'pending' && holes.isEmpty) return 'Waiting for scores';

    if (status == 'complete') {
      if (result == 'halved') return 'Halved — All Square';
      if (winnerName == null) return 'Complete';
      if (tieBreak == 'sudden_death') {
        return '$winnerName wins — sudden death hole $finishedOn';
      }
      if (tieBreak == 'last_hole_won') {
        return '$winnerName wins — last hole';
      }
      if (finishedOn != null) {
        final scheduledEnd = round == 1 ? 9 : 18;
        final remaining    = scheduledEnd - finishedOn;
        final h = holes.firstWhere(
          (h) => h['hole'] == finishedOn,
          orElse: () => <String, dynamic>{},
        );
        final margin = ((h['margin'] as int?) ?? 0).abs();
        // e.g. "3&2" for dormie close, "1 Up" for full-distance win
        if (remaining > 0) return '$winnerName wins ${margin}&$remaining';
        if (margin > 0)    return '$winnerName wins $margin Up';
      }
      return '$winnerName wins';
    }

    // in_progress
    if (holes.isEmpty) return 'In progress';
    final last        = holes.last;
    final lastHoleNum = last['hole'] as int? ?? 0;
    final margin      = last['margin'] as int? ?? 0;

    // Detect sudden death in progress: round-1 semi playing beyond hole 9.
    if (round == 1 && lastHoleNum > 9) {
      if (margin == 0) return 'All Square — sudden death thru $lastHoleNum';
      // Theoretically shouldn't occur (SD would complete on a decisive hole),
      // but guard defensively.
      final leader = margin > 0 ? p1 : p2;
      return '$leader leads — sudden death thru $lastHoleNum';
    }

    if (margin == 0) return 'All Square thru $lastHoleNum';
    final leader = margin > 0 ? p1 : p2;
    return '$leader ${margin.abs()} Up thru $lastHoleNum';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final status  = match['status'] as String;
    final dimmed  = pendingNote != null;
    final p1      = match['player1'] as String;
    final p2      = match['player2'] as String;
    final label   = match['label']  as String? ?? 'Match';

    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: Card(
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: status == 'complete'
              ? BorderSide(color: theme.colorScheme.primary.withOpacity(0.4))
              : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header: label + status ──────────────────────────────────
              Row(children: [
                _LabelBadge(label: label, theme: theme),
                const Spacer(),
                _StatusChip(status: status, theme: theme),
              ]),
              const SizedBox(height: 10),

              // ── Players with colour swatches ────────────────────────────
              Row(children: [
                _PlayerSwatch(color: _kP1Color, name: p1,
                    bold: match['result'] == 'player1', theme: theme),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('vs',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
                _PlayerSwatch(color: _kP2Color, name: p2,
                    bold: match['result'] == 'player2', theme: theme),
              ]),
              const SizedBox(height: 8),

              // ── Score summary ───────────────────────────────────────────
              Text(_summary,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),

              if (pendingNote != null) ...[
                const SizedBox(height: 4),
                Text(pendingNote!,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic)),
              ],

              // ── Hole strip ──────────────────────────────────────────────
              const SizedBox(height: 10),
              _HoleStrip(match: match),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Hole strip ────────────────────────────────────────────────────────────────

class _HoleStrip extends StatelessWidget {
  final Map<String, dynamic> match;
  const _HoleStrip({required this.match});

  /// Build a single coloured hole box with hole-number label below it.
  Widget _buildHoleBox(
    Map<String, dynamic>? holeData,
    int holeNum,
    String p1,
    ThemeData theme, {
    bool forceSD = false,
  }) {
    Color?  boxColor;
    bool    isSD    = forceSD || (holeData?['is_sd'] as bool? ?? false);
    String? caption;

    if (holeData != null) {
      final winner = holeData['winner'] as String?;
      if (winner == null) {
        boxColor = Colors.grey.shade400;
        caption  = '½';
      } else if (winner == p1) {
        boxColor = _kP1Color;
      } else {
        boxColor = _kP2Color;
      }
    }

    return Column(
      children: [
        Container(
          width: 26, height: 26,
          decoration: BoxDecoration(
            color:        boxColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isSD
                  ? Colors.amber.shade700
                  : (boxColor != null
                      ? boxColor
                      : theme.colorScheme.outlineVariant),
              width: isSD ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: caption != null
              ? Text(caption,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold))
              : (isSD
                  ? const Text('★',
                      style: TextStyle(color: Colors.amber, fontSize: 9))
                  : null),
        ),
        const SizedBox(height: 2),
        Text('$holeNum',
            style: theme.textTheme.labelSmall
                ?.copyWith(fontSize: 9, color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final holes     = (match['holes'] as List? ?? [])
        .map((h) => Map<String, dynamic>.from(h as Map))
        .toList();
    final round     = match['round'] as int;
    final startHole = round == 1 ? 1 : 10;
    final p1        = match['player1'] as String;

    // Index holes by hole number for fast lookup.
    final holeByNum = {for (final h in holes) h['hole'] as int: h};

    // Main 9-hole strip (holes 1–9 for semis, 10–18 for back-9 matches).
    final mainStrip = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(9, (i) {
        final holeNum = startHole + i;
        return _buildHoleBox(holeByNum[holeNum], holeNum, p1, theme);
      }),
    );

    // For round-1 semis, check for sudden-death holes (10+) to show below.
    if (round != 1) return mainStrip;

    final sdHoleNums = holeByNum.keys
        .where((n) => n > 9)
        .toList()
      ..sort();

    if (sdHoleNums.isEmpty) return mainStrip;

    // Sudden-death extension row with an amber "SD" label.
    final sdRow = Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color:        Colors.amber.shade100,
            borderRadius: BorderRadius.circular(3),
            border:       Border.all(color: Colors.amber.shade700),
          ),
          child: Text(
            'SD',
            style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.bold,
                color: Colors.amber.shade900),
          ),
        ),
        const SizedBox(width: 6),
        for (final holeNum in sdHoleNums) ...[
          _buildHoleBox(holeByNum[holeNum], holeNum, p1, theme, forceSD: true),
          const SizedBox(width: 4),
        ],
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        mainStrip,
        const SizedBox(height: 6),
        sdRow,
      ],
    );
  }
}

// ── Money card ────────────────────────────────────────────────────────────────

class _MoneyCard extends StatelessWidget {
  final Map<String, dynamic> money;
  const _MoneyCard({required this.money});

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final pool      = (money['prize_pool'] as num? ?? 0).toDouble();
    final entryFee  = (money['entry_fee']  as num? ?? 0).toDouble();
    final payouts   = (money['payouts']    as List? ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .where((p) => (p['amount'] as num? ?? 0) > 0)
        .toList();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.attach_money,
                  color: theme.colorScheme.primary, size: 18),
              const SizedBox(width: 6),
              Text('Money',
                  style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
            ]),
            const SizedBox(height: 10),

            Row(children: [
              Text('Entry fee',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const Spacer(),
              Text('\$${entryFee.toStringAsFixed(2)} / player',
                  style: theme.textTheme.bodySmall),
            ]),
            Row(children: [
              Text('Prize pool',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('\$${pool.toStringAsFixed(2)}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ]),

            if (payouts.isNotEmpty) ...[
              const Divider(height: 16),
              for (final p in payouts) ...[
                Row(children: [
                  Text(p['place'] as String? ?? '',
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p['player'] as String? ?? '—',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '\$${(p['amount'] as num).toStringAsFixed(2)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ]),
                const SizedBox(height: 4),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ── Small reusable widgets ────────────────────────────────────────────────────

class _LabelBadge extends StatelessWidget {
  final String    label;
  final ThemeData theme;
  const _LabelBadge({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onPrimaryContainer)),
      );
}

class _StatusChip extends StatelessWidget {
  final String    status;
  final ThemeData theme;
  const _StatusChip({required this.status, required this.theme});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String text;

    switch (status) {
      case 'complete':
        color = theme.colorScheme.primary;
        text  = 'Complete';
      case 'in_progress':
        color = Colors.orange.shade700;
        text  = 'Live';
      default:
        color = theme.colorScheme.onSurfaceVariant;
        text  = 'Pending';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _PlayerSwatch extends StatelessWidget {
  final Color     color;
  final String    name;
  final bool      bold;
  final ThemeData theme;
  const _PlayerSwatch(
      {required this.color, required this.name,
       required this.bold,  required this.theme});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(name,
              style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ],
      );
}
