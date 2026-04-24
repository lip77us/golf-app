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

    final lb      = rp.leaderboard;
    final isFinal = lb?.status == 'complete';

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
      // Complete Round is handled in the scorecard screen after hole 18.
      bottomNavigationBar: null,
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
      case 'points_531':
        return _ByGroupView(data: data, builder: _Points531GroupCard.new);
      case 'match_play':
        return _ByGroupView(data: data, builder: _MatchPlayGroupCard.new);
      case 'irish_rumble':
        return _IrishRumbleView(data: data);
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
    final theme     = Theme.of(context);
    final results   = (data['results'] as List? ?? []);
    final ballColor = data['ball_color']?.toString() ?? 'Pink';
    final pool      = (data['pool'] as num?)?.toDouble() ?? 0.0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Pool header
        if (pool > 0) ...[
          Row(children: [
            Chip(
              label: Text('$ballColor Ball',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
            const SizedBox(width: 8),
            Text('Pool: \$${pool.toStringAsFixed(2)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 12),
        ],
        ...results.map((r) {
          final row      = r as Map<String, dynamic>;
          final rank     = row['rank'] as int? ?? 0;
          final players  = row['players']?.toString() ?? 'Group ${row['group_number']}';
          final status   = row['status']?.toString() ?? '';
          final survived = status == 'Survived';
          final payout   = (row['payout'] as num?)?.toDouble() ?? 0.0;

          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: survived
                    ? Colors.green
                    : rank == 1
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                child: Text('$rank',
                    style: TextStyle(
                        color: (survived || rank == 1)
                            ? Colors.white
                            : null,
                        fontWeight: FontWeight.bold)),
              ),
              title: Text(players,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(status,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: survived
                          ? Colors.green.shade700
                          : theme.colorScheme.onSurfaceVariant)),
              trailing: payout > 0
                  ? Text(
                      '\$${payout.toStringAsFixed(2)}',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700),
                    )
                  : null,
            ),
          );
        }),
      ],
    );
  }
}

// ---- Low Net ----

// ---- Low Net ----

