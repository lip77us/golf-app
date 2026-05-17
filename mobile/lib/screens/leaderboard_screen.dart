import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import 'tournament_leaderboard_screen.dart' show ChampionshipTabView;

class LeaderboardScreen extends StatefulWidget {
  final int roundId;
  /// Pre-select a specific tab on first load.  Matched against the
  /// game-key list ('nassau', 'skins', '__bandon_cup__', etc.).  If
  /// the key isn't present in this round's tabs, falls through to the
  /// default (first tab).  Used by Championship Leaderboard to drop
  /// users straight onto the Cup tab for cup tournaments.
  final String? initialTabKey;
  const LeaderboardScreen({
    super.key,
    required this.roundId,
    this.initialTabKey,
  });

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with TickerProviderStateMixin {
  TabController? _tabController;
  List<String>   _gameTabs = [];
  bool           _initialTabApplied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RoundProvider>().loadLeaderboard(widget.roundId);
    });
  }

  void _initTabs(Leaderboard lb) {
    // For cup rounds, suppress the raw per-foursome game keys that would appear
    // as duplicate tabs — the processed 'cup_singles' tab covers them.
    final _rawSinglesKeys = {'singles_18', 'singles_nassau'};
    final games = [
      ...lb.activeGames.where((g) =>
          !(lb.isCupRound && _rawSinglesKeys.contains(g))),
      if (lb.tournamentId != null && lb.tournamentActiveGames.isNotEmpty)
        '__championship__',
    ];
    // Add a single Bandon Cup tab for cup rounds (IR + Singles) OR whenever
    // there are nassau cup matches.  The tab loads both cumulative standings
    // AND current-round live data — no separate __cup_round__ tab needed.
    final hasCupNassau = lb.games.containsKey('nassau') &&
        ((lb.games['nassau']!.data as Map<String, dynamic>? ?? {})['by_group']
                as List? ??
            [])
            .any((g) => (g as Map<String, dynamic>)['is_cup_match'] == true);
    if (lb.isCupRound || hasCupNassau) {
      games.add('__bandon_cup__');
    }
    if (_gameTabs.join(',') == games.join(',')) return;
    _gameTabs = games;
    _tabController?.dispose();
    // Honor initialTabKey on the first build that produces a real tab
    // list — subsequent rebuilds preserve whatever tab the user has
    // since switched to.
    int initialIndex = 0;
    if (!_initialTabApplied && widget.initialTabKey != null) {
      final i = games.indexOf(widget.initialTabKey!);
      if (i >= 0) initialIndex = i;
      _initialTabApplied = true;
    }
    _tabController = TabController(
      length: games.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    setState(() {});
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _confirmReopen(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Reopen Round?'),
        content: const Text(
          'This will unlock the round so scores can be edited again. '
          'Any score changes will recalculate the game results.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Reopen'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final rp = context.read<RoundProvider>();
    final success = await rp.reopenRound(widget.roundId);
    if (!context.mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Could not reopen round.'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Round reopened — scores can be edited.'),
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();

    if (!rp.loadingLeaderboard && rp.leaderboard != null) {
      _initTabs(rp.leaderboard!);
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
          if (isFinal)
            IconButton(
              tooltip: 'Reopen round',
              icon: const Icon(Icons.lock_open_outlined),
              onPressed: rp.submitting ? null : () => _confirmReopen(context),
            ),
        ],
        bottom: (_tabController != null && _gameTabs.isNotEmpty)
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: _gameTabs
                    .map((g) => Tab(text: _label(g, lb?.cupName)))
                    .toList(),
              )
            : null,
      ),
      // Show a Done button at the bottom when the round is complete so the
      // user has a clear exit path back to the rounds list.
      bottomNavigationBar: isFinal
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: () =>
                      Navigator.of(context).popUntil((r) => r.isFirst),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Done'),
                ),
              ),
            )
          : null,
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
              if (gameKey == '__championship__') {
                return ChampionshipTabView(
                  tournamentId: lb.tournamentId!,
                  roundId: widget.roundId,
                );
              }
              if (gameKey == '__bandon_cup__') {
                return _BandonCupTabView(
                  roundId       : widget.roundId,
                  tournamentId  : lb.tournamentId,
                  tournamentName: lb.cupName ?? lb.tournamentName ?? 'Bandon Cup',
                );
              }
              // Irish Rumble in cup context: show live card + per-foursome scorecards
              if (gameKey == 'irish_rumble' && lb.tournamentId != null) {
                return _IrishRumbleTabView(
                  roundId:      widget.roundId,
                  tournamentId: lb.tournamentId!,
                );
              }
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

  String _label(String g, [String? cupName]) {
    // Cup tab title tracks the cup competition's display name — falls
    // back to "Bandon Cup" only when no cup name is set on the
    // TeamTournament row (e.g. older data or non-cup contexts).
    if (g == '__bandon_cup__') {
      return cupName ?? 'Bandon Cup';
    }
    const labels = {
      'skins':             'Skins',
      'multi_skins':       'Multi-Group Skins',
      'stableford':        'Stableford',
      'pink_ball':         'Pink Ball',
      'nassau':            'Four Ball',
      'quota_nassau':      'Quota Nassau',
      'sixes':             "Six's",
      'singles_nassau':    'Singles Nassau',
      'singles_18':        '18-Hole Singles',
      'cup_singles':       'Singles-Nassau',
      'cup_singles_18':    'Singles-18',
      'three_person_match': 'Three-Person Match',
      'irish_rumble':      'Irish Rumble',
      'scramble':          'Scramble',
      'low_net_round':     'Stroke Play',
      '__championship__':  'Low Net',
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
      case 'multi_skins':
        return _MultiSkinsView(data: data);
      case 'nassau':
        return _ByGroupView(data: data, builder: _NassauGroupCard.new);
      case 'quota_nassau':
        return _ByGroupView(data: data, builder: _QuotaNassauGroupCard.new);
      case 'sixes':
        return _ByGroupView(data: data, builder: _SixesGroupCard.new);
      case 'points_531':
        return _ByGroupView(data: data, builder: _Points531GroupCard.new);
      case 'singles_nassau':
        return _ByGroupView(data: data, builder: _CupSinglesGroupCard.new);
      case 'singles_18':
        return _ByGroupView(data: data, builder: _Singles18GroupCard.new);
      case 'cup_singles':
        return _ByGroupView(data: data, builder: _CupSinglesGroupCard.new);
      case 'cup_singles_18':
        return _ByGroupView(data: data, builder: _CupSingles18GroupCard.new);
      case 'three_person_match':
        return _ByGroupView(data: data, builder: _ThreePersonMatchGroupCard.new);
      case 'irish_rumble':
        // Cup mode: show head-to-head pairing results.
        // Standard mode: show segment ranking table.
        if (data['is_cup'] == true) return _CupIrishRumbleView(data: data);
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

  static String _ntpLabel(int? ntp) {
    if (ntp == null) return '—';
    if (ntp == 0)   return 'E';
    return ntp < 0 ? '$ntp' : '+$ntp';
  }

  static Color _ntpColor(int? ntp, ThemeData theme) {
    if (ntp == null || ntp == 0) return theme.colorScheme.onSurface;
    return ntp < 0 ? Colors.green.shade700 : theme.colorScheme.error;
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final results   = (data['results'] as List? ?? []);
    final ballColor = data['ball_color']?.toString() ?? 'Pink';
    final entryFee  = (data['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final payouts   = (data['payouts'] as List? ?? []);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Info chips — match Low Net style
        Row(children: [
          Chip(
            label: Text('$ballColor Ball',
                style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          if (entryFee > 0) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text('Entry \$${entryFee.formatBet()}',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
          if (payouts.isNotEmpty) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text(
                  payouts.length == 1 ? 'Winner takes all' : '${payouts.length} places paid',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
        ]),
        const SizedBox(height: 8),

        ...results.map((r) {
          final row             = r as Map<String, dynamic>;
          final rank            = row['rank'] as int? ?? 0;
          final players         = row['players']?.toString() ?? 'Group ${row['group_number']}';
          final status          = row['status']?.toString() ?? '';
          final survived        = status == 'Survived';
          final payout          = (row['payout'] as num?)?.toDouble() ?? 0.0;
          final perPersonPayout = (row['per_person_payout'] as num?)?.toDouble() ?? payout;
          final netToPar        = row['net_to_par'] as int?;
          final eliminatedOn    = row['eliminated_on_hole'] as int?;
          final currentHole     = row['current_hole'] as int?;

          // Subtitle:
          //   "Not started"    — no holes played yet
          //   "Alive Thru 7"   — ball still in play, round not finished
          //   "Survived"       — all 18 holes completed with ball intact
          //   "Lost on Hole 4" — ball was lost
          final notStarted = currentHole == null || currentHole == 0;
          final activelyAlive = survived && !notStarted;
          final String subtitle;
          final Color  subtitleColor;
          if (!survived && eliminatedOn != null) {
            subtitle      = 'Lost on Hole $eliminatedOn';
            subtitleColor = theme.colorScheme.onSurfaceVariant;
          } else if (notStarted) {
            subtitle      = 'Not started';
            subtitleColor = theme.colorScheme.onSurfaceVariant;
          } else if (survived && currentHole != null && currentHole < 18) {
            subtitle      = 'Alive Thru $currentHole';
            subtitleColor = Colors.green.shade700;
          } else {
            // Completed all 18 holes with ball intact
            subtitle      = 'Survived';
            subtitleColor = Colors.green.shade700;
          }

          // Trailing: score on top, per-person payout below (right-justified)
          final ntpStr = _ntpLabel(netToPar);

          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            color: activelyAlive
                ? Colors.green.shade50.withOpacity(0.4)
                : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: activelyAlive
                  ? BorderSide(color: Colors.green.shade300, width: 1.5)
                  : BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: activelyAlive
                    ? Colors.green.shade600
                    : rank == 1
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                child: Text('$rank',
                    style: TextStyle(
                        fontSize: 13,
                        color: activelyAlive || rank == 1 ? Colors.white : null,
                        fontWeight: FontWeight.bold)),
              ),
              title: Text(players,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: subtitleColor)),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (activelyAlive || netToPar != null)
                    Text(
                      ntpStr,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _ntpColor(netToPar, theme),
                      ),
                    ),
                  if (perPersonPayout > 0) ...[
                    Text(
                      '\$${perPersonPayout.formatBet()}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.green.shade700),
                    ),
                    Text('each',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.green.shade600)),
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

// ---- Low Net ----

// ---- Low Net ----

class _LowNetView extends StatefulWidget {
  final Map<String, dynamic> data;
  const _LowNetView({required this.data});

  @override
  State<_LowNetView> createState() => _LowNetViewState();
}

class _LowNetViewState extends State<_LowNetView> {
  // Tracks which player rows are expanded (by '$rank:$name' key).
  final Set<String> _expanded = {};

  static String _ntpLabel(int? ntp) {
    if (ntp == null) return '—';
    if (ntp == 0)   return 'E';
    return ntp < 0 ? '$ntp' : '+$ntp';
  }

  static Color? _ntpColor(int? ntp, ThemeData theme) {
    if (ntp == null || ntp == 0) return null;
    return ntp < 0 ? Colors.green.shade700 : theme.colorScheme.error;
  }

  /// Compact 9-hole scorecard grid.
  /// [holes] is the full 18-hole list from the API; [isFront] selects 1-9 vs 10-18.
  Widget _nineGrid(BuildContext context, List holes,
      {required bool isFront, required bool showNet}) {
    final theme = Theme.of(context);

    // Column widths: hole, par, gross, net
    const double cHole = 26, cPar = 24, cGross = 28, cNet = 28;

    final headerStyle = theme.textTheme.labelSmall!.copyWith(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.onSurfaceVariant,
    );
    const cellStyle = TextStyle(fontSize: 11);

    Widget cell(double w, Widget child) =>
        SizedBox(width: w, child: Center(child: child));

    Widget gridRow({
      required String hole,
      required String par,
      required String gross,
      String? net,
      Color? grossColor,
      Color? netColor,
      bool bold = false,
    }) {
      final style = bold
          ? cellStyle.copyWith(fontWeight: FontWeight.bold)
          : cellStyle;
      return Row(children: [
        cell(cHole,  Text(hole,  style: style)),
        cell(cPar,   Text(par,   style: style)),
        cell(cGross, Text(gross, style: style.copyWith(color: grossColor))),
        if (showNet && net != null)
          cell(cNet, Text(net,   style: style.copyWith(color: netColor))),
      ]);
    }

    final segment = holes
        .where((h) {
          final n = (h as Map)['hole'] as int? ?? 0;
          return isFront ? n <= 9 : n > 9;
        })
        .cast<Map>()
        .toList();

    int totPar = 0, totGross = 0, totNet = 0;
    for (final h in segment) {
      totPar   += (h['par']    as int? ?? 0);
      totGross += (h['gross']  as int? ?? 0);
      totNet   += (h['capped'] as int? ?? 0);
    }
    final totNtp = segment.isEmpty ? null : totNet - totPar;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section label
        Text(
          isFront ? 'Front 9' : 'Back 9',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 4),
        // Header
        Row(children: [
          cell(cHole,  Text('Hole', style: headerStyle)),
          cell(cPar,   Text('Par',  style: headerStyle)),
          cell(cGross, Text('Grs',  style: headerStyle)),
          if (showNet) cell(cNet, Text('Net', style: headerStyle)),
        ]),
        const Divider(height: 5, thickness: 0.5),
        // Per-hole rows
        ...segment.map((h) {
          final hNum   = h['hole']   as int? ?? 0;
          final par    = h['par']    as int? ?? 0;
          final gross  = h['gross']  as int? ?? 0;
          final capped = h['capped'] as int? ?? 0;
          final gDiff  = gross  - par;
          final nDiff  = capped - par;
          return gridRow(
            hole:       '$hNum',
            par:        '$par',
            gross:      '$gross',
            net:        '$capped',
            grossColor: gDiff < 0 ? Colors.green.shade700
                      : gDiff > 0 ? theme.colorScheme.error : null,
            netColor:   nDiff < 0 ? Colors.green.shade700
                      : nDiff > 0 ? theme.colorScheme.error : null,
          );
        }),
        const Divider(height: 6, thickness: 0.5),
        // Totals
        gridRow(
          hole:     isFront ? 'Out' : 'In',
          par:      '$totPar',
          gross:    '$totGross',
          net:      _ntpLabel(totNtp),
          netColor: _ntpColor(totNtp, theme),
          bold:     true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final results    = (widget.data['results'] as List? ?? []);
    final entryFee   = (widget.data['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final payouts    = (widget.data['payouts'] as List? ?? []);
    final hmode      = widget.data['handicap_mode']?.toString() ?? 'net';
    final npct       = widget.data['net_percent'] as int? ?? 100;
    final showNet    = hmode != 'gross';

    final modeLabel = hmode == 'gross' ? 'Gross'
        : hmode == 'strokes_off' ? 'Strokes Off'
        : npct == 100 ? 'Full Net'
        : 'Net $npct%';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Info chips
        Row(children: [
          Chip(
            label: Text(modeLabel, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          if (entryFee > 0) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text('Entry \$${entryFee.formatBet()}',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
          if (payouts.isNotEmpty) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text(
                  payouts.length == 1
                      ? 'Winner takes all'
                      : '${payouts.length} places paid',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
        ]),
        const SizedBox(height: 8),

        // Player rows
        ...results.map((r) {
          final row         = r as Map<String, dynamic>;
          final rank        = row['rank']         as int?  ?? 0;
          final name        = row['name']?.toString()      ?? '—';
          final netToPar    = row['net_to_par']   as int?;
          final holesPlayed = row['holes_played'] as int?  ?? 0;
          final foursomeId  = row['foursome_id']  as int?;
          final payout      = (row['payout'] as num?)?.toDouble();
          final holesList   = (row['holes'] as List? ?? []);
          final key         = '$rank:$name';
          final isExpanded  = _expanded.contains(key);
          final parLabel    = _ntpLabel(netToPar);
          final parColor    = _ntpColor(netToPar, theme);

          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                // ── Summary row (always visible, tappable) ──────────────────
                InkWell(
                  onTap: holesList.isNotEmpty
                      ? () => setState(() {
                            if (isExpanded) _expanded.remove(key);
                            else            _expanded.add(key);
                          })
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: rank == 1
                              ? Colors.amber
                              : rank == 2
                                  ? Colors.grey.shade400
                                  : rank == 3
                                      ? const Color(0xFFcd7f32)
                                      : theme.colorScheme.surfaceContainerHighest,
                          child: Text('$rank',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: rank <= 3 ? Colors.white : null,
                                  fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(name,
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              Text(
                                holesPlayed == 18
                                    ? 'F'
                                    : holesPlayed > 0
                                        ? 'Thru $holesPlayed'
                                        : 'No scores',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(parLabel,
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: parColor)),
                            if (payout != null)
                              Text('\$${payout.formatBet()}',
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(color: Colors.green.shade700)),
                          ],
                        ),
                        const SizedBox(width: 4),
                        if (holesList.isNotEmpty)
                          Icon(
                            isExpanded ? Icons.expand_less : Icons.expand_more,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          )
                        else if (foursomeId != null)
                          IconButton(
                            icon: const Icon(Icons.table_chart_outlined, size: 20),
                            tooltip: 'View scorecard',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              context.read<RoundProvider>().loadScorecard(foursomeId);
                              Navigator.of(context).pushNamed('/scorecard',
                                  arguments: {
                                    'foursomeId': foursomeId,
                                    'readOnly': true,
                                  });
                            },
                          ),
                      ],
                    ),
                  ),
                ),

                // ── Expandable scorecard ────────────────────────────────────
                if (isExpanded && holesList.isNotEmpty)
                  Container(
                    color: theme.colorScheme.surfaceContainerLowest,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Column(
                      children: [
                        const Divider(height: 1),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _nineGrid(context, holesList,
                                  isFront: true, showNet: showNet),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _nineGrid(context, holesList,
                                  isFront: false, showNet: showNet),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
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
    final theme     = Theme.of(context);
    final configured = data['configured'] as bool? ?? true;
    final overall   = (data['overall'] as List? ?? []);
    final entryFee  = (data['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final payouts   = (data['payouts'] as List? ?? []);
    final hmode     = data['handicap_mode']?.toString() ?? 'net';
    final npct      = data['net_percent'] as int? ?? 100;
    final pool      = (data['pool'] as num?)?.toDouble() ?? 0.0;
    final ballsToCount = data['balls_to_count'] as int?;

    if (!configured) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Irish Rumble not configured for this round.\n\n'
            'Use the Game Setup card on the round screen to configure it first.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (overall.isEmpty) {
      return const Center(child: Text('No scores yet.'));
    }

    final modeLabel = hmode == 'gross' ? 'Gross'
        : hmode == 'strokes_off' ? 'Strokes Off'
        : npct == 100 ? 'Full Net'
        : 'Net $npct%';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Info chips — same pattern as Low Net
        Row(children: [
          Chip(
            label: Text(modeLabel, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          if (ballsToCount != null) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text('Best $ballsToCount count',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
          if (entryFee > 0) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text('Entry \$${entryFee.formatBet()}',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
          if (payouts.isNotEmpty) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text(
                  payouts.length == 1 ? 'Winner takes all' : '${payouts.length} places paid',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
        ]),
        const SizedBox(height: 8),

        ...overall.map((r) {
          final row             = r as Map<String, dynamic>;
          final rank            = row['rank'] as int?;
          final hasPhantom      = row['has_phantom'] as bool? ?? false;
          final playersRaw      = row['players']?.toString() ?? '';
          final players         = hasPhantom ? '$playersRaw + Phantom' : playersRaw;
          final ntp             = row['net_to_par'] as int?;
          final currentHole     = row['current_hole'] as int?;
          final payout          = (row['payout'] as num?)?.toDouble() ?? 0.0;
          final perPersonPayout = (row['per_person_payout'] as num?)?.toDouble() ?? payout;
          final isLeading       = rank == 1;

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
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              leading: CircleAvatar(
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
              title: Text(players,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(holeLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _ntpLabel(ntp),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: _ntpColor(ntp, theme),
                    ),
                  ),
                  if (pool > 0) ...[
                    Text(
                      perPersonPayout > 0
                          ? '\$${perPersonPayout.formatBet()}'
                          : '—',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: perPersonPayout > 0
                            ? Colors.green.shade700
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (perPersonPayout > 0)
                      Text('each',
                          style: TextStyle(
                              fontSize: 10,
                              color: Colors.green.shade600)),
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

// ── Irish Rumble tab: cup live card + per-foursome scorecard grids ────────────

class _IrishRumbleTabView extends StatefulWidget {
  final int roundId;
  final int tournamentId;

  const _IrishRumbleTabView({
    required this.roundId,
    required this.tournamentId,
  });

  @override
  State<_IrishRumbleTabView> createState() => _IrishRumbleTabViewState();
}

class _IrishRumbleTabViewState extends State<_IrishRumbleTabView> {
  bool   _loading = true;
  String? _error;
  Map<String, dynamic>? _irMatch;   // the irish_rumble entry from cup-live
  String _t1Name = 'Team 1';
  String _t2Name = 'Team 2';
  String _t1Colour = 'Red';
  String _t2Colour = 'Blue';

  // foursomeId → Scorecard (loaded lazily)
  final Map<int, Scorecard> _scorecards = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final live   = await client.getCupRoundLiveSummary(widget.roundId);

      final matches = (live['matches'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      final irMatch = matches.firstWhere(
        (m) => m['game_type'] == 'irish_rumble',
        orElse: () => <String, dynamic>{},
      );

      // Load scorecards for both IR foursomes in parallel
      final rp     = context.read<RoundProvider>();
      final round  = rp.round;
      final groups = (irMatch['groups'] as List? ?? []).cast<int>();
      final irFoursomes = round?.foursomes
          .where((f) => groups.contains(f.groupNumber))
          .toList() ?? [];

      if (irFoursomes.isNotEmpty) {
        final cards = await Future.wait(
          irFoursomes.map((f) => client.getScorecard(f.id)),
        );
        for (int i = 0; i < irFoursomes.length; i++) {
          _scorecards[irFoursomes[i].id] = cards[i];
        }
      }

      if (!mounted) return;
      setState(() {
        _irMatch   = irMatch.isEmpty ? null : irMatch;
        _t1Name    = live['team1_name']   as String? ?? 'Team 1';
        _t2Name    = live['team2_name']   as String? ?? 'Team 2';
        _t1Colour  = live['team1_colour'] as String? ?? 'Red';
        _t2Colour  = live['team2_colour'] as String? ?? 'Blue';
        _loading   = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  static String _fmtPts(double v) =>
      v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rp    = context.watch<RoundProvider>();
    final round = rp.round;

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: _load, child: const Text('Retry')),
      ]));
    }

    final t1Colour = _cupTeamColor(_t1Colour);
    final t2Colour = _cupTeamColor(_t2Colour);

    final irBallsConfig = round?.irBallsConfig ?? const [];
    final handicapMode  = round?.handicapMode  ?? 'net';

    // Foursomes involved in the IR match, ordered by group number
    final groups      = (_irMatch?['groups'] as List? ?? []).cast<int>();
    final irFoursomes = (round?.foursomes ?? [])
        .where((f) => groups.contains(f.groupNumber))
        .toList()
      ..sort((a, b) => a.groupNumber.compareTo(b.groupNumber));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Top: Bandon Cup live card ──────────────────────────────────────
          if (_irMatch != null)
            _BandonCupLiveCard(
              match:    _irMatch!,
              t1Colour: t1Colour,
              t2Colour: t2Colour,
              t1Name:   _t1Name,
              t2Name:   _t2Name,
              fmtPts:   _fmtPts,
            )
          else
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('No Irish Rumble cup match found.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),

          const SizedBox(height: 8),

          // ── Per-foursome scorecard grids ───────────────────────────────────
          if (irBallsConfig.isEmpty)
            Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Irish Rumble not configured for this round.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ))
          else ...[
            // groups[0] = team1's foursome, groups[1] = team2's foursome
            for (final fs in irFoursomes) () {
              final sc = _scorecards[fs.id];
              final realPlayers = fs.memberships
                  .where((m) => !m.player.isPhantom)
                  .toList();
              // Determine which team colour this group belongs to
              final idx = groups.indexOf(fs.groupNumber);
              final rawTeamColour = idx == 0 ? _t1Colour : _t2Colour;
              final teamColour = _cupTeamColor(rawTeamColour);
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _IRLeaderboardScorecard(
                  groupNumber:   fs.groupNumber,
                  teamColour:    teamColour,
                  teamName:      idx == 0 ? _t1Name : _t2Name,
                  players:       realPlayers,
                  scorecard:     sc,
                  irBallsConfig: irBallsConfig,
                  handicapMode:  handicapMode,
                ),
              );
            }(),
          ],
        ],
      ),
    );
  }
}

// ── Read-only Irish Rumble scorecard for the leaderboard tab ─────────────────

class _IRLeaderboardScorecard extends StatelessWidget {
  final int                         groupNumber;
  final Color                       teamColour;
  final String                      teamName;
  final List<Membership>            players;
  final Scorecard?                  scorecard;
  final List<Map<String, dynamic>>  irBallsConfig;
  final String                      handicapMode;

  const _IRLeaderboardScorecard({
    required this.groupNumber,
    required this.teamColour,
    required this.teamName,
    required this.players,
    required this.scorecard,
    required this.irBallsConfig,
    required this.handicapMode,
  });

  static const double _labelColW = 64.0;
  static const double _cellW     = 34.0;
  static const double _rowH      = 28.0;
  static const double _totalRowH = 30.0;

  int _ballsForHole(int hole) {
    for (final seg in irBallsConfig) {
      final s = seg['start_hole'] as int? ?? 0;
      final e = seg['end_hole']   as int? ?? 0;
      if (hole >= s && hole <= e) return seg['balls_to_count'] as int? ?? 1;
    }
    return 1;
  }

  int? _netToPar(Membership m, int hole) {
    final entry = scorecard?.holeData(hole)?.scoreFor(m.player.id);
    if (entry == null) return null;
    final par = entry.par;
    final raw = handicapMode == 'net' ? entry.netScore : entry.grossScore;
    if (raw == null) return null;
    return (raw.clamp(par - 10, par + 2)) - par;
  }

  Set<int> _countingIds(int hole) {
    final n = _ballsForHole(hole);
    final scored = <({int id, int ntp})>[];
    for (final m in players) {
      final ntp = _netToPar(m, hole);
      if (ntp != null) scored.add((id: m.player.id, ntp: ntp));
    }
    scored.sort((a, b) => a.ntp.compareTo(b.ntp));
    return scored.take(n).map((e) => e.id).toSet();
  }

  String _fmt(int ntp) => ntp == 0 ? 'E' : (ntp > 0 ? '+$ntp' : '$ntp');

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final holeRange  = List.generate(18, (i) => i + 1);
    final countBg    = theme.colorScheme.secondaryContainer.withOpacity(0.55);

    final segBoundaries = <int>{};
    for (int i = 1; i < irBallsConfig.length; i++) {
      final s = irBallsConfig[i]['start_hole'] as int? ?? 0;
      if (s > 1) segBoundaries.add(s);
    }

    // Pre-compute counting player IDs per hole
    final countingIds = { for (final h in holeRange) h: _countingIds(h) };

    // Pre-compute running totals
    int runAcc = 0; bool anyScored = false;
    final runningTotals = <int, int?>{};
    for (final h in holeRange) {
      final n = _ballsForHole(h);
      final scored = <int>[];
      for (final m in players) {
        final ntp = _netToPar(m, h);
        if (ntp != null) scored.add(ntp);
      }
      if (scored.isEmpty) { runningTotals[h] = null; continue; }
      scored.sort();
      runAcc += scored.take(n).fold(0, (s, v) => s + v);
      anyScored = true;
      runningTotals[h] = runAcc;
    }

    Widget cell(Widget child, {Color? bg, bool leftBorder = false}) =>
        Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            border: leftBorder
                ? Border(left: BorderSide(
                    color: theme.colorScheme.outlineVariant, width: 1.5))
                : null,
          ),
          child: child,
        );

    Widget totalCell(Widget child, {Color? bg}) =>
        Container(
          width: _cellW, height: _totalRowH,
          alignment: Alignment.center,
          color: bg,
          child: child,
        );

    final totalVal = runningTotals[18];
    final totalColor = totalVal == null ? null
        : totalVal < 0 ? Colors.green.shade700
        : totalVal > 0 ? theme.colorScheme.error
        : null;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(teamName,
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: teamColour)),
            if (scorecard == null) ...[
              const SizedBox(height: 8),
              Text('Loading scores…',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic)),
            ] else ...[
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hole row
                    Row(children: [
                      SizedBox(width: _labelColW, height: _rowH,
                          child: const Align(alignment: Alignment.centerLeft,
                              child: Text('Hole',
                                  style: TextStyle(fontSize: 11,
                                      fontWeight: FontWeight.bold)))),
                      for (final h in holeRange)
                        cell(Text('$h', style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold))),
                    ]),
                    // Par row
                    Row(children: [
                      SizedBox(width: _labelColW, height: _rowH,
                          child: Align(alignment: Alignment.centerLeft,
                              child: Text('Par',
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(fontStyle: FontStyle.italic)))),
                      for (final h in holeRange)
                        cell(Text(
                          '${scorecard!.holeData(h)?.par ?? "–"}',
                          style: theme.textTheme.bodySmall)),
                    ]),
                    // Balls-to-count row
                    Row(children: [
                      SizedBox(width: _labelColW, height: _rowH,
                          child: Align(alignment: Alignment.centerLeft,
                              child: Text('Count',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant)))),
                      for (final h in holeRange)
                        cell(
                          Text('${_ballsForHole(h)}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.bold)),
                          leftBorder: segBoundaries.contains(h),
                        ),
                    ]),
                    // Divider
                    Container(
                      height: 1,
                      width: _labelColW + _cellW * 18,
                      color: theme.colorScheme.outlineVariant,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                    ),
                    // Player rows
                    for (final m in players) Row(children: [
                      SizedBox(width: _labelColW, height: _rowH,
                          child: Align(alignment: Alignment.centerLeft,
                              child: Text(
                                m.player.displayShort.isNotEmpty
                                    ? m.player.displayShort
                                    : m.player.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: teamColour),
                              ))),
                      for (final h in holeRange) () {
                        final ntp    = _netToPar(m, h);
                        final counts = countingIds[h]!.contains(m.player.id);
                        final Color? bg = (ntp != null && counts) ? countBg : null;
                        final Color textColor = ntp == null
                            ? theme.colorScheme.onSurfaceVariant.withOpacity(0.4)
                            : !counts
                                ? theme.colorScheme.onSurfaceVariant
                                : ntp < 0 ? Colors.green.shade700
                                : ntp > 0 ? Colors.red.shade700
                                : theme.colorScheme.onSurface;
                        return cell(
                          Text(ntp != null ? _fmt(ntp) : '·',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: counts
                                      ? FontWeight.bold : FontWeight.normal,
                                  color: textColor)),
                          bg: bg,
                          leftBorder: segBoundaries.contains(h),
                        );
                      }(),
                    ]),
                    // Divider
                    Container(
                      height: 1,
                      width: _labelColW + _cellW * 18,
                      color: theme.colorScheme.outlineVariant,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                    ),
                    // Running total row
                    Row(children: [
                      SizedBox(width: _labelColW, height: _totalRowH,
                          child: Align(alignment: Alignment.centerLeft,
                              child: Text('Total',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary)))),
                      for (final h in holeRange) () {
                        final rt = runningTotals[h];
                        final isLast = rt == totalVal && rt != null;
                        final Color? bg = isLast
                            ? theme.colorScheme.primaryContainer.withOpacity(0.3)
                            : null;
                        return totalCell(
                          Text(
                            rt != null ? _fmt(rt) : '',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: totalColor),
                          ),
                          bg: bg,
                        );
                      }(),
                    ]),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
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

// ---- Multi-Foursome Skins view (round-level, crosses every group) ----

class _MultiSkinsView extends StatelessWidget {
  /// Multi-skins summary as returned by the backend.  Shape:
  ///   { status, handicap{mode, net_percent},
  ///     players: [{player_id, name, short_name, foursome_id,
  ///                group_number, skins_won, payout, thru}],
  ///     holes:   [{hole, winner_id, winner_short, is_dead}],
  ///     money:   {bet_unit, pool, total_skins} }
  final Map<String, dynamic> data;
  const _MultiSkinsView({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final players = (data['players'] as List? ?? []).cast<Map<String, dynamic>>();
    final holes   = (data['holes']   as List? ?? []).cast<Map<String, dynamic>>();
    final money   = (data['money']   as Map?  ?? {}).cast<String, dynamic>();
    final hcap    = (data['handicap'] as Map? ?? {}).cast<String, dynamic>();

    // Group standings by foursome for the section headers + scorecard
    // nav icon — same visual as the play screen.
    final byGroup = <int, List<Map<String, dynamic>>>{};
    for (final p in players) {
      byGroup.putIfAbsent((p['group_number'] as int? ?? 0), () => []).add(p);
    }
    final groupNums = byGroup.keys.toList()..sort();

    final pool       = (money['pool']        as num?)?.toDouble() ?? 0.0;
    final totalSkins = (money['total_skins'] as num?)?.toInt()    ?? 0;
    final mode       = hcap['mode']        as String? ?? 'net';
    final netPct     = hcap['net_percent'] as int?    ?? 100;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // ── Money / mode summary ────────────────────────────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Pool — \$${pool.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '${players.length} players  •  '
                '$totalSkins skin(s) won  •  '
                'Mode: ${mode.toUpperCase()}'
                '${mode == "net" && netPct != 100 ? " ($netPct%)" : ""}',
                style: theme.textTheme.bodySmall,
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),

        // ── Standings (grouped, with Thru + scorecard icon) ────────
        Card(
          child: Column(children: [
            ListTile(
              dense: true,
              title: const Text('Standings',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: SizedBox(
                width: 140,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: const [
                    SizedBox(width: 36,
                        child: Text('Thru', textAlign: TextAlign.right,
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    SizedBox(width: 8),
                    SizedBox(width: 36,
                        child: Text('Skins', textAlign: TextAlign.right,
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    SizedBox(width: 8),
                    SizedBox(width: 52,
                        child: Text('Payout', textAlign: TextAlign.right,
                            style: TextStyle(fontWeight: FontWeight.bold))),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            for (final gn in groupNums) ...[
              _MsGroupHeader(
                groupNumber: gn,
                foursomeId : byGroup[gn]!.first['foursome_id'] as int? ?? 0,
              ),
              for (final p in byGroup[gn]!)
                ListTile(
                  dense: true,
                  title: Text(p['name'] as String? ?? ''),
                  trailing: SizedBox(
                    width: 140,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        SizedBox(width: 36,
                            child: Text(
                              (p['thru'] as int? ?? 0) == 0
                                  ? '—' : '${p['thru']}',
                              textAlign: TextAlign.right)),
                        const SizedBox(width: 8),
                        SizedBox(width: 36,
                            child: Text('${p['skins_won'] ?? 0}',
                                textAlign: TextAlign.right)),
                        const SizedBox(width: 8),
                        SizedBox(width: 52,
                            child: Text(
                              '\$${((p['payout'] as num?)?.toDouble() ?? 0.0)
                                  .toStringAsFixed(2)}',
                              textAlign: TextAlign.right)),
                      ],
                    ),
                  ),
                ),
            ],
          ]),
        ),
        const SizedBox(height: 12),

        // ── Full scorecard grid ─────────────────────────────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: _MsScorecard(
              holes:        holes,
              participants: players,
            ),
          ),
        ),
      ],
    );
  }
}

class _MsGroupHeader extends StatelessWidget {
  final int groupNumber;
  final int foursomeId;
  const _MsGroupHeader({required this.groupNumber, required this.foursomeId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(children: [
        Text('Group $groupNumber',
            style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold)),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.assignment, size: 20),
          tooltip: 'View scorecard',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: foursomeId == 0
              ? null
              : () => Navigator.of(context).pushNamed(
                    '/scorecard',
                    arguments: {'foursomeId': foursomeId, 'readOnly': true},
                  ),
        ),
      ]),
    );
  }
}

/// Horizontally-scrollable scorecard for Multi-Group Skins.
///
/// Columns: hole numbers + par.  Rows: one per participant showing their
/// gross score per hole with stroke-dot overlays.  The cell of the hole's
/// skin winner is highlighted green so the player + score that won each
/// skin is obvious at a glance; dead-skin holes get a grey "—" header.
class _MsScorecard extends StatefulWidget {
  /// `holes` items are the per-hole payload from the multi-skins summary:
  ///   { hole, par, stroke_index, winner_id, winner_short, is_dead,
  ///     scores: [{player_id, gross, strokes}, …] }
  final List<Map<String, dynamic>> holes;
  /// Standings entries (used for the player labels in the leftmost column,
  /// in the same order the standings table shows them).
  final List<Map<String, dynamic>> participants;

  const _MsScorecard({required this.holes, required this.participants});

  @override
  State<_MsScorecard> createState() => _MsScorecardState();
}

class _MsScorecardState extends State<_MsScorecard> {
  static const double _labelColW = 78.0;
  static const double _cellW     = 32.0;
  static const double _rowH      = 26.0;

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final holes  = widget.holes;
    final winBg  = Colors.green.shade100;
    final winFg  = Colors.green.shade900;
    final deadBg = Colors.grey.shade200;

    final holeMap = {for (final h in holes) (h['hole'] as int): h};
    final visibleHoles = List.generate(18, (i) => i + 1);

    Widget headerCell(int h) {
      final entry  = holeMap[h];
      final isDead = entry?['is_dead'] == true;
      return Container(
        width: _cellW, height: _rowH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDead ? deadBg : null,
        ),
        child: Text(
          '$h',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isDead ? Colors.grey.shade600 : null,
          ),
        ),
      );
    }

    Widget parCell(int h) {
      final par = holeMap[h]?['par'] as int?;
      return SizedBox(
        width: _cellW, height: _rowH,
        child: Center(
          child: Text(
            par == null ? '–' : '$par',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      );
    }

    Widget scoreCell(int playerId, int h) {
      final entry = holeMap[h];
      if (entry == null) {
        return SizedBox(width: _cellW, height: _rowH);
      }
      final scores = (entry['scores'] as List? ?? []).cast<Map<String, dynamic>>();
      final mine = scores.firstWhere(
        (s) => s['player_id'] == playerId,
        orElse: () => const {},
      );
      if (mine.isEmpty) {
        // Participant didn't score this hole yet.
        return SizedBox(width: _cellW, height: _rowH);
      }
      final gross   = mine['gross'] as int;
      final strokes = mine['strokes'] as int? ?? 0;
      final isWinner = entry['winner_id'] == playerId;

      return Container(
        width: _cellW, height: _rowH,
        decoration: BoxDecoration(
          color: isWinner ? winBg : null,
          border: isWinner
              ? Border.all(color: Colors.green.shade400, width: 1)
              : null,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Stack(children: [
          Center(
            child: Text(
              '$gross',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
                color: isWinner ? winFg : null,
              ),
            ),
          ),
          if (strokes > 0)
            Positioned(
              top: 2, right: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  strokes.clamp(0, 2),
                  (i) => Container(
                    width: 4, height: 4,
                    margin: const EdgeInsets.only(left: 1),
                    decoration: BoxDecoration(
                      color: isWinner ? winFg : Colors.red.shade700,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: [
            Text('Scorecard',
                style: theme.textTheme.titleSmall),
            const Spacer(),
            Text('green = skin winner',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hole-number row
              Row(children: [
                SizedBox(
                  width: _labelColW, height: _rowH,
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Hole',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
                for (final h in visibleHoles) headerCell(h),
              ]),
              // Par row
              Row(children: [
                SizedBox(
                  width: _labelColW, height: _rowH,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Par',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontStyle: FontStyle.italic)),
                  ),
                ),
                for (final h in visibleHoles) parCell(h),
              ]),
              Container(
                height: 1,
                width: _labelColW + _cellW * visibleHoles.length,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(vertical: 2),
              ),
              // One row per participant
              for (final p in widget.participants)
                Row(children: [
                  SizedBox(
                    width: _labelColW, height: _rowH,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${(p['short_name'] as String?)?.isNotEmpty == true
                            ? p['short_name']
                            : p['name']} '
                        '(G${p['group_number']})',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  for (final h in visibleHoles)
                    scoreCell(p['player_id'] as int, h),
                ]),
            ],
          ),
        ),
      ],
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
                ? '\$${(payout as num).formatBet()}'
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

    // Cup match metadata
    final isCupMatch    = group['is_cup_match'] == true;
    final cupPointValue = (group['cup_point_value'] as num?)?.toDouble() ?? 1.0;
    final team1Name     = group['team1_name'] as String? ?? '';
    final team2Name     = group['team2_name'] as String? ?? '';

    final t1Names = nas.team1.map((p) => p.shortName).join(' & ');
    final t2Names = nas.team2.map((p) => p.shortName).join(' & ');

    // Team colors: use actual cup team colours for cup matches, orange for casual
    final t1Color    = isCupMatch
        ? _cupTeamColor(group['team1_colour'] as String?)
        : Colors.blue.shade700;
    final team2Color = isCupMatch
        ? _cupTeamColor(group['team2_colour'] as String?)
        : Colors.orange.shade800;

    Color totalColor(double total) {
      if (total > 0) return Colors.green.shade700;
      if (total < 0) return Colors.red.shade700;
      return theme.colorScheme.onSurface;
    }

    String signedDollar(double v) {
      if (v == 0) return '\$0.00';
      final sign = v > 0 ? '+' : '\u2212';
      return '$sign\$${v.abs().formatBet()}';
    }

    // ── Cup match: QuotaNassau-style layout ──────────────────────────────
    // Use the Overall bet's holesPlayed as the "thru N" count — it
    // tracks total holes played across the round, while F9/B9 cap at 9.
    final thru = nas.overall.holesPlayed;

    if (isCupMatch) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Header: team1 (left) vs team2 (right)
            Row(children: [
              Expanded(child: Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Text(t1Names, textAlign: TextAlign.end,
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: t1Color, fontWeight: FontWeight.bold)),
              )),
              SizedBox(width: 68, child: Center(
                child: Text('vs.', style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant)),
              )),
              Expanded(child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(t2Names,
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: team2Color, fontWeight: FontWeight.bold)),
              )),
            ]),
            if (thru > 0 && thru < 18)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Thru $thru',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            const Divider(height: 14),
            // Team1 on left, team2 on right
            _cupSegRow('F9',  nas.front9,  t1Color, team2Color, theme),
            _cupSegRow('B9',  nas.back9,   t1Color, team2Color, theme),
            _cupSegRow('All', nas.overall, t1Color, team2Color, theme),
          ]),
        ),
      );
    }

    // ── Casual match: original layout ─────────────────────────────────────
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Matchup line — player short names in team colors
          Center(
            child: RichText(
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
                    style: TextStyle(color: team2Color),
                  ),
                ],
              ),
            ),
          ),

          // "Thru N" — centered under the names while play is in progress.
          if (thru > 0 && thru < 18)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Thru $thru',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),

          const Divider(height: 16),

          // ── Top bet rows ──────────────────────────────────────────────
          if (nas.isClaremont)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Top (Nassau)',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
            ),
          _betRow(nas.isClaremont ? 'F9' : 'Front 9', nas.front9,  t1Names, t2Names, theme, team2Color: team2Color),
          const SizedBox(height: 4),
          _betRow(nas.isClaremont ? 'B9' : 'Back 9',  nas.back9,   t1Names, t2Names, theme, team2Color: team2Color),
          const SizedBox(height: 4),
          _betRow(nas.isClaremont ? 'All' : 'Overall', nas.overall, t1Names, t2Names, theme, team2Color: team2Color),

          // Top presses
          if (nas.presses.isNotEmpty) ...[
            const Divider(height: 14),
            ..._pressRows(nas.presses, t1Names, t2Names, theme, team2Color: team2Color),
          ],

          // ── Bottom (Claremont) bet rows ───────────────────────────────
          if (nas.isClaremont &&
              nas.bottomFront9 != null &&
              nas.bottomBack9  != null &&
              nas.bottomOverall != null) ...[
            const Divider(height: 14),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Bottom (Claremont)',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
            ),
            _bottomBetRow('F9',  nas.bottomFront9!,  t1Names, t2Names, theme, team2Color: team2Color),
            const SizedBox(height: 4),
            _bottomBetRow('B9',  nas.bottomBack9!,   t1Names, t2Names, theme, team2Color: team2Color),
            const SizedBox(height: 4),
            _bottomBetRow('All', nas.bottomOverall!, t1Names, t2Names, theme, team2Color: team2Color),
            if (nas.bottomPresses.isNotEmpty) ...[
              const Divider(height: 14),
              ..._pressRows(nas.bottomPresses, t1Names, t2Names, theme,
                  labelPrefix: 'Bot ', isBottom: true, team2Color: team2Color),
            ],
          ],

          const Divider(height: 16),

          // ── Summary footer ────────────────────────────────────────────
          if (isCupMatch) ...[
            // Cup match: show team points and match value
            Row(children: [
              Expanded(
                child: Builder(builder: (_) {
                  // Tally cup points: 1 segment pt per nine/overall won
                  double segPts1(NassauBetResult? bet) {
                    if (bet == null) return 0;
                    if (bet.result == 'team1') return cupPointValue;
                    if (bet.result == 'halved') return cupPointValue / 2;
                    return 0;
                  }
                  double segPts2(NassauBetResult? bet) {
                    if (bet == null) return 0;
                    if (bet.result == 'team2') return cupPointValue;
                    if (bet.result == 'halved') return cupPointValue / 2;
                    return 0;
                  }
                  final t1Total = segPts1(nas.front9) + segPts1(nas.back9) + segPts1(nas.overall);
                  final t2Total = segPts2(nas.front9) + segPts2(nas.back9) + segPts2(nas.overall);
                  String fmtPts(double v) => v % 1 == 0 ? v.toInt().toString() : v.toString();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${team1Name.isNotEmpty ? team1Name : t1Names}: ${fmtPts(t1Total)} pts',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade700,
                        ),
                      ),
                      Text(
                        '${team2Name.isNotEmpty ? team2Name : t2Names}: ${fmtPts(t2Total)} pts',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade700,
                        ),
                      ),
                    ],
                  );
                }),
              ),
              Builder(builder: (_) {
                final pv = cupPointValue % 1 == 0 ? cupPointValue.toInt().toString() : cupPointValue.toString();
                return Text(
                  'Match: $pv/$pv/$pv pts',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                );
              }),
            ]),
          ] else ...[
            // Casual match: show dollar amounts
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (nas.isClaremont) ...[
                      Text(
                        'Top:  ${signedDollar(nas.payoutTopTotal)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: totalColor(nas.payoutTopTotal)),
                      ),
                      Text(
                        'Bot:  ${signedDollar(nas.payoutBottomTotal)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: totalColor(nas.payoutBottomTotal)),
                      ),
                      const SizedBox(height: 2),
                    ],
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
                    'Match: \$${nas.betUnit.formatBet()}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (nas.pressUnit > 0)
                    Text(
                      'Press: \$${nas.pressUnit.formatBet()}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  /// Cup segment row: "1 UP" badge on the leading team's side, "All Square"
  /// in the centre when level.  Mirrors the QuotaNassau card layout.
  /// [leftIsTeam2] = true means team2 (red) is shown on the left side.
  static Widget _cupSegRow(
    String label,
    NassauBetResult bet,
    Color leftColor, Color rightColor,
    ThemeData theme, {
    bool leftIsTeam2 = false,
  }) {
    final holes  = bet.holesPlayed;
    final margin = bet.margin;
    final result = bet.result;
    final segLen = label == 'All' ? 18 : 9;

    Widget badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );

    String upText(int abs) {
      final holesLeft = segLen - holes;
      if (holes > 0 && holesLeft > 0 && abs > holesLeft) return '$abs&$holesLeft';
      return '$abs UP';
    }

    Widget? leftW, centerW, rightW;
    if (holes == 0) {
      centerW = Text('Not started', style: TextStyle(
          fontSize: 12, color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic));
    } else if (result == 'halved' || (result == null && margin == 0)) {
      centerW = badge('All Square', theme.colorScheme.onSurfaceVariant);
    } else {
      // team1 wins when result=='team1' or (in-progress) margin > 0
      final team1Wins = result == 'team1' || (result == null && margin > 0);
      final dm = bet.decidedMargin, dr = bet.decidedRemaining;
      final text = (dm != null && dr != null && dr > 0)
          ? '${dm.abs()}&$dr' : upText(margin.abs());
      if (leftIsTeam2) {
        // team2 on left: team2 wins → left badge; team1 wins → right badge
        if (team1Wins) {
          rightW = badge(text, rightColor);
        } else {
          leftW = badge(text, leftColor);
        }
      } else {
        // team1 on left (original): team1 wins → left badge
        if (team1Wins) {
          leftW = badge(text, leftColor);
        } else {
          rightW = badge(text, rightColor);
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 36,
            child: Text(label, style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Align(alignment: Alignment.centerRight,
              child: leftW ?? const SizedBox()),
        )),
        SizedBox(width: 68, child: Center(
            child: centerW ?? Container(
                width: 1, height: 24,
                color: theme.colorScheme.outlineVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Align(alignment: Alignment.centerLeft,
              child: rightW ?? const SizedBox()),
        )),
      ]),
    );
  }

  static Widget _betRow(
    String label,
    NassauBetResult bet,
    String t1Names,
    String t2Names,
    ThemeData theme, {
    Color? team2Color,
  }) {
    final t2Color   = team2Color ?? Colors.orange.shade700;
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
        if (bet.holesPlayed > 0 && holesLeft > 0 && m.abs() > holesLeft) {
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
      color = won ? Colors.blue.shade700 : t2Color;
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
    if (p.result == null) {
      // Still active — show running hole margin.
      final m = p.margin ?? 0;
      if (m == 0) return 'AS';
      final leader = m > 0 ? t1Names : t2Names;
      return '$leader ${m.abs()}UP';
    }
    if (p.result == 'halved') return 'AS';
    final m      = (p.margin ?? 0).abs();
    final winner = p.result == 'team1' ? t1Names : t2Names;
    if (m == 0) return '$winner wins';
    final score  = p.holesRemaining > 0
        ? '$m&${p.holesRemaining}'
        : '${m}UP';
    return '$winner $score';
  }

  /// Bottom press label — margin is in *points* (max ±2/hole), not holes.
  static String _bottomPressResultLabel(
      NassauPressResult p, String t1Names, String t2Names) {
    if (p.result == null) {
      // Still active — show running point margin.
      final m = p.margin ?? 0;
      if (m == 0) return 'AS';
      final leader = m > 0 ? t1Names : t2Names;
      return '$leader +${m.abs()} pts';
    }
    if (p.result == 'halved') return 'AS';
    final m      = (p.margin ?? 0).abs();
    final winner = p.result == 'team1' ? t1Names : t2Names;
    if (m == 0) return '$winner wins';
    return '$winner +$m pts';
  }

  /// Shared press rows widget — used for both top and bottom presses.
  static Iterable<Widget> _pressRows(
    List<NassauPressResult> presses,
    String t1Names,
    String t2Names,
    ThemeData theme, {
    String labelPrefix = '',
    bool isBottom = false,
    Color? team2Color,
  }) {
    final t2Color = team2Color ?? Colors.orange.shade700;
    return presses.map((p) {
      final resultLabel = isBottom
          ? _bottomPressResultLabel(p, t1Names, t2Names)
          : _pressResultLabel(p, t1Names, t2Names);
      Color resultColor;
      if (p.result == 'team1') {
        resultColor = Colors.blue.shade700;
      } else if (p.result == 'team2') {
        resultColor = t2Color;
      } else {
        resultColor = theme.colorScheme.onSurfaceVariant;
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(
            '$labelPrefix${p.pressType == 'manual' ? 'Manual' : 'Auto'} press '
            '${p.startHole}–${p.endHole}',
            style: theme.textTheme.bodySmall,
          ),
          const Spacer(),
          Text(resultLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600, color: resultColor)),
        ]),
      );
    });
  }

  /// Bet row for Claremont bottom (margin in points, not holes).
  static Widget _bottomBetRow(
    String label,
    NassauBottomBetResult bet,
    String t1Names,
    String t2Names,
    ThemeData theme, {
    Color? team2Color,
  }) {
    final t2Color = team2Color ?? Colors.orange.shade700;
    final result = bet.result;
    String display;
    Color  color = theme.colorScheme.onSurface;

    if (result == null) {
      final m = bet.margin;
      if (m == 0) {
        display = bet.holesPlayed == 0 ? 'Not started' : 'AS';
      } else {
        final leader = m > 0 ? t1Names : t2Names;
        display = '$leader ${m > 0 ? '+$m' : '$m'} pts';
        color   = m > 0 ? Colors.blue.shade700 : t2Color;
      }
    } else if (result == 'halved') {
      display = 'AS';
      color   = theme.colorScheme.onSurfaceVariant;
    } else {
      final won    = result == 'team1';
      final winner = won ? t1Names : t2Names;
      color   = won ? Colors.blue.shade700 : t2Color;
      display = '$winner wins';
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
              'Money (unit \$${betUnit.formatBet()})',
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
                    '$sign\$${amt.abs().formatBet()}',
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
                'Bet unit \$${betUnit.formatBet()}  '
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
    return '$sign\$${v.abs().formatBet()}';
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

// ---- Three-Person Match group card ----

class _ThreePersonMatchGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _ThreePersonMatchGroupCard({required this.group});

  static String _hcapLabel(Map<String, dynamic> hcap) {
    final mode = hcap['mode']?.toString() ?? 'net';
    if (mode == 'gross') return 'Gross';
    if (mode == 'strokes_off') return 'SO';
    final pct = (hcap['net_percent'] as num?)?.toInt() ?? 100;
    return pct == 100 ? 'Net' : 'Net ($pct%)';
  }

  static String _fmtPts(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static String _fmtMoney(double v) {
    if (v == 0) return '—';
    final sign = v > 0 ? '+' : '−';
    return '$sign\$${v.abs().formatBet()}';
  }

  static String _placeLabel(int place, {bool tied = false}) {
    if (tied && place > 1) return 'T$place';
    const labels = {1: '1st', 2: '2nd', 3: '3rd'};
    return labels[place] ?? '$place';
  }

  /// One-line match play status string for the phase 2 match.
  static String _p2MatchSummary(Map<String, dynamic> p2) {
    final p2Status   = p2['status']      as String? ?? 'pending';
    final leader     = p2['leader_name'] as String? ?? '?';
    final runnerUp   = p2['runner_up_name'] as String? ?? '?';
    final margin     = (p2['margin']     as num?)?.toInt() ?? 0;
    final lastHole   = (p2['last_hole']  as num?)?.toInt();
    final winnerName = p2['winner_name'] as String?;

    if (p2Status == 'pending') return 'Not started — $leader vs $runnerUp';
    if (p2Status == 'complete') {
      if (winnerName == null) {
        // All square after 18
        return 'All Square — $leader vs $runnerUp';
      }
      // Check if it ended early (dormie / decided before hole 18)
      if (lastHole != null && lastHole < 18) {
        final remaining = 18 - lastHole;
        return '$winnerName ${margin.abs()}&$remaining';
      }
      return '$winnerName wins ${margin.abs()}UP';
    }
    // in_progress
    if (lastHole == null) return '$leader vs $runnerUp — In progress';
    if (margin == 0) return 'All Square thru $lastHole';
    final aheadName = margin > 0 ? leader : runnerUp;
    return '$aheadName ${margin.abs()}UP thru $lastHole';
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final summary    = group['summary'] as Map<String, dynamic>? ?? {};
    final hcap       = summary['handicap'] as Map<String, dynamic>? ?? const {};
    final status     = summary['status']?.toString() ?? 'pending';
    final players    = (summary['players'] as List? ?? const []);
    final holes      = (summary['holes']   as List? ?? const []);
    final money      = summary['money']    as Map<String, dynamic>? ?? const {};
    final entryFee   = (money['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final payouts    = (money['payouts']   as List? ?? const []);
    final phase2     = summary['phase2']   as Map<String, dynamic>?;
    final singleGroup = group['_single_group'] == true;

    String statusLabel;
    switch (status) {
      case 'complete':    statusLabel = 'Final';       break;
      case 'in_progress': statusLabel = 'In progress'; break;
      case 'tiebreak':    statusLabel = 'Tiebreak';    break;
      case 'phase2':      statusLabel = 'Back 9';      break;
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

          // Header: mode + status chip
          Row(children: [
            Expanded(
              child: Text(
                'Three-Person Match — ${_hcapLabel(hcap)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: status == 'phase2'
                    ? theme.colorScheme.tertiaryContainer
                    : status == 'tiebreak'
                        ? Colors.orange.shade100
                        : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(statusLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: status == 'phase2'
                          ? theme.colorScheme.onTertiaryContainer
                          : status == 'tiebreak'
                              ? Colors.orange.shade800
                              : theme.colorScheme.onSurfaceVariant)),
            ),
          ]),
          const SizedBox(height: 10),

          // Player standings (5-3-1 phase)
          if (players.isEmpty)
            Text('No players yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant))
          else ...[
            // Count how many players share each final_place for T2 notation.
            () {
              final placeCount = <int, int>{};
              for (final p in players) {
                final fp = ((p as Map)['final_place'] as num?)?.toInt()
                    ?? ((p)['phase1_place'] as num?)?.toInt() ?? 0;
                placeCount[fp] = (placeCount[fp] ?? 0) + 1;
              }
              return Column(
                children: players.map((p) {
                  final r      = p as Map<String, dynamic>;
                  final name   = r['name']?.toString() ?? '';
                  final pts    = (r['phase1_points'] as num?)?.toDouble() ?? 0.0;
                  final fp     = (r['final_place']   as num?)?.toInt()
                      ?? (r['phase1_place'] as num?)?.toInt() ?? 0;
                  final pMoney = (r['money']         as num?)?.toDouble() ?? 0.0;
                  final isFirst  = fp == 1;
                  final isTied   = (placeCount[fp] ?? 1) > 1;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          _placeLabel(fp, tied: isTied),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: isFirst
                                ? Colors.amber.shade800
                                : theme.colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(name,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text('${_fmtPts(pts)} pts',
                          style: theme.textTheme.bodyMedium),
                      if (entryFee > 0) ...[
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 72,
                          child: Text(
                            _fmtMoney(pMoney),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: pMoney > 0
                                  ? Colors.green.shade700
                                  : pMoney < 0
                                      ? Colors.red.shade700
                                      : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ]),
                  );
                }).toList(),
              );
            }(),
          ],

          // Per-hole grid (reuses Points 5-3-1 grid — same hole entry shape)
          if (holes.isNotEmpty) ...[
            const Divider(height: 20),
            _Points531HoleGrid(holes: holes, players: players),
          ],

          // ── Tiebreak section ─────────────────────────────────────────────
          if (status == 'tiebreak') ...[
            const Divider(height: 20),
            _TpmTiebreakSection(
                tiebreak: summary['tiebreak'] as Map<String, dynamic>?,
                players: players,
                theme: theme),
          ],

          // ── Phase 2 — back-9 match play section ─────────────────────────
          if (phase2 != null) ...[
            const Divider(height: 20),
            _TpmPhase2Section(phase2: phase2, theme: theme),
          ],

          // Payout summary (shown when complete and entry fee > 0)
          if (entryFee > 0 && status == 'complete' &&
              payouts.any((p) => ((p as Map)['amount'] as num? ?? 0) > 0)) ...[
            const Divider(height: 16),
            ...payouts
                .where((p) => ((p as Map)['amount'] as num? ?? 0) > 0)
                .map((p) {
              final row    = p as Map<String, dynamic>;
              final place  = row['place']  as String? ?? '';
              final player = row['player'] as String?;
              final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(children: [
                  SizedBox(
                    width: 36,
                    child: Text(place,
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: Text(player ?? '—',
                        style: theme.textTheme.bodySmall),
                  ),
                  Text('\$${amount.toStringAsFixed(0)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.green.shade700,
                          fontWeight: FontWeight.w600)),
                ]),
              );
            }),
          ],
        ]),
      ),
    );
  }
}

/// Section widget showing the sudden-death tiebreak progress.
class _TpmTiebreakSection extends StatelessWidget {
  final Map<String, dynamic>? tiebreak;
  final List                  players;
  final ThemeData             theme;
  const _TpmTiebreakSection({
    required this.tiebreak,
    required this.players,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final tb = tiebreak ?? {};
    final leaderFound = tb['leader_found'] == true;
    final leaderName  = tb['leader_name'] as String?;
    final tiedAName   = tb['tied_a_name'] as String?;
    final tiedBName   = tb['tied_b_name'] as String?;
    final tbHoles     = (tb['holes'] as List? ?? []);

    // Column headers: before leader found, use standings order from players.
    final col0 = leaderFound ? (leaderName ?? '?')
        : (players.isNotEmpty ? (players[0] as Map)['short_name']?.toString() ?? '?' : '?');
    final col1 = leaderFound ? (tiedAName  ?? '?')
        : (players.length > 1 ? (players[1] as Map)['short_name']?.toString() ?? '?' : '?');
    final col2 = leaderFound ? (tiedBName  ?? '?')
        : (players.length > 2 ? (players[2] as Map)['short_name']?.toString() ?? '?' : '?');

    final muted = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final bodySmall = theme.textTheme.bodySmall;

    Widget scoreCell(int? score, int? minScore) {
      final isWin = score != null && minScore != null && score == minScore;
      return SizedBox(
        width: 40,
        child: Text(
          score?.toString() ?? '—',
          textAlign: TextAlign.center,
          style: bodySmall?.copyWith(
            fontWeight: isWin ? FontWeight.bold : FontWeight.normal,
            color: isWin ? theme.colorScheme.primary : theme.colorScheme.onSurface,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sudden Death',
            style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),

        // Describe the current SD state.
        Text(
          leaderFound
              ? '${leaderName ?? "?"} leads — ${tiedAName ?? "?"} vs ${tiedBName ?? "?"} in SD for 2nd'
              : '3-way SD — keep scoring hole by hole',
          style: bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),

        if (tbHoles.isNotEmpty) ...[
          const SizedBox(height: 8),
          // Header
          Row(children: [
            SizedBox(width: 48, child: Text('Hole', style: muted)),
            SizedBox(width: 40, child: Text(col0, textAlign: TextAlign.center, style: muted)),
            SizedBox(width: 40, child: Text(col1, textAlign: TextAlign.center, style: muted)),
            SizedBox(width: 40, child: Text(col2, textAlign: TextAlign.center, style: muted)),
          ]),
          ...tbHoles.map((h) {
            final row       = h as Map<String, dynamic>;
            final holeNum   = (row['hole'] as num?)?.toInt() ?? 0;
            final c0        = (row['leader_net'] as num?)?.toInt();
            final c1        = (row['tb_a_net']   as num?)?.toInt();
            final c2        = (row['tb_b_net']   as num?)?.toInt();
            final allScores = [c0, c1, c2].whereType<int>();
            final minScore  = allScores.isNotEmpty
                ? allScores.reduce((a, b) => a < b ? a : b) : null;
            final tieCount  = [c0, c1, c2].where((s) => s == minScore).length;
            final suffix    = tieCount == 3 ? ' (all ↔)' : tieCount == 2 ? ' (tied)' : '';
            return Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                SizedBox(
                  width: 48,
                  child: Text('H$holeNum$suffix',
                      style: bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                scoreCell(c0, minScore),
                scoreCell(c1, minScore),
                scoreCell(c2, minScore),
              ]),
            );
          }),
        ] else ...[
          const SizedBox(height: 4),
          Text('Scoring continues from hole 10.',
              style: bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic)),
        ],
      ],
    );
  }
}

/// Section widget for the back-9 match play phase of Three-Person Match.
class _TpmPhase2Section extends StatelessWidget {
  final Map<String, dynamic> phase2;
  final ThemeData            theme;
  const _TpmPhase2Section({required this.phase2, required this.theme});

  @override
  Widget build(BuildContext context) {
    final p2Status    = phase2['status']        as String? ?? 'pending';
    final leader      = phase2['leader_name']   as String? ?? '?';
    final runnerUp    = phase2['runner_up_name'] as String? ?? '?';
    final margin      = (phase2['margin']       as num?)?.toInt() ?? 0;
    final lastHole    = (phase2['last_hole']    as num?)?.toInt();
    final winnerName  = phase2['winner_name']   as String?;
    final p2Holes     = (phase2['holes']        as List? ?? const []);

    // Status line text & color
    String statusText;
    Color  statusColor;
    if (p2Status == 'complete') {
      if (winnerName == null) {
        statusText  = 'All Square after 18';
        statusColor = theme.colorScheme.onSurfaceVariant;
      } else if (lastHole != null && lastHole < 18) {
        final remaining = 18 - lastHole;
        statusText  = '$winnerName wins ${margin.abs()}&$remaining';
        statusColor = Colors.green.shade700;
      } else {
        statusText  = '$winnerName wins ${margin.abs()}UP';
        statusColor = Colors.green.shade700;
      }
    } else if (p2Status == 'in_progress') {
      if (lastHole == null || margin == 0) {
        statusText  = 'All Square${lastHole != null ? ' thru $lastHole' : ''}';
        statusColor = theme.colorScheme.onSurface;
      } else {
        final aheadName = margin > 0 ? leader : runnerUp;
        statusText  = '$aheadName ${margin.abs()}UP thru $lastHole';
        statusColor = theme.colorScheme.primary;
      }
    } else {
      statusText  = 'Not started yet';
      statusColor = theme.colorScheme.onSurfaceVariant;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Text('Back 9 Match Play',
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),

        // Matchup line
        Row(children: [
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: leader,
                    style: const TextStyle(color: Colors.blue),
                  ),
                  TextSpan(
                    text: ' vs ',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.normal),
                  ),
                  TextSpan(
                    text: runnerUp,
                    style: TextStyle(color: Colors.orange.shade800),
                  ),
                ],
              ),
            ),
          ),
        ]),
        const SizedBox(height: 4),

        // Status text
        Text(statusText,
            style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: statusColor)),

        // Compact per-hole strip (holes 10–18) when any holes are scored
        if (p2Holes.isNotEmpty) ...[
          const SizedBox(height: 8),
          _TpmPhase2HoleStrip(
            holes:        p2Holes,
            leader:       leader,
            runnerUp:     runnerUp,
            theme:        theme,
          ),
        ],
      ],
    );
  }
}

