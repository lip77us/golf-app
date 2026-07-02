import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../config.dart';
import '../game_catalog.dart';
import '../game_colors.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/icon_help_sheet.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/inline_message.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../utils/watcher_invite.dart';
import '../utils/golf_colors.dart';
import '../widgets/score_mark.dart';
import '../widgets/borrowed_fourth.dart';
import 'match_play_screen.dart' show MatchPlayDetailView;
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
      // First time here: explain the watcher / spectator-link icons.
      maybeShowLeaderboardHelp(context);
    });
  }

  void _initTabs(Leaderboard lb) {
    // For cup rounds, suppress the raw per-foursome game keys that would appear
    // as duplicate tabs — the processed 'cup_singles' tab covers them.
    final _rawSinglesKeys = {'singles_18', 'singles_nassau'};
    // Triple Cup plays 6 holes alt-shot per foursome, so low net is
    // meaningless on these rounds — suppress the Stroke Play tab.
    final isTripleCupRound = lb.activeGames.contains('triple_cup');

    // Tab order, left → right:
    //   1. Tournament TYPE (the headline): Cup, then Championship.
    //   2. The round's own per-round game(s) (side games).
    //   3. "My Foursome" utility tab.
    //   4. Low Net (scores) — ALWAYS rightmost.
    final games = <String>[];

    // 1. Tournament type — leftmost. A single Bandon Cup tab covers cup rounds
    // (IR + Singles) or any nassau cup matches; the championship covers non-cup
    // tournaments (Stableford / Stroke Play). For a cup, the cup leads and the
    // stroke-play championship sits just after it.
    final hasCupNassau = lb.games.containsKey('nassau') &&
        ((lb.games['nassau']!.data as Map<String, dynamic>? ?? {})['by_group']
                as List? ??
            [])
            .any((g) => (g as Map<String, dynamic>)['is_cup_match'] == true);
    if (lb.isCupRound || hasCupNassau) {
      games.add('__bandon_cup__');
    }
    if (lb.tournamentId != null && lb.tournamentActiveGames.isNotEmpty) {
      games.add('__championship__');
    }

    // 2. The round's own games (side games). Low Net is excluded here — it's
    // pinned rightmost below even when it's an active round game.
    games.addAll(lb.activeGames.where((g) =>
        !(lb.isCupRound && _rawSinglesKeys.contains(g)) &&
        g != 'low_net_round'));

    // 3. "My Foursome" — only earns a tab in multi-foursome rounds (tournaments,
    //    multi-group play), where it isolates the viewer's group. In a single-
    //    foursome round it just duplicates the game tab, so require 2+ groups.
    final myPid = context.read<AuthProvider>().player?.id;
    if (myPid != null &&
        _foursomeCount(lb) > 1 &&
        _viewerIsInAnyFoursome(lb, myPid)) {
      games.add('__my_foursome__');
    }

    // 4. Low Net (scores) — ALWAYS rightmost; the backend supplies the block for
    // any individual-ball round (not in active_games). Excluded for Triple Cup.
    if (!isTripleCupRound &&
        lb.games.containsKey('low_net_round') &&
        !games.contains('low_net_round')) {
      games.add('low_net_round');
    }
    // Triple Cup gets two tabs: a prominent cup-score Overview (the "cool
    // screen") followed by the per-match Details card.
    final tcIdx = games.indexOf('triple_cup');
    if (tcIdx >= 0) games.insert(tcIdx, '__triple_cup_overview__');

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

  /// Build the public spectator URL for this round and copy it to the
  /// clipboard.  Strips the `/api` suffix off Config.baseUrl since the
  /// watch page is served from the bare host.
  void _shareWatchLink(BuildContext context, String token) {
    final api  = Config.baseUrl;
    final host = api.endsWith('/api') ? api.substring(0, api.length - 4) : api;
    final url  = '$host/watch/$token/';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Text('Spectator link copied: $url'),
    ));
  }

  /// Open the round's full scorecard (read-only) from the leaderboard, so it's
  /// reachable during AND after the round without going through score entry.
  /// Single-foursome rounds open directly; multi-group rounds ask which group.
  Future<void> _openScorecard() async {
    final nav       = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final rp        = context.read<RoundProvider>();

    var foursomes =
        (rp.round?.id == widget.roundId) ? rp.round!.foursomes : const <Foursome>[];
    if (foursomes.isEmpty) {
      try {
        foursomes = (await context
                .read<AuthProvider>()
                .client
                .getRound(widget.roundId))
            .foursomes;
      } catch (_) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Could not open the scorecard. Try again.')));
        return;
      }
    }
    if (!mounted) return;
    if (foursomes.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('No scorecard available for this round yet.')));
      return;
    }

    final foursomeId = foursomes.length == 1
        ? foursomes.first.id
        : await _pickFoursome(foursomes);
    if (foursomeId == null || !mounted) return;
    nav.pushNamed('/scorecard',
        arguments: {'foursomeId': foursomeId, 'readOnly': true});
  }

  /// Bottom sheet to choose which group's scorecard to open (multi-group rounds).
  Future<int?> _pickFoursome(List<Foursome> foursomes) {
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text("Which group's scorecard?",
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
          ),
          for (final fs in foursomes)
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text('Group ${fs.groupNumber}'),
              subtitle: Text(
                fs.memberships
                    .where((m) => !m.player.isPhantom)
                    .map((m) => m.player.shortName)
                    .join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(ctx).pop(fs.id),
            ),
        ]),
      ),
    );
  }

  /// The leaderboard's secondary actions, folded behind a more_vert menu so the
  /// header stays uncluttered on a narrow phone (the spectator link used to get
  /// pushed off the edge once the chat icon was added).
  Widget _buildOverflowMenu(
    BuildContext context,
    RoundProvider rp, {
    required String? watchToken,
    required bool isFinal,
  }) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'refresh':
            context.read<RoundProvider>().loadLeaderboard(widget.roundId);
            break;
          case 'invite':
            inviteWatcher(context, roundId: widget.roundId);
            break;
          case 'share':
            if (watchToken != null) _shareWatchLink(context, watchToken);
            break;
          case 'help':
            showLeaderboardHelp(context);
            break;
          case 'reopen':
            if (!rp.submitting) _confirmReopen(context);
            break;
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'refresh',
          child: ListTile(
            leading: Icon(Icons.refresh),
            title: Text('Refresh'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'invite',
          child: ListTile(
            leading: Icon(Icons.visibility_outlined),
            title: Text('Invite a watcher'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (watchToken != null)
          const PopupMenuItem(
            value: 'share',
            child: ListTile(
              leading: Icon(Icons.share_outlined),
              title: Text('Share spectator link'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        const PopupMenuItem(
          value: 'help',
          child: ListTile(
            leading: Icon(Icons.help_outline),
            title: Text('What do these buttons do?'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (isFinal)
          const PopupMenuItem(
            value: 'reopen',
            child: ListTile(
              leading: Icon(Icons.lock_open_outlined),
              title: Text('Reopen round'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
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

    final watchToken = rp.round?.watchToken;
    final courseName = rp.round?.course.name;

    // Cross-account support read: this round belongs to a different account and
    // the viewer is support staff. Flag it so it's clear it's a read-only copy.
    final auth = context.watch<AuthProvider>();
    final isSupportView = auth.isSupport &&
        lb?.accountId != null &&
        lb!.accountId != auth.account?.id;

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Leaderboard',
        // Keep the header to a few direct icons + an overflow menu so it never
        // crowds out the spectator link on a narrow phone (GolfAppBar guidance:
        // 0–2 actions, fold the rest behind more_vert).
        actions: [
          // Round chat / event feed. Hidden in a support view (read-only).
          if (!isSupportView)
            RoundChatButton(roundId: widget.roundId, title: courseName),
          // Full scorecard — always reachable here, during AND after the round
          // (previously only inside the score-entry screen).
          IconButton(
            tooltip: 'Scorecard',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: _openScorecard,
          ),
          // Refresh is a fallback (the leaderboard reloads on entry), so it
          // folds into the ⋯ overflow — keeping the toolbar to the 0–2 actions
          // above.  The support view hides ⋯, so keep refresh inline there.
          if (isSupportView)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  context.read<RoundProvider>().loadLeaderboard(widget.roundId),
            ),
          if (!isSupportView)
            _buildOverflowMenu(context, rp,
                watchToken: watchToken, isFinal: isFinal),
        ],
        bottom: (_tabController != null && _gameTabs.isNotEmpty)
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: _gameTabs
                    .map((g) => Tab(text: _label(g, lb)))
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
      body: isSupportView
          ? Column(children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.amber.shade700,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.visibility_outlined,
                      size: 16, color: Colors.black87),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Support · read-only — '
                      '${lb.accountName ?? 'another account'} · round #${lb.roundId}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5),
                    ),
                  ),
                ]),
              ),
              Expanded(child: _buildBody(context, rp)),
            ])
          : _buildBody(context, rp),
    );
  }

  Widget _buildBody(BuildContext context, RoundProvider rp) {
    if (rp.loadingLeaderboard) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.leaderboard == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InlineMessage(kind: InlineMessageKind.error, text: rp.error!),
          const SizedBox(height: 8),
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
                // The championship is cumulative across ALL rounds — never
                // scope it to the current round (passing roundId triggers the
                // single-round backend branch that reports "1/1 rounds" and
                // hides earlier rounds). Matches the tournament-level view.
                return ChampionshipTabView(
                  tournamentId: lb.tournamentId!,
                  roundId: null,
                );
              }
              if (gameKey == '__bandon_cup__') {
                return _BandonCupTabView(
                  roundId       : widget.roundId,
                  tournamentId  : lb.tournamentId,
                  tournamentName: lb.cupName ?? lb.tournamentName ?? 'Cup',
                );
              }
              if (gameKey == '__my_foursome__') {
                final myPid = context.read<AuthProvider>().player?.id;
                return RefreshIndicator(
                  onRefresh: () => rp.loadLeaderboard(widget.roundId),
                  child: _MyFoursomeTabView(leaderboard: lb, playerId: myPid),
                );
              }
              // Irish Rumble in cup context: show live card + per-foursome
              // scorecards.  Tournament alone isn't enough — a casual side
              // game running inside a non-cup tournament (e.g. low-net
              // championship + IR + red ball) won't have a cup config, and
              // _IrishRumbleTabView's cup-live API call would 404.  Gate on
              // isCupRound so non-cup IR falls through to _GameView.
              if (gameKey == 'irish_rumble'
                  && lb.isCupRound
                  && lb.tournamentId != null) {
                return _IrishRumbleTabView(
                  roundId:      widget.roundId,
                  tournamentId: lb.tournamentId!,
                );
              }
              if (gameKey == '__triple_cup_overview__') {
                final game = lb.games['triple_cup'];
                if (game == null) {
                  return const Center(child: Text('No data yet.'));
                }
                return RefreshIndicator(
                  onRefresh: () => rp.loadLeaderboard(widget.roundId),
                  child: _TripleCupOverviewView(
                      data: game.data as Map<String, dynamic>),
                );
              }
              final game = lb.games[gameKey];
              if (game == null) {
                return const Center(child: Text('No data yet.'));
              }
              return RefreshIndicator(
                onRefresh: () => rp.loadLeaderboard(widget.roundId),
                child: _GameView(
                  gameKey: gameKey,
                  game: game,
                  // Score-entry (membership) order, when the round is loaded.
                  playerOrder: (rp.round?.id == widget.roundId)
                      ? [
                          for (final fs in rp.round!.foursomes)
                            for (final m in fs.realPlayers) m.player.id,
                        ]
                      : const <int>[],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  String _label(String g, [Leaderboard? lb]) {
    // Cup tab title tracks the cup competition's display name — falls
    // back to a generic "Cup" only when no cup name is set on the
    // TeamTournament row (e.g. older data or non-cup contexts).
    if (g == '__bandon_cup__') {
      return lb?.cupName ?? 'Cup';
    }
    if (g == '__my_foursome__') return 'My Foursome';
    // Triple Cup is split into an Overview (cup score) + Details (matches).
    if (g == '__triple_cup_overview__') return 'Overview';
    if (g == 'triple_cup') return 'Details';
    // A heads-up, Overall-only Nassau is a Singles Match — label it as such.
    // (2-v-2 Overall-only is Fourball, not a Singles Match, so require one
    // player per side.)
    if (g == 'nassau') {
      final groups =
          ((lb?.games['nassau']?.data as Map?)?['by_group'] as List?) ?? const [];
      final s = groups.isNotEmpty
          ? ((groups.first as Map?)?['summary'] as Map?)
          : null;
      final teams = s?['teams'] as Map?;
      final headsUp = (teams?['team1'] as List?)?.length == 1 &&
          (teams?['team2'] as List?)?.length == 1;
      if (s != null &&
          s['play_front'] == false &&
          s['play_back'] == false &&
          s['play_overall'] != false &&
          headsUp) {
        return 'Singles Match';
      }
    }
    if (g == '__championship__') {
      // Reflect the tournament's actual championship rather than a hardcoded
      // "Low Net" — a Stableford Championship round should read "Stableford".
      final ta = lb?.tournamentActiveGames ?? const <String>[];
      if (ta.contains('stableford_championship')) return 'Stableford';
      if (ta.contains('match_play') && !ta.contains('low_net')) return 'Mini Singles Bracket';
      // Title the Stroke Play championship with the tournament's name so it's
      // distinct from a per-round "Stroke Play" side game. Guard against the
      // cup case where the tournament name already appears as the cup tab.
      final tn = lb?.tournamentName;
      final cn = lb?.cupName;
      if (tn != null && tn.isNotEmpty && tn != cn) return tn;
      return 'Stroke Play';
    }
    // Pink Ball tab tracks the configured ball colour (e.g. "Red Ball").
    if (g == 'pink_ball') {
      final color =
          ((lb?.games['pink_ball']?.data as Map?)?['ball_color'])?.toString();
      return (color != null && color.isNotEmpty) ? '$color Ball' : 'Pink Ball';
    }
    return gameDisplayName(g);
  }

  /// True iff *playerId* shows up on any foursome in any active
  /// per-foursome game on this leaderboard.  Drives whether the
  /// "My Foursome" tab is shown.  Currently scans `triple_cup`,
  /// `nassau`, `quota_nassau`, `skins`, `sixes` — every per-group
  /// game uses a `by_group` shape with player IDs accessible
  /// somewhere on each group entry.
  /// Number of distinct foursomes/groups in the round, read from any
  /// per-foursome game's `by_group` list. 1 (or 0) for a single-foursome
  /// casual round; N for a tournament or multi-group round.
  int _foursomeCount(Leaderboard lb) {
    final groups = <Object>{};
    for (final g in lb.games.values) {
      final list = ((g.data as Map?)?['by_group'] as List? ?? const []);
      for (final grp in list) {
        if (grp is Map) {
          groups.add((grp['group_number'] ?? grp['foursome_id'] ?? grp.hashCode)
              as Object);
        }
      }
    }
    return groups.length;
  }

  bool _viewerIsInAnyFoursome(Leaderboard lb, int playerId) {
    for (final key in const ['triple_cup', 'nassau', 'quota_nassau',
                              'skins', 'sixes']) {
      final g = lb.games[key];
      if (g == null) continue;
      final groups = ((g.data as Map?)?['by_group'] as List? ?? []);
      for (final grp in groups) {
        if (_groupContainsPlayer(grp as Map, playerId)) return true;
      }
    }
    return false;
  }
}

/// Recursive-ish helper: returns true when [group] (a `by_group`
/// entry from any per-foursome game summary) contains [playerId]
/// somewhere reachable (top-level players list, nested matches'
/// players, etc.).
bool _groupContainsPlayer(Map group, int playerId) {
  final summary = (group['summary'] as Map?) ?? group;
  // Most TC / Nassau / Quota summaries expose either a flat
  // `players` list or per-match `players`.
  final flat = (summary['players'] as List? ?? []);
  for (final p in flat) {
    if (p is Map && p['player_id'] == playerId) return true;
  }
  final matches = (summary['matches'] as List? ?? []);
  for (final m in matches) {
    if (m is! Map) continue;
    for (final p in (m['players'] as List? ?? [])) {
      if (p is Map && p['player_id'] == playerId) return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Game-specific views
// ---------------------------------------------------------------------------

class _GameView extends StatelessWidget {
  final String gameKey;
  final LeaderboardGame game;
  // Player ids in score-entry (foursome membership) order; used to order the
  // Low Net rows the same way as the score screen.  Empty = keep net-rank order.
  final List<int> playerOrder;

  const _GameView(
      {required this.gameKey, required this.game, this.playerOrder = const []});

  @override
  Widget build(BuildContext context) {
    final data = game.data as Map<String, dynamic>;

    switch (gameKey) {
      case 'stableford':
        return _StablefordView(data: data);
      case 'pink_ball':
        return _RedBallView(data: data);
      case 'low_net_round':
        return _LowNetView(data: data, playerOrder: playerOrder);
      case 'skins':
        return _ByGroupView(data: data, builder: _SkinsGroupCard.new);
      case 'spots':
        return _ByGroupView(data: data, builder: _SpotsGroupCard.new);
      case 'triple_cup':
        return _ByGroupView(data: data, builder: _TripleCupGroupCard.new);
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
      case 'vegas':
        return _ByGroupView(data: data, builder: _VegasGroupCard.new);
      case 'fourball':
        return _ByGroupView(data: data, builder: _FourballGroupCard.new);
      case 'wolf':
        return _ByGroupView(data: data, builder: _WolfGroupCard.new);
      case 'rabbit':
        return _ByGroupView(data: data, builder: _RabbitGroupCard.new);
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
      case 'match_play':
        // Single-elimination bracket per foursome (4-player groups).
        // Without this case the tab fell through to _RawJsonView and
        // dumped the API payload as plain text.
        return _ByGroupView(data: data, builder: _MatchPlayGroupCard.new);
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

  Widget _chip(String label) => Chip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      );

  String _num(num v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final results = (data['results'] as List? ?? []);
    final style   = data['payout_style']?.toString() ?? 'pool';
    final hmode   = data['handicap_mode']?.toString() ?? 'net';
    final netPct  = data['net_percent'] as int? ?? 100;
    final table   = data['table'] as Map<String, dynamic>?;
    final entry   = (data['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final rate    = (data['per_point_rate'] as num?)?.toDouble() ?? 0.0;
    final ppMode  = data['per_point_mode']?.toString() ?? 'average';
    final lossCap = (data['loss_cap'] as num?)?.toDouble();
    final modeLabel = switch (ppMode) {
      'first' => 'Just first',
      'all'   => 'Everyone above',
      _       => 'vs Average',
    };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          _chip(hmode == 'gross' ? 'Gross' : 'Net $netPct%'),
          if (style == 'pool' && entry > 0)
            _chip('Pool \$${_num(entry)}/player'),
          if (style == 'per_point')
            _chip('\$${_num(rate)}/pt · $modeLabel'),
          if (style == 'per_point' && lossCap != null)
            _chip('Cap \$${_num(lossCap)}/player'),
        ]),
        if (table != null) ...[
          const SizedBox(height: 8),
          Text(
            'Alb ${table['albatross']} · Eag ${table['eagle']} · '
            'Bird ${table['birdie']} · Par ${table['par']} · '
            'Bog ${table['bogey']} · Dbl ${table['double']}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        // Per-hole points detail — mirrors the "Stableford points" grid on the
        // score-entry screen so the side-game leaderboard isn't too sparse.
        if (results.isNotEmpty) ...[
          _StablefordPointsGrid(results: results),
          const SizedBox(height: 12),
        ],
        ...results.map((e) {
          final r        = e as Map<String, dynamic>;
          final pts      = r['total_points'] as int? ?? 0;
          final payout   = (r['payout'] as num?)?.toDouble();
          final excluded = r['excluded'] as bool? ?? false;
          final hp       = r['holes_played'] as int? ?? 0;
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              leading: CircleAvatar(
                  radius: 16, child: Text('${r['rank'] ?? ''}')),
              title: Text(r['player_name']?.toString() ?? '—'),
              subtitle: Text(
                excluded ? 'Not eligible for prizes'
                    : (hp > 0 ? 'Thru $hp' : 'Not started'),
                style: theme.textTheme.bodySmall,
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('$pts pts',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  if (payout != null && payout != 0)
                    Text(
                      payout >= 0 ? '+\$${_num(payout)}' : '−\$${_num(-payout)}',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600,
                          color: payout >= 0
                              ? Colors.green.shade700
                              : theme.colorScheme.error),
                    ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

/// Per-hole Stableford points grid for the leaderboard — Hole / per-player
/// points / running Total. Mirrors the score-entry "Stableford points" section
/// (without the Par row / current-hole highlight, which need the live
/// scorecard). Driven purely by the summary's `results` (each carries a
/// `holes:{hole:pts}` map + `total_points`).
class _StablefordPointsGrid extends StatelessWidget {
  final List results;
  const _StablefordPointsGrid({required this.results});

  static const double _labelColW = 64.0;
  static const double _cellW     = 28.0;
  static const double _rowH      = 26.0;
  static const double _totW      = 36.0;

  String _short(String full) {
    final first = full.trim().isEmpty ? '—' : full.trim().split(' ').first;
    return first.length > 8 ? first.substring(0, 8) : first;
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final holeRange = List.generate(18, (i) => i + 1);

    Widget cell(Widget child, double w) =>
        SizedBox(width: w, height: _rowH, child: Center(child: child));
    Widget labelCell(String s, {bool bold = false, bool italic = false}) =>
        SizedBox(
          width: _labelColW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(s,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                    fontStyle: italic ? FontStyle.italic : FontStyle.normal)),
          ),
        );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Stableford points',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Hole numbers + Total
              Row(children: [
                labelCell('Hole', bold: true),
                for (final h in holeRange)
                  cell(Text('$h',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)), _cellW),
                cell(const Text('Tot',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    _totW),
              ]),
              Container(
                height: 1,
                width: _labelColW + _cellW * holeRange.length + _totW,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(vertical: 2),
              ),
              // Per-player points rows
              for (final e in results)
                () {
                  final r     = e as Map<String, dynamic>;
                  final holes = (r['holes'] as Map?)?.cast<String, dynamic>()
                      ?? const {};
                  final total = r['total_points'] ?? 0;
                  return Row(children: [
                    labelCell(_short(r['player_name']?.toString() ?? '—')),
                    for (final h in holeRange)
                      cell(Text(holes['$h'] == null ? '' : '${holes['$h']}',
                          style: theme.textTheme.bodySmall), _cellW),
                    cell(Text('$total',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                        _totW),
                  ]);
                }(),
            ]),
          ),
        ]),
      ),
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
        // Info chips — wrap so they never overflow the row.
        Wrap(spacing: 8, runSpacing: 4, children: [
          Chip(
            label: Text('$ballColor Ball',
                style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          if (entryFee > 0)
            Chip(
              label: Text('Entry \$${entryFee.formatBet()}',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          if (payouts.isNotEmpty)
            Chip(
              label: Text(
                  payouts.length == 1 ? 'Winner takes all' : '${payouts.length} places paid',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
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
          final lostBy          = row['lost_by'] as String?;

          // Subtitle:
          //   "Not started"          — no holes played yet
          //   "Alive Thru 7"         — ball still in play, round not done
          //   "Survived"             — all 18 holes completed
          //   "Lost by RyanL (hole 8)" — ball was lost; carrier named when known
          final notStarted = currentHole == null || currentHole == 0;
          final activelyAlive = survived && !notStarted;
          final String subtitle;
          final Color  subtitleColor;
          if (!survived && eliminatedOn != null) {
            subtitle      = lostBy != null
                ? 'Lost by $lostBy (hole $eliminatedOn)'
                : 'Lost on Hole $eliminatedOn';
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
                        // Golf convention: under par red, even/over black.
                        color: toParColor(netToPar) ?? theme.colorScheme.onSurface,
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
  final List<int> playerOrder;
  const _LowNetView({required this.data, this.playerOrder = const []});

  @override
  State<_LowNetView> createState() => _LowNetViewState();
}

class _LowNetViewState extends State<_LowNetView> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Auto-scroll to the right so the latest holes (current play) are visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static String _ntpLabel(int? ntp) {
    if (ntp == null) return '—';
    if (ntp == 0)   return 'E';
    return ntp < 0 ? '$ntp' : '+$ntp';
  }

  // Score colours (under par = red, par/over = default) live in
  // utils/golf_colors.dart — scoreColor() / toParColor() — so the convention is
  // shared and changed in one place.

  /// One hole cell: GROSS score with handicap-stroke dots in the corner —
  /// mirrors the score-entry stroke-play grid so the user reads the raw score
  /// and the strokes and can figure the net.  The number is COLOURED by net vs
  /// par (under = green, over = red) — the part not shown on the score screen.
  static Widget _scoreCell(
      ThemeData theme, Map h, bool showNet, TextStyle cellStyle) {
    final gross    = h['gross'] as int?;
    final par      = h['par'] as int?;
    // Gross digit coloured by NET (or gross) vs par, with circle/square
    // scorecard notation.  No stroke dots — the shape carries the result.
    final colourBy = showNet ? ((h['capped'] ?? h['net']) as int?) : gross;
    return scoreMark(
      text: gross == null ? '–' : '$gross',
      diff: (colourBy != null && par != null) ? colourBy - par : null,
      baseStyle: cellStyle.copyWith(fontWeight: FontWeight.w600),
      theme: theme,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final results = [...(widget.data['results'] as List? ?? [])];
    // Order rows like the score-entry screen (foursome membership order) when
    // we know it; otherwise keep the server's net-rank order.  Players not in
    // the order list fall to the end, stably.
    final order = widget.playerOrder;
    if (order.isNotEmpty) {
      int idx(dynamic r) {
        final pid = (r as Map)['player_id'] as int?;
        final i = pid == null ? -1 : order.indexOf(pid);
        return i < 0 ? 1 << 30 : i;
      }
      results.sort((a, b) => idx(a).compareTo(idx(b)));
    }
    final entryFee= (widget.data['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final payouts = (widget.data['payouts'] as List? ?? []);
    final hmode   = widget.data['handicap_mode']?.toString() ?? 'net';
    final npct    = widget.data['net_percent'] as int? ?? 100;
    final showNet = hmode != 'gross';

    final modeLabel = hmode == 'gross' ? 'Gross'
        : hmode == 'strokes_off' ? 'Strokes Off'
        : npct == 100 ? 'Full Net'
        : 'Net $npct%';

    final chips = Wrap(spacing: 8, runSpacing: 4, children: [
      Chip(
        label: Text(modeLabel, style: const TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
      if (entryFee > 0)
        Chip(
          label: Text('Entry \$${entryFee.formatBet()}',
              style: const TextStyle(fontSize: 11)),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
        ),
      if (payouts.isNotEmpty)
        Chip(
          label: Text(
              payouts.length == 1
                  ? 'Winner takes all'
                  : '${payouts.length} places paid',
              style: const TextStyle(fontSize: 11)),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
        ),
    ]);

    if (results.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        chips,
        const SizedBox(height: 24),
        const Center(child: Text('No scores yet.')),
      ]);
    }

    // Par per hole — union across players so any hole anyone played gets a column.
    final parByHole = <int, int>{};
    for (final r in results) {
      for (final h in ((r as Map)['holes'] as List? ?? [])) {
        final m = h as Map;
        final n = m['hole'] as int?;
        final p = m['par'] as int?;
        if (n != null && p != null) parByHole[n] = p;
      }
    }
    final holeNums = parByHole.keys.toList()..sort();

    // No per-hole data yet → simple standings list.
    if (holeNums.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        chips,
        const SizedBox(height: 8),
        ...results.map((r) => _standingsRow(theme, r as Map<String, dynamic>)),
      ]);
    }

    // ── One row per player; holes are columns (scroll horizontally). The
    //    player column (rank/name/total) stays pinned so you can scan a hole
    //    across everyone at once. ──
    const double nameW = 132, holeW = 30, headH = 22, parH = 20, rowH = 38;
    final headerStyle = theme.textTheme.labelSmall!.copyWith(
        fontWeight: FontWeight.bold, color: theme.colorScheme.onSurfaceVariant);
    final parStyle = theme.textTheme.labelSmall!
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    const cellStyle = TextStyle(fontSize: 12);
    final divider = BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5);
    // Dark line under the Par row, separating the header from the data.
    final headSep = BorderSide(color: theme.colorScheme.outline, width: 1.4);

    Widget box(double w, double h, Widget child,
        {Alignment align = Alignment.center,
        EdgeInsets? pad,
        bool border = false,
        BorderSide? bottomSide}) {
      final side = bottomSide ?? (border ? divider : null);
      return Container(
        width: w, height: h, alignment: align, padding: pad,
        decoration:
            side != null ? BoxDecoration(border: Border(bottom: side)) : null,
        child: child,
      );
    }

    // Pinned left column: header, par label, then rank + name (+ payout) + total.
    final frozen = <Widget>[
      box(nameW, headH, Text('Hole', style: headerStyle),
          align: Alignment.centerLeft, pad: const EdgeInsets.only(left: 4)),
      box(nameW, parH, Text('Par', style: parStyle),
          align: Alignment.centerLeft, pad: const EdgeInsets.only(left: 4),
          bottomSide: headSep),
      for (final r in results)
        () {
          final row = r as Map<String, dynamic>;
          final rank = row['rank'] as int? ?? 0;
          final name = row['name']?.toString() ?? '—';
          final ntp = row['net_to_par'] as int?;
          final payout = (row['payout'] as num?)?.toDouble();
          return box(nameW, rowH,
            Row(children: [
              SizedBox(
                  width: 16,
                  child: Text('$rank',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold))),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    if (payout != null)
                      Text('\$${payout.formatBet()}',
                          style: TextStyle(
                              fontSize: 9, color: Colors.green.shade700)),
                  ],
                ),
              ),
              Text(_ntpLabel(ntp),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: toParColor(ntp))),
              // Match the gap on the other side of the divider (margin: 6) so
              // the net score isn't tight against the border line.
              const SizedBox(width: 6),
            ]),
            align: Alignment.centerLeft, border: true);
        }(),
    ];

    // Totals: gross Out (1-9) appears once hole 9 is reached; In, Gross (total)
    // and Net appear once hole 18 is reached.
    const double totW = 36;
    final frontHoles = holeNums.where((n) => n <= 9).toList();
    final backHoles  = holeNums.where((n) => n > 9).toList();
    final showOut = holeNums.contains(9);
    final showEnd = holeNums.contains(18);
    final outPar = frontHoles.fold<int>(0, (s, n) => s + (parByHole[n] ?? 0));
    final inPar  = backHoles.fold<int>(0, (s, n) => s + (parByHole[n] ?? 0));
    final totalPar = outPar + inPar;

    // Scrollable columns, in scorecard order: front holes, Out (after 9), back
    // holes, then In / Gross / Net (after 18).  Par row has a dark line under it.
    final headerRow = Row(children: [
      for (final n in frontHoles) box(holeW, headH, Text('$n', style: headerStyle)),
      if (showOut) box(totW, headH, Text('Out', style: headerStyle)),
      for (final n in backHoles) box(holeW, headH, Text('$n', style: headerStyle)),
      if (showEnd) ...[
        box(totW, headH, Text('In', style: headerStyle)),
        box(totW, headH, Text('Gross', style: headerStyle)),
        box(totW, headH, Text('Net', style: headerStyle)),
      ],
    ]);
    final parRow = Row(children: [
      for (final n in frontHoles)
        box(holeW, parH, Text('${parByHole[n]}', style: parStyle),
            bottomSide: headSep),
      if (showOut)
        box(totW, parH, Text('$outPar', style: parStyle), bottomSide: headSep),
      for (final n in backHoles)
        box(holeW, parH, Text('${parByHole[n]}', style: parStyle),
            bottomSide: headSep),
      if (showEnd) ...[
        box(totW, parH, Text('$inPar', style: parStyle), bottomSide: headSep),
        box(totW, parH, Text('$totalPar', style: parStyle), bottomSide: headSep),
        box(totW, parH, const SizedBox(), bottomSide: headSep),
      ],
    ]);
    final playerRows = <Widget>[
      for (final r in results)
        () {
          final row = r as Map<String, dynamic>;
          final hm = <int, Map>{};
          for (final h in (row['holes'] as List? ?? [])) {
            final m = h as Map;
            final n = m['hole'] as int?;
            if (n != null) hm[n] = m;
          }
          int grossSum(List<int> hs) => hs.fold<int>(
              0, (s, n) => s + ((hm[n]?['gross'] as int?) ?? 0));
          final netTotal = row['total_net'] as int?;
          final ntp = row['net_to_par'] as int?;
          Widget holeCell(int n) => box(holeW, rowH,
              hm[n] == null
                  ? Text('–',
                      style: cellStyle.copyWith(
                          color: theme.colorScheme.onSurfaceVariant))
                  : _scoreCell(theme, hm[n]!, showNet, cellStyle),
              border: true);
          Widget totCell(String text, {bool bold = false, Color? color}) =>
              box(totW, rowH,
                  Text(text,
                      style: cellStyle.copyWith(
                          fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                          color: color)),
                  border: true);
          return Row(children: [
            for (final n in frontHoles) holeCell(n),
            if (showOut) totCell('${grossSum(frontHoles)}'),
            for (final n in backHoles) holeCell(n),
            if (showEnd) ...[
              totCell('${grossSum(backHoles)}'),
              totCell('${grossSum(holeNums)}'),
              totCell('${netTotal ?? ''}',
                  bold: true, color: toParColor(ntp)),
            ],
          ]);
        }(),
    ];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        chips,
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pinned net-score column, with a stronger divider before the holes.
            Container(
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: theme.colorScheme.outline, width: 2),
                ),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: frozen),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [headerRow, parRow, ...playerRows],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          showNet
              ? 'Gross per hole. Red/circle = under net par; square = over.'
              : 'Gross per hole. Red/circle = under par; square = over.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _standingsRow(ThemeData theme, Map<String, dynamic> row) {
    final rank = row['rank'] as int? ?? 0;
    final name = row['name']?.toString() ?? '—';
    final ntp = row['net_to_par'] as int?;
    final payout = (row['payout'] as num?)?.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(
            width: 24,
            child: Text('$rank',
                style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(child: Text(name)),
        if (payout != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text('\$${payout.formatBet()}',
                style: TextStyle(color: Colors.green.shade700)),
          ),
        Text(_ntpLabel(ntp),
            style: TextStyle(
                fontWeight: FontWeight.bold, color: toParColor(ntp))),
      ]),
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
    final variant      = data['variant']?.toString() ?? 'classic';

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
        // Info chips — wrap so they never overflow the row.
        Wrap(spacing: 8, runSpacing: 4, children: [
          Chip(
            label: Text(modeLabel, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          // Variant label — the per-hole balls-to-count varies under
          // every variant other than Classic (and even Classic varies
          // by segment), so a single "Best N count" pill would lie.
          // Show the variant name instead; the score-entry screen
          // already surfaces "Best N count this hole" per hole.
          Chip(
            label: Text(
              switch (variant) {
                'arizona_shuffle' => 'Arizona Shuffle',
                'shuffle'         => 'Shuffle (par-based)',
                'custom'          => 'Custom',
                _                 => 'Classic',
              },
              style: const TextStyle(fontSize: 11),
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          if (entryFee > 0)
            Chip(
              label: Text('Entry \$${entryFee.formatBet()}',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          if (payouts.isNotEmpty)
            Chip(
              label: Text(
                  payouts.length == 1 ? 'Winner takes all' : '${payouts.length} places paid',
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
        ]),
        const SizedBox(height: 8),

        // Borrowed-4th explainer — shown once when any group is a leveled
        // threesome carrying a whole-field donor rotation (docs/irish-rumble.md).
        if (overall.any((r) => borrowedFourthFromJson((r as Map)['phantom']) != null)) ...[
          const BorrowedFourthNote(),
          const SizedBox(height: 8),
        ],

        ...overall.map((r) {
          final row             = r as Map<String, dynamic>;
          final rank            = row['rank'] as int?;
          final hasPhantom      = row['has_phantom'] as bool? ?? false;
          final phantomInfo     = borrowedFourthFromJson(row['phantom']);
          final playersRaw      = row['players']?.toString() ?? '';
          // "Borrowed 4th" only for a cross-foursome (whole-field) phantom; a
          // legacy intra-foursome tournament phantom keeps the generic label.
          final players         = phantomInfo != null
              ? '$playersRaw + Borrowed 4th'
              : hasPhantom ? '$playersRaw + Phantom' : playersRaw;
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
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
                          // Golf convention: under par red, even/over default.
                          color: toParColor(ntp),
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
                // Borrowed-4th: anonymous pending count only — the donor
                // identities are deliberately NOT shown on the public
                // leaderboard (only the threesome's own scorer sees them).
                if (phantomInfo != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    child: Builder(builder: (_) {
                      final pending = pendingDonorHoles(phantomInfo);
                      return Text(
                        pending > 0
                            ? 'Borrowed 4th · $pending hole'
                                '${pending == 1 ? '' : 's'} pending'
                            : 'Borrowed 4th · all holes in',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    }),
                  ),
              ],
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
    // Golf convention: under par red, even/over default.
    final totalColor = toParColor(totalVal);

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
                                : ntp < 0 ? underParColor
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

    final pool       = (money['pool']        as num?)?.toDouble() ?? 0.0;
    final totalSkins = (money['total_skins'] as num?)?.toInt()    ?? 0;
    final mode       = hcap['mode']        as String? ?? 'net';
    final netPct     = hcap['net_percent'] as int?    ?? 100;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // ── Compact standings card — matches the per-game block at the
        // bottom of the score-entry screen so the user sees the same
        // pool/Thru/Skins/Payout summary in both places. ─────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.attach_money, size: 18),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Multi-Group Skins — '
                      '\$${pool.toStringAsFixed(2)} pool, '
                      '$totalSkins skin(s) won',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    'Mode: ${mode.toUpperCase()}'
                    '${mode == "net" && netPct != 100 ? " ($netPct%)" : ""}',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ]),
                const SizedBox(height: 4),
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(),
                    1: FixedColumnWidth(36),
                    2: FixedColumnWidth(40),
                    3: FixedColumnWidth(56),
                  },
                  children: [
                    TableRow(children: [
                      Text('Player',
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold)),
                      Text('Thru', textAlign: TextAlign.right,
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold)),
                      Text('Skins', textAlign: TextAlign.right,
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold)),
                      Text('Payout', textAlign: TextAlign.right,
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold)),
                    ]),
                    for (final p in players)
                      TableRow(children: [
                        Text(
                          (p['short_name'] as String?)?.isNotEmpty == true
                              ? p['short_name'] as String
                              : (p['name'] as String? ?? ''),
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          (p['thru'] as int? ?? 0) == 0
                              ? '—' : '${p['thru']}',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall,
                        ),
                        Text('${p['skins_won'] ?? 0}',
                            textAlign: TextAlign.right,
                            style: theme.textTheme.bodySmall),
                        Text(
                          '\$${((p['payout'] as num?)?.toDouble() ?? 0.0)
                              .toStringAsFixed(2)}',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall,
                        ),
                      ]),
                  ],
                ),
              ],
            ),
          ),
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

  /// When true, a second block of per-player rows shows each hole's points
  /// (read from each score entry's `points`) below the gross rows.
  final bool showPoints;

  /// Legend text shown beside the "Scorecard" heading. Null hides it (used by
  /// games with no skin-winner highlight, e.g. Sixes / Wolf).
  final String? legend;

  const _MsScorecard({
    required this.holes,
    required this.participants,
    this.showPoints = false,
    this.legend = 'green = skin winner',
  });

  @override
  State<_MsScorecard> createState() => _MsScorecardState();
}

class _MsScorecardState extends State<_MsScorecard> {
  static const double _labelColW = 78.0;
  static const double _cellW     = 32.0;
  static const double _rowH      = 26.0;

  final ScrollController _ctrl = ScrollController();

  // Last hole that actually has scores — so the auto-scroll lands on the
  // latest *played* hole, not the highest hole present in the data (Wolf
  // lists all 18 up front, including unplayed ones).
  int get _lastScoredHole => widget.holes
      .where((h) => ((h['scores'] as List?) ?? const []).isNotEmpty)
      .map((h) => (h['hole'] as int?) ?? 0)
      .fold(0, (a, b) => a > b ? a : b);

  @override
  void initState() {
    super.initState();
    _scheduleScroll();
  }

  @override
  void didUpdateWidget(covariant _MsScorecard old) {
    super.didUpdateWidget(old);
    _scheduleScroll();
  }

  // Scroll so the latest scored hole is visible (~7 columns from the left), so
  // the most recent activity shows without scrolling right.
  void _scheduleScroll() {
    final hole = _lastScoredHole;
    if (hole == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      final target = (_labelColW + (hole - 7) * _cellW)
          .clamp(0.0, _ctrl.position.maxScrollExtent);
      _ctrl.animateTo(target,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

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

    Widget pointsCell(int playerId, int h) {
      final entry = holeMap[h];
      if (entry == null) return SizedBox(width: _cellW, height: _rowH);
      final scores =
          (entry['scores'] as List? ?? []).cast<Map<String, dynamic>>();
      final mine = scores.firstWhere(
        (s) => s['player_id'] == playerId,
        orElse: () => const {},
      );
      if (mine.isEmpty || mine['points'] == null) {
        return SizedBox(width: _cellW, height: _rowH);
      }
      final pts = (mine['points'] as num).toDouble();
      final color = pts > 0
          ? Colors.green.shade700
          : pts < 0
              ? Colors.red.shade700
              : theme.colorScheme.onSurfaceVariant;
      final txt = pts == 0
          ? '·'
          : '${pts > 0 ? '+' : '−'}${pts.abs() == pts.abs().roundToDouble() ? pts.abs().toStringAsFixed(0) : pts.abs().toStringAsFixed(1)}';
      return SizedBox(
        width: _cellW, height: _rowH,
        child: Center(
          child: Text(txt,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ),
      );
    }

    Widget participantLabel(Map<String, dynamic> p, {String? suffix}) => SizedBox(
          width: _labelColW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              ((p['short_name'] as String?)?.isNotEmpty == true
                      ? p['short_name'] as String
                      : (p['name'] as String? ?? '')) +
                  (suffix ?? ''),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: [
            Text('Scorecard',
                style: theme.textTheme.titleSmall),
            const Spacer(),
            if (widget.legend != null)
              Text(widget.legend!,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        SingleChildScrollView(
          controller: _ctrl,
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
              // One row per participant — name plus "(N)" net strokes
              // in play so an observer can see who is shooting net what.
              for (final p in widget.participants)
                Row(children: [
                  SizedBox(
                    width: _labelColW, height: _rowH,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: RichText(
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        softWrap: false,
                        text: TextSpan(
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600),
                          children: [
                            TextSpan(text:
                              (p['short_name'] as String?)?.isNotEmpty == true
                                  ? p['short_name'] as String
                                  : (p['name'] as String? ?? '')),
                            if (p['phcp_in_play'] != null)
                              TextSpan(
                                text: ' (${p['phcp_in_play']})',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w400),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (final h in visibleHoles)
                    scoreCell(p['player_id'] as int, h),
                ]),

              // Second block: per-player points won on each hole.
              if (widget.showPoints) ...[
                Container(
                  height: 1,
                  width: _labelColW + _cellW * visibleHoles.length,
                  color: theme.colorScheme.outlineVariant,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                ),
                for (final p in widget.participants)
                  Row(children: [
                    participantLabel(p, suffix: ' pts'),
                    for (final h in visibleHoles)
                      pointsCell(p['player_id'] as int, h),
                  ]),
              ],
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
    final players  = (summary['players'] as List? ?? []).cast<Map<String, dynamic>>();
    final holes    = (summary['holes']   as List? ?? []).cast<Map<String, dynamic>>();
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
          ...players.map((p) {
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
          // Per-hole scorecard — gross scores with the skin-winner cell
          // highlighted, mirroring the Multi-Group Skins view.  Adds a
          // visual answer to "who actually won each hole?" right next
          // to the totals above.
          if (holes.isNotEmpty) ...[
            const Divider(height: 20),
            _MsScorecard(
              holes:        holes,
              participants: players,
            ),
          ],
        ]),
      ),
    );
  }
}

// ---- Spots leaderboard card (capture add-on, separate pot) ----

class _SpotsGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _SpotsGroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final summary = group['summary'] as Map<String, dynamic>? ?? {};
    final players = (summary['players'] as List? ?? []).cast<Map<String, dynamic>>();
    final holes   = (summary['holes']   as List? ?? []).cast<Map<String, dynamic>>();
    final money   = summary['money'] as Map<String, dynamic>? ?? {};
    final total   = money['total_spots'] ?? 0;
    final style   = summary['payout_style']?.toString() == 'pool'
        ? 'Pool' : 'Pay around';
    final status  = summary['status']?.toString() ?? 'pending';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text('$total spot${total == 1 ? '' : 's'} · $style',
                style: const TextStyle(fontSize: 12)),
          ]),
          const SizedBox(height: 2),
          Text('Status: ${status.replaceAll('_', ' ')}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const Divider(height: 16),
          ...players.map((p) {
            final spots  = p['spots'] ?? 0;
            final payout = p['payout'];
            final payStr = payout != null
                ? '\$${(payout as num).formatBet()}'
                : '\$0.00';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text(p['name']?.toString() ?? '—')),
                Text('$spots spot${spots == 1 ? '' : 's'}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Text(payStr, style: const TextStyle(fontWeight: FontWeight.w500)),
              ]),
            );
          }),
          // Where the spots were awarded / removed (sparse — only scored holes).
          if (holes.isNotEmpty) ...[
            const Divider(height: 16),
            Text('SPOTS BY HOLE',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 10, letterSpacing: 0.5, fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            _SpotsHoleStrip(holes: holes),
          ],
        ]),
      ),
    );
  }
}

/// Per-hole Spots chips that wrap across lines (no horizontal scroll) so you can
/// see many holes at once. Each pill: hole number + short name with a green (+)
/// or red (−) spot count. Sparse — only scored holes.
class _SpotsHoleStrip extends StatelessWidget {
  final List<Map<String, dynamic>> holes;
  const _SpotsHoleStrip({required this.holes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const tab = [FontFeature.tabularFigures()];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final h in holes)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: '${h['hole']}  ',
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: tab,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                for (final e in (h['spots'] as List? ?? [])
                    .cast<Map<String, dynamic>>())
                  () {
                    final c = (e['count'] as num?)?.toInt() ?? 0;
                    return TextSpan(
                      text: '${e['short_name'] ?? '?'} ${c > 0 ? '+' : '−'}'
                          '${c.abs()}   ',
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: tab,
                          color: c >= 0 ? GameColors.win : GameColors.loss),
                    );
                  }(),
              ]),
            ),
          ),
      ],
    );
  }
}

// ---- 18-Hole Match leaderboard card (Overall-only Nassau) ----
//
// Mirrors the under-score-entry "Match Progress" table: full names, blue/red
// sides, a per-hole grid (net scores + colour-coded Won-by), the running match
// status, and the leader's running money (awarded even before the match ends).
class _MatchLeaderboardCard extends StatefulWidget {
  final NassauSummary nas;
  const _MatchLeaderboardCard({required this.nas});

  @override
  State<_MatchLeaderboardCard> createState() => _MatchLeaderboardCardState();
}

class _MatchLeaderboardCardState extends State<_MatchLeaderboardCard> {
  final ScrollController _scroll = ScrollController();
  static const double _labelW = 96;
  static const double _cellW = 26;
  static const double _rowH = 24;

  @override
  void initState() {
    super.initState();
    // Scroll the grid so the latest played hole is in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final thru = widget.nas.overall.holesPlayed;
      if (_scroll.hasClients && thru > 7) {
        _scroll.jumpTo(((thru - 7) * _cellW)
            .clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _clip(String s) => s.length > 5 ? s.substring(0, 5) : s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nas = widget.nas;
    final t1Color = GameColors.team1;
    final t2Color = GameColors.team2;

    final p1 = nas.team1.isNotEmpty ? nas.team1.first : null;
    final p2 = nas.team2.isNotEmpty ? nas.team2.first : null;
    String full(p, fallback) =>
        (p?.name.isNotEmpty ?? false) ? p!.name as String : fallback;
    String short(p, fallback) =>
        (p?.shortName.isNotEmpty ?? false) ? p!.shortName as String : fallback;
    final n1 = full(p1, 'Player 1');
    final n2 = full(p2, 'Player 2');
    final s1 = short(p1, n1);
    final s2 = short(p2, n2);

    final margin  = nas.overall.margin;        // + = player 1 up
    final thru    = nas.overall.holesPlayed;
    final decided = nas.overall.result != null;
    final leaderColor =
        margin > 0 ? t1Color : margin < 0 ? t2Color : theme.colorScheme.onSurface;
    final leaderName = margin > 0 ? n1 : margin < 0 ? n2 : null;

    String status;
    if (decided) {
      final left = 18 - thru;
      status = left > 0
          ? '$leaderName wins ${margin.abs()}&$left'
          : '$leaderName wins ${margin.abs()} up';
    } else if (margin == 0) {
      status = 'All Square';
    } else {
      status = '$leaderName ${margin.abs()} UP';
    }

    // Award the current leader the stake even mid-match (status-screen style).
    final bet = nas.betUnit;
    final money = margin == 0
        ? (decided ? 'Halved — no money' : 'All square — no money')
        : '$leaderName  +\$${bet.formatBet()}';

    final byHole = {for (final h in nas.holes) h.hole: h};

    Widget cell(Widget child, {Color? bg, bool current = false}) => Container(
          width: _cellW,
          height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ??
                (current
                    ? theme.colorScheme.primaryContainer.withValues(alpha: .3)
                    : null),
          ),
          child: child,
        );

    Widget labelCell(String text, {Color? color, FontStyle? style}) => SizedBox(
          width: _labelW,
          height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: color, fontWeight: FontWeight.w600, fontStyle: style)),
          ),
        );

    Widget scoreRow(String label, Color color, int? Function(NassauHoleData) get) =>
        Row(children: [
          labelCell(label, color: color),
          for (var h = 1; h <= 18; h++)
            cell(
              Text(
                byHole[h] != null && get(byHole[h]!) != null
                    ? '${get(byHole[h]!)}'
                    : '·',
                style: theme.textTheme.labelSmall,
              ),
              current: h == thru,
            ),
        ]);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header — full names, blue vs red
          Center(
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                children: [
                  TextSpan(text: n1, style: TextStyle(color: t1Color)),
                  TextSpan(
                      text: '  vs  ',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.normal)),
                  TextSpan(text: n2, style: TextStyle(color: t2Color)),
                ],
              ),
            ),
          ),
          if (thru > 0 && thru < 18)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Thru $thru',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          const Divider(height: 14),

          // Match status + running money
          Center(
            child: Text(status,
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: leaderColor, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(money,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: margin == 0
                      ? theme.colorScheme.onSurfaceVariant
                      : Colors.green.shade700,
                  fontWeight: FontWeight.w600,
                )),
          ),
          const SizedBox(height: 10),

          // Per-hole grid
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: _scroll,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                labelCell('Hole'),
                for (var h = 1; h <= 18; h++)
                  cell(
                    Text('$h',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    current: h == thru,
                  ),
              ]),
              scoreRow(s1, t1Color, (d) => d.t1Net),
              scoreRow(s2, t2Color, (d) => d.t2Net),
              // Won-by — colour-coded short name of the hole winner
              Row(children: [
                labelCell('Won by', style: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant),
                for (var h = 1; h <= 18; h++)
                  Builder(builder: (_) {
                    final d = byHole[h];
                    if (d == null || d.winner == null) {
                      return cell(Text('·', style: theme.textTheme.labelSmall));
                    }
                    if (d.winner == 'team1') {
                      return cell(
                        Text(_clip(s1),
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            softWrap: false,
                            style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: t1Color)),
                        bg: GameColors.team1Bg,
                      );
                    }
                    if (d.winner == 'team2') {
                      return cell(
                        Text(_clip(s2),
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            softWrap: false,
                            style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: t2Color)),
                        bg: GameColors.team2Bg,
                      );
                    }
                    return cell(
                      Text('=',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: Colors.grey.shade600)),
                      bg: Colors.grey.shade100,
                    );
                  }),
              ]),
            ]),
          ),
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

    // When the cap clamps the settlement, the headline shows the (smaller)
    // amount that actually changes hands \u2014 so surface the real, uncapped match
    // position too, or the losing side can't see how big the hole really is.
    final isCapped = nas.lossCap != null &&
        nas.payoutTotal.abs() > nas.lossCap! + 0.001;
    String capContext(double rawSigned) {
      if (!isCapped) return '';
      final mag = rawSigned.abs().formatBet();
      return rawSigned >= 0 ? '  (up \$$mag)' : '  (down \$$mag)';
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

    // ── 18-Hole Match: dedicated 1-v-1 card (full per-hole grid) ──────────
    if (nas.isEighteenHoleMatch) {
      return _MatchLeaderboardCard(nas: nas);
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
          // Only show the live bets — an Overall-only game is an 18-hole match.
          if (nas.playFront) ...[
            _betRow(nas.isClaremont ? 'F9' : 'Front 9', nas.front9,  t1Names, t2Names, theme, team2Color: team2Color),
            const SizedBox(height: 4),
          ],
          if (nas.playBack) ...[
            _betRow(nas.isClaremont ? 'B9' : 'Back 9',  nas.back9,   t1Names, t2Names, theme, team2Color: team2Color),
            const SizedBox(height: 4),
          ],
          if (nas.playOverall)
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
                          color: GameColors.team1,
                        ),
                      ),
                      Text(
                        '${team2Name.isNotEmpty ? team2Name : t2Names}: ${fmtPts(t2Total)} pts',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: GameColors.team2,
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
                      // payoutTotalCapped == payoutTotal when uncapped; the
                      // "(down $X)" suffix shows the real hole when capped.
                      '$t1Names: ${signedDollar(nas.payoutTotalCapped)}'
                      '${capContext(nas.payoutTotal)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: totalColor(nas.payoutTotalCapped),
                      ),
                    ),
                    Text(
                      '$t2Names: ${signedDollar(-nas.payoutTotalCapped)}'
                      '${capContext(-nas.payoutTotal)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: totalColor(-nas.payoutTotalCapped),
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
                  if (nas.lossCap != null)
                    Text(
                      'Cap: \$${nas.lossCap!.formatBet()}',
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

// ---- Sixes group card ----

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

  /// Team-vs-team subtitle for one segment, broken into parts so the
  /// caller can render the leading / winning team with extra emphasis
  /// (bold + primary colour).  The flat string the leaderboard used to
  /// show buried the leader on in-progress segments; this returns
  /// `leader`, `joiner`, and `trailer` instead so a RichText widget can
  /// style each piece independently.
  static ({String? leader, String joiner, String trailer, String tone})
      _segmentParts(Map<String, dynamic> seg) {
    final t1  = (seg['team1'] as Map<String, dynamic>? ?? const {})['players']
        as List? ?? const [];
    final t2  = (seg['team2'] as Map<String, dynamic>? ?? const {})['players']
        as List? ?? const [];
    final t1s = _teamString(t1);
    final t2s = _teamString(t2);
    final winner = seg['winner']?.toString() ?? '—';
    final status = seg['status']?.toString() ?? 'pending';

    if (winner == 'Team 1') {
      return (leader: t1s, joiner: ' beat ', trailer: t2s, tone: 'won');
    }
    if (winner == 'Team 2') {
      return (leader: t2s, joiner: ' beat ', trailer: t1s, tone: 'won');
    }
    if (winner == 'Halved') {
      return (leader: null, joiner: 'Halved — ',
              trailer: '$t1s vs $t2s', tone: 'halved');
    }

    // In progress or pending — derive the leader from the last hole's
    // signed margin (+ve = team 1 ahead, −ve = team 2 ahead).
    final holes = (seg['holes'] as List? ?? const []);
    final lastMargin = holes.isEmpty
        ? 0
        : (((holes.last as Map<String, dynamic>)['margin'] as num?)?.toInt() ?? 0);

    if (status == 'in_progress' && lastMargin > 0) {
      return (leader: t1s, joiner: ' vs ', trailer: t2s, tone: 'leading');
    }
    if (status == 'in_progress' && lastMargin < 0) {
      return (leader: t2s, joiner: ' vs ', trailer: t1s, tone: 'leading');
    }
    return (leader: null, joiner: '', trailer: '$t1s vs $t2s', tone: 'pending');
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
    final holes    = (summary['holes']   as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final players  = (summary['players'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

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
                  Builder(builder: (_) {
                    final parts   = _segmentParts(seg);
                    final muted   = theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant);
                    final leader  = theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700);
                    return RichText(
                      text: TextSpan(style: muted, children: [
                        if (parts.joiner == 'Halved — ')
                          TextSpan(text: parts.joiner),
                        if (parts.leader != null) ...[
                          TextSpan(text: parts.leader, style: leader),
                          TextSpan(text: parts.joiner),
                          TextSpan(text: parts.trailer),
                        ] else
                          TextSpan(text: parts.trailer),
                      ]),
                    );
                  }),
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

          // Per-hole gross scorecard — the same table the Skins card shows
          // under its money box (no winner highlight; Sixes is a team best-ball
          // with no single per-hole player winner).
          if (holes.isNotEmpty) ...[
            const Divider(height: 20),
            _MsScorecard(holes: holes, participants: players, legend: null),
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
    final lossCap  = (money['loss_cap']  as num?)?.toDouble();

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
                '\u2022  Par is $parPH pts / hole.'
                '${lossCap != null ? '  \u2022  Loss cap \$${lossCap.formatBet()}/player.' : ''}',
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

/// Leaderboard card for a Wolf foursome.  Shows the standings (points +
/// money, zero-based so the table nets to zero) with each player's holes
/// played and a compact "Wolf by hole" strip.
class _WolfGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _WolfGroupCard({required this.group});

  static String _hcapLabel(Map hcap) {
    final mode = hcap['mode']?.toString() ?? 'net';
    if (mode == 'gross') return 'Gross';
    if (mode == 'strokes_off') return 'SO';
    final pct = (hcap['net_percent'] as num?)?.toInt() ?? 100;
    return pct == 100 ? 'Net' : 'Net ($pct%)';
  }

  static String _fmtPoints(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static String _fmtMoney(double v) {
    if (v == 0) return '—';
    final sign = v > 0 ? '+' : '−';
    return '$sign\$${v.abs().formatBet()}';
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final summary = group['summary'] as Map<String, dynamic>? ?? {};
    final hcap    = summary['handicap'] as Map<String, dynamic>? ?? const {};
    final status  = summary['status']?.toString() ?? 'pending';
    final players = (summary['players'] as List? ?? const []);
    final holes   = (summary['holes']   as List? ?? const []);
    final money   = summary['money']    as Map<String, dynamic>? ?? const {};
    final betUnit = (money['bet_unit']  as num?)?.toDouble() ?? 0.0;
    final lossCap = (money['loss_cap']  as num?)?.toDouble();

    final singleGroup = group['_single_group'] == true;

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
          Row(children: [
            Expanded(
              child: Text('Wolf — ${_hcapLabel(hcap)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
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

          if (players.isEmpty)
            Text('No players yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant))
          else
            ...players.map((p) {
              final r    = p as Map<String, dynamic>;
              final name = r['name']?.toString() ?? '';
              final pts  = (r['points'] as num?)?.toDouble() ?? 0.0;
              final hp   = (r['holes_played'] as num?)?.toInt() ?? 0;
              final mny  = (r['money'] as num?)?.toDouble() ?? 0.0;
              final ptsColor = pts > 0
                  ? Colors.green.shade700
                  : pts < 0 ? Colors.red.shade700
                            : theme.colorScheme.onSurfaceVariant;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text(name,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text('${pts >= 0 ? '+' : '−'}${_fmtPoints(pts.abs())} pts',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: ptsColor, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Text('($hp)',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  if (betUnit > 0) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 72,
                      child: Text(_fmtMoney(mny),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: mny > 0
                                ? Colors.green.shade700
                                : mny < 0 ? Colors.red.shade700
                                          : theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                  ],
                ]),
              );
            }),

          if (holes.isNotEmpty) ...[
            const Divider(height: 20),
            Text('Wolf by hole',
                style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final h in holes)
                if ((h as Map)['winning_side'] != null)
                  _wolfChip(theme, h),
            ]),
          ],

          if (betUnit > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Bet unit \$${betUnit.formatBet()}  •  one point = one stake.'
                '${lossCap != null ? '  •  Loss cap \$${lossCap.formatBet()}/player.' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),

          // Per-hole gross scorecard + a second block of per-hole points,
          // built from each hole's per-player entries (only entries that have
          // actually been scored). No winner highlight.
          if (holes.isNotEmpty) ...[
            const Divider(height: 20),
            _MsScorecard(
              showPoints: true,
              legend: null,
              holes: <Map<String, dynamic>>[
                for (final h in holes)
                  <String, dynamic>{
                    'hole'     : (h as Map)['hole'],
                    'par'      : h['par'],
                    'winner_id': null,
                    'scores'   : <Map<String, dynamic>>[
                      for (final e in (h['entries'] as List? ?? const []))
                        if ((e as Map)['gross'] != null)
                          <String, dynamic>{
                            'player_id': e['player_id'],
                            'gross'    : e['gross'],
                            'strokes'  : (((e['gross'] as int?) ?? 0) -
                                    ((e['net_score'] as int?) ??
                                        (e['gross'] as int?) ?? 0))
                                .clamp(0, 9),
                            'points'   : e['points'],
                          },
                    ],
                  },
              ],
              participants: players.cast<Map<String, dynamic>>(),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _wolfChip(ThemeData theme, Map h) {
    final hole = (h['hole'] as num?)?.toInt() ?? 0;
    final wolf = h['wolf_short']?.toString() ?? '';
    final side = h['winning_side']?.toString();
    final dec  = h['decision']?.toString() ?? '';
    final tag  = dec == 'blind' ? 'B' : dec == 'lone' ? 'L'
              : dec == 'partner' ? 'P' : '';
    // Wolf-side = team 1 (blue), Opponents = team 2 (orange); ties neutral.
    final c = side == 'wolf'
        ? GameColors.team1
        : side == 'opponents'
            ? GameColors.team2
            : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withOpacity(0.4)),
      ),
      child: Text('$hole: $wolf${tag.isNotEmpty ? ' $tag' : ''}',
          style: theme.textTheme.labelSmall?.copyWith(
              color: c, fontWeight: FontWeight.w600)),
    );
  }
}

/// Leaderboard card for a Rabbit foursome.  Shows the standings (money +
/// segments won) and a per-segment strip with each segment's holder.
class _RabbitGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _RabbitGroupCard({required this.group});

  static String _hcapLabel(Map hcap) {
    final mode = hcap['mode']?.toString() ?? 'net';
    if (mode == 'gross') return 'Gross';
    if (mode == 'strokes_off') return 'SO';
    final pct = (hcap['net_percent'] as num?)?.toInt() ?? 100;
    return pct == 100 ? 'Net' : 'Net ($pct%)';
  }

  static String _fmtMoney(double v) {
    if (v == 0) return '—';
    final sign = v > 0 ? '+' : '−';
    return '$sign\$${v.abs().formatBet()}';
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final summary = group['summary'] as Map<String, dynamic>? ?? {};
    final hcap    = summary['handicap'] as Map<String, dynamic>? ?? const {};
    final status  = summary['status']?.toString() ?? 'pending';
    final players = (summary['players']  as List? ?? const []);
    final segs    = (summary['segments'] as List? ?? const []);
    final accumulate = summary['accumulate'] as bool? ?? true;
    final money   = summary['money'] as Map<String, dynamic>? ?? const {};
    final betUnit = (money['bet_unit'] as num?)?.toDouble() ?? 0.0;
    final pot     = (money['pot'] as num?)?.toDouble() ?? (betUnit * 3);
    final numSeg  = (summary['num_segments'] as num?)?.toInt() ?? 1;

    final singleGroup = group['_single_group'] == true;
    String statusLabel;
    switch (status) {
      case 'complete':    statusLabel = 'Final';       break;
      case 'in_progress': statusLabel = 'In progress'; break;
      default:            statusLabel = 'Pending';     break;
    }

    final fmt = numSeg == 1
        ? '1×18' : numSeg == 2 ? '2×9' : '3×6';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!singleGroup) ...[
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Divider(height: 12),
          ],
          Row(children: [
            Expanded(
              child: Text(
                  'Rabbit — ${_hcapLabel(hcap)} · $fmt'
                  '${accumulate ? ' · accumulate' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
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

          if (players.isEmpty)
            Text('No players yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant))
          else
            ...players.map((p) {
              final r    = p as Map<String, dynamic>;
              final name = r['name']?.toString() ?? '';
              final mny  = (r['money'] as num?)?.toDouble() ?? 0.0;
              final won  = (r['segments_won'] as num?)?.toInt() ?? 0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text(name,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  Icon(Icons.directions_run, size: 14,
                      color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 2),
                  Text('$won',
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  if (betUnit > 0) ...[
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 72,
                      child: Text(_fmtMoney(mny),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: mny > 0 ? Colors.green.shade700
                                : mny < 0 ? Colors.red.shade700
                                          : theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600)),
                    ),
                  ],
                ]),
              );
            }),

          if (segs.isNotEmpty) ...[
            const Divider(height: 20),
            Text('Segments',
                style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            ...segs.map((s) {
              final seg = s as Map<String, dynamic>;
              final lo  = seg['start_hole']; final hi = seg['end_hole'];
              final holder = seg['holder_short']?.toString();
              final complete = seg['complete'] as bool? ?? false;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(children: [
                  SizedBox(width: 92,
                    child: Text('Holes $lo–$hi', style: theme.textTheme.bodySmall)),
                  Expanded(
                    child: Text(
                      holder == null
                          ? (complete ? 'Loose (push)' : 'Loose')
                          : 'Rabbit: $holder',
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: holder == null
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.primary)),
                  ),
                  if (!complete)
                    Text('in play', style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                ]),
              );
            }),
          ],

          if (betUnit > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Pot \$${pot.formatBet()}  (3 × \$${betUnit.formatBet()} '
                  'entry)  •  holder of each segment wins its share.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
        ]),
      ),
    );
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
              'Mini Singles Bracket not set up for this group.\n'
              'Use the Game Setup card on the round screen.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ]),
        ),
      );
    }

    final summary     = rawSummary as Map<String, dynamic>? ?? {};
    final singleGroup = group['_single_group'] == true;

    // Use the shared MatchPlayDetailView (the same rich layout that the
    // dedicated score-entry → Match Play screen uses) so the leaderboard
    // reads at the same depth: status banner, hole-by-hole strips, money
    // card.  Only the per-group header is leaderboard-specific.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!singleGroup) ...[
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Divider(height: 12),
          ],
          MatchPlayDetailView(data: summary, scrollable: false),
        ]),
      ),
    );
  }
}

