/// screens/tournament_leaderboard_screen.dart
/// ---------------------------------------------
/// Tournament-level championship leaderboard.
/// Fetches GET /api/tournaments/{id}/leaderboard/ and shows tabs for each
/// active tournament game:
///   • Low Net Championship — cumulative net standings with per-round totals
///   • Match Play          — per-group bracket results (Semis + Final + 3rd)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../utils/golf_colors.dart';
import '../utils/watcher_invite.dart';
import '../utils/route_observer.dart';
import '../widgets/error_view.dart';
import '../widgets/inline_message.dart';
import '../widgets/stroke_play_strip.dart';
import '../widgets/synced_scroll_group.dart';
import 'tournament_low_net_setup_screen.dart';
import 'tournament_stableford_setup_screen.dart';

class TournamentLeaderboardScreen extends StatefulWidget {
  final int    tournamentId;
  final String tournamentName;

  const TournamentLeaderboardScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<TournamentLeaderboardScreen> createState() =>
      _TournamentLeaderboardScreenState();
}

class _TournamentLeaderboardScreenState
    extends State<TournamentLeaderboardScreen>
    with TickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  TabController?             _tabCtrl;
  List<String>               _tabs    = [];
  Map<String, dynamic>?      _payload;
  bool                       _loading = true;
  String?                    _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _tabCtrl?.dispose();
    super.dispose();
  }

  /// Returning to the leaderboard (a screen on top was popped) — silently
  /// re-fetch so standings are fresh without flashing the full-screen spinner.
  @override
  void didPopNext() => _load(silent: true);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(silent: true);
  }

  int _lastTabIndex = 0;

  void _onTabChanged() {
    final c = _tabCtrl;
    if (c == null || c.indexIsChanging) return;   // wait until it settles
    if (c.index == _lastTabIndex) return;          // no actual tab change
    _lastTabIndex = c.index;
    _load(silent: true);
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() { _loading = true; _error = null; });
    }
    try {
      final client  = context.read<AuthProvider>().client;
      final payload = await client.getTournamentLeaderboard(widget.tournamentId);
      if (!mounted) return;

      final activeGames = (payload['active_games'] as List? ?? [])
          .map((g) => g as String)
          .toList();

      // Only show tabs for games that have data in the games map. Dedupe so a
      // game listed twice (e.g. championship + same-id side game) can't produce
      // two identical tabs.
      final gamesMap = payload['games'] as Map? ?? {};
      final tabs = <String>[];
      for (final g in activeGames) {
        if (gamesMap.containsKey(g) && !tabs.contains(g)) tabs.add(g);
      }
      // The day bet is not a tournament-level active game — it belongs to the
      // final round — but it IS a tab, and it is the LAST one. Tabs are named
      // for what they pay, so it comes after the side games rather than
      // beside a cut-off tournament name.
      for (final k in gamesMap.keys) {
        final g = k as String;
        if (!tabs.contains(g) && g == 'day_bet') tabs.add(g);
      }

      setState(() {
        _payload = payload;
        _tabs    = tabs;
        _loading = false;
      });

      if (_tabCtrl == null || _tabCtrl!.length != tabs.length) {
        _tabCtrl?.dispose();
        _tabCtrl = TabController(length: tabs.length, vsync: this);
        _lastTabIndex = _tabCtrl!.index;
        // Refresh on tab switch so moving between game tabs shows the latest
        // standings (silent — no spinner flash).
        _tabCtrl!.addListener(_onTabChanged);
        setState(() {});
      }
    } catch (e) {
      // On a silent refresh keep the last-good standings rather than flipping
      // to a full-screen error for a transient failure.
      if (mounted && !silent) {
        setState(() { _error = friendlyError(e); _loading = false; });
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  static const _labels = {
    'low_net'      : 'Stroke Play (Championship)',
    'low_net_round': 'Stroke Play',
    'stableford_championship': 'Stableford',
    'match_play'   : 'Mini Singles Bracket',
  };

  /// Tabs read the name the TD set — the ball game as he typed it, and
  /// "Day bet · R2" for the round it pays on.
  String _tabLabel(String g) {
    final data = (_payload?['games'] as Map? ?? {})[g];
    final fromServer = (data is Map ? data['label'] : null)?.toString();
    if (fromServer != null && fromServer.isNotEmpty) {
      // The championship keeps its friendlier local label.
      if (g == 'day_bet' || g == 'pink_ball') return fromServer;
    }
    return _labels[g] ?? gameDisplayName(g);
  }

  @override
  Widget build(BuildContext context) {
    final isStaff = context.read<AuthProvider>().isAdmin;
    final activeGames =
        (_payload?['active_games'] as List? ?? []).map((g) => g as String).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tournamentName),
        actions: [
          IconButton(
            tooltip: 'Invite a watcher',
            icon: const Icon(Icons.visibility_outlined),
            onPressed: () =>
                inviteWatcher(context, tournamentId: widget.tournamentId),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          if (isStaff && activeGames.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Configure',
              onSelected: (g) => _configure(g),
              itemBuilder: (_) => [
                if (activeGames.contains('low_net'))
                  const PopupMenuItem(
                      value: 'low_net',
                      child: Text('Configure Stroke Play')),
                if (activeGames.contains('stableford_championship'))
                  const PopupMenuItem(
                      value: 'stableford_championship',
                      child: Text('Configure Stableford')),
              ],
            ),
        ],
        bottom: (_tabCtrl != null && _tabs.isNotEmpty)
            ? TabBar(
                controller  : _tabCtrl,
                isScrollable: true,
                tabs: _tabs.map((g) => Tab(text: _tabLabel(g))).toList(),
              )
            : null,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    if (_tabs.isEmpty || _tabCtrl == null) {
      return const Center(
        child: Text('No championship games configured.\n'
            'Select Stroke Play or Mini Singles Bracket when creating the tournament.',
            textAlign: TextAlign.center),
      );
    }

    final gamesMap = (_payload?['games'] as Map? ?? {})
        .map((k, v) => MapEntry(k as String, v as Map<String, dynamic>));

    return TabBarView(
      controller: _tabCtrl,
      children: _tabs.map((g) {
        final data = gamesMap[g];
        if (data == null) return const Center(child: Text('No data yet.'));
        return RefreshIndicator(
          onRefresh: _load,
          child: _GameView(gameKey: g, data: data),
        );
      }).toList(),
    );
  }

  void _configure(String game) {
    if (game == 'low_net') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TournamentLowNetSetupScreen(
            tournamentId: widget.tournamentId),
      )).then((_) => _load());
    } else if (game == 'stableford_championship') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TournamentStablefordSetupScreen(
            tournamentId: widget.tournamentId),
      )).then((_) => _load());
    }
  }
}