class _LowNetView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _LowNetView({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final results   = (data['results'] as List? ?? []);
    final entryFee  = (data['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final payouts   = (data['payouts'] as List? ?? []);
    final hmode     = data['handicap_mode']?.toString() ?? 'net';
    final npct      = data['net_percent'] as int? ?? 100;

    // Subtitle: handicap mode label
    final modeLabel = hmode == 'gross' ? 'Gross'
        : hmode == 'strokes_off' ? 'Strokes Off'
        : npct == 100 ? 'Full Net'
        : 'Net $npct%';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Info row
        Row(children: [
          Chip(
            label: Text(modeLabel, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          if (entryFee > 0) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text('Entry \$${entryFee.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
          if (payouts.isNotEmpty) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text('${payouts.length} places paid',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
        ]),
        const SizedBox(height: 8),

        // Results
        ...results.map((r) {
          final row        = r as Map<String, dynamic>;
          final rank       = row['rank'] as int? ?? 0;
          final name       = row['name']?.toString() ?? '—';
          final netToPar   = row['net_to_par'] as int?;
          final holes      = row['holes_played'] as int? ?? 0;
          final foursomeId = row['foursome_id'] as int?;
          final payout     = (row['payout'] as num?)?.toDouble();
          final partial    = holes < 18;

          // Net-to-par label: "E", "-3", "+5"
          final parLabel = netToPar == null ? '—'
              : netToPar == 0 ? 'E'
              : netToPar < 0 ? '$netToPar'
              : '+$netToPar';
          final parColor = netToPar == null
              ? null
              : netToPar < 0
                  ? Colors.green.shade700
                  : netToPar > 0
                      ? theme.colorScheme.error
                      : null;

          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: rank == 1
                    ? Colors.amber
                    : rank == 2
                        ? Colors.grey.shade400
                        : rank == 3
                            ? const Color(0xFFcd7f32)
                            : theme.colorScheme.surfaceContainerHighest,
                child: Text('$rank',
                    style: TextStyle(
                        color: rank <= 3 ? Colors.white : null,
                        fontWeight: FontWeight.bold)),
              ),
              title: Text(name),
              subtitle: partial
                  ? Text('$holes holes played',
                      style: theme.textTheme.bodySmall)
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        parLabel,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: parColor,
                        ),
                      ),
                      if (payout != null)
                        Text('\$${payout.toStringAsFixed(2)}',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: Colors.green.shade700)),
                    ],
                  ),
                  // Scorecard icon — navigates to that player's foursome card
                  if (foursomeId != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.table_chart_outlined, size: 20),
                      tooltip: 'View scorecard',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        context.read<RoundProvider>().loadScorecard(foursomeId);
                        Navigator.of(context).pushNamed('/scorecard',
                            arguments: {'foursomeId': foursomeId, 'readOnly': true});
                      },
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ---- Irish Rumble ----

class _IrishRumbleView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _IrishRumbleView({required this.data});

  static String _ntpLabel(int? ntp) {
    if (ntp == null) return '—';
    if (ntp == 0)   return 'E';
    return ntp < 0 ? '$ntp' : '+$ntp';
  }

  static Color? _ntpColor(int? ntp, ThemeData theme) {
    if (ntp == null || ntp == 0) return null;
    return ntp < 0 ? Colors.green.shade700 : theme.colorScheme.error;
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final overall = (data['overall'] as List? ?? []);
    final pool    = (data['pool'] as num?)?.toDouble() ?? 0.0;

    if (overall.isEmpty) {
      return const Center(child: Text('No scores yet.'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (pool > 0) ...[
          Text('Pool: \$${pool.toStringAsFixed(2)}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
        ],
        ...overall.map((r) {
          final row         = r as Map<String, dynamic>;
          final rank        = row['rank'] as int?;         // null = no complete segment yet
          final players     = row['players']?.toString() ?? '';
          final ntp         = row['net_to_par'] as int?;
          final currentHole = row['current_hole'] as int?;
          final payout      = (row['payout'] as num?)?.toDouble() ?? 0.0;
          final isLeading   = rank == 1;

          final holeLabel = currentHole == null
              ? 'No scores'
              : currentHole == 18
                  ? 'F'
                  : 'Thru $currentHole';

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            elevation: isLeading ? 1 : 0,
            color: isLeading
                ? theme.colorScheme.primaryContainer.withOpacity(0.3)
                : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: isLeading
                    ? theme.colorScheme.primary.withOpacity(0.4)
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                // Rank badge
                CircleAvatar(
                  radius: 16,
                  backgroundColor: isLeading
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Text(
                    rank != null ? '$rank' : '—',
                    style: TextStyle(
                        fontSize: rank != null ? 13 : 11,
                        fontWeight: FontWeight.bold,
                        color: isLeading ? Colors.white : null),
                  ),
                ),
                const SizedBox(width: 12),

                // Team name + players
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(players,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(holeLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),

                // Score to net
                SizedBox(
                  width: 44,
                  child: Text(
                    _ntpLabel(ntp),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: _ntpColor(ntp, theme),
                    ),
                  ),
                ),

                // Payout
                if (pool > 0) ...[
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 56,
                    child: Text(
                      payout > 0
                          ? '\$${payout.toStringAsFixed(2)}'
                          : '—',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: payout > 0
                            ? Colors.green.shade700
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ]),
            ),
          );
        }),
      ],
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
    // When the round has only one foursome the "Group N" header on each
    // card is pointless (there's nothing to distinguish from).  Inject a
    // flag the cards can respect to hide their header.  Cards that don't
    // look for this flag simply ignore it.
    final singleGroup = groups.length == 1;
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: groups.length,
      itemBuilder: (_, i) {
        final g = {
          ...(groups[i] as Map<String, dynamic>),
          '_single_group': singleGroup,
        };
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
    // summary shape: { status, handicap_mode, net_percent, carryover,
    //   allow_junk, players: [{player_id, name, skins_won, junk_skins,
    //   total_skins, payout}], money: {bet_unit, pool, total_skins} }
    final summary  = group['summary'] as Map<String, dynamic>? ?? {};
    final players  = (summary['players'] as List? ?? []);
    final money    = summary['money'] as Map<String, dynamic>? ?? {};
    final pool     = money['pool'] ?? 0;
    final status   = summary['status']?.toString() ?? 'pending';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text('Pool: \$$pool',
                style: const TextStyle(fontSize: 12)),
          ]),
          const SizedBox(height: 2),
          Text('Status: ${status.replaceAll('_', ' ')}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const Divider(height: 16),
          ...players.map((t) {
            final p        = t as Map<String, dynamic>;
            final skinsWon = p['skins_won'] ?? 0;
            final junk     = p['junk_skins'] ?? 0;
            final payout   = p['payout'];
            final payStr   = payout != null
                ? '\$${(payout as num).toStringAsFixed(2)}'
                : '\$0.00';
            final skinsLabel = junk > 0
                ? '$skinsWon skin${skinsWon == 1 ? '' : 's'} and $junk junk'
                : '$skinsWon skin${skinsWon == 1 ? '' : 's'}';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text(p['name']?.toString() ?? '—')),
                Text(skinsLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Text(payStr,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ]),
            );
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
    final theme       = Theme.of(context);
    final summaryRaw  = group['summary'] as Map<String, dynamic>? ?? {};
    final nas         = NassauSummary.fromJson(summaryRaw);
    final singleGroup = group['_single_group'] == true;

    final t1Names = nas.team1.map((p) => p.shortName).join(' & ');
    final t2Names = nas.team2.map((p) => p.shortName).join(' & ');

    Color totalColor(double total) {
      if (total > 0) return Colors.green.shade700;
      if (total < 0) return Colors.red.shade700;
      return theme.colorScheme.onSurface;
    }

    String signedDollar(double v) {
      if (v == 0) return '\$0.00';
      final sign = v > 0 ? '+' : '\u2212';
      return '$sign\$${v.abs().toStringAsFixed(2)}';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!singleGroup) ...[
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
          ],

          // Team line — T1 blue, T2 orange to match the play screen.
          RichText(
            text: TextSpan(
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              children: [
                TextSpan(
                  text: t1Names,
                  style: const TextStyle(color: Colors.blue),
                ),
                TextSpan(
                  text: '  vs  ',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
                TextSpan(
                  text: t2Names,
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ],
            ),
          ),

          const Divider(height: 16),

          // Bet rows — use full team names ("JimD & Paul"), not just lead player.
          _betRow('Front 9',  nas.front9,  t1Names, t2Names, theme),
          const SizedBox(height: 4),
          _betRow('Back 9',   nas.back9,   t1Names, t2Names, theme),
          const SizedBox(height: 4),
          _betRow('Overall',  nas.overall, t1Names, t2Names, theme),

          // Presses (if any) — no nine prefix (3-9, not F3-9)
          if (nas.presses.isNotEmpty) ...[
            const Divider(height: 14),
            ...nas.presses.map((p) {
              final resultLabel = _pressResultLabel(p, t1Names, t2Names);
              // Color the result by winner (blue=T1, orange=T2, grey=AS/pending)
              Color resultColor;
              if (p.result == 'team1') {
                resultColor = Colors.blue.shade700;
              } else if (p.result == 'team2') {
                resultColor = Colors.orange.shade700;
              } else {
                resultColor = theme.colorScheme.onSurfaceVariant;
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Text(
                    '${p.pressType == 'manual' ? 'Manual' : 'Auto'} press '
                    '${p.startHole}–${p.endHole}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const Spacer(),
                  Text(resultLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: resultColor)),
                ]),
              );
            }),
          ],

          const Divider(height: 16),

          // Payout summary — full team names
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$t1Names: ${signedDollar(nas.payoutTotal)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: totalColor(nas.payoutTotal),
                    ),
                  ),
                  Text(
                    '$t2Names: ${signedDollar(-nas.payoutTotal)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: totalColor(-nas.payoutTotal),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Match: \$${nas.betUnit.toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                if (nas.pressUnit > 0)
                  Text(
                    'Press: \$${nas.pressUnit.toStringAsFixed(2)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ]),
        ]),
      ),
    );
  }

  static Widget _betRow(
    String label,
    NassauBetResult bet,
    String t1Names,
    String t2Names,
    ThemeData theme,
  ) {
    final result   = bet.result;
    final nineLen  = label == 'Overall' ? 18 : 9;
    final holesLeft = nineLen - bet.holesPlayed;
    String display;
    Color  color = theme.colorScheme.onSurface;

    if (result == null) {
      final m = bet.margin;
      if (m == 0) {
        display = bet.holesPlayed == 0 ? 'Not started' : 'AS';
      } else {
        final leader = m > 0 ? t1Names : t2Names;
        if (bet.holesPlayed > 0 && m.abs() > holesLeft) {
          // Mathematically decided before last hole — match-play "&" notation.
          display = '$leader ${m.abs()}&$holesLeft';
        } else {
          display = '$leader ${m.abs()}UP';
        }
      }
    } else if (result == 'halved') {
      display = 'AS';
      color   = theme.colorScheme.onSurfaceVariant;
    } else {
      // Completed nine — show winner name + score.
      final won    = result == 'team1';
      final winner = won ? t1Names : t2Names;
      color = won ? Colors.blue.shade700 : Colors.orange.shade700;
      // Use frozen decided score if the nine ended early (e.g. "JimD & Paul 5&4").
      final dm = bet.decidedMargin;
      final dr = bet.decidedRemaining;
      if (dm != null && dr != null && dr > 0) {
        display = '$winner ${dm.abs()}&$dr';
      } else {
        final m = bet.margin.abs();
        display = m > 0 ? '$winner ${m}UP' : '$winner wins';
      }
    }

    return Row(children: [
      SizedBox(width: 72, child: Text(label, style: theme.textTheme.bodySmall)),
      Expanded(
        child: Text(display,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600, color: color)),
      ),
    ]);
  }

  static String _pressResultLabel(
      NassauPressResult p, String t1Names, String t2Names) {
    if (p.result == null) return 'In progress';
    if (p.result == 'halved') return 'AS';
    final m      = (p.margin ?? 0).abs();
    final winner = p.result == 'team1' ? t1Names : t2Names;
    if (m == 0) return '$winner wins';
    final score  = p.holesRemaining > 0
        ? '$m&${p.holesRemaining}'
        : '${m}UP';
    return '$winner $score';
  }
}