// (Removed) _MatchRow / _MatchPlayGroupCard._matchSummary used to render a
// condensed one-line match summary in the leaderboard.  Replaced by
// MatchPlayDetailView (imported from match_play_screen) so the leaderboard
// matches the depth of the dedicated Match Play screen.

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
        InlineMessage(kind: InlineMessageKind.error, text: _error!),
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
    final cupStatus   = src['cup_status'] as String? ?? 'in_progress';
    final liveMatches = (_live?['matches'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    bool _hasUnresolved(Map<String, dynamic> m) {
      final segs = (m['segments'] as List? ?? []).cast<Map<String, dynamic>>();
      final inds = (m['individual_matches'] as List? ?? []).cast<Map<String, dynamic>>();
      return segs.any((s) => s['is_resolved'] != true) ||
             inds.any((i) => i['is_resolved'] != true);
    }
    int _gameOrder(Map<String, dynamic> m) {
      const order = {'irish_rumble': 0, 'nassau': 1, 'singles_nassau': 2,
                     'singles_18': 3, 'triple_cup': 4};
      return order[m['game_type'] as String? ?? ''] ?? 99;
    }
    int _groupOrder(Map<String, dynamic> m) {
      final groups = (m['groups'] as List? ?? []).cast<int>();
      return groups.isEmpty ? 9999 : groups.first;
    }
    int _matchSort(Map<String, dynamic> a, Map<String, dynamic> b) {
      final byGame = _gameOrder(a).compareTo(_gameOrder(b));
      if (byGame != 0) return byGame;
      return _groupOrder(a).compareTo(_groupOrder(b));
    }

    // Live = at least one unresolved side.  Completed = every side
    // resolved.  Completed cards aren't surfaced anywhere else in the
    // app, so we keep them visible (collapsed) on the Cup tab.
    final activeMatches = liveMatches.where(_hasUnresolved).toList()
      ..sort(_matchSort);
    final completedMatches = liveMatches
        .where((m) => !_hasUnresolved(m))
        .toList()
      ..sort(_matchSort);

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
            cupStatus: cupStatus,
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
          ] else if (_live != null && completedMatches.isEmpty) ...[
            const SizedBox(height: 24),
            Center(
              child: Text(
                'No live matches in progress.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],

          // ── Completed Matches ───────────────────────────────────────────
          // Final state of foursomes whose every side has resolved — the
          // only place in the app to inspect what happened on a finished
          // group.  Same _BandonCupLiveCard layout as Live Now; the
          // game-specific sub-widgets render the resolved chips/totals.
          if (completedMatches.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'COMPLETED',
                  style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.2,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
            ]),
            const SizedBox(height: 12),
            ...completedMatches.map((m) => _BandonCupLiveCard(
                  match    : m,
                  t1Colour : t1Colour,
                  t2Colour : t2Colour,
                  t1Name   : t1Name,
                  t2Name   : t2Name,
                  fmtPts   : _fmtPts,
                )),
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
  /// 'in_progress' | 'team1_won' | 'team2_won' | 'tied'
  final String   cupStatus;
  final String Function(double) fmtPts;

  const _BandonCupScoreboard({
    required this.t1Name,   required this.t2Name,
    required this.t1Colour, required this.t2Colour,
    required this.t1Pts,    required this.t2Pts,
    required this.cupName,  required this.fmtPts,
    this.cupStatus = 'in_progress',
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
            final leftIsT1  = true /* team 1 always on the left, matching score entry order */;
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

          // Status / to-win footer.
          // Winner banner takes precedence — once a side clinches (or the
          // cup is mathematically tied with all points awarded), surface
          // that outcome instead of the "X pts needed to win" hint.
          if (cupStatus == 'team1_won' || cupStatus == 'team2_won')
            _CupWinnerBanner(
              winnerName: cupStatus == 'team1_won' ? t1Name : t2Name,
              winnerColour:
                  cupStatus == 'team1_won' ? t1Colour : t2Colour,
              cupName: cupName,
            )
          else if (cupStatus == 'tied')
            Container(
              width: double.infinity,
              color: Colors.amber.shade700,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: const Text(
                'CUP TIED',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            )
          else if (toWin != null)
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

// ── Winner banner shown once a team has clinched the cup ──────────────────────

class _CupWinnerBanner extends StatelessWidget {
  final String winnerName;
  final Color  winnerColour;
  final String cupName;

  const _CupWinnerBanner({
    required this.winnerName,
    required this.winnerColour,
    required this.cupName,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: winnerColour,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.emoji_events, color: Colors.white, size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${winnerName.toUpperCase()} WINS '
              '${cupName.toUpperCase()}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
              ),
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
                final leftIsT1 = true /* team 1 always on the left, matching score entry order */;
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
                final leftIsT1   = true /* team 1 always on the left, matching score entry order */;
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
            else if (gameType == 'quota_nassau' || gameType == 'triple_cup')
              Builder(builder: (ctx) {
                final leftIsT1   = true /* team 1 always on the left, matching score entry order */;
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
                  // Team 1 always on the left (color follows the team).
                  leftIsTeam2: false)
            else if (gameType == 'irish_rumble')
              _IRLiveRows(
                  segments: segments,
                  t1Players: t1Players, t2Players: t2Players,
                  t1Colour: t1Colour,  t2Colour: t2Colour,
                  pv: pv, fmtPts: fmtPts)
            else if (gameType == 'quota_nassau')
              _QuotaNassauLiveRows(
                  matches: indivs, t1Colour: t1Colour, t2Colour: t2Colour)
            else if (gameType == 'triple_cup')
              _TripleCupLiveRows(
                  matches:    indivs,
                  t1Colour:   t1Colour, t2Colour: t2Colour,
                  t1Name:     t1Name,   t2Name:   t2Name,
                  pv:         pv,
                  fmtPts:     fmtPts,
                  totalPossible: totalPossible)
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
    final leftIsT1  = true /* team 1 always on the left, matching score entry order */;
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

// ── Triple Cup: one expandable row per foursome ──────────────────────────────
//
// Each Triple Cup foursome contributes 4 matches (fourball, foursomes,
// 2 singles).  In the Bandon Cup-style live feed we render that as a
// single collapsed row showing the running cup score for the foursome;
// tapping the chevron expands into the 4 sub-matches.  Keeps the feed
// scrollable when there are 12–15 foursomes × 4 matches = 48–60 matches.

class _TripleCupLiveRows extends StatelessWidget {
  final List<Map<String, dynamic>> matches;
  final Color  t1Colour, t2Colour;
  final String t1Name,   t2Name;
  final double pv;
  final double totalPossible;
  final String Function(double) fmtPts;

  const _TripleCupLiveRows({
    required this.matches,
    required this.t1Colour, required this.t2Colour,
    required this.t1Name,   required this.t2Name,
    required this.pv,
    required this.totalPossible,
    required this.fmtPts,
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

    // Foursome-level rollup: sum t1_pts / t2_pts across all 4 sub-matches.
    double t1Total = 0, t2Total = 0;
    for (final m in matches) {
      t1Total += (m['t1_pts'] as num?)?.toDouble() ?? 0;
      t2Total += (m['t2_pts'] as num?)?.toDouble() ?? 0;
    }
    // "Remaining" = total possible minus what's already been awarded.
    // For 4-player / 3-player TC every match is worth 1 point, so the
    // old `pv * resolved_count` math worked.  2-player TC weights the
    // Overall match 2× (1+1+2 = 4) so a constant pv per match would
    // under-report by 1 the moment Overall resolves.  t1_pts + t2_pts
    // sums to the match's actual contribution (full for a win, split
    // for a halve), so totalling across resolved matches is correct
    // for any per-match weighting.
    final remaining = totalPossible - (t1Total + t2Total);
    final leftIsT1 = true /* team 1 always on the left, matching score entry order */;
    final leftScore  = leftIsT1 ? t1Total : t2Total;
    final rightScore = leftIsT1 ? t2Total : t1Total;
    final leftColor  = leftIsT1 ? t1Colour : t2Colour;
    final rightColor = leftIsT1 ? t2Colour : t1Colour;

    // Surface in-progress match status next to the cup-points header
    // so the TD / spectator can see how the live matches are going
    // without expanding.  Resolved matches don't appear here — their
    // contribution is baked into the t1/t2 totals already.  Pending
    // matches (played == 0) are also skipped: nothing meaningful to
    // show yet.  Each bit carries its leader's team colour so multiple
    // simultaneous singles render in distinct colours ("1 UP thru 3"
    // in red, "2 UP thru 3" in blue, etc.) and AS stays neutral.
    final liveBits = <({String text, Color color})>[];
    for (final m in matches) {
      final played    = (m['holes_played']      as num?)?.toInt() ?? 0;
      final marginRaw = (m['overall_holes_up'] as num?)?.toInt() ?? 0;
      final marginAbs = marginRaw.abs();
      final resolved  = m['is_resolved'] as bool? ?? false;
      if (resolved || played == 0) continue;
      final text = marginAbs == 0
          ? 'AS thru $played'
          : '$marginAbs UP thru $played';
      final color = marginRaw > 0
          ? t1Colour
          : marginRaw < 0
              ? t2Colour
              : theme.colorScheme.onSurfaceVariant;
      liveBits.add((text: text, color: color));
    }

    final header = Row(children: [
      Text(fmtPts(leftScore),
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: leftColor)),
      const SizedBox(width: 6),
      Text('–', style: TextStyle(
          fontSize: 14,
          color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(width: 6),
      Text(fmtPts(rightScore),
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: rightColor)),
      const SizedBox(width: 10),
      Expanded(
        // When something is live, prioritise its status — the "X pts
        // left" is implicit context.  Show that hint only when nothing
        // is in flight (all pending or all resolved).  Each live bit
        // is its own TextSpan so multi-match strings render with each
        // match in its leader's colour (e.g. red "1 UP thru 3", grey
        // "AS thru 3" separated by a neutral comma).
        child: liveBits.isNotEmpty
            ? Text.rich(
                TextSpan(
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600),
                  children: [
                    for (var i = 0; i < liveBits.length; i++) ...[
                      if (i > 0) const TextSpan(text: ', '),
                      TextSpan(
                        text: liveBits[i].text,
                        style: TextStyle(color: liveBits[i].color),
                      ),
                    ],
                  ],
                ),
                overflow: TextOverflow.ellipsis,
              )
            : Text(
                remaining > 0
                    ? '${fmtPts(remaining)} pt${remaining == 1 ? '' : 's'} left'
                    : 'All matches resolved',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
      ),
    ]);

    return Theme(
      // Strip ExpansionTile's default vertical padding so the row
      // sits flush with the rest of the card's content.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        title: header,
        children: matches.map((m) => _TripleCupSubMatchRow(
              match:     m,
              t1Colour:  t1Colour,
              t2Colour:  t2Colour,
              t1Name:    t1Name,
              t2Name:    t2Name,
              fmtPts:    fmtPts,
            )).toList(),
      ),
    );
  }
}

class _TripleCupSubMatchRow extends StatelessWidget {
  final Map<String, dynamic> match;
  final Color  t1Colour, t2Colour;
  final String t1Name,   t2Name;
  final String Function(double) fmtPts;
  const _TripleCupSubMatchRow({
    required this.match,
    required this.t1Colour, required this.t2Colour,
    required this.t1Name,   required this.t2Name,
    required this.fmtPts,
  });

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final label  = match['label']?.toString() ?? match['segment']?.toString() ?? '';
    final p1     = match['player1']?.toString() ?? '';
    final p2     = match['player2']?.toString() ?? '';
    final result = match['result']?.toString();
    final played = (match['holes_played']    as num?)?.toInt() ?? 0;
    final marginAbs = ((match['overall_holes_up'] as num?)?.toInt() ?? 0).abs();
    final isResolved = match['is_resolved'] as bool? ?? false;

    String status;
    Color statusColor;
    if (isResolved) {
      // Resolved matches show the winning team's name (in team color)
      // rather than a "1–0" score — the points are already aggregated
      // in the foursome rollup header above and on the big scoreboard.
      // "Halved" stays as text for ties.
      if (result == 'team1') {
        status = t1Name;
        statusColor = t1Colour;
      } else if (result == 'team2') {
        status = t2Name;
        statusColor = t2Colour;
      } else {
        status = 'Halved';
        statusColor = theme.colorScheme.onSurfaceVariant;
      }
    } else if (played == 0) {
      status = '—';
      statusColor = theme.colorScheme.onSurfaceVariant;
    } else if (marginAbs == 0) {
      status = 'AS thru $played';
      statusColor = theme.colorScheme.onSurfaceVariant;
    } else {
      // Positive overall_holes_up = team1 ahead.
      final overallUp = (match['overall_holes_up'] as num?)?.toInt() ?? 0;
      status = '$marginAbs UP thru $played';
      statusColor = overallUp > 0 ? t1Colour : t2Colour;
    }

    final dim = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        // Segment label ("Fourball", "Foursomes", "Singles 1") — dim grey
        // so the focal point is the colored golfer names + status.
        SizedBox(
          width: 72,
          child: Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: dim)),
        ),
        // Golfer names in their team colors, "vs" in grey.
        Expanded(
          child: RichText(
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: theme.textTheme.bodySmall,
              children: [
                TextSpan(
                  text: p1,
                  style: TextStyle(
                      color: t1Colour, fontWeight: FontWeight.w600),
                ),
                TextSpan(
                  text: '  vs  ',
                  style: TextStyle(color: dim),
                ),
                TextSpan(
                  text: p2,
                  style: TextStyle(
                      color: t2Colour, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        Text(status,
            style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: statusColor)),
      ]),
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
    final leftIsT1   = true /* team 1 always on the left, matching score entry order */;
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
    final p1OnLeft    = true /* team 1 always on the left */;
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
    final p1OnLeft   = true /* team 1 always on the left */;
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

// ---- Triple Cup (One Round Ryder Cup) group card ----

/// Compact strokes-off display for a side of a Triple Cup match
/// — same shape as the score-entry match card:
///   • Foursomes → "Team −4"
///   • Singles   → "−2"
///   • Fourball  → "−0 / −8"
/// Returns null in NET/gross mode (no SO concept) or when no player
/// on this team has strokes_off populated.
String? _tcMatchSoLine(Map<String, dynamic> match, int teamNumber) {
  final players = (match['players'] as List? ?? [])
      .cast<Map<String, dynamic>>()
      .where((p) => (p['team_number'] as int? ?? 0) == teamNumber &&
                    (p['is_phantom'] as bool? ?? false) == false)
      .toList();
  if (players.isEmpty) return null;
  final segment = match['segment']?.toString() ?? 'singles';
  final hasAnySo = players.any((p) => p['strokes_off'] != null);
  if (!hasAnySo) return null;
  String fmt(dynamic so) => so == null ? '?' : '−${so as int}';
  if (segment == 'foursomes') {
    return 'Team ${fmt(players.first['strokes_off'])}';
  }
  return players.map((p) => fmt(p['strokes_off'])).join(' / ');
}

/// Triple Cup **Overview** tab — the "cool screen": the cup scoreboard
/// (Orange/team 2 left, Blue/team 1 right) followed by a box per match showing
/// each match's live score as it progresses ("2 UP thru 5", "AS thru 3",
/// "3 and 2"). One card per foursome/group.
class _TripleCupOverviewView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _TripleCupOverviewView({required this.data});

  @override
  Widget build(BuildContext context) {
    final groups = (data['by_group'] as List? ?? const []);
    if (groups.isEmpty) {
      return const Center(child: Text('No data yet.'));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final g in groups)
          _card(context, g as Map, multiGroup: groups.length > 1),
      ],
    );
  }

  Widget _card(BuildContext context, Map group, {required bool multiGroup}) {
    final theme = Theme.of(context);
    final raw = Map<String, dynamic>.from((group['summary'] as Map?) ?? const {});
    final summary = TripleCupSummary.fromJson(raw);
    final t1Color = summary.team1Color;
    final t2Color = summary.team2Color;

    String nameOr(String? n, String fb) =>
        (n ?? '').trim().isEmpty ? fb : (n ?? '').trim();
    final t1Label = nameOr(raw['team1_name'] as String?, 'Blue');
    final t2Label = nameOr(raw['team2_name'] as String?, 'Orange');

    // Full player names per team (deduped across segments) — shown once so a
    // watcher knows who the short labels in each match refer to.
    List<String> roster(int teamNum) {
      final seen = <String>{};
      final out = <String>[];
      for (final m in summary.matches) {
        for (final n in (teamNum == 1 ? m.team1.players : m.team2.players)) {
          if (n.trim().isNotEmpty && seen.add(n.trim())) out.add(n.trim());
        }
      }
      return out;
    }
    final t1Roster = roster(1).join(', ');
    final t2Roster = roster(2).join(', ');

    String fmt(double p) =>
        p == p.truncateToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(1);

    Widget pill(String label, double pts, Color color) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.bold, fontSize: 13)),
            Text(fmt(pts),
                style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w900,
                    fontSize: 36,
                    height: 1)),
          ],
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(children: [
          if (multiGroup)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Group ${group['group_number']}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Team 1 on the left, team 2 on the right — matches score entry
              // and the cup tab (the color follows the team, not the order).
              pill(t1Label, summary.team1Points, t1Color),
              Text('—',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              pill(t2Label, summary.team2Points, t2Color),
            ],
          ),
          if (t1Roster.isNotEmpty || t2Roster.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text(t1Roster,
                    style: TextStyle(
                        fontSize: 11,
                        color: t1Color,
                        fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: Text(t2Roster,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 11,
                        color: t2Color,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
          ],
          const SizedBox(height: 12),
          // One box per match — live score as it progresses.
          for (final m in summary.matches)
            _matchBox(theme, m, t1Color, t2Color),
        ]),
      ),
    );
  }

  Widget _matchBox(
      ThemeData theme, TripleCupMatch m, Color t1Color, Color t2Color) {
    // Colour the status by whoever currently leads (or the final winner).
    Color leaderColor;
    if (m.result == 'team1') {
      leaderColor = t1Color;
    } else if (m.result == 'team2') {
      leaderColor = t2Color;
    } else if (m.result == 'halved') {
      leaderColor = theme.colorScheme.onSurfaceVariant;
    } else {
      final margin = m.holes.isNotEmpty ? m.holes.last.margin : 0;
      leaderColor = margin > 0
          ? t1Color
          : margin < 0
              ? t2Color
              : theme.colorScheme.onSurfaceVariant;
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(m.label,
            style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Row(children: [
          // Orange (team 2) left, Blue (team 1) right.
          Expanded(
            child: Text(m.team2.shorts.join(' & '),
                style: TextStyle(
                    color: t2Color, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(m.statusDisplay,
                style: TextStyle(
                    color: leaderColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text(m.team1.shorts.join(' & '),
                textAlign: TextAlign.right,
                style: TextStyle(
                    color: t1Color, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ]),
      ]),
    );
  }
}

class _TripleCupGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _TripleCupGroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final summary = group['summary'] as Map<String, dynamic>? ?? {};
    final overall = summary['overall'] as Map<String, dynamic>? ?? {};
    final matches = (summary['matches'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    final t1Pts = (overall['team1_points'] as num? ?? 0).toDouble();
    final t2Pts = (overall['team2_points'] as num? ?? 0).toDouble();
    // Parse via num so a double-valued points_available (legacy or
    // future fractional match) doesn't crash the widget build.
    final possible = ((overall['points_available'] as num?) ?? 0).toInt();

    // Cup team colours come down on the summary as colour-name
    // strings (e.g. "Green", "Gold").  Resolve once and use for
    // every team-tinted element on the card.  Casual rounds fall
    // back to the historical red/blue.
    final t1Color = resolveTripleCupTeamColor(
        summary['team1_colour'] as String?, kTripleCupTeam1Color);
    final t2Color = resolveTripleCupTeamColor(
        summary['team2_colour'] as String?, kTripleCupTeam2Color);
    // One-letter team marker for the hole-by-hole won-by row.  Falls
    // back to 'B'/'O' (Blue / Orange) for casual rounds (no team names).
    String initialFrom(String? name, String fallback) {
      final n = (name ?? '').trim();
      if (n.isEmpty) return fallback;
      return n.substring(0, 1).toUpperCase();
    }
    final t1Initial = initialFrom(summary['team1_name'] as String?, 'B');
    final t2Initial = initialFrom(summary['team2_name'] as String?, 'O');

    // Full player names per team (deduped across segments), shown once.
    List<String> roster(int teamNum) {
      final seen = <String>{};
      final out = <String>[];
      for (final m in matches) {
        final team = (m['team$teamNum'] as Map?) ?? const {};
        for (final n in ((team['players'] as List?)?.cast<String>() ?? const [])) {
          if (n.trim().isNotEmpty && seen.add(n.trim())) out.add(n.trim());
        }
      }
      return out;
    }
    final t1Roster = roster(1).join(', ');
    final t2Roster = roster(2).join(', ');

    String fmt(double p) =>
        p == p.truncateToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(1);

    final foursomeId = group['foursome_id'] as int?;
    return Card(
      child: InkWell(
        onTap: foursomeId == null
            ? null
            : () => Navigator.of(context)
                .pushNamed('/triple-cup', arguments: foursomeId),
        child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Group ${group['group_number']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const Spacer(),
            // Live cup score — team 1 on the left, team 2 on the right
            // (matches score entry / cup tab; color follows the team).
            Text(fmt(t1Pts),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: t1Color)),
            Text(' – ',
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant)),
            Text(fmt(t2Pts),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: t2Color)),
            Text(' of $possible',
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 4),
          Text('Triple Cup',
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
          if (t1Roster.isNotEmpty || t2Roster.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text(t1Roster,
                    style: TextStyle(
                        fontSize: 11,
                        color: t1Color,
                        fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: Text(t2Roster,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 11,
                        color: t2Color,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
          ],
          const Divider(height: 14),
          ...matches.map((m) {
            final label   = m['label']?.toString() ?? '';
            final segment = m['segment']?.toString() ?? 'singles';
            final t1Names = ((m['team1'] as Map?)?['shorts'] as List?)
                    ?.cast<String>().join(' & ') ?? '';
            final t2Names = ((m['team2'] as Map?)?['shorts'] as List?)
                    ?.cast<String>().join(' & ') ?? '';
            final result  = m['result']?.toString();
            final winLabel = m['winner_label']?.toString() ?? '—';
            // Right-justified winner indicator: name the winning side by its
            // short names (clearer for a watcher than "Team 1/Team 2"); keep
            // the live status / "Halved" when not decided team1/team2.
            final winnerDisplay = result == 'team1'
                ? t1Names
                : result == 'team2'
                    ? t2Names
                    : winLabel;
            final color = result == 'team1'
                ? t1Color
                : result == 'team2'
                    ? t2Color
                    : theme.colorScheme.onSurfaceVariant;

            // Compact SO line per team — same shape as the
            // score-entry match card: "Team −N" for foursomes,
            // "−N" for singles, "−A / −B" for fourball.  Null
            // in NET/gross modes.
            final t1So = _tcMatchSoLine(m, 1);
            final t2So = _tcMatchSoLine(m, 2);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Container(
                      width: 70,
                      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        label.isEmpty ? segment : label,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onPrimaryContainer),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Team 2 (Orange) side on the left — names on top,
                          // SO under.
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t2Names,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: t2Color,
                                      fontWeight: FontWeight.w600)),
                              if (t2So != null)
                                Text(t2So,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: t2Color)),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text('vs',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ),
                          // Team 1 (Blue) side on the right — names on top,
                          // SO under.
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t1Names,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: t1Color,
                                      fontWeight: FontWeight.w600)),
                              if (t1So != null)
                                Text(t1So,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: t1Color)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Text(winnerDisplay,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ]),
                ),
                _TripleCupHoleDetail(
                  match:     m,
                  t1Color:   t1Color,
                  t2Color:   t2Color,
                  t1Initial: t1Initial,
                  t2Initial: t2Initial,
                ),
              ],
            );
          }),
          // No per-group money section: Triple Cup is team-vs-team, not
          // per-foursome payouts.  Cup-level settlement (if any) lives
          // on the tournament-level Bandon Cup card.
        ]),
      ),
      ),
    );
  }
}

