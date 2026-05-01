/// screens/tournament_leaderboard_screen.dart
/// ---------------------------------------------
/// Tournament-level championship leaderboard.
/// Fetches GET /api/tournaments/{id}/leaderboard/ and shows tabs for each
/// active tournament game:
///   • Low Net Championship — cumulative net standings with per-round totals
///   • Match Play          — per-group bracket results (Semis + Final + 3rd)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'tournament_low_net_setup_screen.dart';

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
    with TickerProviderStateMixin {
  TabController?             _tabCtrl;
  List<String>               _tabs    = [];
  Map<String, dynamic>?      _payload;
  bool                       _loading = true;
  String?                    _error;

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

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final payload = await client.getTournamentLeaderboard(widget.tournamentId);
      if (!mounted) return;

      final activeGames = (payload['active_games'] as List? ?? [])
          .map((g) => g as String)
          .toList();

      // Only show tabs for games that have data in the games map
      final gamesMap = payload['games'] as Map? ?? {};
      final tabs = activeGames
          .where((g) => gamesMap.containsKey(g))
          .toList();

      setState(() {
        _payload = payload;
        _tabs    = tabs;
        _loading = false;
      });

      if (_tabCtrl == null || _tabCtrl!.length != tabs.length) {
        _tabCtrl?.dispose();
        _tabCtrl = TabController(length: tabs.length, vsync: this);
        setState(() {});
      }
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  static const _labels = {
    'low_net'   : 'Stroke Play',
    'match_play': 'Match Play',
  };

  @override
  Widget build(BuildContext context) {
    final isStaff = context.read<AuthProvider>().isStaff;
    final activeGames =
        (_payload?['active_games'] as List? ?? []).map((g) => g as String).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tournamentName),
        actions: [
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
              ],
            ),
        ],
        bottom: (_tabCtrl != null && _tabs.isNotEmpty)
            ? TabBar(
                controller  : _tabCtrl,
                isScrollable: true,
                tabs: _tabs.map((g) =>
                    Tab(text: _labels[g] ?? g)).toList(),
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
            'Select Low Net or Match Play when creating the tournament.',
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
      case 'match_play':
        return _MatchPlayChampView(data: data);
      default:
        return Center(child: Text('Unknown game: $gameKey'));
    }
  }
}

// ===========================================================================
// Low Net Championship view
// ===========================================================================

class _LowNetChampView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _LowNetChampView({required this.data});

  /// "F" when all holes in the tournament are complete, otherwise "1"–"36".
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
    if (ntp < 0)     return Colors.green.shade700;
    if (ntp > 0)     return Colors.red.shade700;
    return theme.colorScheme.onSurface;
  }

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final results     = (data['results'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final totalRounds = data['total_rounds'] as int? ?? 1;
    final totalHoles  = totalRounds * 18;
    final entryFee    = (data['entry_fee'] as num? ?? 0).toDouble();
    final payouts     = (data['payouts'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final hasPrize    = payouts.isNotEmpty;

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
            child: Row(children: [
              _InfoChip('Mode',
                  _modeLabel(data['handicap_mode'] as String? ?? 'net')),
              const SizedBox(width: 12),
              if ((data['net_percent'] as int? ?? 100) != 100)
                _InfoChip('Hcp %', '${data['net_percent']}%'),
              if (entryFee > 0) ...[
                const SizedBox(width: 12),
                _InfoChip('Entry', '\$${entryFee.toStringAsFixed(0)}'),
              ],
              const Spacer(),
              Text(
                '${data['rounds_played'] ?? 0} / $totalRounds rounds',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          ),
        ),

        const SizedBox(height: 8),

        // ── Column headers ─────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: [
            const SizedBox(width: 36),          // rank
            const Expanded(child: Text('Player',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
            const SizedBox(width: 34, child: Text('Thru',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            for (int r = 1; r <= totalRounds; r++)
              SizedBox(width: 40,
                  child: Text('R$r Net',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10,
                          fontWeight: FontWeight.w600))),
            const SizedBox(width: 46, child: Text('Total',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            if (hasPrize)
              const SizedBox(width: 46, child: Text('Prize',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
          ]),
        ),

        // ── Standing rows ──────────────────────────────────────────────────
        ...results.map((r) {
          final rank        = r['rank'] as int?;
          final ntp         = r['net_to_par'] as int?;
          final holesPlayed = r['holes_played'] as int? ?? 0;
          final roundNtps   = (r['round_ntps'] as List? ?? [])
              .map((v) => v as int).toList();
          final payout      = (r['payout'] as num?)?.toDouble();
          final isLeading   = rank == 1;

          return Card(
            margin   : const EdgeInsets.only(bottom: 6),
            elevation: isLeading ? 1 : 0,
            color: isLeading
                ? theme.colorScheme.primaryContainer.withOpacity(0.25)
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                // Rank
                SizedBox(
                  width: 28,
                  child: Text(
                    rank != null ? '$rank' : '—',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize  : 14,
                        color: isLeading
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                // Name
                Expanded(
                  child: Text(r['name'] as String? ?? '—',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                ),
                // Thru
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
                            ? FontWeight.normal
                            : FontWeight.w600),
                  ),
                ),
                // Per-round net-to-par
                for (int ri = 0; ri < totalRounds; ri++) ...[
                  SizedBox(
                    width: 40,
                    child: ri < roundNtps.length
                        ? Text(
                            _ntpLabel(roundNtps[ri]),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: _ntpColor(roundNtps[ri], theme),
                                fontWeight: FontWeight.w500),
                          )
                        : Text('—',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                  ),
                ],
                // Net-to-par total
                SizedBox(
                  width: 46,
                  child: Text(
                    _ntpLabel(ntp),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize  : 15,
                        color     : _ntpColor(ntp, theme)),
                  ),
                ),
                // Payout
                if (hasPrize)
                  SizedBox(
                    width: 46,
                    child: Text(
                      payout != null && payout > 0
                          ? '\$${payout.toStringAsFixed(0)}'
                          : '',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize  : 12,
                          fontWeight: FontWeight.w600,
                          color     : Colors.green.shade700),
                    ),
                  ),
              ]),
            ),
          );
        }),

        const SizedBox(height: 16),
        Text(
          'Net strokes are capped at double-bogey (par + 2) per hole.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  static String _modeLabel(String m) {
    switch (m) {
      case 'gross':       return 'Gross';
      case 'strokes_off': return 'Strokes Off';
      default:            return 'Net';
    }
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
            'No match play brackets found.\n'
            'Set up Match Play for each foursome to see results here.',
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

  const ChampionshipTabView({super.key, required this.tournamentId});

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
    'low_net'   : 'Stroke Play',
    'match_play': 'Match Play',
  };

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
      final payload = await client.getTournamentLeaderboard(widget.tournamentId);
      if (!mounted) return;

      final activeGames = (payload['active_games'] as List? ?? [])
          .map((g) => g as String).toList();
      final gamesMap = payload['games'] as Map? ?? {};
      final tabs = activeGames.where((g) => gamesMap.containsKey(g)).toList();

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
          Text(_error!, style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center),
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
          tabs: _tabs.map((g) => Tab(text: _labels[g] ?? g)).toList(),
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
