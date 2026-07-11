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
import '../game_colors.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/round_chat_button.dart';

// Colours used for Player-1 and Player-2 holes across all match cards.
// Matches the score-entry name colours (GameColors.team1 / team2) so a player
// reads in the same colour on the leaderboard as in score entry.
final _kP1Color = GameColors.team1; // blue
final _kP2Color = GameColors.team2; // orange

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

  /// True once any score has been entered for this foursome — gates the
  /// app-bar Exit (✕) on a single-foursome casual round. This screen reads its
  /// data from a raw summary map (no `_pending` map / scorecard), so the signal
  /// comes from the foursome's `hasAnyScore` flag.
  bool get _hasAnyScore {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    return fs?.hasAnyScore ?? false;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    // On a single-foursome casual round, once a score is entered swap the back
    // arrow for an explicit ✕ Exit (back is easily mistaken for "previous hole")
    // that returns to the casual rounds list.
    final isCasualSingle = (rp.round?.isCasual ?? false) &&
        (rp.round?.foursomes.length ?? 1) == 1;
    final showExit = isCasualSingle && _hasAnyScore;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Match Play'),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: showExit ? 'Exit to rounds' : 'Close',
          onPressed: showExit
              ? () => Navigator.of(context).popUntil(
                  (r) => r.settings.name == '/casual-rounds' || r.isFirst)
              : () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (rp.round != null)
            RoundChatButton(roundId: rp.round!.id),
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

  Widget _buildContent() => MatchPlayDetailView(data: _data!);
}

// ── Shared detail view ───────────────────────────────────────────────────────
//
// Renders the full rich bracket layout (status banner + semis + final/3rd +
// money) for a single foursome's match-play summary.  Used by both
// [MatchPlayScreen] (the dedicated screen launched from score entry) and
// the leaderboard's per-group card so the user sees the same depth of
// detail in both places.
//
// Pass [scrollable: false] when embedding inside another scroll view (the
// leaderboard already wraps tabs in a scroll); leave the default true when
// using the view as a top-level screen body.

class MatchPlayDetailView extends StatelessWidget {
  final Map<String, dynamic> data;
  /// When true, wraps content in a ListView with padding; when false,
  /// returns a non-scrolling Column suitable for embedding.
  final bool scrollable;

  const MatchPlayDetailView({
    super.key,
    required this.data,
    this.scrollable = true,
  });