/// Compact per-segment hole-by-hole grid shown under each Triple Cup
/// match on the leaderboard.  Rows:
///   • Hole / Par / SI
///   • One row per player (fourball + singles) OR one row per team
///     (foursomes — alt-shot is one ball, so per-player isn't meaningful)
///   • "Won by" row
///
/// Player cells highlight in pale team color when the player's score
/// contributed to their team winning the hole (best-ball or singles).
/// Team rows highlight similarly for the winning team in foursomes.
class _TripleCupHoleDetail extends StatelessWidget {
  final Map<String, dynamic> match;
  final Color t1Color;
  final Color t2Color;
  final String t1Initial;
  final String t2Initial;
  const _TripleCupHoleDetail({
    required this.match,
    required this.t1Color,
    required this.t2Color,
    this.t1Initial = 'R',
    this.t2Initial = 'B',
  });

  static const double _labelColW = 60.0;
  static const double _cellW     = 30.0;
  static const double _rowH      = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final players = (match['players'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final holes   = (match['holes']   as List? ?? [])
        .cast<Map<String, dynamic>>();
    final segment   = match['segment']?.toString() ?? 'singles';
    final startHole = match['start_hole'] as int? ?? 1;
    final endHole   = match['end_hole']   as int? ?? startHole + 5;
    if (players.isEmpty) return const SizedBox.shrink();

    final holeRange = List.generate(
        endHole - startHole + 1, (i) => startHole + i);
    final byHole = {for (final h in holes) (h['hole'] as int): h};

    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8, top: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hole numbers
            Row(children: [
              _labelCell('Hole', bold: true),
              for (final h in holeRange)
                _cell(Text('$h',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold))),
            ]),
            // Par
            Row(children: [
              _labelCell('Par', italic: true),
              for (final h in holeRange)
                _cell(Text('${byHole[h]?['par'] ?? '-'}',
                    style: theme.textTheme.bodySmall)),
            ]),
            // Stroke Index — lets the user verify which holes get strokes.
            Row(children: [
              _labelCell('SI', italic: true),
              for (final h in holeRange)
                _cell(Text('${byHole[h]?['stroke_index'] ?? '-'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant))),
            ]),
            Container(
              height: 1,
              width: _labelColW + _cellW * holeRange.length,
              color: theme.colorScheme.outlineVariant,
              margin: const EdgeInsets.symmetric(vertical: 2),
            ),
            if (segment == 'foursomes')
              ..._teamRows(theme, holeRange, byHole, players)
            else
              ..._playerRows(theme, holeRange, byHole, players),
            Container(
              height: 1,
              width: _labelColW + _cellW * holeRange.length,
              color: theme.colorScheme.outlineVariant,
              margin: const EdgeInsets.symmetric(vertical: 2),
            ),
            // Won-by row
            Row(children: [
              _labelCell('Won by', italic: true, dim: true),
              for (final h in holeRange) Builder(builder: (_) {
                final w = byHole[h]?['winner']?.toString();
                if (w == 'T1') {
                  return _cell(
                    Text(t1Initial,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: t1Color)),
                    bg: t1Color.withValues(alpha: 0.18),
                  );
                }
                if (w == 'T2') {
                  return _cell(
                    Text(t2Initial,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: t2Color)),
                    bg: t2Color.withValues(alpha: 0.18),
                  );
                }
                if (w == 'Halved') {
                  return _cell(
                    Text('=',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade600)),
                    bg: Colors.grey.shade100,
                  );
                }
                return _cell(Text('·',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)));
              }),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _labelCell(String s, {bool bold = false, bool italic = false,
                                bool dim = false}) {
    return SizedBox(
      width: _labelColW, height: _rowH,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Builder(builder: (ctx) => Text(s,
            style: TextStyle(
              fontSize: 11,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
              color: dim
                  ? Theme.of(ctx).colorScheme.onSurfaceVariant
                  : null,
            )),
        ),
      ),
    );
  }