// ===========================================================================
// Game views dispatcher
// ===========================================================================

class _GameView extends StatelessWidget {
  final String             gameKey;
  final Map<String, dynamic> data;
  const _GameView({required this.gameKey, required this.data});

  @override
  Widget build(BuildContext context) {
    switch (gameKey) {
      case 'low_net':
        return _LowNetChampView(data: data);
      case 'stableford_championship':
        return _StablefordChampView(data: data);
      case 'match_play':
        return _MatchPlayChampView(data: data);
      case 'day_bet':
        return _DayBetView(data: data);
      default:
        return Center(child: Text('Unknown game: $gameKey'));
    }
  }
}

// ===========================================================================
// Day bet — the final round's stroke play side bet
// ===========================================================================

/// The only board in the set whose result is not knowable while it is being
/// played, so it is drawn honestly rather than tidily.
///
/// The temptation is to hide the ineligible. That makes the board jump at the
/// end with no explanation, so instead the championship money winners stay in
/// place **in italic**, with one line at the top saying what the italic means.
/// The Mini Singles finalists are a different case entirely: they are playing
/// a match rather than posting a card, so they are neither charged nor ranked
/// and get no row at all.
class _DayBetView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _DayBetView({required this.data});

  static String _ntp(int? v) =>
      v == null ? '—' : (v == 0 ? 'E' : (v > 0 ? '+$v' : '$v'));

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final results = (data['results'] as List? ?? []).cast<Map<String, dynamic>>();
    final fee     = (data['entry_fee'] as num? ?? 0).toDouble();
    final pool    = (data['pool'] as num? ?? 0).toDouble();
    final places  = data['places_supported'] as int? ?? 0;
    final provisional = data['provisional'] as bool? ?? true;
    final absent  = data['absent_count'] as int? ?? 0;

    if (results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No scores in the final round yet.',
              textAlign: TextAlign.center),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Wrap(spacing: 12, runSpacing: 4, children: [
              _InfoChip('Round', '${data['round_number']}'),
              if (fee > 0) _InfoChip('Entry', '\$${fee.toStringAsFixed(0)}'),
              _InfoChip('Pool', '\$${pool.toStringAsFixed(0)}'),
              _InfoChip('Places', '$places'),
            ]),
          ),
        ),
        const SizedBox(height: 8),

        InlineMessage(
          kind: InlineMessageKind.info,
          text: 'Italic rows are currently in the 36-hole money. They are not '
              'eligible for this bet and are not charged for it — their entry '
              'is returned when the championship closes. Positions and the '
              'pool firm up then.',
        ),
        const SizedBox(height: 8),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: const [
            Expanded(child: Text('Player',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
            SizedBox(width: 46, child: Text('Net',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            SizedBox(width: 52, child: Text('Prize',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
          ]),
        ),

        ...results.map((r) {
          final eligible = r['eligible'] as bool? ?? true;
          final payout   = (r['payout'] as num?)?.toDouble();
          final thru     = r['holes_played'] as int? ?? 0;
          final reason   = r['ineligible_reason'] as String?;
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                SizedBox(
                  width: 28,
                  child: Text('${r['rank']}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r['player_name']?.toString() ?? '—',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          // Italic marks a row that cannot collect.
                          fontStyle: eligible
                              ? FontStyle.normal : FontStyle.italic,
                          color: eligible
                              ? null : theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        // A net score without its holes is not comparable, so
                        // Thru sits under the name rather than in a sorted
                        // column of its own.
                        reason ?? (thru >= 18 ? 'F' : 'thru $thru'),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text(_ntp(r['net_to_par'] as int?),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontStyle: eligible
                              ? FontStyle.normal : FontStyle.italic,
                          color: _dayBetNetColor(r, eligible, theme))),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    payout != null && payout > 0
                        ? '\$${payout.toStringAsFixed(0)}' : '',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: provisional
                            ? FontWeight.w500 : FontWeight.w700,
                        fontStyle: provisional
                            ? FontStyle.italic : FontStyle.normal,
                        color: provisional
                            ? theme.colorScheme.onSurfaceVariant
                            : Colors.green.shade700),
                  ),
                ),
              ]),
            ),
          );
        }),

        const SizedBox(height: 14),
        Text(
          [
            if (absent > 0)
              data['absent_note']?.toString() ?? '',
            data['dq_note']?.toString() ?? '',
            if (provisional) 'Nothing settles until every round is closed.',
          ].where((s) => s.isNotEmpty).join(' '),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  static Color? _dayBetNetColor(
      Map<String, dynamic> r, bool eligible, ThemeData theme) {
    if (!eligible) return theme.colorScheme.onSurfaceVariant;
    return toParColor(r['net_to_par'] as int?) ?? theme.colorScheme.onSurface;
  }
}