/// Compact hole-by-hole match play strip for Phase 2.
/// Shows hole numbers as a scrollable row with W/L/H indicators and
/// the running margin below.
class _TpmPhase2HoleStrip extends StatelessWidget {
  final List           holes;
  final String         leader;
  final String         runnerUp;
  final ThemeData      theme;
  const _TpmPhase2HoleStrip({
    required this.holes,
    required this.leader,
    required this.runnerUp,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    const cellW = 28.0;
    const rowH  = 20.0;
    const labelW = 52.0;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: hole numbers
          Row(children: [
            SizedBox(
              width: labelW,
              height: rowH,
              child: Text('Hole',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold)),
            ),
            for (final h in holes)
              SizedBox(
                width: cellW,
                height: rowH,
                child: Center(
                  child: Text(
                    '${(h as Map<String, dynamic>)['hole']}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
          ]),
          // Leader row: W/L/H
          Row(children: [
            SizedBox(
              width: labelW,
              height: rowH,
              child: Text(
                leader,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.blue, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final h in holes) ...[
              () {
                final hm         = h as Map<String, dynamic>;
                final leaderWins = hm['leader_wins'];
                String cell;
                Color  color;
                if (leaderWins == true) {
                  cell  = 'W';
                  color = Colors.green.shade700;
                } else if (leaderWins == false) {
                  cell  = 'L';
                  color = Colors.red.shade700;
                } else {
                  cell  = 'H';
                  color = theme.colorScheme.onSurfaceVariant;
                }
                return SizedBox(
                  width: cellW,
                  height: rowH,
                  child: Center(
                    child: Text(cell,
                        style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.bold, color: color)),
                  ),
                );
              }(),
            ],
          ]),
          // Margin row
          Row(children: [
            SizedBox(
              width: labelW,
              height: rowH,
              child: Text('Margin',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
            for (final h in holes) ...[
              () {
                final hm  = h as Map<String, dynamic>;
                final m   = (hm['margin'] as num?)?.toInt() ?? 0;
                final lbl = m == 0 ? 'AS' : (m > 0 ? '+$m' : '$m');
                final col = m > 0
                    ? Colors.blue.shade700
                    : m < 0
                        ? Colors.orange.shade800
                        : theme.colorScheme.onSurfaceVariant;
                return SizedBox(
                  width: cellW,
                  height: rowH,
                  child: Center(
                    child: Text(lbl,
                        style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600, color: col)),
                  ),
                );
              }(),
            ],
          ]),
        ],
      ),
    );
  }
}


// ---- Match Play group card ----

class _MatchPlayGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _MatchPlayGroupCard({required this.group});