  Widget _cell(Widget child, {Color? bg}) => Container(
        width: _cellW, height: _rowH,
        alignment: Alignment.center,
        decoration: bg == null ? null : BoxDecoration(color: bg),
        child: child,
      );

  Widget _scoreCell({
    required int? gross,
    required int strokes,
    required Color teamColor,
    required Color highlight,
    required bool isWin,
  }) {
    if (gross == null) {
      return _cell(const Text('·',
          style: TextStyle(fontSize: 11, color: Colors.grey)));
    }
    return _cell(
      Stack(alignment: Alignment.topCenter, children: [
        // Strokes ribbon along the top of the cell — one solid dot
        // per stroke in the team color so it's visible without
        // hunting (Sixes-style corner dots were too easy to miss).
        if (strokes > 0)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                strokes.clamp(0, 3),
                (_) => Container(
                  width: 4, height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: teamColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('$gross',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isWin ? FontWeight.bold : FontWeight.w600,
                  color: isWin ? teamColor : null,
                )),
          ),
        ),
      ]),
      bg: isWin ? highlight : null,
    );
  }

  /// Per-player rows for fourball / singles segments.  A player's cell
  /// is highlighted when their net equals the team's net AND their
  /// team won the hole (i.e. they contributed to the win).
  List<Widget> _playerRows(ThemeData theme, List<int> holeRange,
      Map<int, Map<String, dynamic>> byHole,
      List<Map<String, dynamic>> players) {
    return [
      for (final p in players) Builder(builder: (_) {
        final teamNum   = p['team_number'] as int? ?? 1;
        final teamColor = teamNum == 1 ? t1Color : t2Color;
        final highlight = teamColor.withValues(alpha: 0.12);
        final pid = p['player_id'] as int;
        final hcap   = p['playing_handicap'] as int?;
        final soVal  = p['strokes_off']      as int?;
        // SO mode → "SO 5", else "(5)" when handicap known.
        final badge = soVal != null
            ? 'SO $soVal'
            : (hcap != null ? '($hcap)' : null);
        return Row(children: [
          SizedBox(
            width: _labelColW, height: _rowH,
            child: Align(
              alignment: Alignment.centerLeft,
              child: RichText(
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: teamColor),
                  children: [
                    TextSpan(text: p['short_name']?.toString() ?? '?'),
                    if (badge != null)
                      TextSpan(
                        text: ' $badge',
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w500,
                            color: teamColor.withOpacity(0.7)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          for (final h in holeRange) Builder(builder: (_) {
            final hData = byHole[h];
            final scores = (hData?['scores'] as List? ?? [])
                .cast<Map<String, dynamic>>();
            final my = scores.where(
                    (s) => (s['player_id'] as int?) == pid)
                .firstOrNull;
            final gross   = my?['gross']   as int?;
            final net     = my?['net']     as int?;
            final strokes = my?['strokes'] as int? ?? 0;
            final winner  = hData?['winner']?.toString();
            final teamNet = teamNum == 1
                ? (hData?['t1_net'] as int?)
                : (hData?['t2_net'] as int?);
            final isMyTeamWinner = (winner == 'T1' && teamNum == 1) ||
                                   (winner == 'T2' && teamNum == 2);
            final contributed = isMyTeamWinner &&
                teamNet != null && net != null && net == teamNet;
            return _scoreCell(
              gross: gross,
              strokes: strokes,
              teamColor: teamColor,
              highlight: highlight,
              isWin: contributed,
            );
          }),
        ]);
      }),
    ];
  }

  /// Two team rows for foursomes (alt-shot).  Per-player detail isn't
  /// meaningful — one ball per team — so the row shows the team net
  /// plus stroke dots for the alt-shot team allocation.
  List<Widget> _teamRows(ThemeData theme, List<int> holeRange,
      Map<int, Map<String, dynamic>> byHole,
      List<Map<String, dynamic>> players) {
    String teamLabel(int teamNum) {
      final shorts = players
          .where((p) => (p['team_number'] as int?) == teamNum &&
                        (p['is_phantom'] as bool? ?? false) == false)
          .map((p) => p['short_name']?.toString() ?? '?')
          .toList();
      return shorts.isEmpty ? '—' : shorts.join('/');
    }

    Widget teamRow(int teamNum) {
      final teamColor = teamNum == 1 ? t1Color : t2Color;
      final highlight = teamColor.withValues(alpha: 0.12);
      return Row(children: [
        SizedBox(
          width: _labelColW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              teamLabel(teamNum),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: teamColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        for (final h in holeRange) Builder(builder: (_) {
          final hData = byHole[h];
          final gross = teamNum == 1
              ? (hData?['t1_team_gross'] as int?)
              : (hData?['t2_team_gross'] as int?);
          final strokes = (teamNum == 1
              ? (hData?['t1_team_strokes'] as int?)
              : (hData?['t2_team_strokes'] as int?)) ?? 0;
          final winner = hData?['winner']?.toString();
          final isWin = (winner == 'T1' && teamNum == 1) ||
                        (winner == 'T2' && teamNum == 2);
          return _scoreCell(
            gross: gross,
            strokes: strokes,
            teamColor: teamColor,
            highlight: highlight,
            isWin: isWin,
          );
        }),
      ]);
    }

    return [teamRow(1), teamRow(2)];
  }
}

/// "My Foursome" tab — filters every per-foursome game on the
/// leaderboard down to the one foursome the viewer is playing in.
/// Reuses each game type's existing _*GroupCard widget so the
/// per-segment detail (Triple Cup hole grid, Nassau bet rows,
/// etc.) is identical to what shows on the regular game tab.
class _MyFoursomeTabView extends StatelessWidget {
  final Leaderboard leaderboard;
  final int?        playerId;
  const _MyFoursomeTabView({
    required this.leaderboard,
    required this.playerId,
  });

  static const Map<String, GroupCardBuilder> _cardBuilders = {
    'triple_cup' : _TripleCupGroupCard.new,
    'nassau'     : _NassauGroupCard.new,
    'quota_nassau': _QuotaNassauGroupCard.new,
    'skins'      : _SkinsGroupCard.new,
    'sixes'      : _SixesGroupCard.new,
    'fourball'   : _FourballGroupCard.new,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (playerId == null) {
      return const Center(child: Text('Sign in to see your foursome.'));
    }

    // For every game key we know how to render, find the by_group
    // entry containing the viewer's player_id and pull it out.
    final cards = <Widget>[];
    for (final entry in _cardBuilders.entries) {
      final g = leaderboard.games[entry.key];
      if (g == null) continue;
      final groups = ((g.data as Map?)?['by_group'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      final my = groups.firstWhere(
        (grp) => _groupContainsPlayer(grp, playerId!),
        orElse: () => const {},
      );
      if (my.isEmpty) continue;
      // Inject the same _single_group flag _ByGroupView uses so cards
      // can hide their "Group N" header when there's only one card
      // showing in this tab.
      final withFlag = {...my, '_single_group': true};
      cards.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: entry.value(group: withFlag),
      ));
    }

    if (cards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "You're not in any foursome on this round.",
            style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: cards,
    );
  }
}


// ---------------------------------------------------------------------------
// Fourball — one card per foursome (the 2v2 best-ball match + money).
// ---------------------------------------------------------------------------

class _FourballGroupCard extends StatefulWidget {
  final Map<String, dynamic> group;
  const _FourballGroupCard({required this.group});

  @override
  State<_FourballGroupCard> createState() => _FourballGroupCardState();
}

class _FourballGroupCardState extends State<_FourballGroupCard> {
  final ScrollController _scroll = ScrollController();
  static const double _labelW = 96;
  static const double _cellW  = 26;
  static const double _rowH   = 24;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final summary = FourballSummary.fromJson(
        (widget.group['summary'] as Map).cast<String, dynamic>());

    final t1Color = GameColors.team1;
    final t2Color = GameColors.team2;

    String join(List<String> a, List<String> b) =>
        (a.isNotEmpty ? a : b).join(' & ');
    final n1 = join(summary.team1.players, summary.team1.shortNames);
    final n2 = join(summary.team2.players, summary.team2.shortNames);
    final s1 = join(summary.team1.shortNames, summary.team1.players);
    final s2 = join(summary.team2.shortNames, summary.team2.players);

    final margin  = summary.holesUp;          // + = team 1 up
    final thru    = summary.holes.isEmpty
        ? 0
        : summary.holes.map((h) => h.hole).reduce((a, b) => a > b ? a : b);
    final decided = summary.status == 'complete' || summary.status == 'halved';
    final leaderColor = margin > 0
        ? t1Color
        : margin < 0 ? t2Color : theme.colorScheme.onSurface;
    final leaderName = margin > 0 ? s1 : margin < 0 ? s2 : null;

    // Auto-scroll the grid so the latest played hole is in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && thru > 7) {
        _scroll.jumpTo(((thru - 7) * _cellW)
            .clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });

    String status;
    if (summary.status == 'pending') {
      status = 'Not started';
    } else if (decided && margin == 0) {
      status = 'All Square';
    } else if (decided) {
      final left = summary.finishedOnHole != null
          ? 18 - summary.finishedOnHole!
          : 0;
      status = left > 0
          ? '$leaderName wins ${margin.abs()}&$left'
          : '$leaderName wins ${margin.abs()} up';
    } else if (margin == 0) {
      status = thru == 0 ? 'Not started' : 'All Square';
    } else {
      status = '$leaderName ${margin.abs()} UP';
    }

    // Provisionally award the current leader the per-player stake, mirroring
    // the 18-Hole Match card (status-screen style).
    final bet = summary.betAmount;
    final money = margin == 0
        ? (decided ? 'Halved — no money' : 'All square — no money')
        : '$leaderName  +\$${bet.formatBet()} each';

    final byHole = {for (final h in summary.holes) h.hole: h};

    Widget cell(Widget child, {Color? bg, bool current = false}) => Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ??
                (current
                    ? theme.colorScheme.primaryContainer.withValues(alpha: .3)
                    : null),
          ),
          child: child,
        );

    Widget labelCell(String text, {Color? color, FontStyle? style}) => SizedBox(
          width: _labelW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: color, fontWeight: FontWeight.w600, fontStyle: style)),
          ),
        );

    Widget scoreRow(String label, Color color, int? Function(FourballHole) get) =>
        Row(children: [
          labelCell(label, color: color),
          for (var h = 1; h <= 18; h++)
            cell(
              Text(
                byHole[h] != null && get(byHole[h]!) != null
                    ? '${get(byHole[h]!)}'
                    : '·',
                style: theme.textTheme.labelSmall,
              ),
              current: h == thru,
            ),
        ]);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header — team long names, team 1 vs team 2.
          Center(
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                children: [
                  TextSpan(text: n1, style: TextStyle(color: t1Color)),
                  TextSpan(
                      text: '  vs  ',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.normal)),
                  TextSpan(text: n2, style: TextStyle(color: t2Color)),
                ],
              ),
            ),
          ),
          if (thru > 0 && thru < 18)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Thru $thru',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          const Divider(height: 14),

          // Match status + running money
          Center(
            child: Text(status,
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: leaderColor, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(money,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: margin == 0
                      ? theme.colorScheme.onSurfaceVariant
                      : Colors.green.shade700,
                  fontWeight: FontWeight.w600,
                )),
          ),
          const SizedBox(height: 10),

          // Per-hole grid — team best balls + won-by.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: _scroll,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                labelCell('Hole'),
                for (var h = 1; h <= 18; h++)
                  cell(
                    Text('$h',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    current: h == thru,
                  ),
              ]),
              scoreRow(s1, t1Color, (d) => d.t1Net),
              scoreRow(s2, t2Color, (d) => d.t2Net),
              // Won-by — team colour each hole.
              Row(children: [
                labelCell('Won by', style: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant),
                for (var h = 1; h <= 18; h++)
                  Builder(builder: (_) {
                    final d = byHole[h];
                    if (d == null) {
                      return cell(Text('·', style: theme.textTheme.labelSmall));
                    }
                    if (d.winner == 'T1') {
                      return cell(
                        Text('T1',
                            style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold, color: t1Color)),
                        bg: GameColors.team1Bg,
                      );
                    }
                    if (d.winner == 'T2') {
                      return cell(
                        Text('T2',
                            style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold, color: t2Color)),
                        bg: GameColors.team2Bg,
                      );
                    }
                    return cell(
                      Text('=',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: Colors.grey.shade600)),
                      bg: Colors.grey.shade100,
                    );
                  }),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Las Vegas — one card per foursome (team totals + money + per-hole numbers).