// ---- Six's group card ----

class _SixesGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _SixesGroupCard({required this.group});

  /// Pretty-print a team as "Paul & Mike" (2 players) or "Paul, Mike, Kim"
  /// (3+).  Empty list → "—".
  static String _teamString(List players) {
    final names = players.map((p) => p.toString()).toList();
    if (names.isEmpty) return '—';
    if (names.length == 2) return '${names[0]} & ${names[1]}';
    return names.join(', ');
  }

  /// Team-vs-team subtitle for one segment.  Examples:
  ///   "Paul & Mike beat John & Sarah"
  ///   "Halved — Paul & Mike vs John & Sarah"
  ///   "Paul & Mike vs John & Sarah" (pending / in-progress)
  static String _segmentResult(Map<String, dynamic> seg) {
    final t1  = (seg['team1'] as Map<String, dynamic>? ?? const {})['players']
        as List? ?? const [];
    final t2  = (seg['team2'] as Map<String, dynamic>? ?? const {})['players']
        as List? ?? const [];
    final w   = seg['winner']?.toString() ?? '—';
    final t1s = _teamString(t1);
    final t2s = _teamString(t2);
    switch (w) {
      case 'Team 1': return '$t1s beat $t2s';
      case 'Team 2': return '$t2s beat $t1s';
      case 'Halved': return 'Halved — $t1s vs $t2s';
      default      : return '$t1s vs $t2s';
    }
  }

  /// Result text for one segment, shown to the right of the match label.
  /// Since team composition rotates every match, we show the match SCORE
  /// (e.g. "4 and 2") instead of repeating team names.  Mirrors
  /// SixesSegment.statusDisplay in models.dart so the same language
  /// appears on the scoring screen and the leaderboard.
  static String _segmentScore(Map<String, dynamic> seg) {
    final holes    = (seg['holes'] as List? ?? const []);
    final status   = seg['status']?.toString() ?? 'pending';
    final winner   = seg['winner']?.toString() ?? '—';
    final startH   = (seg['start_hole'] as num?)?.toInt() ?? 1;
    final endH     = (seg['end_hole']   as num?)?.toInt() ?? startH;
    final played   = holes.length;
    final lastMarg = holes.isEmpty
        ? 0
        : (((holes.last as Map<String, dynamic>)['margin'] as num?)?.toInt() ?? 0);
    final absMarg  = lastMarg.abs();
    final totalH   = endH - startH + 1;
    final holesLeft = totalH - played;

    if (status == 'complete' || status == 'halved') {
      if (winner == 'Halved') return 'Halved';
      // Early finish: "X and Y" (e.g. "4 and 2" = 4 up with 2 to play)
      if (holesLeft > 0) return '$absMarg and $holesLeft';
      // Ran the full segment
      return absMarg > 0 ? '$absMarg UP' : 'Halved';
    }
    if (status == 'in_progress') {
      if (lastMarg == 0) return 'AS thru $played';
      return '$absMarg UP thru $played';
    }
    return 'Pending';
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final summary  = group['summary'] as Map<String, dynamic>? ?? {};
    final segments = (summary['segments'] as List? ?? []);
    final money    = summary['money']   as Map<String, dynamic>? ?? const {};
    final byPlayer = (money['by_player'] as List? ?? const []);
    final betUnit  = (money['bet_unit'] as num?)?.toDouble() ?? 0.0;

    // In a single-foursome round the "Group N" header is pointless.
    // _ByGroupView injects this flag so we can hide it.
    final singleGroup = group['_single_group'] == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!singleGroup) ...[
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Divider(height: 12),
          ],

          // Per-match rows: label + score on line 1, then the team
          // composition as a subtitle so it's clear who beat whom for
          // this particular 6-hole (or early-finish) match.  The score
          // (e.g. "4 and 2") is the primary signal; the subtitle is the
          // "who".
          ...segments.map((s) {
            final seg = s as Map<String, dynamic>;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        seg['label']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(_segmentScore(seg),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    _segmentResult(seg),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            );
          }),

          // Per-player money totals: shown only when the bet unit is
          // non-zero so a round played "for fun" stays uncluttered.
          if (byPlayer.isNotEmpty && betUnit > 0) ...[
            const Divider(height: 16),
            Text(
              'Money (unit \$${betUnit.toStringAsFixed(2)})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            ...byPlayer.map((row) {
              final r     = row as Map<String, dynamic>;
              final name  = r['name']?.toString() ?? '';
              final amt   = (r['amount'] as num?)?.toDouble() ?? 0.0;
              final sign  = amt > 0 ? '+' : (amt < 0 ? '\u2212' : ''); // +, −, ""
              final color = amt > 0
                  ? Colors.green.shade700
                  : amt < 0
                      ? Colors.red.shade700
                      : theme.colorScheme.onSurfaceVariant;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(children: [
                  Expanded(child: Text(name)),
                  Text(
                    '$sign\$${amt.abs().toStringAsFixed(2)}',
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ]),
              );
            }),
          ],
        ]),
      ),
    );
  }
}