// ===========================================================================
// Stableford Championship view — cumulative points across rounds
// ===========================================================================

class _StablefordChampView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _StablefordChampView({required this.data});

  Widget _chip(String s) => Chip(
        label: Text(s, style: const TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact, padding: EdgeInsets.zero);

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final results     = (data['results'] as List? ?? []);
    final table       = data['table'] as Map<String, dynamic>?;
    final hmode       = data['handicap_mode']?.toString() ?? 'net';
    final netPct      = data['net_percent'] as int? ?? 100;
    final entry       = (data['entry_fee'] as num?)?.toDouble() ?? 0.0;
    final totalRounds = data['total_rounds'] as int? ?? 0;
    if (results.isEmpty) {
      return const Center(child: Text('No Stableford scores yet.'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          _chip(hmode == 'gross' ? 'Gross' : 'Net $netPct%'),
          if (entry > 0) _chip('Pool \$${entry.toStringAsFixed(0)}/player'),
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
        ...results.map((e) {
          final r        = e as Map<String, dynamic>;
          final pts      = r['total_points'] as int? ?? 0;
          final payout   = (r['payout'] as num?)?.toDouble();
          final thru     = r['current_thru'] as int? ?? 0;
          final curRound = r['current_round'] as int? ?? 0;
          final thruStr  = thru >= 18 ? 'F' : '$thru';
          final subtitle = totalRounds > 1
              ? 'Thru $thruStr · Round $curRound of $totalRounds'
              : 'Thru $thruStr';
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              leading: CircleAvatar(radius: 16, child: Text('${r['rank'] ?? ''}')),
              title: Text(r['player_name']?.toString() ?? '—'),
              subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('$pts pts',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  if (payout != null && payout > 0)
                    Text('+\$${payout.toStringAsFixed(payout == payout.roundToDouble() ? 0 : 2)}',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600,
                            color: Colors.green.shade700)),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ===========================================================================
// Low Net Championship view
// ===========================================================================

class _LowNetChampView extends StatefulWidget {
  final Map<String, dynamic> data;
  const _LowNetChampView({required this.data});

  @override
  State<_LowNetChampView> createState() => _LowNetChampViewState();
}

class _LowNetChampViewState extends State<_LowNetChampView> {
  final Set<String> _expanded = {};

  /// Four round columns fit beside a name and a total; six do not. So the
  /// round columns are their own horizontal strip, every row scrolls with the
  /// header, and it opens on the most recent round.
  final _strip = SyncedScrollGroup();
  bool _openedOnNewest = false;

  static const double _roundColW = 44;
  static const int    _visibleRoundCols = 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _openedOnNewest) return;
      _openedOnNewest = true;
      _strip.jumpToEnd();
    });
  }

  @override
  void dispose() {
    _strip.dispose();
    super.dispose();
  }

  /// The round columns, as one horizontally-scrolling strip capped at four
  /// visible columns. Header and every row share an offset, so what sits
  /// under R4 is always R4.
  Widget _roundStrip(int totalRounds, Widget Function(int roundIndex) cell) {
    final shown = totalRounds < _visibleRoundCols
        ? totalRounds : _visibleRoundCols;
    return SizedBox(
      width: _roundColW * shown,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _strip.attach(),
        physics: totalRounds <= _visibleRoundCols
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        child: Row(children: [
          for (int r = 0; r < totalRounds; r++)
            SizedBox(width: _roundColW, child: cell(r)),
        ]),
      ),
    );
  }

  static String _thruLabel(int holesPlayed, int totalHoles) {
    if (holesPlayed <= 0)          return '—';
    if (holesPlayed >= totalHoles) return 'F';
    return '$holesPlayed';
  }

  static String _ntpLabel(int? ntp) {
    if (ntp == null) return '—';
    if (ntp == 0)    return 'E';
    return ntp > 0 ? '+$ntp' : '$ntp';
  }

  static Color _ntpColor(int? ntp, ThemeData theme) {
    if (ntp == null) return theme.colorScheme.onSurfaceVariant;
    // Golf convention: under par red, even/over neutral (shared toParColor).
    return toParColor(ntp) ?? theme.colorScheme.onSurface;
  }

  static String _modeLabel(String m) {
    switch (m) {
      case 'gross':       return 'Gross';
      case 'strokes_off': return 'Strokes Off';
      default:            return 'Net';
    }
  }


  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final results     = (widget.data['results'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final totalRounds = widget.data['total_rounds'] as int? ?? 1;
    final totalHoles  = totalRounds * 18;
    final entryFee    = (widget.data['entry_fee'] as num? ?? 0).toDouble();
    final payouts     = (widget.data['payouts'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final hasPrize    = payouts.isNotEmpty;
    final hmode       = widget.data['handicap_mode'] as String? ?? 'net';
    final countingRule = widget.data['counting_rule'] as String?;
    // Money is a PROJECTION until the round closes. A golfer thru 1 showing
    // \$48 in green was the single most misleading thing on the live board.
    final projected   = (widget.data['rounds_played'] as int? ?? 0) < totalRounds;

    if (results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No scores have been entered yet.',
              textAlign: TextAlign.center),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // ── Header info ────────────────────────────────────────────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment:
                WrapCrossAlignment.center, children: [
              _InfoChip('Mode', _modeLabel(hmode)),
              if ((widget.data['net_percent'] as int? ?? 100) != 100)
                _InfoChip('Hcp %', '${widget.data['net_percent']}%'),
              if (entryFee > 0)
                _InfoChip('Entry', '\$${entryFee.toStringAsFixed(0)}'),
              // The counting rule belongs on the board that applies it —
              // "Best 4 of 6" — so a golfer can see why a column is struck.
              if (countingRule != null) _InfoChip('Counts', countingRule),
              _InfoChip('Rounds',
                  '${widget.data['rounds_played'] ?? 0} / $totalRounds'),
            ]),
          ),
        ),
        const SizedBox(height: 8),

        // ── Column headers ─────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: [
            const Expanded(child: Text('Player',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
            const SizedBox(width: 34, child: Text('Thru',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            if (totalRounds > 1)
              _roundStrip(
                totalRounds,
                (r) => Text('R${r + 1}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(width: 46, child: Text('Net',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            if (hasPrize)
              const SizedBox(width: 46, child: Text('Prize',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            const SizedBox(width: 24), // chevron space
          ]),
        ),

        // ── Standing rows ──────────────────────────────────────────────────
        ...results.map((r) {
          final rank        = r['rank']         as int?;
          final name        = r['name']?.toString() ?? '—';
          final handicap    = r['handicap']     as int? ?? 0;
          final ntp         = r['net_to_par']   as int?;
          final holesPlayed = r['holes_played'] as int? ?? 0;
          final roundNtps   = (r['round_ntps']  as List? ?? [])
              .map((v) => v as int).toList();
          final roundHoles  = (r['round_holes'] as List? ?? []);
          final roundCounts = (r['round_counts'] as List? ?? [])
              .map((v) => v == true).toList();
          final roundComplete = (r['round_complete'] as List? ?? [])
              .map((v) => v == true).toList();
          final roundLabels = (r['round_labels'] as List? ?? [])
              .map((v) => v.toString()).toList();
          final payout      = (r['payout'] as num?)?.toDouble();
          final isLeading   = rank == 1;
          final hasHoles    = roundHoles.isNotEmpty &&
              (roundHoles.first as List?)?.isNotEmpty == true;
          final key         = '$rank:$name';
          final isExpanded  = _expanded.contains(key);

          return Card(
            margin   : const EdgeInsets.only(bottom: 6),
            elevation: isLeading ? 1 : 0,
            clipBehavior: Clip.antiAlias,
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
              children: [
                // ── Summary row ───────────────────────────────────────────
                InkWell(
                  onTap: hasHoles
                      ? () => setState(() {
                            if (isExpanded) _expanded.remove(key);
                            else            _expanded.add(key);
                          })
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Row(children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: name,
                                style: const TextStyle(fontWeight: FontWeight.w500)),
                            TextSpan(
                              // CH everywhere — the card, the rotation sheet
                              // and this board all showed a different label
                              // for one number.
                              text: '  CH $handicap',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.normal,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ]),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          _thruLabel(holesPlayed, totalHoles),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: holesPlayed >= totalHoles
                                  ? theme.colorScheme.onSurface
                                  : Colors.green.shade700,
                              fontWeight: holesPlayed >= totalHoles
                                  ? FontWeight.normal : FontWeight.w600),
                        ),
                      ),
                      if (totalRounds > 1)
                        _roundStrip(totalRounds, (ri) {
                          if (ri >= roundNtps.length) {
                            return Text('—',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant));
                          }
                          // Best-N: a dropped round is STRUCK THROUGH, not
                          // hidden, so a golfer can see what he is throwing
                          // away — and it moves as scores land. A round still
                          // in progress is amber: it shows and its holes are
                          // on the card, but it never displaces a finished one.
                          final counts   = ri < roundCounts.length
                              ? roundCounts[ri] : true;
                          final complete = ri < roundComplete.length
                              ? roundComplete[ri] : true;
                          return Text(
                            _ntpLabel(roundNtps[ri]),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: !counts
                                  ? theme.colorScheme.onSurfaceVariant
                                  : (complete
                                      ? _ntpColor(roundNtps[ri], theme)
                                      : Colors.amber.shade800),
                              fontWeight: FontWeight.w500,
                              decoration: counts
                                  ? null : TextDecoration.lineThrough,
                            ),
                          );
                        }),
                      SizedBox(
                        width: 46,
                        child: Text(_ntpLabel(ntp),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15,
                                color: _ntpColor(ntp, theme))),
                      ),
                      if (hasPrize)
                        SizedBox(
                          width: 46,
                          child: Text(
                            payout != null && payout > 0
                                ? '\$${payout.toStringAsFixed(0)}' : '',
                            textAlign: TextAlign.center,
                            // Muted italic while it is a projection; full
                            // weight only once every round is closed.
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: projected
                                    ? FontWeight.w500 : FontWeight.w700,
                                fontStyle: projected
                                    ? FontStyle.italic : FontStyle.normal,
                                color: projected
                                    ? theme.colorScheme.onSurfaceVariant
                                    : Colors.green.shade700),
                          ),
                        ),
                      SizedBox(
                        width: 24,
                        child: hasHoles
                            ? Icon(
                                isExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                                color: theme.colorScheme.onSurfaceVariant)
                            : const SizedBox.shrink(),
                      ),
                    ]),
                  ),
                ),

                // ── Expandable per-round scorecards ───────────────────────
                if (isExpanded && hasHoles)
                  Container(
                    color: theme.colorScheme.surfaceContainerLowest,
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int ri = 0; ri < roundHoles.length; ri++) ...[
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                          if (totalRounds > 1)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                ri < roundLabels.length
                                    ? roundLabels[ri] : 'Round ${ri + 1}',
                                style: theme.textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          // Same colored per-hole strip as the per-round Stroke
                          // Play tab (net/gross vs par + stroke dots), so the
                          // championship reads identically.
                          strokePlayHoleStrip(
                            context,
                            holes:   (roundHoles[ri] as List),
                            showNet: hmode != 'gross',
                          ),
                          if (ri < roundHoles.length - 1)
                            const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          );
        }),

        // Money is a projection until the last card is in — the muted italic
        // above needs the sentence that explains it.
        if (hasPrize && projected) ...[
          const SizedBox(height: 14),
          Text(
            'Projected — pays on the final standing.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic),
          ),
        ],

        // ONE line, once, on every net board. The shipped footnote argued with
        // itself — it capped at a number and then added to it.
        if (hmode != 'gross') ...[
          const SizedBox(height: 10),
          Text(
            'No hole counts for more than net double bogey — par + 2, plus any '
            'strokes you get on that hole.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (countingRule != null && countingRule.startsWith('Best')) ...[
          const SizedBox(height: 8),
          Text(
            '$countingRule. A struck round is dropped from the total; an amber '
            'one is still being played and cannot displace a finished round.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  const _InfoChip(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RichText(text: TextSpan(
      style: theme.textTheme.bodySmall,
      children: [
        TextSpan(text: '$label: ',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        TextSpan(text: value,
            style: TextStyle(fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface)),
      ],
    ));
  }
}