// ---------------------------------------------------------------------------

class _VegasGroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _VegasGroupCard({required this.group});

  String _money(double v) {
    if (v == 0) return '—';
    final s = v > 0 ? '+' : '−';
    return '$s\$${v.abs().toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary =
        VegasSummary.fromJson((group['summary'] as Map).cast<String, dynamic>());

    Color winColor(String? w) => w == 'team1' ? GameColors.team1
        : w == 'team2' ? GameColors.team2
        : theme.colorScheme.onSurfaceVariant;

    Widget teamRow(VegasTeamSummary t, Color color) {
      final names = t.players.map((p) => p.shortName).join(' & ');
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Container(width: 4, height: 20,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Expanded(child: Text(names,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis)),
          Text('${t.points} pts',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 10),
          SizedBox(width: 64, child: Text(_money(t.money),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: t.money > 0 ? GameColors.win
                      : t.money < 0 ? GameColors.loss
                      : theme.colorScheme.onSurfaceVariant))),
        ]),
      );
    }

    final t1 = summary.teams.where((t) => t.teamNumber == 1).firstOrNull;
    final t2 = summary.teams.where((t) => t.teamNumber == 2).firstOrNull;

    // Replace the wall of per-hole bubbles with the genuinely useful stuff:
    // how far along we are, the biggest single-hole swing, and the last hole.
    final scored = summary.holes;
    final thru = scored.isEmpty
        ? 0
        : scored.map((h) => h.hole).reduce((a, b) => a > b ? a : b);
    VegasHole? big;
    for (final h in scored) {
      if (h.winner != 'team1' && h.winner != 'team2') continue;
      if (big == null || h.points > big.points) big = h;
    }

    String namesFor(String? w) {
      final t = w == 'team1' ? t1 : (w == 'team2' ? t2 : null);
      return t == null ? '' : t.players.map((p) => p.shortName).join(' & ');
    }
    String dollars(double v) => v == v.roundToDouble()
        ? '\$${v.toStringAsFixed(0)}'
        : '\$${v.toStringAsFixed(2)}';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Group ${group['group_number']}',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (thru > 0) ...[
              const SizedBox(width: 8),
              Text('Thru $thru',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            const Spacer(),
            Text(summary.birdieMode == 'flip' ? 'Flip' : 'Multiply',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (summary.carryover) ...[
              const SizedBox(width: 8),
              Text('Carryover', style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
          const SizedBox(height: 6),
          if (t1 != null) teamRow(t1, GameColors.team1),
          if (t2 != null) teamRow(t2, GameColors.team2),
          if (big != null) ...[
            const Divider(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: winColor(big.winner).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: winColor(big.winner).withValues(alpha: 0.35)),
              ),
              child: Row(children: [
                Icon(Icons.star_rounded, size: 18, color: winColor(big.winner)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('BIGGEST HOLE',
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              letterSpacing: 0.5,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 1),
                      Text.rich(
                        TextSpan(style: theme.textTheme.bodySmall, children: [
                          TextSpan(text: 'Hole ${big.hole}  ·  '),
                          TextSpan(
                              text: namesFor(big.winner),
                              style: TextStyle(
                                  color: winColor(big.winner),
                                  fontWeight: FontWeight.bold)),
                          TextSpan(
                              text: '  +${big.points} pts',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          if (big.points * summary.betUnit != 0)
                            TextSpan(
                                text:
                                    '  ·  ${dollars(big.points * summary.betUnit)}'),
                          if (big.multiplier > 1)
                            TextSpan(
                                text: '  (×${big.multiplier})',
                                style: TextStyle(
                                    color: theme.colorScheme.onSurfaceVariant)),
                        ]),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ],
          if (scored.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(children: [
              Text('HOLE BY HOLE',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant)),
              const Spacer(),
              // Which colour is which side (the totals rows above use the same).
              if (t1 != null)
                Text(t1.players.map((p) => p.shortName).join('&'),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: GameColors.team1)),
              const Text('  '),
              if (t2 != null)
                Text(t2.players.map((p) => p.shortName).join('&'),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: GameColors.team2)),
            ]),
            const SizedBox(height: 5),
            _VegasHoleGrid(holes: scored),
          ],
        ]),
      ),
    );
  }
}