// ---- Points 5-3-1 group card ----

class _Points531GroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _Points531GroupCard({required this.group});

  /// Friendly handicap tag for the card header: "Net (90%)", "Gross", "SO".
  static String _hcapLabel(Map<String, dynamic> hcap) {
    final mode = hcap['mode']?.toString() ?? 'net';
    if (mode == 'gross') return 'Gross';
    if (mode == 'strokes_off') return 'SO';
    final pct = (hcap['net_percent'] as num?)?.toInt() ?? 100;
    return pct == 100 ? 'Net' : 'Net ($pct%)';
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final summary  = group['summary'] as Map<String, dynamic>? ?? {};
    final hcap     = summary['handicap'] as Map<String, dynamic>? ?? const {};
    final status   = summary['status']?.toString() ?? 'pending';
    final players  = (summary['players'] as List? ?? const []);
    final holes    = (summary['holes']   as List? ?? const []);
    final money    = summary['money']    as Map<String, dynamic>? ?? const {};
    final betUnit  = (money['bet_unit']  as num?)?.toDouble() ?? 0.0;
    final parPH    = (money['par_per_hole'] as num?)?.toInt() ?? 3;

    // In a single-foursome round the "Group N" header is pointless.
    final singleGroup = group['_single_group'] == true;

    // Short pretty label for the status line — mirrors the ones used
    // by other cards so the leaderboard stays visually consistent.
    String statusLabel;
    switch (status) {
      case 'complete':    statusLabel = 'Final';       break;
      case 'in_progress': statusLabel = 'In progress'; break;
      default:            statusLabel = 'Pending';     break;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!singleGroup) ...[
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Divider(height: 12),
          ],

          // Header: mode + status tag
          Row(children: [
            Expanded(
              child: Text(
                'Points 5-3-1 — ${_hcapLabel(hcap)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(statusLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
          ]),

          const SizedBox(height: 10),

          // Player totals — always visible, even before any hole is
          // scored, so the card has presence from the start of the round.
          if (players.isEmpty)
            Text('No players yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant))
          else
            ...players.map((p) {
              final r     = p as Map<String, dynamic>;
              final name  = r['name']?.toString() ?? '';
              final pts   = (r['points'] as num?)?.toDouble() ?? 0.0;
              final hp    = (r['holes_played'] as num?)?.toInt() ?? 0;
              final money = (r['money'] as num?)?.toDouble() ?? 0.0;
              final delta = pts - parPH * hp;
              final deltaSign  = delta > 0 ? '+' : (delta < 0 ? '\u2212' : '');
              final deltaColor = delta > 0
                  ? Colors.green.shade700
                  : delta < 0
                      ? Colors.red.shade700
                      : theme.colorScheme.onSurfaceVariant;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text(name,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  // Points total (with "vs par" delta next to it so the
                  // user can see at a glance who's up and who's down).
                  Text('${_fmtPoints(pts)} pts',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 8),
                  Text(
                    '($deltaSign${_fmtPoints(delta.abs())})',
                    style: TextStyle(
                        color: deltaColor, fontWeight: FontWeight.w600,
                        fontSize: 12),
                  ),
                  if (betUnit > 0) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 72,
                      child: Text(
                        _fmtMoney(money),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: money > 0
                              ? Colors.green.shade700
                              : money < 0
                                  ? Colors.red.shade700
                                  : theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ]),
              );
            }),

          // Per-hole grid — compact, expandable.  Collapsed by default so
          // the card matches the size of the Sixes card at a glance.
          if (holes.isNotEmpty) ...[
            const Divider(height: 20),
            _Points531HoleGrid(
              holes:   holes,
              players: players,
            ),
          ],

          if (betUnit > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Bet unit \$${betUnit.toStringAsFixed(2)}  '
                '\u2022  Par is $parPH pts / hole.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ]),
      ),
    );
  }

  /// Drop trailing ".0" from whole numbers while keeping ".5" on half-points
  /// (the only possible fraction with 5/3/1 tie-splits: 4.5, 3.5, 1.5, 2.5
  /// can't occur but (5+3)/2=4, (3+1)/2=2, (5+3+1)/3=3 are all whole;
  /// the pair average rule makes .5 impossible with these numerators).
  /// Keeping this helper anyway so a future rule change (e.g. 4/2/1)
  /// wouldn't need a UI patch.
  static String _fmtPoints(double v) {
    if ((v * 2).roundToDouble() == v * 2 && v == v.roundToDouble()) {
      return v.toStringAsFixed(0);
    }
    return v.toStringAsFixed(1);
  }

  /// Format money as "+$3.00" / "−$1.50" / "—".
  static String _fmtMoney(double v) {
    if (v == 0) return '—';
    final sign = v > 0 ? '+' : '\u2212';
    return '$sign\$${v.abs().toStringAsFixed(2)}';
  }
}