// ===========================================================================
// Match Play Championship view
// ===========================================================================

class _MatchPlayChampView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _MatchPlayChampView({required this.data});

  @override
  Widget build(BuildContext context) {
    final brackets = (data['brackets'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    if (brackets.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No Mini Singles Brackets found.\n'
            'Set up a Mini Singles Bracket for each foursome to see results here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Group brackets by round_number
    final byRound = <int, List<Map<String, dynamic>>>{};
    for (final b in brackets) {
      final rn = b['round_number'] as int? ?? 1;
      byRound.putIfAbsent(rn, () => []).add(b);
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: byRound.entries.map((roundEntry) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 4),
              child: Text('Round ${roundEntry.key}',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            ...roundEntry.value.map((bracket) =>
                _BracketCard(bracket: bracket)),
            const SizedBox(height: 12),
          ],
        );
      }).toList(),
    );
  }
}

class _BracketCard extends StatelessWidget {
  final Map<String, dynamic> bracket;
  const _BracketCard({required this.bracket});

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final groupNum   = bracket['group_number'] as int? ?? 1;
    final status     = bracket['status'] as String? ?? 'pending';
    final matches    = (bracket['matches'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final money      = bracket['money'] as Map<String, dynamic>?;
    final prizePool  = (money?['prize_pool'] as num? ?? 0).toDouble();

    // Split into round 1 (semis) and round 2 (final + 3rd)
    final semis  = matches.where((m) => m['round'] == 1).toList();
    final finals = matches.where((m) => m['round'] == 2).toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Row(children: [
            Text('Group $groupNum',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const Spacer(),
            _StatusChip(status),
            if (prizePool > 0) ...[
              const SizedBox(width: 8),
              Text('Pool: \$${prizePool.toStringAsFixed(0)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),

          const Divider(height: 16),

          // Semis
          if (semis.isNotEmpty) ...[
            Text('Holes 1–9 (Semi-finals)',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ...semis.map((m) => _MatchRow(match: m)),
            const SizedBox(height: 10),
          ],

          // Finals
          if (finals.isNotEmpty) ...[
            Text('Holes 10–18 (Final & 3rd Place)',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ...finals.map((m) => _MatchRow(match: m)),
          ],

          // Payouts
          if (money != null) ...[
            const Divider(height: 16),
            _PayoutBlock(money: money),
          ],
        ]),
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  final Map<String, dynamic> match;
  const _MatchRow({required this.match});

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final label      = match['label'] as String? ?? '';
    final p1         = match['player1'] as String? ?? '—';
    final p2         = match['player2'] as String? ?? '—';
    final winnerName = match['winner_name'] as String?;
    final status     = match['status'] as String? ?? 'pending';
    final isFinal    = label == 'Final';

    Color? labelColor;
    if (isFinal) labelColor = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        // Match label
        SizedBox(
          width: 72,
          child: Text(label,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: labelColor ?? theme.colorScheme.onSurfaceVariant,
                  fontWeight: isFinal ? FontWeight.bold : FontWeight.normal)),
        ),
        // Players + result
        Expanded(
          child: status == 'pending'
              ? Text('$p1  vs  $p2',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant))
              : status == 'complete' && winnerName != null
                  ? RichText(text: TextSpan(
                      style: theme.textTheme.bodyMedium,
                      children: [
                        TextSpan(
                          text: winnerName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        TextSpan(
                          text: ' def. ${winnerName == p1 ? p2 : p1}',
                          style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ))
                  : Text('$p1  vs  $p2',
                      style: theme.textTheme.bodyMedium),
        ),
        // In-progress indicator
        if (status == 'in_progress')
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Icon(Icons.sports_golf,
                size: 14, color: Colors.green.shade600),
          ),
      ]),
    );
  }
}

class _PayoutBlock extends StatelessWidget {
  final Map<String, dynamic> money;
  const _PayoutBlock({required this.money});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final payouts = (money['payouts'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    if (payouts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Payouts',
            style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        ...payouts.map((p) {
          final place  = p['place'] as String? ?? '';
          final player = p['player'] as String?;
          final amount = (p['amount'] as num? ?? 0).toDouble();
          final hasPayout = amount > 0 && player != null;
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              Text('$place  ',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600)),
              Text(player ?? '—',
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: hasPayout ? FontWeight.w500 : null)),
              const Spacer(),
              if (hasPayout)
                Text('\$${amount.toStringAsFixed(0)}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade700)),
            ]),
          );
        }),
      ],
    );
  }
}

