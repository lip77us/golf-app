import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/round_provider.dart';

class LeaderboardScreen extends StatefulWidget {
  final int roundId;
  const LeaderboardScreen({super.key, required this.roundId});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with TickerProviderStateMixin {
  TabController? _tabController;
  List<String>   _gameTabs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RoundProvider>().loadLeaderboard(widget.roundId);
    });
  }

  void _initTabs(List<String> games) {
    if (_gameTabs.join(',') == games.join(',')) return;
    _gameTabs = games;
    _tabController?.dispose();
    _tabController = TabController(length: games.length, vsync: this);
    setState(() {});
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();

    if (!rp.loadingLeaderboard && rp.leaderboard != null) {
      _initTabs(rp.leaderboard!.activeGames);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leaderboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                context.read<RoundProvider>().loadLeaderboard(widget.roundId),
          ),
        ],
        bottom: (_tabController != null && _gameTabs.isNotEmpty)
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: _gameTabs.map((g) => Tab(text: _label(g))).toList(),
              )
            : null,
      ),
      body: _buildBody(context, rp),
    );
  }

  Widget _buildBody(BuildContext context, RoundProvider rp) {
    if (rp.loadingLeaderboard) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.leaderboard == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(rp.error!, style: const TextStyle(color: Colors.red)),
          FilledButton(
            onPressed: () => rp.loadLeaderboard(widget.roundId),
            child: const Text('Retry'),
          ),
        ]),
      );
    }
    final lb = rp.leaderboard;
    if (lb == null || _tabController == null || _gameTabs.isEmpty) {
      return const Center(child: Text('No games active.'));
    }

    final isFinal = lb.status == 'complete';

    return Column(
      children: [
        if (isFinal)
          Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Icon(Icons.emoji_events,
                    color: Theme.of(context).colorScheme.tertiary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Final Results  ·  ${lb.course}  ·  ${lb.roundDate}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _gameTabs.map((gameKey) {
              final game = lb.games[gameKey];
              if (game == null) {
                return const Center(child: Text('No data yet.'));
              }
              return RefreshIndicator(
                onRefresh: () => rp.loadLeaderboard(widget.roundId),
                child: _GameView(gameKey: gameKey, game: game),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  String _label(String g) {
    const labels = {
      'skins':        'Skins',
      'stableford':   'Stableford',
      'pink_ball':    'Pink Ball',
      'nassau':       'Nassau',
      'sixes':        "Six's",
      'match_play':   'Match Play',
      'irish_rumble': 'Irish Rumble',
      'scramble':     'Scramble',
      'low_net_round':'Low Net',
    };
    return labels[g] ?? g;
  }
}

// ---------------------------------------------------------------------------
// Game-specific views
// ---------------------------------------------------------------------------

class _GameView extends StatelessWidget {
  final String gameKey;
  final LeaderboardGame game;

  const _GameView({required this.gameKey, required this.game});

  @override
  Widget build(BuildContext context) {
    final data = game.data as Map<String, dynamic>;

    switch (gameKey) {
      case 'stableford':
        return _StablefordView(data: data);
      case 'pink_ball':
        return _RedBallView(data: data);
      case 'low_net_round':
        return _LowNetView(data: data);
      case 'skins':
        return _ByGroupView(data: data, builder: _SkinsGroupCard.new);
      case 'nassau':
        return _ByGroupView(data: data, builder: _NassauGroupCard.new);
      case 'sixes':
        return _ByGroupView(data: data, builder: _SixesGroupCard.new);
      case 'match_play':
        return _ByGroupView(data: data, builder: _MatchPlayGroupCard.new);
      default:
        return _RawJsonView(data: data);
    }
  }
}

// ---- Stableford ----

class _StablefordView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _StablefordView({required this.data});

  @override
  Widget build(BuildContext context) {
    final results = (data['results'] as List? ?? []);
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = results[i] as Map<String, dynamic>;
        return ListTile(
          leading: CircleAvatar(child: Text('${r['rank'] ?? i + 1}')),
          title: Text(r['player_name']?.toString() ?? '—'),
          trailing: Text(
            '${r['total_points'] ?? 0} pts',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        );
      },
    );
  }
}

// ---- Red Ball / Pink Ball ----

class _RedBallView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _RedBallView({required this.data});

  @override
  Widget build(BuildContext context) {
    final results = (data['results'] as List? ?? []);
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r      = results[i] as Map<String, dynamic>;
        final status = r['status']?.toString() ?? '';
        final isWinner = status.contains('Survived');
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: isWinner ? Colors.green : Colors.grey,
            child: Text('${r['rank'] ?? i + 1}',
                style: const TextStyle(color: Colors.white)),
          ),
          title: Text('Group ${r['group_number']}'),
          subtitle: Text(status),
          trailing: r['total_net_score'] != null
              ? Text('${r['total_net_score']} net',
                  style: const TextStyle(fontSize: 13))
              : null,
        );
      },
    );
  }
}

