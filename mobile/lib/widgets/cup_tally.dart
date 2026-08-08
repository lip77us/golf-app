import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../utils/cup_colors.dart';

String _fmtPts(double v) =>
    v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

String _initial(String s) => s.trim().isEmpty ? '?' : s.trim()[0].toUpperCase();

/// The live cup tally + clinch line, shared across every cup surface (the
/// tournament card, the round hub, and the Triple Cup overview) so "are we up,
/// and how close is it" reads the same everywhere.
///
/// Compact by design: a team line ([chip] name  a – b  name [chip]) over a
/// points bar whose notch marks to-win, or a winner/tied banner once decided.
class CupTally extends StatelessWidget {
  final String  t1Name, t2Name;
  final Color   t1Colour, t2Colour;
  final double  t1Pts, t2Pts;
  final double? toWin, totalPossible;
  /// 'in_progress' | 'team1_won' | 'team2_won' | 'tied'
  final String  cupStatus;

  const CupTally({
    super.key,
    required this.t1Name,   required this.t2Name,
    required this.t1Colour, required this.t2Colour,
    required this.t1Pts,    required this.t2Pts,
    required this.cupStatus,
    this.toWin,
    this.totalPossible,
  });

  Widget _chip(String name, Color colour) => Container(
        width: 22, height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colour, borderRadius: BorderRadius.circular(6)),
        child: Text(_initial(name),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        _chip(t1Name, t1Colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(t1Name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t1Colour, fontWeight: FontWeight.w700)),
        ),
        Text('${_fmtPts(t1Pts)} – ${_fmtPts(t2Pts)}',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
        Expanded(
          child: Text(t2Name,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t2Colour, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 8),
        _chip(t2Name, t2Colour),
      ]),
      const SizedBox(height: 8),
      if (cupStatus == 'team1_won' || cupStatus == 'team2_won')
        _banner(
          theme,
          '${cupStatus == 'team1_won' ? t1Name : t2Name} wins the cup',
          cupStatus == 'team1_won' ? t1Colour : t2Colour,
        )
      else if (cupStatus == 'tied')
        _banner(theme, 'Cup tied', Colors.amber.shade800)
      else ...[
        _bar(theme),
        const SizedBox(height: 6),
        Text(
          '${_fmtPts(toWin ?? 0)} to win  ·  ${_fmtPts(t1Pts + t2Pts)} of '
          '${_fmtPts(_total)} points played',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    ]);
  }

  double get _total => (totalPossible != null && totalPossible! > 0)
      ? totalPossible!
      : (toWin != null ? (toWin! * 2 - 1) : (t1Pts + t2Pts));

  Widget _bar(ThemeData theme) {
    final total = _total <= 0 ? 1.0 : _total;
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      final t1w = (t1Pts / total * w).clamp(0.0, w);
      final t2w = (t2Pts / total * w).clamp(0.0, w);
      final notchX = toWin != null ? (toWin! / total * w).clamp(0.0, w) : null;
      return SizedBox(
        height: 14,
        child: Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Stack(children: [
              Container(color: theme.colorScheme.surfaceContainerHighest),
              Align(alignment: Alignment.centerLeft,
                  child: Container(width: t1w, color: t1Colour)),
              Align(alignment: Alignment.centerRight,
                  child: Container(width: t2w, color: t2Colour)),
            ]),
          ),
          if (notchX != null)
            Positioned(
              left: (notchX - 1).clamp(0.0, w - 2),
              top: -2, bottom: -2,
              child: Container(width: 2, color: theme.colorScheme.onSurface),
            ),
        ]),
      );
    });
  }

  Widget _banner(ThemeData theme, String text, Color colour) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(color: colour, fontWeight: FontWeight.w800)),
      );
}

/// Drop-in that fetches a tournament's cup standings and renders [CupTally].
/// Shows nothing until it loads (and on any failure or an unstarted cup with no
/// points on the line), so it never breaks the surface it sits on.
class CupTallyLoader extends StatefulWidget {
  final int tournamentId;
  /// Applied only when the tally actually renders, so a hidden loader leaves no
  /// gap on the surface it sits on.
  final EdgeInsetsGeometry padding;
  const CupTallyLoader({
    super.key,
    required this.tournamentId,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<CupTallyLoader> createState() => _CupTallyLoaderState();
}

class _CupTallyLoaderState extends State<CupTallyLoader> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = context.read<AuthProvider>().client;
      final d = await client.getTournamentCupStandings(widget.tournamentId);
      if (mounted) setState(() => _data = d);
    } catch (_) {/* leave the surface unchanged on failure */}
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return const SizedBox.shrink();
    final total = (d['total_possible'] as num?)?.toDouble() ?? 0.0;
    if (total <= 0) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      child: CupTally(
      t1Name       : d['team1_name'] as String? ?? 'Team 1',
      t2Name       : d['team2_name'] as String? ?? 'Team 2',
      t1Colour     : cupTeamColor(d['team1_colour'] as String? ?? 'Red'),
      t2Colour     : cupTeamColor(d['team2_colour'] as String? ?? 'Blue'),
      t1Pts        : (d['team1_points'] as num?)?.toDouble() ?? 0.0,
      t2Pts        : (d['team2_points'] as num?)?.toDouble() ?? 0.0,
      toWin        : (d['to_win'] as num?)?.toDouble(),
      totalPossible: total,
      cupStatus    : d['cup_status'] as String? ?? 'in_progress',
      ),
    );
  }
}