/// Horizontally-scrollable per-hole Vegas grid that auto-scrolls to the latest
/// hole, so a live round shows what just happened without manual scrolling.
class _VegasHoleGrid extends StatefulWidget {
  final List<VegasHole> holes;
  const _VegasHoleGrid({required this.holes});

  @override
  State<_VegasHoleGrid> createState() => _VegasHoleGridState();
}

class _VegasHoleGridState extends State<_VegasHoleGrid> {
  final _ctrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToEnd();
  }

  @override
  void didUpdateWidget(_VegasHoleGrid old) {
    super.didUpdateWidget(old);
    // New hole(s) came in on refresh → keep the latest in view.
    if (old.holes.length != widget.holes.length) _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ctrl.hasClients) {
        _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color winColor(String? w) => w == 'team1'
        ? GameColors.team1
        : w == 'team2'
            ? GameColors.team2
            : theme.colorScheme.onSurfaceVariant;
    return SingleChildScrollView(
      controller: _ctrl,
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final h in widget.holes)
          Container(
            width: 34,
            margin: const EdgeInsets.only(right: 3),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: winColor(h.winner).withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Column(children: [
              Text('${h.hole}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 3),
              Text('${h.team1Number ?? '–'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: GameColors.team1,
                      fontWeight: h.winner == 'team1'
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              Text('${h.team2Number ?? '–'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: GameColors.team2,
                      fontWeight: h.winner == 'team2'
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(height: 2),
              Text(h.winner == 'halved' ? '½' : '+${h.points}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: winColor(h.winner),
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
      ]),
    );
  }
}