// ---- Low Net ----

class _LowNetView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _LowNetView({required this.data});

  @override
  Widget build(BuildContext context) {
    final results = (data['results'] as List? ?? []);
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = results[i] as Map<String, dynamic>;
        return ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(r['name']?.toString() ?? '—'),
          trailing: Text(
            '${r['total_net'] ?? "—"}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        );
      },
    );
  }
}

// ---- Generic by-group wrapper ----

typedef GroupCardBuilder = Widget Function(
    {required Map<String, dynamic> group});

class _ByGroupView extends StatelessWidget {
  final Map<String, dynamic> data;
  final GroupCardBuilder builder;

  const _ByGroupView({required this.data, required this.builder});

  @override
  Widget build(BuildContext context) {
    final groups = (data['by_group'] as List? ?? []);
    if (groups.isEmpty) {
      return const Center(child: Text('No data yet.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: groups.length,
      itemBuilder: (_, i) {
        final g = groups[i] as Map<String, dynamic>;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: builder(group: g),
        );
      },
    );
  }
}

// ---- Skins group card ----

class _SkinsGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _SkinsGroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final summary = group['summary'] as Map<String, dynamic>? ?? {};
    final totals  = (summary['totals'] as List? ?? []);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Group ${group['group_number']}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...totals.map((t) {
            final p = t as Map<String, dynamic>;
            return Row(children: [
              Expanded(child: Text(p['player']?.toString() ?? '—')),
              Text('${p['skins_won'] ?? 0} skins',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Text('\$${p['dollar_value'] ?? 0}'),
            ]);
          }),
        ]),
      ),
    );
  }
}

// ---- Nassau group card ----

class _NassauGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _NassauGroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final summary = group['summary'] as Map<String, dynamic>? ?? {};
    final front   = summary['front9']   as Map<String, dynamic>? ?? {};
    final back    = summary['back9']    as Map<String, dynamic>? ?? {};
    final overall = summary['overall']  as Map<String, dynamic>? ?? {};
    final payouts = summary['payouts']  as Map<String, dynamic>? ?? {};
    final teams   = summary['teams']    as Map<String, dynamic>? ?? {};

    String _teamStr(String key) =>
        (teams[key] as List? ?? []).join(' & ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Group ${group['group_number']}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('T1: ${_teamStr('team1')}  vs  T2: ${_teamStr('team2')}',
              style: const TextStyle(fontSize: 13)),
          const Divider(height: 16),
          _row('Front 9', front['result'], front['margin']),
          _row('Back 9',  back['result'],  back['margin']),
          _row('Overall', overall['result'], overall['margin']),
          const Divider(height: 16),
          Text('Net payout: \$${payouts['total'] ?? 0}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _row(String label, dynamic result, dynamic margin) {
    final r = result?.toString() ?? '—';
    final m = margin as int? ?? 0;
    final display = r == 'halved'
        ? 'Halved'
        : r == 'team1' ? 'T1 wins ${m.abs()}up'
        : r == 'team2' ? 'T2 wins ${m.abs()}up'
        : '—';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label)),
        Text(display),
      ]),
    );
  }
}

// ---- Six's group card ----

class _SixesGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _SixesGroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final summary  = group['summary'] as Map<String, dynamic>? ?? {};
    final segments = (summary['segments'] as List? ?? []);
    final overall  = summary['overall'] as Map<String, dynamic>? ?? {};

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Group ${group['group_number']}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'T1: ${overall['team1_wins']}  T2: ${overall['team2_wins']}  '
            'Halved: ${overall['halves']}',
          ),
          const Divider(height: 12),
          ...segments.map((s) {
            final seg = s as Map<String, dynamic>;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(seg['label']?.toString() ?? '')),
                Text(seg['winner']?.toString() ?? '—',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            );
          }),
        ]),
      ),
    );
  }
}

// ---- Match Play group card ----

class _MatchPlayGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _MatchPlayGroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final summary = group['summary'] as Map<String, dynamic>? ?? {};
    final matches = (summary['matches'] as List? ?? []);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            if (summary['winner'] != null) ...[
              const Spacer(),
              const Icon(Icons.emoji_events, size: 16, color: Colors.amber),
              const SizedBox(width: 4),
              Text(summary['winner'].toString(),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ]),
          const Divider(height: 12),
          ...matches.map((m) {
            final match  = m as Map<String, dynamic>;
            final winner = match['winner_name']?.toString();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Text(match['label']?.toString() ?? '',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${match['player1']} vs ${match['player2']}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (winner != null)
                  Text(winner,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
              ]),
            );
          }),
        ]),
      ),
    );
  }
}

// ---- Fallback raw JSON view ----

class _RawJsonView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _RawJsonView({required this.data});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(data.toString()),
    );
  }
}