  List<Map<String, dynamic>> _matchesForRound(int round) =>
      (data['matches'] as List? ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .where((m) => (m['round'] as int) == round)
          .toList();

  String? _r2PendingNote(Map<String, dynamic> match) {
    if (match['players_tbd'] == true) {
      return 'Players set once both semis finish';
    }
    if (match['players_tentative'] == true) {
      return 'Tracking live — matchup confirmed when SD resolves';
    }
    return null;
  }

  static String _hcapLabel(Map<String, dynamic>? h) {
    final mode = h?['mode']?.toString() ?? 'net';
    if (mode == 'gross') return 'Gross — no strokes';
    if (mode == 'strokes_off') return 'Strokes-Off-Low';
    final pct = (h?['net_percent'] as num?)?.toInt() ?? 100;
    return pct == 100 ? 'Net — full handicap' : 'Net $pct%';
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

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final status  = data['status'] as String? ?? 'pending';
    final winner  = data['winner'] as String?;
    final r1      = _matchesForRound(1);
    final r2      = _matchesForRound(2);

    final children = <Widget>[
      // ── Status banner ─────────────────────────────────────────────────
      _StatusBanner(status: status, winner: winner),
      const SizedBox(height: 8),
      // Handicap mode — so it's clear whether strokes are Strokes-Off-Low,
      // full net, or gross (the scorecard dots below follow this).
      Row(children: [
        Icon(Icons.flag_outlined,
            size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(_hcapLabel(data['handicap'] as Map<String, dynamic>?),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 16),

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
      if (data['money'] != null)
        _MoneyCard(money: data['money'] as Map<String, dynamic>),
    ];

    if (scrollable) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: children,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
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
      // No banner while live — the leaderboard refreshes on entry (and Refresh
      // stays in the ⋯ menu / pull-to-refresh), and the per-match "Live" chips
      // plus status lines already convey that play is under way.
      return const SizedBox.shrink();
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

              // ── Scoring detail (par / SI / gross + stroke dots) ─────────
              // Present only once a match's players are known (semis always;
              // final/consolation after both semis finish). Dots are the
              // prospective full-net handicap strokes the bracket scores on.
              if (match['scorecard'] != null)
                _MatchScoreDetail(match: match),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Scoring detail grid ─────────────────────────────────────────────────────

/// Compact hole-by-hole scorecard for a single match: Hole / Par / SI rows
/// plus one row per player showing gross + stroke dots, the winner's cell
/// tinted in their colour. Strokes show PROSPECTIVELY (before a hole is
/// scored) so a player can see where their strokes fall over the 9 holes.
class _MatchScoreDetail extends StatelessWidget {
  final Map<String, dynamic> match;
  const _MatchScoreDetail({required this.match});

  static const double _labelW = 42.0;
  static const double _cellW  = 28.0;
  static const double _rowH   = 22.0;

  int? _p1() => match['player1_id'] as int?;
  int? _p2() => match['player2_id'] as int?;

  String _short(Map sc, int? pid, String fallback) {
    for (final p in (sc['players'] as List? ?? const [])) {
      if ((p as Map)['player_id'] == pid) {
        final s = p['short_name'] as String?;
        if (s != null && s.isNotEmpty) return s;
      }
    }
    return fallback;
  }

  Map _scoreOf(Map hole, int? pid) => ((hole['scores'] as List? ?? const [])
      .cast<Map>()
      .firstWhere((s) => s['player_id'] == pid, orElse: () => const {}));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sc    = match['scorecard'] as Map<String, dynamic>?;
    if (sc == null) return const SizedBox.shrink();
    final holes = (sc['holes'] as List? ?? const [])
        .map((h) => Map<String, dynamic>.from(h as Map))
        .toList();
    if (holes.isEmpty) return const SizedBox.shrink();

    final p1id = _p1();
    final p2id = _p2();
    final p1short = _short(sc, p1id, match['player1'] as String? ?? 'P1');
    final p2short = _short(sc, p2id, match['player2'] as String? ?? 'P2');

    Widget cell(Widget child, {Color? bg}) => Container(
          width: _cellW, height: _rowH, alignment: Alignment.center,
          decoration: bg == null ? null : BoxDecoration(color: bg),
          child: child,
        );
    Widget label(String s, {bool italic = false, Color? color}) => SizedBox(
          width: _labelW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(s,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                    color: color)),
          ),
        );

    Widget playerRow(int? pid, Color color, String short) => Row(children: [
          label(short, color: color),
          for (final h in holes) Builder(builder: (_) {
            final s       = _scoreOf(h, pid);
            final gross   = s['gross'] as int?;
            final strokes = (s['strokes'] as int?) ?? 0;
            final isWin   = h['winner_id'] == pid;
            if (gross == null && strokes == 0) {
              return cell(const Text('·',
                  style: TextStyle(fontSize: 10, color: Colors.grey)));
            }
            return cell(
              Stack(alignment: Alignment.topCenter, children: [
                if (strokes > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(
                        strokes.clamp(0, 3),
                        (_) => Container(
                          width: 3, height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration:
                              BoxDecoration(color: color, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      gross == null ? '·' : '$gross',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isWin ? FontWeight.bold : FontWeight.w500,
                        color: gross == null
                            ? Colors.grey
                            : (isWin ? color : null),
                      ),
                    ),
                  ),
                ),
              ]),
              bg: isWin ? color.withValues(alpha: 0.14) : null,
            );
          }),
        ]);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Scorecard  ·  dots = strokes',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  label('Hole', color: theme.colorScheme.onSurfaceVariant),
                  for (final h in holes)
                    cell(Text('${h['hole']}${h['is_sd'] == true ? '*' : ''}',
                        style: const TextStyle(
                            fontSize: 10, fontWeight: FontWeight.bold))),
                ]),
                Row(children: [
                  label('Par', italic: true),
                  for (final h in holes)
                    cell(Text('${h['par'] ?? '-'}',
                        style: const TextStyle(fontSize: 10))),
                ]),
                Row(children: [
                  label('SI', italic: true,
                      color: theme.colorScheme.onSurfaceVariant),
                  for (final h in holes)
                    cell(Text('${h['stroke_index'] ?? '-'}',
                        style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            color: theme.colorScheme.onSurfaceVariant))),
                ]),
                Container(
                  height: 1,
                  width: _labelW + _cellW * holes.length,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  color: theme.colorScheme.outlineVariant,
                ),
                playerRow(p1id, _kP1Color, p1short),
                playerRow(p2id, _kP2Color, p2short),
              ],
            ),
          ),
        ],
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