/// Compact per-hole points grid for Points 5-3-1.  Each row is a player,
/// each column a hole.  Points are rendered as small numbers (bold for
/// the hole winner).  Horizontally scrollable on narrow screens.
class _Points531HoleGrid extends StatelessWidget {
  final List holes;
  final List players;
  const _Points531HoleGrid({required this.holes, required this.players});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Pull the player list off the summary (which is already sorted by
    // money desc) so the order is stable and matches the card header.
    final playerIds = players
        .map((p) => (p as Map<String, dynamic>)['player_id'] as int)
        .toList();
    final shortByPid = <int, String>{
      for (final p in players)
        (p as Map<String, dynamic>)['player_id'] as int:
            ((p)['short_name'] as String?)?.isNotEmpty == true
                ? (p)['short_name'] as String
                : (p)['name'] as String? ?? '?',
    };

    // Lookup: hole_number → {player_id → entry}
    final byHole = <int, Map<int, Map<String, dynamic>>>{};
    for (final h in holes) {
      final m    = h as Map<String, dynamic>;
      final hole = (m['hole'] as num?)?.toInt() ?? 0;
      final entries = (m['entries'] as List? ?? const []);
      final inner = <int, Map<String, dynamic>>{};
      for (final e in entries) {
        final em  = e as Map<String, dynamic>;
        final pid = (em['player_id'] as num?)?.toInt() ?? -1;
        if (pid >= 0) inner[pid] = em;
      }
      byHole[hole] = inner;
    }

    final sortedHoles = byHole.keys.toList()..sort();

    // Column spec
    const labelColW = 48.0;
    const cellW     = 30.0;
    const rowH      = 26.0;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: hole numbers
          Row(children: [
            SizedBox(
              width: labelColW,
              height: rowH,
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Text('Hole',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
            for (final h in sortedHoles)
              SizedBox(
                width: cellW,
                height: rowH,
                child: Center(
                  child: Text('$h',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
          ]),
          const SizedBox(height: 2),
          // One row per player
          for (final pid in playerIds)
            Row(children: [
              SizedBox(
                width: labelColW,
                height: rowH,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(shortByPid[pid] ?? '?',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
              ),
              for (final h in sortedHoles) _PointsCell(
                entry: byHole[h]?[pid],
                cellW: cellW,
                rowH: rowH,
                theme: theme,
              ),
            ]),
        ],
      ),
    );
  }
}

class _PointsCell extends StatelessWidget {
  final Map<String, dynamic>? entry;
  final double cellW;
  final double rowH;
  final ThemeData theme;
  const _PointsCell({
    required this.entry,
    required this.cellW,
    required this.rowH,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final pts = (entry?['points'] as num?)?.toDouble();
    String text = '—';
    FontWeight weight = FontWeight.w400;
    Color? color;
    if (pts != null) {
      text = pts == pts.roundToDouble()
          ? pts.toStringAsFixed(0)
          : pts.toStringAsFixed(1);
      if (pts >= 5) {
        weight = FontWeight.bold;
        color  = Colors.green.shade700;
      } else if (pts >= 3) {
        weight = FontWeight.w600;
      }
    }
    return SizedBox(
      width: cellW,
      height: rowH,
      child: Center(
        child: Text(text,
            style: TextStyle(
                fontSize: 12, fontWeight: weight, color: color)),
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