  /// One-line score/status summary for a single match — mirrors
  /// _MatchPlayStatusCard._matchSummary() in score_entry_screen.dart.
  static String _matchSummary(Map<String, dynamic> match) {
    final status           = match['status']           as String? ?? 'pending';
    final result           = match['result']           as String?;
    final holes            = (match['holes']           as List?  ?? []);
    final p1               = match['player1']          as String? ?? '?';
    final winnerName       = match['winner_name']      as String?;
    final finishedOn       = match['finished_hole']    as int?;
    final tieBreak         = match['tie_break']        as String?;
    final round            = match['round']            as int? ?? 1;
    final playersTbd       = match['players_tbd']       as bool? ?? false;
    final playersTentative = match['players_tentative'] as bool? ?? false;

    // Back-9 match: no semi winner confirmed yet (e.g. both tied after F9)
    if (playersTbd) return 'Awaiting semi results';
    // Back-9 match: one semi confirmed, other still in sudden death
    if (playersTentative && status != 'complete') return 'Tracking live — SD in progress';
    if (status == 'pending' && holes.isEmpty) return 'Not started';

    if (status == 'complete') {
      if (result == 'halved') return 'Halved';
      if (winnerName == null) return 'Complete';
      if (tieBreak == 'sudden_death')  return '$winnerName wins (SD)';
      if (tieBreak == 'last_hole_won') return '$winnerName wins (last hole)';
      if (finishedOn != null) {
        final scheduledEnd = round == 1 ? 9 : 18;
        final remaining    = scheduledEnd - finishedOn;
        final h = holes.cast<Map<String, dynamic>>().firstWhere(
              (h) => h['hole'] == finishedOn, orElse: () => <String, dynamic>{});
        final margin = ((h['margin'] as int?) ?? 0).abs();
        if (remaining > 0) return '$winnerName ${margin}&$remaining';
        if (margin > 0)    return '$winnerName wins $margin Up';
      }
      return '$winnerName wins';
    }

    // in_progress
    if (holes.isEmpty) return 'In progress';
    final last        = holes.last as Map<String, dynamic>;
    final lastHoleNum = last['hole']   as int? ?? 0;
    final margin      = last['margin'] as int? ?? 0;
    if (margin == 0) return 'All Square thru $lastHoleNum';
    final leader = margin > 0 ? p1 : (match['player2'] as String? ?? '?');
    return '$leader ${margin.abs()} Up thru $lastHoleNum';
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final rawSummary = group['summary'];

    // Bracket not yet configured for this foursome.
    if (rawSummary == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Match Play bracket not set up for this group.\n'
              'Use the Game Setup card on the round screen.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ]),
        ),
      );
    }

    final summary  = rawSummary as Map<String, dynamic>? ?? {};
    final allMatches = (summary['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    final r1 = allMatches.where((m) => (m['round'] as int? ?? 1) == 1).toList();
    final r2 = allMatches.where((m) => (m['round'] as int? ?? 1) == 2).toList();
    final winner = summary['winner']?.toString();
    final status = summary['status']?.toString() ?? 'pending';
    final singleGroup = group['_single_group'] == true;

    // Money info
    final money      = summary['money'] as Map<String, dynamic>? ?? {};
    final entryFee   = (money['entry_fee']  as num?)?.toDouble() ?? 0.0;
    final prizePool  = (money['prize_pool'] as num?)?.toDouble() ?? 0.0;
    final payouts    = (money['payouts']    as List? ?? []);
    final hasPayouts = payouts.any((p) =>
        ((p as Map)['amount'] as num? ?? 0) > 0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          if (!singleGroup || winner != null) ...[
            Row(children: [
              if (!singleGroup)
                Text('Group ${group['group_number']}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              if (winner != null) ...[
                if (!singleGroup) const Spacer(),
                const Icon(Icons.emoji_events, size: 16, color: Colors.amber),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(winner,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ]),
            const Divider(height: 12),
          ],

          // Status chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: status == 'complete'
                  ? Colors.green.shade100
                  : status == 'in_progress'
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              status == 'complete'
                  ? 'Final'
                  : status == 'in_progress'
                      ? 'In progress'
                      : 'Pending',
              style: theme.textTheme.labelSmall?.copyWith(
                color: status == 'complete'
                    ? Colors.green.shade800
                    : status == 'in_progress'
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          // Semis section
          if (r1.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Semis (F9)',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            for (final m in r1) _MatchRow(match: m, theme: theme),
          ],

          // Final & 3rd section
          if (r2.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Final & 3rd (B9)',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            for (final m in r2) _MatchRow(match: m, theme: theme),
          ],

          // Money block — only when there's an entry fee
          if (entryFee > 0 && (hasPayouts || prizePool > 0)) ...[
            const Divider(height: 16),
            Row(children: [
              Text('Pool: \$${prizePool.toStringAsFixed(0)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600)),
            ]),
            if (hasPayouts) ...[
              const SizedBox(height: 4),
              ...payouts.where((p) =>
                  ((p as Map)['amount'] as num? ?? 0) > 0)
                  .map((p) {
                final row    = p as Map<String, dynamic>;
                final place  = row['place']  as String? ?? '';
                final player = row['player'] as String?;
                final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(children: [
                    SizedBox(
                      width: 32,
                      child: Text(place,
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600)),
                    ),
                    Expanded(
                      child: Text(player ?? '—',
                          style: theme.textTheme.bodySmall),
                    ),
                    Text('\$${amount.toStringAsFixed(0)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w600)),
                  ]),
                );
              }),
            ],
          ],
        ]),
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  final Map<String, dynamic> match;
  final ThemeData            theme;
  const _MatchRow({required this.match, required this.theme});

  @override
  Widget build(BuildContext context) {
    final p1     = match['player1'] as String? ?? '?';
    final p2     = match['player2'] as String? ?? '?';
    final label  = match['label']   as String? ?? '';
    final status = match['status']  as String? ?? 'pending';
    final summary = _MatchPlayGroupCard._matchSummary(match);

    final Color summaryColor;
    if (status == 'complete') {
      summaryColor = Colors.green.shade700;
    } else if (status == 'in_progress') {
      summaryColor = theme.colorScheme.primary;
    } else {
      summaryColor = theme.colorScheme.onSurfaceVariant;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(label,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$p1 vs $p2',
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 2),
          Text(summary,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: summaryColor, fontWeight: FontWeight.w600)),
        ],
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

// ---------------------------------------------------------------------------
// Bandon Cup unified tab — cumulative standings + current-round live events
// ---------------------------------------------------------------------------
//
// Layout:
//   1. Grand-total scoreboard (team colours, score in the middle)
//   2. Live / in-progress matches for the current round only
//      • Four Ball (Nassau): one row per unresolved segment
//      • Irish Rumble:       raw stroke scores on each side, pending in italic
//      • Singles:            individual match status

// Parse "Red" / "Blue" / "#ff0000" → Flutter Color (top-level so all cup widgets share it)
Color _cupTeamColor(String? raw) {
  switch ((raw ?? '').toLowerCase().trim()) {
    case 'red':         return const Color(0xFFB71C1C);
    case 'blue':        return const Color(0xFF0D47A1);
    case 'green':       return const Color(0xFF1B5E20);
    case 'gold':
    case 'yellow':      return const Color(0xFFF57F17);
    case 'orange':      return const Color(0xFFE65100);
    case 'purple':      return const Color(0xFF4A148C);
    case 'black':       return Colors.black87;
    default:
      final hex = (raw ?? '').replaceAll('#', '');
      if (hex.length == 6) {
        final v = int.tryParse('FF$hex', radix: 16);
        if (v != null) return Color(v);
      }
      return const Color(0xFF455A64);
  }
}

class _BandonCupTabView extends StatefulWidget {
  final int     roundId;
  final int?    tournamentId;
  final String  tournamentName;

  const _BandonCupTabView({
    required this.roundId,
    required this.tournamentName,
    this.tournamentId,
  });

  @override
  State<_BandonCupTabView> createState() => _BandonCupTabViewState();
}

class _BandonCupTabViewState extends State<_BandonCupTabView> {
  Map<String, dynamic>? _standings;   // from getTournamentCupStandings
  Map<String, dynamic>? _live;        // from getCupRoundLiveSummary
  bool    _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final futures = [
        if (widget.tournamentId != null)
          client.getTournamentCupStandings(widget.tournamentId!),
        client.getCupRoundLiveSummary(widget.roundId),
      ];
      final results = await Future.wait(futures.cast<Future>());
      if (mounted) {
        setState(() {
          _loading = false;
          if (widget.tournamentId != null) {
            _standings = results[0] as Map<String, dynamic>;
            _live      = results[1] as Map<String, dynamic>;
          } else {
            _standings = null;
            _live      = results[0] as Map<String, dynamic>;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // Delegates to the shared top-level helper
  static Color _teamColor(String? raw) => _cupTeamColor(raw);

  static String _fmtPts(double v) {
    if (v % 1 == 0) return v.toInt().toString();
    // Always show one decimal for halves
    return v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: _load, child: const Text('Retry')),
      ]));
    }

    // Use standings for cumulative total; fall back to live round data
    final src         = _standings ?? _live ?? {};
    final t1Name      = src['team1_name']   as String? ?? 'Team 1';
    final t2Name      = src['team2_name']   as String? ?? 'Team 2';
    final t1Colour    = _teamColor(src['team1_colour'] as String?);
    final t2Colour    = _teamColor(src['team2_colour'] as String?);
    final totalT1     = (src['team1_points']    as num?)?.toDouble() ?? 0.0;
    final totalT2     = (src['team2_points']    as num?)?.toDouble() ?? 0.0;
    final toWin       = (src['to_win']           as num?)?.toDouble();
    final liveMatches = (_live?['matches'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    // Only show matches that have at least one unresolved segment/match.
    // Irish Rumble is always shown first.
    final activeMatches = liveMatches.where((m) {
      final segs = (m['segments'] as List? ?? []).cast<Map<String, dynamic>>();
      final inds = (m['individual_matches'] as List? ?? []).cast<Map<String, dynamic>>();
      return segs.any((s) => s['is_resolved'] != true) ||
             inds.any((i) => i['is_resolved'] != true);
    }).toList()
      ..sort((a, b) {
        const order = {'irish_rumble': 0, 'nassau': 1, 'singles_nassau': 2, 'singles_18': 3};
        final ai = order[a['game_type'] as String? ?? ''] ?? 99;
        final bi = order[b['game_type'] as String? ?? ''] ?? 99;
        return ai.compareTo(bi);
      });

    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // ── Grand Total Scoreboard ──────────────────────────────────────
          _BandonCupScoreboard(
            t1Name   : t1Name,
            t2Name   : t2Name,
            t1Colour : t1Colour,
            t2Colour : t2Colour,
            t1Pts    : totalT1,
            t2Pts    : totalT2,
            toWin    : toWin,
            cupName  : widget.tournamentName,
            fmtPts   : _fmtPts,
          ),

          // ── Live Match Events ───────────────────────────────────────────
          if (activeMatches.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'LIVE NOW',
                  style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.2,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
            ]),
            const SizedBox(height: 12),
            ...activeMatches.map((m) => _BandonCupLiveCard(
                  match    : m,
                  t1Colour : t1Colour,
                  t2Colour : t2Colour,
                  t1Name   : t1Name,
                  t2Name   : t2Name,
                  fmtPts   : _fmtPts,
                )),
          ] else if (_live != null) ...[
            const SizedBox(height: 24),
            Center(
              child: Text(
                'No live matches in progress.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Grand total scoreboard card ───────────────────────────────────────────────

class _BandonCupScoreboard extends StatelessWidget {
  final String   t1Name, t2Name, cupName;
  final Color    t1Colour, t2Colour;
  final double   t1Pts, t2Pts;
  final double?  toWin;
  final String Function(double) fmtPts;

  const _BandonCupScoreboard({
    required this.t1Name,   required this.t2Name,
    required this.t1Colour, required this.t2Colour,
    required this.t1Pts,    required this.t2Pts,
    required this.cupName,  required this.fmtPts,
    this.toWin,
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final tied    = t1Pts == t2Pts;
    final t1Leads = t1Pts > t2Pts;

    // Solid coloured block for one team — white text throughout.
    Widget teamBlock(
        String name, double pts, Color bg, bool isLeading) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          color: bg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                fmtPts(pts),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: isLeading ? 62 : 52,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 3,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Cup name banner
          Container(
            width: double.infinity,
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              cupName.toUpperCase(),
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(
                  letterSpacing: 1.5,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),

          // Solid colour team score blocks — red team always on left.
          // Detect which team is "red" by comparing the red channel, same
          // logic used in the Irish Rumble section of _BandonCupLiveCard.
          Builder(builder: (ctx) {
            final leftIsT1  = t1Colour.red >= t2Colour.red;
            final leftName  = leftIsT1 ? t1Name   : t2Name;
            final leftPts   = leftIsT1 ? t1Pts    : t2Pts;
            final leftCol   = leftIsT1 ? t1Colour : t2Colour;
            final rightName = leftIsT1 ? t2Name   : t1Name;
            final rightPts  = leftIsT1 ? t2Pts    : t1Pts;
            final rightCol  = leftIsT1 ? t2Colour : t1Colour;
            final leftLeads = leftPts > rightPts;
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  teamBlock(leftName,  leftPts,  leftCol,  leftLeads || tied),
                  Container(width: 3, color: Colors.white),
                  teamBlock(rightName, rightPts, rightCol, !leftLeads || tied),
                ],
              ),
            );
          }),

          // Status / to-win footer — always show points needed when known
          if (toWin != null)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                tied && (t1Pts > 0 || t2Pts > 0)
                    ? 'All Square — ${fmtPts(toWin!)} pts needed to win'
                    : '${fmtPts(toWin!)} pts needed to win',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Live match card — dispatches to the right layout by game type ─────────────

class _BandonCupLiveCard extends StatelessWidget {
  final Map<String, dynamic>     match;
  final Color                    t1Colour, t2Colour;
  final String                   t1Name, t2Name;
  final String Function(double)  fmtPts;

  const _BandonCupLiveCard({
    required this.match,
    required this.t1Colour, required this.t2Colour,
    required this.t1Name,   required this.t2Name,
    required this.fmtPts,
  });

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final gameType  = match['game_type']   as String? ?? '';
    final gameLabel = match['game_label']  as String? ?? gameType;
    final groups    = (match['groups'] as List? ?? []).cast<int>();
    final pv        = (match['point_value'] as num?)?.toDouble() ?? 1.0;
    final t1Players = (match['team1_players'] as List? ?? []).cast<String>();
    final t2Players = (match['team2_players'] as List? ?? []).cast<String>();
    final segments  = (match['segments'] as List? ?? []).cast<Map<String, dynamic>>();
    final indivs    = (match['individual_matches'] as List? ?? []).cast<Map<String, dynamic>>();

    final groupLabel = groups.length == 1
        ? 'Group ${groups.first}'
        : 'Groups ${groups.join(' & ')}';
    final totalPossible = (match['total_possible'] as num?)?.toDouble() ?? pv;
    final pvLabel = gameType == 'irish_rumble'
        ? '${totalPossible % 1 == 0 ? totalPossible.toInt().toString() : fmtPts(totalPossible)} pts • winner-take-all'
        : (pv % 1 == 0
            ? '${pv.toInt()} pt${pv >= 2 ? "s" : ""}/seg'
            : '${fmtPts(pv)} pts/seg');

    // Compute the match's "Thru N" — the furthest hole anyone in this
    // match has scored.  Nassau segments report `holes_played`; Irish
    // Rumble segments split it into `a_holes_played` / `b_holes_played`
    // by segment half; per-pair singles modes use `holes_played` on
    // each individual match row.
    int thru = 0;
    for (final s in segments) {
      final hp  = (s['holes_played']   as num?)?.toInt() ?? 0;
      final ah  = (s['a_holes_played'] as num?)?.toInt() ?? 0;
      final bh  = (s['b_holes_played'] as num?)?.toInt() ?? 0;
      if (hp > thru) thru = hp;
      if (ah > thru) thru = ah;
      if (bh > thru) thru = bh;
    }
    for (final m in indivs) {
      final hp = (m['holes_played'] as num?)?.toInt() ?? 0;
      if (hp > thru) thru = hp;
    }
    final thruLabel = (thru > 0 && thru < 18) ? '  •  Thru $thru' : '';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Card header
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(gameLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$groupLabel • $pvLabel$thruLabel',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ]),
            const SizedBox(height: 10),

            // Team name header — red always on left, blue on right.
            // Detect which of t1/t2 is "red" by comparing the red channel.
            // Irish Rumble shows team names. Nassau uses player names with the same red-left layout.
            // Singles Nassau shows individual matchups only — no team header needed.
            if (gameType == 'irish_rumble') ...[
              Builder(builder: (ctx) {
                final leftIsT1 = t1Colour.red >= t2Colour.red;
                final leftName   = leftIsT1 ? t1Name   : t2Name;
                final leftColor  = leftIsT1 ? t1Colour : t2Colour;
                final rightName  = leftIsT1 ? t2Name   : t1Name;
                final rightColor = leftIsT1 ? t2Colour : t1Colour;
                return Row(children: [
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Text(leftName,
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: leftColor,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                  SizedBox(
                    width: 68,
                    child: Center(child: Text('vs.',
                        style: TextStyle(fontSize: 12,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
                  ),
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Text(rightName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: rightColor,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                ]);
              }),
            ] else if (gameType == 'nassau')
              Builder(builder: (ctx) {
                // Red team always on left — detect by comparing red channel.
                final leftIsT1   = t1Colour.red >= t2Colour.red;
                final leftPly    = leftIsT1 ? t1Players : t2Players;
                final leftColor  = leftIsT1 ? t1Colour  : t2Colour;
                final rightPly   = leftIsT1 ? t2Players : t1Players;
                final rightColor = leftIsT1 ? t2Colour  : t1Colour;
                return Row(children: [
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Text(leftPly.join(' & '),
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: leftColor,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                  SizedBox(
                    width: 68,
                    child: Center(child: Text('vs.',
                        style: TextStyle(fontSize: 12,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
                  ),
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Text(rightPly.join(' & '),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: rightColor,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                ]);
              })
            else if (gameType == 'quota_nassau')
              Builder(builder: (ctx) {
                final leftIsT1   = t1Colour.red >= t2Colour.red;
                final leftPly    = leftIsT1 ? t1Players : t2Players;
                final leftColor  = leftIsT1 ? t1Colour  : t2Colour;
                final rightPly   = leftIsT1 ? t2Players : t1Players;
                final rightColor = leftIsT1 ? t2Colour  : t1Colour;
                return Row(children: [
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Text(leftPly.join(' & '),
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: leftColor,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                  SizedBox(
                    width: 68,
                    child: Center(child: Text('vs.',
                        style: TextStyle(fontSize: 12,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
                  ),
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Text(rightPly.join(' & '),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: rightColor,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                ]);
              })
            else
              Row(children: [
                Expanded(child: Text(t1Players.join(', '),
                    style: TextStyle(color: t1Colour, fontWeight: FontWeight.w600,
                        fontSize: 13),
                    overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Expanded(child: Text(t2Players.join(', '),
                    style: TextStyle(color: t2Colour, fontWeight: FontWeight.w600,
                        fontSize: 13),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis)),
              ]),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),

            // Game-type-specific rows
            if (gameType == 'nassau')
              _NassauLiveRows(
                  segments: segments,
                  t1Colour: t1Colour, t2Colour: t2Colour,
                  t1Players: t1Players, t2Players: t2Players,
                  // Red team on left: team2 is on left when t2 is redder
                  leftIsTeam2: t2Colour.red >= t1Colour.red)
            else if (gameType == 'irish_rumble')
              _IRLiveRows(
                  segments: segments,
                  t1Players: t1Players, t2Players: t2Players,
                  t1Colour: t1Colour,  t2Colour: t2Colour,
                  pv: pv, fmtPts: fmtPts)
            else if (gameType == 'quota_nassau')
              _QuotaNassauLiveRows(
                  matches: indivs, t1Colour: t1Colour, t2Colour: t2Colour)
            else if (gameType == 'singles_nassau')
              _CupSinglesLiveRows(
                  matches: indivs, t1Colour: t1Colour, t2Colour: t2Colour)
            else
              _SinglesLiveRows(
                  matches: indivs, t1Colour: t1Colour, t2Colour: t2Colour,
                  pv: pv, fmtPts: fmtPts),
          ],
        ),
      ),
    );
  }
}

// ── Quota Nassau live rows: combined TEAM totals (F9 / All) ──────────────────
//
// Aggregates all individual matches so that:
//   Team 1 = all player1 entries combined
//   Team 2 = all player2 entries combined
// Shows combined pts vs combined quota for F9 and 18-hole (All).

class _QuotaNassauLiveRows extends StatelessWidget {
  final List<Map<String, dynamic>> matches;
  final Color t1Colour, t2Colour;
  const _QuotaNassauLiveRows({
    required this.matches,
    required this.t1Colour, required this.t2Colour,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (matches.isEmpty) {
      return Text('Not started.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic));
    }

    // Aggregate across all individual matches
    int t1Quota18 = 0, t2Quota18 = 0;
    int t1F9Pts   = 0, t2F9Pts   = 0;
    int t1AllPts  = 0, t2AllPts  = 0;
    int holesPlayed = 0;

    for (final m in matches) {
      t1Quota18  += (m['player1_quota'] as num?)?.toInt() ?? 0;
      t2Quota18  += (m['player2_quota'] as num?)?.toInt() ?? 0;
      t1F9Pts    += (m['p1_f9_pts']     as num?)?.toInt() ?? 0;
      t2F9Pts    += (m['p2_f9_pts']     as num?)?.toInt() ?? 0;
      t1AllPts   += (m['p1_all_pts']    as num?)?.toInt() ?? 0;
      t2AllPts   += (m['p2_all_pts']    as num?)?.toInt() ?? 0;
      final hp    = (m['holes_played']  as num?)?.toInt() ?? 0;
      if (hp > holesPlayed) holesPlayed = hp;
    }

    // Team-level F9/B9 quota split (avoids rounding errors from odd individual quotas)
    final t1F9Quota = t1Quota18 ~/ 2;
    final t2F9Quota = t2Quota18 ~/ 2;
    final t1B9Quota = t1Quota18 - t1F9Quota;
    final t2B9Quota = t2Quota18 - t2F9Quota;

    // B9 pts = All pts − F9 pts
    final t1B9Pts = t1AllPts - t1F9Pts;
    final t2B9Pts = t2AllPts - t2F9Pts;

    // Team F9/B9 results: compare combined team stpl minus combined team quota.
    // Must NOT aggregate per-pair individual match results — those compare
    // player1 vs player2 within a pairing, not team vs team.
    String? _teamResult(int t1pts, int t1q, int t2pts, int t2q, bool resolved) {
      if (!resolved) return null;
      final d1 = t1pts - t1q, d2 = t2pts - t2q;
      if (d1 > d2) return 'player1';
      if (d2 > d1) return 'player2';
      return 'halved';
    }
    final f9Result  = _teamResult(t1F9Pts,  t1F9Quota,  t2F9Pts,  t2F9Quota,  holesPlayed >= 9);
    final b9Result  = _teamResult(t1B9Pts,  t1B9Quota,  t2B9Pts,  t2B9Quota,  holesPlayed >= 18);
    final allResult = _teamResult(t1AllPts, t1Quota18,  t2AllPts, t2Quota18,  holesPlayed >= 18);

    String vsQ(int pts, int q) {
      final d = pts - q;
      if (d == 0) return 'E';
      return d > 0 ? '+$d' : '$d';
    }

    // Score badge pair for a resolved segment
    Widget? segBadges(String? result, double pv) {
      if (result == null) return null;
      double t1p = 0, t2p = 0;
      if (result == 'player1')      { t1p = pv; }
      else if (result == 'player2') { t2p = pv; }
      else { t1p = pv / 2; t2p = pv / 2; }
      String fmt(double v) => v % 1 == 0 ? v.toInt().toString() : '½';
      Widget dot(double pts, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.withOpacity(0.12),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: c.withOpacity(0.4)),
        ),
        child: Text(fmt(pts),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: c)),
      );
      return Row(mainAxisSize: MainAxisSize.min, children: [
        dot(t1p, t1Colour),
        const SizedBox(width: 4),
        dot(t2p, t2Colour),
      ]);
    }

    // One score row: [label] T1 right-aligned | badges or divider | T2 left-aligned
    // notStarted=true → shows the label + "Not started" text instead of scores.
    Widget pairRow(String label, int t1pts, int t1q, int t2pts, int t2q,
        {Widget? centerBadge, bool notStarted = false}) {
      if (notStarted) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 32,
                child: Text(label,
                    style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurfaceVariant))),
            const Expanded(child: SizedBox()),
            Text('Not started',
                style: TextStyle(fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic)),
            const Expanded(child: SizedBox()),
          ]),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          // Row label (F9 / B9 / All)
          SizedBox(
            width: 32,
            child: Text(label,
                style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant)),
          ),
          // T1 right-aligned, with right padding before center
          Expanded(child: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
              Text('$t1pts stpl',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                      color: t1Colour)),
              Text('Quota $t1q  (${vsQ(t1pts, t1q)})',
                  style: TextStyle(fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
          )),
          // Center: fixed-width slot so T1/T2 columns never shift
          SizedBox(
            width: 68,
            child: Center(
              child: centerBadge ?? Container(
                  width: 1, height: 32,
                  color: theme.colorScheme.outlineVariant),
            ),
          ),
          // T2 left-aligned, with left padding after center
          Expanded(child: Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('$t2pts stpl',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                      color: t2Colour)),
              Text('Quota $t2q  (${vsQ(t2pts, t2q)})',
                  style: TextStyle(fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
          )),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          holesPlayed == 0
              ? 'Not started'
              : '$holesPlayed hole${holesPlayed == 1 ? '' : 's'} played',
          style: TextStyle(
              fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        pairRow('F9',  t1F9Pts,  t1F9Quota,  t2F9Pts,  t2F9Quota,
            centerBadge: segBadges(f9Result, 1.0),
            notStarted: holesPlayed == 0),
        pairRow('B9',  t1B9Pts,  t1B9Quota,  t2B9Pts,  t2B9Quota,
            centerBadge: segBadges(b9Result, 1.0),
            notStarted: holesPlayed < 10),
        pairRow('All', t1AllPts, t1Quota18,  t2AllPts, t2Quota18,
            centerBadge: segBadges(allResult, 1.0),
            notStarted: holesPlayed == 0),
      ],
    );
  }
}

// ── Nassau: one row per unresolved segment ────────────────────────────────────

class _NassauLiveRows extends StatelessWidget {
  final List<Map<String, dynamic>> segments;
  final Color t1Colour, t2Colour;
  final List<String> t1Players, t2Players;
  /// When true, team2 (red) is displayed on the left and team1 (blue) on the right.
  final bool leftIsTeam2;
  const _NassauLiveRows({
    required this.segments,
    required this.t1Colour, required this.t2Colour,
    this.t1Players = const [], this.t2Players = const [],
    this.leftIsTeam2 = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final pending = segments.where((s) => s['is_resolved'] != true).toList();
    if (pending.isEmpty) {
      return Text('All segments resolved.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic));
    }

    Widget badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );

    return Column(
      children: pending.map((seg) {
        final rawLabel = seg['label'] as String? ?? seg['segment'] as String? ?? '—';
        // Normalise label: "Front 9" → "F9", "Back 9" → "B9", "Overall" → "All"
        final label = rawLabel == 'Front 9' ? 'F9'
            : rawLabel == 'Back 9'  ? 'B9'
            : rawLabel == 'Overall' ? 'All'
            : rawLabel;
        final margin  = (seg['margin'] as num?)?.toInt() ?? 0;
        final holes   = (seg['holes_played'] as num?)?.toInt() ?? 0;
        final segLen  = label == 'All' ? 18 : 9;

        Widget? leftW, centerW, rightW;
        if (holes == 0) {
          centerW = Text('Not started', style: TextStyle(
              fontSize: 12, color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic));
        } else if (margin == 0) {
          centerW = badge('All Square', theme.colorScheme.onSurfaceVariant);
        } else {
          final abs       = margin.abs();
          final holesLeft = segLen - holes;
          final text      = (holesLeft > 0 && abs > holesLeft) ? '$abs&$holesLeft' : '$abs UP';
          // margin > 0 means team1 is winning
          final team1Wins = margin > 0;
          if (leftIsTeam2) {
            // team2 on left: team2 wins → left badge, team1 wins → right badge
            if (team1Wins) {
              rightW = badge(text, t1Colour);
            } else {
              leftW = badge(text, t2Colour);
            }
          } else {
            if (team1Wins) {
              leftW = badge(text, t1Colour);
            } else {
              rightW = badge(text, t2Colour);
            }
          }
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 36,
                child: Text(label, style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant))),
            Expanded(child: Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Align(alignment: Alignment.centerRight,
                  child: leftW ?? const SizedBox()),
            )),
            SizedBox(width: 68, child: Center(
                child: centerW ?? Container(
                    width: 1, height: 24,
                    color: theme.colorScheme.outlineVariant))),
            Expanded(child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Align(alignment: Alignment.centerLeft,
                  child: rightW ?? const SizedBox()),
            )),
          ]),
        );
      }).toList(),
    );
  }
}

// ── Irish Rumble: per-foursome vs-par scores, coloring the leader ─────────────

class _IRLiveRows extends StatelessWidget {
  final List<Map<String, dynamic>> segments;
  final List<String>               t1Players, t2Players;
  final Color                      t1Colour, t2Colour;
  final double                     pv;
  final String Function(double)    fmtPts;

  const _IRLiveRows({
    required this.segments,
    required this.t1Players, required this.t2Players,
    required this.t1Colour,  required this.t2Colour,
    required this.pv,        required this.fmtPts,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (segments.isEmpty) return const SizedBox.shrink();

    // Use the first (Overall) segment which has per-foursome vs-par data.
    // a = team1 (blue/t1Colour), b = team2 (red/t2Colour)
    // Convention: red (b/t2) on the left, blue (a/t1) on the right.
    final seg          = segments.first;
    final aVsPar       = (seg['a_vs_par']       as num?)?.toInt();
    final bVsPar       = (seg['b_vs_par']       as num?)?.toInt();
    final aHoles       = (seg['a_holes_played'] as num?)?.toInt() ?? 0;
    final bHoles       = (seg['b_holes_played'] as num?)?.toInt() ?? 0;

    String _fmtVsPar(int? v) {
      if (v == null) return '–';
      if (v == 0) return 'E';
      return v > 0 ? '+$v' : '$v';
    }

    // Detect which of t1/t2 is the "red" team (higher red channel = left side),
    // matching the same convention used in the card header.
    // a = t1 data, b = t2 data (from the backend segment keys).
    final leftIsT1  = t1Colour.red >= t2Colour.red;
    final leftVsPar  = leftIsT1 ? aVsPar  : bVsPar;
    final rightVsPar = leftIsT1 ? bVsPar  : aVsPar;
    final leftHoles  = leftIsT1 ? aHoles  : bHoles;
    final rightHoles = leftIsT1 ? bHoles  : aHoles;
    final leftColour  = leftIsT1 ? t1Colour : t2Colour;
    final rightColour = leftIsT1 ? t2Colour : t1Colour;

    // Color only the lower (more negative = better) score in that team's colour.
    final neutral = theme.colorScheme.onSurfaceVariant;
    Color lColor = neutral;
    Color rColor = neutral;
    if (leftVsPar != null && rightVsPar != null) {
      if (leftVsPar  < rightVsPar) lColor = leftColour;
      else if (rightVsPar < leftVsPar)  rColor = rightColour;
    } else if (leftVsPar  != null && rightVsPar == null) {
      lColor = leftColour;
    } else if (rightVsPar != null && leftVsPar  == null) {
      rColor = rightColour;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Left (red team)
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                _fmtVsPar(leftVsPar),
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: lColor),
              ),
              const SizedBox(height: 2),
              Text(
                leftHoles > 0 ? 'thru $leftHoles' : '–',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          ),

          // Right (blue team)
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(
                _fmtVsPar(rightVsPar),
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: rColor),
                textAlign: TextAlign.end,
              ),
              const SizedBox(height: 2),
              Text(
                rightHoles > 0 ? 'thru $rightHoles' : '–',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.end,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Singles: individual match status rows ─────────────────────────────────────

class _SinglesLiveRows extends StatelessWidget {
  final List<Map<String, dynamic>> matches;
  final Color                      t1Colour, t2Colour;
  final double                     pv;
  final String Function(double)    fmtPts;

  const _SinglesLiveRows({
    required this.matches,
    required this.t1Colour, required this.t2Colour,
    required this.pv, required this.fmtPts,
  });

  static String _statusLabel(Map<String, dynamic> m) {
    final status       = m['status']          as String? ?? '';
    final result       = m['result']          as String?;
    final holesPlayed  = m['holes_played']    as int?    ?? 0;
    final overallUp    = m['overall_holes_up'] as int?   ?? 0;
    final finishedOn   = m['finished_on_hole'] as int?;
    final p1           = m['player1']         as String? ?? '?';
    final p2           = m['player2']         as String? ?? '?';

    if (result == 'halved')  return 'Halved';
    if (result == 'team1' || result == 'player1') {
      if (finishedOn != null) {
        final rem = 18 - finishedOn;
        final mag = overallUp.abs();
        return rem > 0 ? '$p1 ${mag}&$rem' : '$p1 ${mag}Up';
      }
      return '$p1 wins';
    }
    if (result == 'team2' || result == 'player2') {
      if (finishedOn != null) {
        final rem = 18 - finishedOn;
        final mag = overallUp.abs();
        return rem > 0 ? '$p2 ${mag}&$rem' : '$p2 ${mag}Up';
      }
      return '$p2 wins';
    }
    if (status == 'pending' || holesPlayed == 0) return 'Not started';
    if (overallUp == 0) return 'AS thru $holesPlayed';
    final leader = overallUp > 0 ? p1 : p2;
    return '$leader ${overallUp.abs()} Up thru $holesPlayed';
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final pending = matches.where((m) => m['is_resolved'] != true).toList();
    if (pending.isEmpty) {
      return Text('All matches complete.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic));
    }
    return Column(
      children: pending.map((m) {
        final p1          = m['player1']          as String? ?? '?';
        final p2          = m['player2']          as String? ?? '?';
        final status      = _statusLabel(m);
        final holesPlayed = m['holes_played']     as int?    ?? 0;
        final overallUp   = m['overall_holes_up'] as int?    ?? 0;
        final result      = m['result']           as String?;

        // Badge colour: leader's team colour, neutral for AS / not started
        final bool hasLeader = holesPlayed > 0 &&
            overallUp != 0 &&
            result != 'halved';
        final Color leaderColour = overallUp > 0 ? t1Colour : t2Colour;
        final Color badgeColour  = hasLeader
            ? leaderColour
            : theme.colorScheme.onSurfaceVariant;
        final Color badgeBg = hasLeader
            ? leaderColour.withOpacity(0.15)
            : theme.colorScheme.surfaceContainerHighest;
        final Color badgeBorder = hasLeader
            ? leaderColour.withOpacity(0.4)
            : theme.colorScheme.outlineVariant;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            // Player 1
            Expanded(
              child: Text(p1,
                  style: TextStyle(
                      color: t1Colour,
                      fontWeight: FontWeight.w600,
                      fontSize: 13),
                  overflow: TextOverflow.ellipsis),
            ),
            // Status badge
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: badgeBorder, width: 1),
                ),
                child: Text(status,
                    style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: badgeColour,
                        fontWeight: hasLeader
                            ? FontWeight.w600
                            : FontWeight.normal)),
              ),
            ),
            // Player 2
            Expanded(
              child: Text(p2,
                  style: TextStyle(
                      color: t2Colour,
                      fontWeight: FontWeight.w600,
                      fontSize: 13),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        );
      }).toList(),
    );
  }
}



// ── Cup Singles live rows: per-match headers + F9/B9/All segment rows ─────────
//  Mirrors _NassauGroupCard cup layout: red (p2) on left, blue (p1) on right.

class _CupSinglesLiveRows extends StatelessWidget {
  final List<Map<String, dynamic>> matches;
  final Color t1Colour, t2Colour;   // t1=blue (player1), t2=red (player2)

  const _CupSinglesLiveRows({
    required this.matches,
    required this.t1Colour,
    required this.t2Colour,
  });

  // Segment row.
  // holesUp > 0 means p1 leads. p1OnLeft controls which side p1 occupies.
  static Widget _segRow(
    String  label,
    String? segStatus,
    String? segResult,
    int?    holesUp,
    int?    finishedOn,
    int     endHole,
    Color   leftColor,
    Color   rightColor,
    ThemeData theme, {
    bool p1OnLeft = false,
  }) {
    Widget badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );

    Widget? leftW, centerW, rightW;
    if (segStatus == null || segStatus == 'pending') {
      centerW = Text('—', style: TextStyle(
          fontSize: 13, color: theme.colorScheme.outlineVariant));
    } else {
      final up = holesUp ?? 0;
      if (segResult == 'halved' || up == 0) {
        centerW = badge('All Square', theme.colorScheme.onSurfaceVariant);
      } else {
        final p1Leads = up > 0;
        final String text;
        if (segStatus == 'complete' &&
            finishedOn != null &&
            finishedOn < endHole) {
          text = '${up.abs()}&${endHole - finishedOn}';
        } else {
          text = '${up.abs()} UP';
        }
        // Badge goes on the winning player's side.
        final winnerOnLeft = p1Leads == p1OnLeft;
        if (winnerOnLeft) {
          leftW  = badge(text, leftColor);
        } else {
          rightW = badge(text, rightColor);
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 36,
            child: Text(label, style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Align(alignment: Alignment.centerRight,
              child: leftW ?? const SizedBox()),
        )),
        SizedBox(width: 68, child: Center(
            child: centerW ?? Container(
                width: 1, height: 24,
                color: theme.colorScheme.outlineVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Align(alignment: Alignment.centerLeft,
              child: rightW ?? const SizedBox()),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final pending = matches.where((m) => m['is_resolved'] != true).toList();
    if (pending.isEmpty) {
      return Text('All matches complete.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic));
    }

    // Detect which team is "red" — red always goes on the left.
    final leftIsT1   = t1Colour.red >= t2Colour.red;
    final leftColour  = leftIsT1 ? t1Colour : t2Colour;
    final rightColour = leftIsT1 ? t2Colour : t1Colour;

    return Column(
      children: pending.asMap().entries.expand<Widget>((entry) {
        final i = entry.key;
        final m = entry.value;
        final p1          = m['player1']      as String? ?? '?';  // t1
        final p2          = m['player2']      as String? ?? '?';  // t2
        final holesPlayed = m['holes_played'] as int?    ?? 0;

        // Arrange names so red team is always on the left.
        final leftName  = leftIsT1 ? p1 : p2;
        final rightName = leftIsT1 ? p2 : p1;

        return [
          if (i > 0) const Divider(height: 18),

          // Per-match header: red player on left, blue player on right
          Row(children: [
            Expanded(child: Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Text(leftName, textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: leftColour,
                      fontWeight: FontWeight.bold, fontSize: 13)),
            )),
            SizedBox(width: 68, child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('vs.', style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant)),
                if (holesPlayed > 0)
                  Text('thru $holesPlayed',
                      style: TextStyle(
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurfaceVariant)),
              ]),
            )),
            Expanded(child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(rightName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: rightColour,
                      fontWeight: FontWeight.bold, fontSize: 13)),
            )),
          ]),
          const Divider(height: 12),

          // F9 / B9 / All segment rows
          _segRow('F9',
            m['f9_status']           as String?,
            m['f9_result']           as String?,
            m['f9_holes_up']         as int?,
            m['f9_finished_on_hole'] as int?,
            9,  leftColour, rightColour, theme, p1OnLeft: leftIsT1),
          _segRow('B9',
            m['b9_status']           as String?,
            m['b9_result']           as String?,
            m['b9_holes_up']         as int?,
            m['b9_finished_on_hole'] as int?,
            18, leftColour, rightColour, theme, p1OnLeft: leftIsT1),
          _segRow('All',
            m['status']              as String?,
            m['result']              as String?,
            m['overall_holes_up']    as int?,
            m['finished_on_hole']    as int?,
            18, leftColour, rightColour, theme, p1OnLeft: leftIsT1),
        ];
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Cup Irish Rumble — head-to-head pairing view
// ---------------------------------------------------------------------------

class _CupIrishRumbleView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _CupIrishRumbleView({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final pairings = (data['pairings'] as List? ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();

    if (pairings.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No Irish Rumble pairings configured.',
              textAlign: TextAlign.center),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: pairings.map((p) {
        final teamA       = p['team_a']         as String? ?? 'Team A';
        final teamB       = p['team_b']         as String? ?? 'Team B';
        final groupA      = p['group_a']        as int?    ?? 0;
        final groupB      = p['group_b']        as int?    ?? 0;
        final f9          = p['front9_result']  as String?;
        final b9          = p['back9_result']   as String?;
        final ovr         = p['overall_result'] as String?;
        final colorA      = _cupTeamColor(p['team_a_colour'] as String?);
        final colorB      = _cupTeamColor(p['team_b_colour'] as String?);

        String _label(String? result, String a, String b) {
          if (result == null) return '—';
          if (result == 'team_a') return a;
          if (result == 'team_b') return b;
          return 'Halved';
        }

        Color _color(String? result, ThemeData t) {
          if (result == null) return t.colorScheme.onSurfaceVariant;
          if (result == 'team_a') return colorA;
          if (result == 'team_b') return colorB;
          return t.colorScheme.onSurface;
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              RichText(text: TextSpan(
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                children: [
                  TextSpan(text: 'Group $groupA (', style: TextStyle(color: theme.colorScheme.onSurface)),
                  TextSpan(text: teamA, style: TextStyle(color: colorA)),
                  TextSpan(text: ')  vs  Group $groupB (', style: TextStyle(color: theme.colorScheme.onSurface)),
                  TextSpan(text: teamB, style: TextStyle(color: colorB)),
                  TextSpan(text: ')', style: TextStyle(color: theme.colorScheme.onSurface)),
                ],
              )),
              const SizedBox(height: 10),
              Row(children: [
                for (final seg in [
                  ('F9',  f9),
                  ('B9',  b9),
                  ('All', ovr),
                ])
                  Expanded(
                    child: Column(children: [
                      Text(seg.$1,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text(
                        _label(seg.$2, teamA, teamB),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize  : 13,
                          color     : _color(seg.$2, theme),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ]),
                  ),
              ]),
            ]),
          ),
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Singles 18 — live-style row card (P1 | status badge | P2)
// Matches the Bandon Cup "Live Now" layout for singles matches.
// ---------------------------------------------------------------------------

class _Singles18GroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _Singles18GroupCard({required this.group});

  static String _statusLabel(Map<String, dynamic> m) {
    final status      = m['status']           as String? ?? '';
    final result      = m['result']           as String?;
    final holesPlayed = m['holes_played']     as int?    ?? 0;
    final overallUp   = m['overall_holes_up'] as int?    ?? 0;
    final finishedOn  = m['finished_on_hole'] as int?;
    final p1          = m['player1']          as String? ?? '?';
    final p2          = m['player2']          as String? ?? '?';

    if (holesPlayed == 0) return 'Not started';
    if (status == 'complete') {
      if (result == 'halved') return 'Halved';
      final winner = result == 'player1' ? p1 : p2;
      if (finishedOn != null) {
        final rem = 18 - finishedOn;
        final mag = overallUp.abs();
        return rem > 0 ? '$winner ${mag}&$rem' : '$winner wins $mag Up';
      }
      return '$winner wins';
    }
    if (overallUp == 0) return 'AS thru $holesPlayed';
    final leader = overallUp > 0 ? p1 : p2;
    return '$leader ${overallUp.abs()} Up thru $holesPlayed';
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final rawSummary = group['summary'];

    if (rawSummary == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('Singles not yet set up for this group.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }

    final summary = rawSummary as Map<String, dynamic>;
    final matches = (summary['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

    final t1Color = _cupTeamColor(
        (group['team1_colour'] as String?) ??
        (summary['team1_colour'] as String?));
    final t2Color = _cupTeamColor(
        (group['team2_colour'] as String?) ??
        (summary['team2_colour'] as String?));

    if (matches.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('No singles matches found.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }

    // Determine display order: Red always on left, Blue on right.
    // Check raw colour strings from the summary to decide if a swap is needed.
    final t1ColourStr = ((group['team1_colour'] as String?) ??
            (summary['team1_colour'] as String?) ?? '')
        .toLowerCase()
        .trim();
    final t2ColourStr = ((group['team2_colour'] as String?) ??
            (summary['team2_colour'] as String?) ?? '')
        .toLowerCase()
        .trim();
    // Swap so that the red team is always on the left side.
    final swapSides = t2ColourStr == 'red' || t1ColourStr == 'blue';
    final leftColor  = swapSides ? t2Color : t1Color;
    final rightColor = swapSides ? t1Color : t2Color;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          children: matches.asMap().entries.map((entry) {
            final i           = entry.key;
            final m           = entry.value;
            final p1Raw       = m['player1'] as String? ?? '?';
            final p2Raw       = m['player2'] as String? ?? '?';
            final leftPlayer  = swapSides ? p2Raw : p1Raw;
            final rightPlayer = swapSides ? p1Raw : p2Raw;
            final statusText  = _statusLabel(m);
            final holesPlayed = m['holes_played']     as int? ?? 0;
            final overallUp   = m['overall_holes_up'] as int? ?? 0;
            final result      = m['result']           as String?;

            // Badge colour: leader's team colour, neutral for AS / not started
            final bool hasLeader = holesPlayed > 0 &&
                overallUp != 0 &&
                result != 'halved';
            // overallUp > 0 means player1 leads (t1Color), regardless of swap
            final Color leaderColor =
                overallUp > 0 ? t1Color : t2Color;
            final Color badgeColor =
                hasLeader ? leaderColor : theme.colorScheme.onSurfaceVariant;
            final Color badgeBg = hasLeader
                ? leaderColor.withOpacity(0.15)
                : theme.colorScheme.surfaceContainerHighest;
            final Color badgeBorder = hasLeader
                ? leaderColor.withOpacity(0.4)
                : theme.colorScheme.outlineVariant;

            return Padding(
              padding: EdgeInsets.only(
                top:    i == 0 ? 4 : 6,
                bottom: i == matches.length - 1 ? 4 : 6,
              ),
              child: Row(children: [
                // Left player (Red)
                Expanded(
                  child: Text(leftPlayer,
                      style: TextStyle(
                          color: leftColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
                // Status badge
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: badgeBorder, width: 1),
                    ),
                    child: Text(statusText,
                        style: TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: badgeColor,
                            fontWeight: hasLeader
                                ? FontWeight.w600
                                : FontWeight.normal)),
                  ),
                ),
                // Right player (Blue)
                Expanded(
                  child: Text(rightPlayer,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          color: rightColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cup Singles — Nassau-style 1-v-1 match cards (mirrors _NassauGroupCard)
// ---------------------------------------------------------------------------

class _CupSinglesGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _CupSinglesGroupCard({required this.group});

  // ── Segment row — mirrors _NassauGroupCard._cupSegRow ────────────────────
  // leftColor = team1/player1, rightColor = team2/player2
  static Widget _singlesSegRow(
    String  label,
    String? segStatus,    // 'pending' | 'in_progress' | 'complete'
    String? segResult,    // null | 'player1' | 'player2' | 'halved'
    int?    holesUp,      // positive = player1 leads
    int?    finishedOn,   // hole number segment was decided on (if early)
    int     endHole,      // 9 for F9/B9-segment, 18 for All
    Color   leftColor,
    Color   rightColor,
    ThemeData theme, {
    bool p1OnLeft = true,
  }) {
    Widget badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );

    Widget? leftW, centerW, rightW;

    if (segStatus == null || segStatus == 'pending') {
      centerW = Text('—', style: TextStyle(
          fontSize: 13, color: theme.colorScheme.outlineVariant));
    } else {
      final up = holesUp ?? 0;
      if (segResult == 'halved' || up == 0) {
        centerW = badge('All Square', theme.colorScheme.onSurfaceVariant);
      } else {
        final p1Leads = up > 0;
        final String text;
        if (segStatus == 'complete' &&
            finishedOn != null &&
            finishedOn < endHole) {
          // Decided before last hole → X&Y notation
          final rem = endHole - finishedOn;
          text = '${up.abs()}&$rem';
        } else {
          text = '${up.abs()} UP';
        }
        // Badge goes on the winning player's side.
        final winnerOnLeft = p1Leads == p1OnLeft;
        if (winnerOnLeft) {
          leftW  = badge(text, leftColor);
        } else {
          rightW = badge(text, rightColor);
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 36,
            child: Text(label, style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Align(alignment: Alignment.centerRight,
              child: leftW ?? const SizedBox()),
        )),
        SizedBox(width: 68, child: Center(
            child: centerW ?? Container(
                width: 1, height: 24,
                color: theme.colorScheme.outlineVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Align(alignment: Alignment.centerLeft,
              child: rightW ?? const SizedBox()),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final rawSummary = group['summary'];
    final groupNum   = group['group_number'] as int? ?? 0;
    final t1Color    = _cupTeamColor(
        (group['team1_colour'] as String?) ??
        ((rawSummary as Map?)?['team1_colour'] as String?));
    final t2Color    = _cupTeamColor(
        (group['team2_colour'] as String?) ??
        ((rawSummary as Map?)?['team2_colour'] as String?));

    if (rawSummary == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Group $groupNum',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Singles not yet set up for this group.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
    }

    final summary = rawSummary as Map<String, dynamic>;
    final matches = (summary['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

    // Red always on the left.
    final p1OnLeft    = t1Color.red >= t2Color.red;
    final leftColor   = p1OnLeft ? t1Color : t2Color;
    final rightColor  = p1OnLeft ? t2Color : t1Color;

    if (matches.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('No singles matches found.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: matches.asMap().entries.expand<Widget>((entry) {
            final i           = entry.key;
            final m           = entry.value;
            final p1Raw       = m['player1']      as String? ?? '?';
            final p2Raw       = m['player2']      as String? ?? '?';
            final holesPlayed = m['holes_played'] as int?    ?? 0;
            // Arrange so red team is on the left.
            final leftName  = p1OnLeft ? p1Raw : p2Raw;
            final rightName = p1OnLeft ? p2Raw : p1Raw;
            return [
              if (i > 0) const Divider(height: 22),

              // Header: red player on left, blue player on right
              Row(children: [
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(leftName, textAlign: TextAlign.end,
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: leftColor, fontWeight: FontWeight.bold)),
                )),
                SizedBox(width: 68, child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('vs.', style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant)),
                    if (holesPlayed > 0)
                      Text('thru $holesPlayed',
                          style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                )),
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Text(rightName,
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: rightColor, fontWeight: FontWeight.bold)),
                )),
              ]),
              const Divider(height: 14),

              // F9 segment (leftColor=red p1OnLeft, badge logic uses p1OnLeft)
              _singlesSegRow(
                'F9',
                m['f9_status']           as String?,
                m['f9_result']           as String?,
                m['f9_holes_up']         as int?,
                m['f9_finished_on_hole'] as int?,
                9,
                leftColor, rightColor, theme, p1OnLeft: p1OnLeft,
              ),
              // B9 segment
              _singlesSegRow(
                'B9',
                m['b9_status']           as String?,
                m['b9_result']           as String?,
                m['b9_holes_up']         as int?,
                m['b9_finished_on_hole'] as int?,
                18,
                leftColor, rightColor, theme, p1OnLeft: p1OnLeft,
              ),
              // All segment
              _singlesSegRow(
                'All',
                m['status']              as String?,
                m['result']              as String?,
                m['overall_holes_up']    as int?,
                m['finished_on_hole']    as int?,
                18,
                leftColor, rightColor, theme, p1OnLeft: p1OnLeft,
              ),
            ];
          }).toList(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cup Singles 18 — same header as Singles-Nassau but one "All" row per match
// ---------------------------------------------------------------------------

class _CupSingles18GroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _CupSingles18GroupCard({required this.group});

  // Single overall row — mirrors _CupSinglesGroupCard._singlesSegRow
  static Widget _allRow(
    String? status,
    String? result,
    int?    holesUp,
    int?    finishedOn,
    Color   leftColor,
    Color   rightColor,
    ThemeData theme, {
    bool p1OnLeft = true,
  }) {
    Widget badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );

    Widget? leftW, centerW, rightW;
    if (status == null || status == 'pending') {
      centerW = Text('—', style: TextStyle(
          fontSize: 13, color: theme.colorScheme.outlineVariant));
    } else {
      final up = holesUp ?? 0;
      if (result == 'halved' || up == 0) {
        centerW = badge('All Square', theme.colorScheme.onSurfaceVariant);
      } else {
        final p1Leads = up > 0;
        final String text;
        if (status == 'complete' && finishedOn != null && finishedOn < 18) {
          text = '${up.abs()}&${18 - finishedOn}';
        } else {
          text = '${up.abs()} UP';
        }
        final winnerOnLeft = p1Leads == p1OnLeft;
        if (winnerOnLeft) {
          leftW  = badge(text, leftColor);
        } else {
          rightW = badge(text, rightColor);
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 36,
            child: Text('All', style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Align(alignment: Alignment.centerRight,
              child: leftW ?? const SizedBox()),
        )),
        SizedBox(width: 68, child: Center(
            child: centerW ?? Container(
                width: 1, height: 24,
                color: theme.colorScheme.outlineVariant))),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Align(alignment: Alignment.centerLeft,
              child: rightW ?? const SizedBox()),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final rawSummary = group['summary'];
    final groupNum   = group['group_number'] as int? ?? 0;
    final t1Color    = _cupTeamColor(
        (group['team1_colour'] as String?) ??
        ((rawSummary as Map?)?['team1_colour'] as String?));
    final t2Color    = _cupTeamColor(
        (group['team2_colour'] as String?) ??
        ((rawSummary as Map?)?['team2_colour'] as String?));

    if (rawSummary == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Group $groupNum',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Singles not yet set up for this group.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
    }

    final summary = rawSummary as Map<String, dynamic>;
    final matches = (summary['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

    // Red always on the left.
    final p1OnLeft   = t1Color.red >= t2Color.red;
    final leftColor  = p1OnLeft ? t1Color : t2Color;
    final rightColor = p1OnLeft ? t2Color : t1Color;

    if (matches.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('No singles matches found.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: matches.asMap().entries.expand<Widget>((entry) {
            final i           = entry.key;
            final m           = entry.value;
            final p1Raw       = m['player1']      as String? ?? '?';
            final p2Raw       = m['player2']      as String? ?? '?';
            final holesPlayed = m['holes_played'] as int?    ?? 0;
            final leftName    = p1OnLeft ? p1Raw : p2Raw;
            final rightName   = p1OnLeft ? p2Raw : p1Raw;
            return [
              if (i > 0) const Divider(height: 22),

              // Header: red player on left, blue player on right
              Row(children: [
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(leftName, textAlign: TextAlign.end,
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: leftColor, fontWeight: FontWeight.bold)),
                )),
                SizedBox(width: 68, child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('vs.', style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant)),
                    if (holesPlayed > 0)
                      Text('thru $holesPlayed',
                          style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                )),
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Text(rightName,
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: rightColor, fontWeight: FontWeight.bold)),
                )),
              ]),
              const Divider(height: 14),

              // Single overall match row
              _allRow(
                m['status']           as String?,
                m['result']           as String?,
                m['overall_holes_up'] as int?,
                m['finished_on_hole'] as int?,
                leftColor, rightColor, theme, p1OnLeft: p1OnLeft,
              ),
            ];
          }).toList(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _QuotaNassauGroupCard — one leaderboard card per cup Quota Nassau foursome
// ---------------------------------------------------------------------------

class _QuotaNassauGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _QuotaNassauGroupCard({required this.group});

  /// Format a quota-margin float: "+2.5", "E", "−1"
  static String _fmt(double v) {
    if (v == 0) return 'E';
    final abs = v.abs().toStringAsFixed(1).replaceAll('.0', '');
    return v > 0 ? '+$abs' : '−$abs';
  }

  /// Format a player's individual vs-quota: "+3", "E", "−2"
  static String _fmtVsQ(double? v) {
    if (v == null) return '—';
    if (v == 0) return 'E';
    final abs = v.abs().toStringAsFixed(1).replaceAll('.0', '');
    return v > 0 ? '+$abs' : '−$abs';
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final groupNum   = group['group_number'] as int? ?? 0;
    final team1Name  = group['team1_name']   as String? ?? '';
    final team2Name  = group['team2_name']   as String? ?? '';
    final t1Color    = _cupTeamColor(group['team1_colour'] as String?);
    final t2Color    = _cupTeamColor(group['team2_colour'] as String?);
    final rawSummary = group['summary'] as Map<String, dynamic>?;

    if (rawSummary == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Group $groupNum',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Quota Nassau not yet set up for this group.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
    }

    final matches = (rawSummary['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

    if (matches.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('No matches.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }

    // ── Build combined TEAM totals across all matches ─────────────────────
    // Team 1 = all player1 entries; Team 2 = all player2 entries.
    int team1Quota18 = 0;
    int team2Quota18 = 0;
    final team1Players = <String>[];
    final team2Players = <String>[];

    // Combined stableford by hole number
    final t1ByHole = <int, int>{};
    final t2ByHole = <int, int>{};

    for (final m in matches) {
      final p1m = (m['player1'] as Map<String, dynamic>? ?? {});
      final p2m = (m['player2'] as Map<String, dynamic>? ?? {});
      team1Quota18 += (p1m['quota'] as int? ?? 0);
      team2Quota18 += (p2m['quota'] as int? ?? 0);
      team1Players.add(p1m['short_name'] as String? ?? '?');
      team2Players.add(p2m['short_name'] as String? ?? '?');

      for (final h in (m['holes'] as List? ?? [])) {
        final hm   = h as Map<String, dynamic>;
        final hole = hm['hole'] as int? ?? 0;
        t1ByHole[hole] = (t1ByHole[hole] ?? 0) + (hm['p1_stableford'] as int? ?? 0);
        t2ByHole[hole] = (t2ByHole[hole] ?? 0) + (hm['p2_stableford'] as int? ?? 0);
      }
    }

    final holesPlayed = t1ByHole.isEmpty ? 0
        : t1ByHole.keys.reduce((a, b) => a > b ? a : b);

    final t1F9  = t1ByHole.entries.where((e) => e.key <= 9)
        .fold(0, (s, e) => s + e.value);
    final t2F9  = t2ByHole.entries.where((e) => e.key <= 9)
        .fold(0, (s, e) => s + e.value);
    final t1All = t1ByHole.values.fold(0, (s, v) => s + v);
    final t2All = t2ByHole.values.fold(0, (s, v) => s + v);
    final t1B9  = t1All - t1F9;
    final t2B9  = t2All - t2F9;

    // Team-level quota split (avoids rounding skew from odd individual quotas)
    final t1F9Quota  = team1Quota18 ~/ 2;
    final t2F9Quota  = team2Quota18 ~/ 2;
    final t1B9Quota  = team1Quota18 - t1F9Quota;
    final t2B9Quota  = team2Quota18 - t2F9Quota;

    // ── Helper: format a resolved Nassau segment result as score badges ───
    Widget? _segBadges(String? result, double pv) {
      if (result == null) return null;
      double t1p = 0, t2p = 0;
      if (result == 'player1')      { t1p = pv; }
      else if (result == 'player2') { t2p = pv; }
      else { t1p = pv / 2; t2p = pv / 2; }
      String fmt(double v) => v % 1 == 0 ? v.toInt().toString() : '½';
      Widget dot(double pts, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.withOpacity(0.12),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: c.withOpacity(0.4)),
        ),
        child: Text(fmt(pts),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: c)),
      );
      return Row(mainAxisSize: MainAxisSize.min, children: [
        dot(t1p, t1Color),
        const SizedBox(width: 4),
        dot(t2p, t2Color),
      ]);
    }

    // Team F9/B9 results: compare combined team stpl vs combined team quota.
    // Per-pair front9.result is player1-vs-player2 within a pairing — that
    // is NOT the same as the team result and must not be aggregated that way.
    String? _teamResult(int t1pts, int t1q, int t2pts, int t2q, bool played) {
      if (!played) return null;
      final d1 = t1pts - t1q, d2 = t2pts - t2q;
      if (d1 > d2) return 'player1';
      if (d2 > d1) return 'player2';
      return 'halved';
    }
    final f9Count   = t1ByHole.keys.where((h) => h <= 9).length;
    final b9Count   = t1ByHole.keys.where((h) => h > 9).length;
    final f9Played  = f9Count >= 9;
    final b9Played  = b9Count >= 9;
    final allPlayed = f9Played && b9Played;
    final f9ResultAgg  = _teamResult(t1F9,  t1F9Quota,  t2F9,  t2F9Quota,  f9Played);
    final b9ResultAgg  = _teamResult(t1B9,  t1B9Quota,  t2B9,  t2B9Quota,  b9Played);
    final allResultAgg = _teamResult(t1All, team1Quota18, t2All, team2Quota18, allPlayed);

    // ── Helper: one score row ─────────────────────────────────────────────
    Widget scoreRow(String label, int t1pts, int t1q, int t2pts, int t2q, int played,
        {Widget? centerBadge}) {
      if (played == 0) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 36,
                child: Text(label, style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurfaceVariant))),
            const Expanded(child: SizedBox()),
            Text('Not started',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic, fontSize: 12)),
            const Expanded(child: SizedBox()),
          ]),
        );
      }

      String vsQ(int pts, int q) {
        final diff = pts - q;
        if (diff == 0) return 'E';
        return diff > 0 ? '+$diff' : '$diff';
      }

      // Layout: [label] [T1 stpl right-aligned] [badges or divider] [T2 stpl left-aligned]
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          // Row label (F9 / B9 / All)
          SizedBox(
            width: 36,
            child: Text(label,
                style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant)),
          ),
          // T1: right-aligned, with right padding before center
          Expanded(child: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$t1pts stpl',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                      color: t1Color)),
              Text('Quota $t1q  (${vsQ(t1pts, t1q)})',
                  style: TextStyle(fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
          )),
          // Center: fixed-width slot so T1/T2 columns never shift
          SizedBox(
            width: 68,
            child: Center(
              child: centerBadge ?? Container(
                  width: 1, height: 32,
                  color: theme.colorScheme.outlineVariant),
            ),
          ),
          // T2: left-aligned, with left padding after center
          Expanded(child: Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$t2pts stpl',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                      color: t2Color)),
              Text('Quota $t2q  (${vsQ(t2pts, t2q)})',
                  style: TextStyle(fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
          )),
        ]),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Header: names centered around "vs." — mirrors the score row layout
          Row(children: [
            Expanded(child: Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Text(
                team1Players.join(' & '),
                textAlign: TextAlign.end,
                style: theme.textTheme.titleSmall?.copyWith(
                    color: t1Color, fontWeight: FontWeight.bold),
              ),
            )),
            SizedBox(
              width: 68,
              child: Center(
                child: Text('vs.',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
            Expanded(child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(
                team2Players.join(' & '),
                style: theme.textTheme.titleSmall?.copyWith(
                    color: t2Color, fontWeight: FontWeight.bold),
              ),
            )),
          ]),

          const Divider(height: 14),

          // Combined quota + pts rows
          Text(
            holesPlayed == 0
                ? 'Not started'
                : '$holesPlayed hole${holesPlayed == 1 ? '' : 's'} played',
            style: TextStyle(fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),

          scoreRow('F9',  t1F9,  t1F9Quota,  t2F9,  t2F9Quota,  f9Count,
              centerBadge: _segBadges(f9ResultAgg, 1.0)),
          scoreRow('B9',  t1B9,  t1B9Quota,  t2B9,  t2B9Quota,  b9Count,
              centerBadge: _segBadges(b9ResultAgg, 1.0)),
          scoreRow('All', t1All, team1Quota18, t2All, team2Quota18, holesPlayed,
              centerBadge: _segBadges(allResultAgg, 1.0)),
        ]),
      ),
    );
  }
}
