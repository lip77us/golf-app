/// ryder_cup_scoreboard_screen.dart
///
/// Shows the live cup standings:
///   • Overall team totals at the top
///   • Per-round breakdown with match-level detail
///
/// Uses GET /api/tournaments/<id>/team-tournament/ which returns the
/// ryder_cup_summary response.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../theme/halved_brand.dart';

/// A cup team's own colour — the TD chose it, so it is kept (docs/color-standard.md).
Color _teamColour(String colour) =>
    resolveTripleCupTeamColor(colour, Halved.pine);

const _kCardBorder = BorderSide(color: Halved.cardBorder);

class RyderCupScoreboardScreen extends StatefulWidget {
  final int    tournamentId;
  final String tournamentName;

  const RyderCupScoreboardScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<RyderCupScoreboardScreen> createState() =>
      _RyderCupScoreboardScreenState();
}

class _RyderCupScoreboardScreenState
    extends State<RyderCupScoreboardScreen> {
  TeamTournamentSummary? _summary;
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final s = await context.read<AuthProvider>().client
          .getTeamTournament(widget.tournamentId);
      if (mounted) setState(() { _summary = s; });
    } catch (e) {
      if (mounted) setState(() {
        _error        = friendlyError(e);
        _networkError = isNetworkError(e);
      });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        foregroundColor: Halved.deepPine,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(_summary?.cupName ?? 'Cup Scoreboard',
            style: Halved.sectionHead().copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Halved.deepPine)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(message: _error!, isNetwork: _networkError, onRetry: _load);
    }
    final s = _summary!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _StandingsCard(teams: s.teams),
          const SizedBox(height: 8),
          ...s.rounds.map((r) => _RoundCard(
            round: r,
            teams: s.teams,
          )),
          if (s.rounds.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text(
                  'No rounds configured yet.\n'
                  'Set up a round\'s Cup Play config to see points here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overall standings
// ---------------------------------------------------------------------------

class _StandingsCard extends StatelessWidget {
  final List<CupTeam> teams;
  const _StandingsCard({required this.teams});

  @override
  Widget build(BuildContext context) {
    final sorted = [...teams]..sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
    final maxPts = sorted.isNotEmpty ? sorted.first.totalPoints : 1.0;

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: _kCardBorder),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('OVERALL STANDINGS',
              style: Halved.label(color: Halved.muted, weight: FontWeight.w700)
                  .copyWith(fontSize: 11, letterSpacing: 0.5)),
          const SizedBox(height: 12),
          ...sorted.asMap().entries.map((entry) {
            final pos  = entry.key;
            final team = entry.value;
            final frac = maxPts > 0 ? team.totalPoints / maxPts : 0.0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  SizedBox(
                    width: 28,
                    child: Text('${pos + 1}.',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Halved.deepPine)),
                  ),
                  Container(
                    width: 10, height: 10,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: _teamColour(team.colour),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Expanded(
                    child: Text(team.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Halved.deepPine)),
                  ),
                  Text(
                    _fmtPts(team.totalPoints),
                    style: Halved.sectionHead().copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Halved.deepPine),
                  ),
                ]),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: frac.clamp(0, 1).toDouble(),
                  minHeight: 6,
                  color: _teamColour(team.colour),
                  backgroundColor: Halved.surface,
                  borderRadius: BorderRadius.circular(3),
                ),
              ]),
            );
          }),
        ]),
      ),
    );
  }

  String _fmtPts(double pts) =>
      pts % 1 == 0 ? pts.toInt().toString() : pts.toStringAsFixed(1);
}

// ---------------------------------------------------------------------------
// Per-round card
// ---------------------------------------------------------------------------

class _RoundCard extends StatefulWidget {
  final CupRound    round;
  final List<CupTeam> teams;

  const _RoundCard({required this.round, required this.teams});

  @override
  State<_RoundCard> createState() => _RoundCardState();
}

