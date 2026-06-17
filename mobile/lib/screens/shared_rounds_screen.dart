/// shared_rounds_screen.dart
/// "Shared with me" — read-only cross-account follows. Lists rounds/tournaments
/// in other accounts you were invited to WATCH (matched by your verified phone).
/// Rounds you actually play in live in your own active list instead; completed
/// follows age off after a week. Tapping a round opens the read-only leaderboard.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'tournament_leaderboard_screen.dart';

class SharedRoundsScreen extends StatefulWidget {
  const SharedRoundsScreen({super.key});

  @override
  State<SharedRoundsScreen> createState() => _SharedRoundsScreenState();
}

class _SharedRoundsScreenState extends State<SharedRoundsScreen> {
  List<SharedRoundSummary> _rounds = [];
  bool    _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rounds =
          await context.read<AuthProvider>().client.getSharedRounds();
      if (mounted) setState(() { _rounds = rounds; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  String _formatDate(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
  }

  /// Open a shared item. First calls join (best-effort) so the person who
  /// invited me lands in my "My Golfers", then opens the read-only leaderboard.
  Future<void> _openShared(SharedRoundSummary r) async {
    final client = context.read<AuthProvider>().client;
    final nav = Navigator.of(context);
    try {
      if (r.isTournament) {
        await client.joinTournament(r.id);
      } else {
        await client.joinRound(r.id);
      }
    } catch (_) {/* non-fatal — open anyway */}
    if (!mounted) return;
    if (r.isTournament) {
      nav.push(MaterialPageRoute(
        builder: (_) => TournamentLeaderboardScreen(
            tournamentId: r.id, tournamentName: r.groupLabel),
      ));
    } else {
      nav.pushNamed('/leaderboard', arguments: r.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared with me'),
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
      return ErrorView(message: 'Could not load shared rounds.', onRetry: _load);
    }
    if (_rounds.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            Icon(Icons.groups_2_outlined, size: 56, color: Colors.grey),
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'When a friend invites you to watch one of their rounds, it '
                'shows up here so you can follow along. Rounds you play in '
                'appear in your own Casual Rounds list.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _rounds.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = _rounds[i];
          final games = r.activeGames.isEmpty
              ? '' : '  ·  ${r.activeGames.join(", ")}';
          // Tournament watchers show the event name as the title (no single
          // course); casual rounds show the course.
          final title = r.isTournament && r.courseName.isEmpty
              ? r.groupLabel
              : r.courseName;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              foregroundColor:
                  Theme.of(context).colorScheme.onPrimaryContainer,
              child: Icon(
                  r.isTournament ? Icons.emoji_events : Icons.golf_course),
            ),
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${r.groupLabel}  ·  ${_formatDate(r.date)}$games',
              maxLines: 2, overflow: TextOverflow.ellipsis,
            ),
            trailing: r.status == 'in_progress'
                ? const Chip(
                    label: Text('Live', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  )
                : const Icon(Icons.chevron_right),
            onTap: () => _openShared(r),
          );
        },
      ),
    );
  }
}