// ===========================================================================
// ChampionshipTabView — embeddable widget (no Scaffold) used by the
// per-round LeaderboardScreen to show a Championship tab inline.
// ===========================================================================

class ChampionshipTabView extends StatefulWidget {
  final int tournamentId;
  final int? roundId; // When provided, filter to this round only

  const ChampionshipTabView({super.key, required this.tournamentId, this.roundId});

  @override
  State<ChampionshipTabView> createState() => _ChampionshipTabViewState();
}

class _ChampionshipTabViewState extends State<ChampionshipTabView>
    with TickerProviderStateMixin {
  TabController?        _tabCtrl;
  List<String>          _tabs    = [];
  Map<String, dynamic>? _payload;
  bool                  _loading = true;
  String?               _error;

  static const _labels = {
    'low_net'      : 'Stroke Play (Championship)',
    'low_net_round': 'Stroke Play',
    'stableford_championship': 'Stableford',
    'match_play'   : 'Mini Singles Bracket',
  };

  /// Tabs read the name the TD set — the ball game as he typed it, and
  /// "Day bet · R2" for the round it pays on.
  String _tabLabel(String g) {
    final data = (_payload?['games'] as Map? ?? {})[g];
    final fromServer = (data is Map ? data['label'] : null)?.toString();
    if (fromServer != null && fromServer.isNotEmpty) {
      // The championship keeps its friendlier local label.
      if (g == 'day_bet' || g == 'pink_ball') return fromServer;
    }
    return _labels[g] ?? gameDisplayName(g);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabCtrl?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final payload = await client.getTournamentLeaderboard(
          widget.tournamentId, roundId: widget.roundId);
      if (!mounted) return;

      final activeGames = (payload['active_games'] as List? ?? [])
          .map((g) => g as String).toList();
      final gamesMap = payload['games'] as Map? ?? {};
      final tabs = <String>[];
      for (final g in activeGames) {
        if (gamesMap.containsKey(g) && !tabs.contains(g)) tabs.add(g);
      }
      // The day bet is not a tournament-level active game — it belongs to the
      // final round — but it IS a tab, and it is the LAST one. Tabs are named
      // for what they pay, so it comes after the side games rather than
      // beside a cut-off tournament name.
      for (final k in gamesMap.keys) {
        final g = k as String;
        if (!tabs.contains(g) && g == 'day_bet') tabs.add(g);
      }

      if (_tabCtrl == null || _tabCtrl!.length != tabs.length) {
        _tabCtrl?.dispose();
        _tabCtrl = TabController(length: tabs.isEmpty ? 1 : tabs.length, vsync: this);
      }

      setState(() {
        _payload = payload;
        _tabs    = tabs;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InlineMessage(kind: InlineMessageKind.error, text: _error!),
          const SizedBox(height: 12),
          FilledButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    if (_tabs.isEmpty || _tabCtrl == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No championship games configured.',
              textAlign: TextAlign.center),
        ),
      );
    }

    final gamesMap = (_payload?['games'] as Map? ?? {})
        .map((k, v) => MapEntry(k as String, v as Map<String, dynamic>));

    // Single championship game → render directly (no nested tab bar)
    if (_tabs.length == 1) {
      final gameKey = _tabs.first;
      final data    = gamesMap[gameKey];
      if (data == null) return const Center(child: Text('No data yet.'));
      return RefreshIndicator(
        onRefresh: _load,
        child: _GameView(gameKey: gameKey, data: data),
      );
    }

    // Multiple championship games → nested tab bar
    return Column(
      children: [
        TabBar(
          controller  : _tabCtrl,
          isScrollable: true,
          tabs: _tabs.map((g) => Tab(text: _tabLabel(g))).toList(),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children  : _tabs.map((g) {
              final data = gamesMap[g];
              if (data == null) return const Center(child: Text('No data yet.'));
              return RefreshIndicator(
                onRefresh: _load,
                child: _GameView(gameKey: g, data: data),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color bg;
    String label;
    switch (status) {
      case 'complete':
        bg    = Colors.grey.shade200;
        label = 'Complete';
        break;
      case 'in_progress':
        bg    = Colors.green.shade100;
        label = 'In Progress';
        break;
      default:
        bg    = theme.colorScheme.surfaceContainerHighest;
        label = 'Pending';
    }
    return Container(
      padding   : const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color       : bg,
          borderRadius: BorderRadius.circular(12)),
      child: Text(label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
    );
  }
}