class _RoundCardState extends State<_RoundCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final r      = widget.round;
    final sorted = [...r.teamPoints]
      ..sort((a, b) => (b['points'] as num).compareTo(a['points'] as num));

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: _kCardBorder),
      child: Column(children: [
        InkWell(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(children: [
              // Round badge
              Container(
                width: 36, height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Halved.deepPine,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('R${r.roundNumber}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(r.course,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Halved.deepPine)),
                  Text(r.date,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Halved.muted)),
                ]),
              ),
              // Points summary chips
              ...sorted.map((tp) => Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Halved.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_teamShort(tp['team_name'] as String)} '
                    '${_fmtPts(tp['points'] as double)}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Halved.deepPine),
                  ),
                ),
              )),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant),
            ]),
          ),
        ),

        if (_expanded) ...[
          const Divider(height: 1, color: Color(0xFFEEF3EE)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: r.matches.isEmpty
                  ? [const Text('No match data yet.',
                      style: TextStyle(fontStyle: FontStyle.italic))]
                  : r.matches.map((m) => _MatchRow(
                      match: m, teams: widget.teams)).toList(),
            ),
          ),
        ],
      ]),
    );
  }

  String _teamShort(String name) =>
      name.length <= 4 ? name : name.substring(0, 4);

  String _fmtPts(double pts) =>
      pts % 1 == 0 ? pts.toInt().toString() : pts.toStringAsFixed(1);
}

// ---------------------------------------------------------------------------
// Match row — one logical match with F9 / B9 / 18 segment chips
// ---------------------------------------------------------------------------

class _MatchRow extends StatelessWidget {
  final CupMatch    match;
  final List<CupTeam> teams;

  const _MatchRow({required this.match, required this.teams});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        // Game type label
        Container(
          width: 52,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Halved.surface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            _gameLabel(match.gameType),
            style: const TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: Halved.pine),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(width: 8),
        // Match label
        Expanded(
          child: Text(
            match.displayLabel,
            style: const TextStyle(fontSize: 13, color: Halved.deepPine),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Segment result chips
        ...match.segments.map((seg) => Padding(
          padding: const EdgeInsets.only(left: 4),
          child: _SegmentChip(segment: seg, match: match, teams: teams),
        )),
      ]),
    );
  }

  String _gameLabel(String gt) {
    switch (gt) {
      case 'nassau':        return '4-Ball';
      case 'quota_nassau':  return 'Quota';
      case 'irish_rumble':  return 'Irish';
      case 'match_play':    return 'Singles';
      default:              return gt;
    }
  }
}

class _SegmentChip extends StatelessWidget {
  final CupSegmentResult segment;
  final CupMatch         match;

  final List<CupTeam> teams;

  const _SegmentChip(
      {required this.segment, required this.match, required this.teams});

  @override
  Widget build(BuildContext context) {
    final result = segment.result;
    Color? bg;
    Color fg = Halved.deepPine;
    String label = segment.segmentLabel;

    // A won segment is filled in the winning team's own colour (the TD's
    // choice); level and not-yet-played stay neutral.
    Color teamFill(String name, int number) {
      for (final t in teams) {
        if (t.name == name || t.shortCode == name) return _teamColour(t.colour);
      }
      // The label did not match a team: fall back on the team's NUMBER so the
      // two sides can never both come out the same colour.
      for (final t in teams) {
        if (t.teamNumber == number) return _teamColour(t.colour);
      }
      return number == 1 ? Halved.pine : Halved.teamClay;
    }

    if (result == null) {
      bg = Halved.surface;
      fg = Halved.muted;
      label = '${segment.segmentLabel} –';
    } else if (result == 'halved') {
      bg = const Color(0xFFE6ECE7);
      label = '${segment.segmentLabel} ½';
    } else {
      final name = result == 'team1' ? match.team1 : match.team2;
      bg = teamFill(name, result == 'team1' ? 1 : 2);
      fg = Colors.white;
      label = '${segment.segmentLabel} $name';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}
