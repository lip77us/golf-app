import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/home_data.dart';
import '../utils/shared_round.dart';
import '../widgets/app_drawer.dart';
import 'casual_round_screen.dart';
import 'new_round_wizard.dart';
import 'player_list_screen.dart';

/// The home: the one thing the golfer is in right now, then a short look at
/// their last five rounds. Replaces landing on the Tournaments board and then
/// the Rounds board (handoff-home-startup).
///
/// **Open from memory.** The last home is saved to the device and drawn first;
/// the server's answer updates it in place and only the hero crossfades
/// (200 ms). With nothing saved the launch screen is held for at most 1.2 s,
/// then the skeleton — never an empty state before BOTH the rounds and the
/// tournaments have answered (they are fetched together, and the home is only
/// built from a complete answer).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _holdFor = Duration(milliseconds: 1200);

  Map<String, dynamic>? _home;
  bool _holding = true;
  bool _offline = false;
  bool _failed = false;
  int _rotate = 0;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _holdTimer = Timer(_holdFor, () {
      if (mounted) setState(() => _holding = false);
    });
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _start() async {
    final saved = await loadSavedHome();
    if (saved != null && mounted) {
      setState(() {
        _home = saved;
        _holding = false;
      });
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final auth = context.read<AuthProvider>();
    final c = auth.client;
    try {
      // Rounds, tournaments and stats TOGETHER; the home is drawn from the
      // complete answer, so no empty state can appear while one is still out.
      final r = await Future.wait<dynamic>([
        c.getCasualRounds(status: 'in_progress'),
        c.getCasualRounds(status: 'pending')
            .catchError((_) => <CasualRoundSummary>[]),
        c.getCasualRounds(status: 'complete'),
        c.getTournaments(includePlaying: true),
        c.getPlayingForMe().catchError((_) => <ScoringRound>[]),
        c.getSharedRounds().catchError((_) => <SharedRoundSummary>[]),
        c.getHomeStats(rotate: _rotate++).catchError(
            (_) => <String, dynamic>{'enough': false, 'rounds': []}),
      ]);
      final home = buildHome(
        now: DateTime.now(),
        playerName: auth.player?.name,
        active: List.from(r[0]),
        pending: List.from(r[1]),
        recent: List.from(r[2]),
        tournaments: List.from(r[3]),
        playing: List.from(r[4]),
        watching: List.from(r[5]),
        stats: Map<String, dynamic>.from(r[6]),
      );
      saveHome(home);
      if (!mounted) return;
      setState(() {
        _home = home;
        _offline = false;
        _failed = false;
        _holding = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _offline = _home != null;
        _failed = _home == null;
        _holding = false;
      });
    }
  }

  Future<void> _open(Map? action) async {
    if (action == null) return;
    final nav = Navigator.of(context);
    if (action['round'] != null) {
      await nav.pushNamed('/round', arguments: action['round']);
    }
    if (mounted) _refresh();
  }

  Future<void> _newRound({List<int> ids = const [], String? game}) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            CasualRoundScreen(playAgainPlayerIds: ids, playAgainGame: game)));
    if (mounted) _refresh();
  }

  Future<void> _newTournament() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const NewRoundWizard()));
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    // The launch screen, held: same pine ground as the native one.
    if (_home == null && _holding) {
      return Scaffold(
        backgroundColor: Halved.deepPine,
        body: Center(
          child: SvgPicture.asset('assets/icon/halved_mark.svg',
              width: 120, height: 120),
        ),
      );
    }
    final home = _home;
    final heroIsStart = home != null && home['hero'] == null;

    return Scaffold(
      backgroundColor: Halved.surface,
      drawer: AppDrawer(
        playerName: auth.player?.name,
        onTournamentsTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/tournaments').then((_) => _refresh());
        },
        onCasualRoundsTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/casual-rounds').then((_) => _refresh());
        },
        onPlayersTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerListScreen()));
        },
        onSettingsTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/settings');
        },
        onLogout: () async {
          await clearSavedHome();
          await auth.logout();
        },
      ),
      body: SafeArea(
        bottom: false,
        child: home == null
            ? (_failed ? _error() : const _Skeleton())
            : RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                  children: _sections(home),
                ),
              ),
      ),
      bottomNavigationBar: home == null || heroIsStart
          ? null
          : _Dock(onRound: _newRound, onTournament: _newTournament),
    );
  }

  Widget _error() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Couldn’t load your home.', style: Halved.body()),
          const SizedBox(height: 12),
          FilledButton(onPressed: _refresh, child: const Text('Try again')),
        ]),
      );

  List<Widget> _sections(Map<String, dynamic> h) {
    final hero = h['hero'] as Map<String, dynamic>?;
    final live = (h['live'] as List).cast<Map>();
    final coming = (h['coming'] as List).cast<Map>();
    final recent = (h['recent'] as List).cast<Map>();
    final stats = (h['stats'] as Map).cast<String, dynamic>();
    final first = h['firstLaunch'] == true;
    final updated = _offline
        ? DateTime.fromMillisecondsSinceEpoch(h['savedAt'] as int)
        : null;

    return [
      _Header(
        greeting: h['greeting'] as String,
        context: updated == null
            ? h['context'] as String
            : 'Updated ${_hm(updated)}',
        onMenu: () => Scaffold.of(context).openDrawer(),
      ),
      const SizedBox(height: 14),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(
          key: ValueKey(hero == null
              ? 'start-$first'
              : '${hero['rule']}-${hero['id']}-${hero['thru']}'),
          child: hero == null
              ? _StartCard(
                  first: first,
                  again: (h['again'] as List? ?? const []).cast<Map>(),
                  onAgain: (a) => _newRound(
                      ids: (a['ids'] as List).cast<int>(),
                      game: a['game'] as String?),
                  onRound: _newRound,
                  onTournament: _newTournament)
              : _HeroCard(hero: hero, onTap: () => _open(hero['action'] as Map?)),
        ),
      ),
      if (live.isNotEmpty) ...[
        const _SectionLabel('Live now'),
        for (final w in live) _LiveRow(row: w, onTap: () => _watch(w)),
      ],
      if (coming.isNotEmpty) ...[
        const _SectionLabel('Coming up'),
        for (final c in coming) _ComingRow(row: c, onTap: () => _open(c['action'] as Map?)),
      ],
      _SectionLabel('Your last 5 rounds',
          trailing: recent.isEmpty && first ? null : 'All rounds ›',
          onTrailing: () =>
              Navigator.of(context).pushNamed('/casual-rounds').then((_) => _refresh())),
      _StatsCard(stats: stats),
      if (recent.isNotEmpty) ...[
        const _SectionLabel('Recent'),
        for (final r in recent) _RecentRow(row: r, onTap: () => _open(r['action'] as Map?)),
      ],
    ];
  }

  Future<void> _watch(Map w) async {
    // The saved home holds no live objects, so find the row again.
    final id = w['watchId'] as int;
    try {
      final all = await context.read<AuthProvider>().client.getSharedRounds();
      final r = all.firstWhere(
          (x) => x.id == id && x.isTournament == (w['isTournament'] == true));
      if (!mounted) return;
      await openWatchedRound(context, r);
    } catch (_) {}
    if (mounted) _refresh();
  }
}

String _hm(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')}';
}

// ── Pieces ──────────────────────────────────────────────────────────────────

TextStyle _head(double size, {Color color = Halved.deepPine}) =>
    GoogleFonts.schibstedGrotesk(
        fontSize: size, fontWeight: FontWeight.w700, color: color);

class _Header extends StatelessWidget {
  final String greeting, context;
  final VoidCallback onMenu;
  const _Header(
      {required this.greeting, required this.context, required this.onMenu});

  @override
  Widget build(BuildContext c) => Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: Halved.deepPine, borderRadius: BorderRadius.circular(11)),
          padding: const EdgeInsets.all(5),
          child: SvgPicture.asset('assets/icon/halved_mark.svg'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(greeting, style: _head(19)),
            Text(context,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Halved.body(color: Halved.muted)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.menu), onPressed: onMenu),
      ]);
}

class _HeroCard extends StatelessWidget {
  final Map<String, dynamic> hero;
  final VoidCallback onTap;
  const _HeroCard({required this.hero, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final light = hero['light'] == true;
    final live = hero['dot'] == 'live';
    final tiles = (hero['tiles'] as List).cast<Map>();
    final avatars = (hero['avatars'] as List).cast<Map>();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment(-0.3, -1),
          end: Alignment(0.3, 1),
          colors: [Color(0xFF0F6E56), Color(0xFF0B1F1A)],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: live ? Halved.brightMint : const Color(0xFFF2B84B)),
          ),
          const SizedBox(width: 8),
          Text((hero['tag'] as String).toUpperCase(),
              style: Halved.body(color: Colors.white70, weight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        Text(hero['title'] as String, style: _head(22, color: Colors.white)),
        const SizedBox(height: 2),
        Text(hero['sub'] as String, style: Halved.body(color: Colors.white70)),
        if (tiles.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(children: [
            for (final t in tiles)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(14)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t['k'] as String,
                        style: Halved.body(color: Colors.white60)),
                    Text(t['v'] as String,
                        style: _head(20, color: Halved.brightMint)),
                  ]),
                ),
              ),
          ]),
        ],
        if (avatars.isNotEmpty || (hero['names'] as String).isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(children: [
            for (final a in avatars)
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.only(right: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: a['me'] == true
                        ? Halved.brightMint
                        : Colors.white.withValues(alpha: .16)),
                child: Text(a['i'] as String,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: a['me'] == true ? Halved.deepPine : Colors.white)),
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(hero['names'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Halved.body(color: Colors.white70)),
            ),
          ]),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: light ? Colors.white : Halved.brightMint,
              foregroundColor: Halved.deepPine,
              shape: const StadiumBorder(),
            ),
            onPressed: onTap,
            child: Text(hero['button'] as String,
                style: _head(17, color: Halved.deepPine)),
          ),
        ),
      ]),
    );
  }
}

class _StartCard extends StatelessWidget {
  final bool first;
  final List<Map> again;
  final void Function(Map) onAgain;
  final VoidCallback onRound, onTournament;
  const _StartCard(
      {required this.first,
      required this.again,
      required this.onAgain,
      required this.onRound,
      required this.onTournament});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(first ? 'Your first round' : 'Where are we playing?',
              style: _head(24)),
          const SizedBox(height: 4),
          Text(
              first
                  ? 'Set up a round in under a minute.'
                  : 'Nothing on your calendar. Start one in under a minute.',
              style: Halved.body(color: Halved.muted)),
          const SizedBox(height: 14),
          _StartRow(
              dark: true,
              icon: Icons.add,
              title: 'New round',
              sub: 'Pick your golfers and a game',
              onTap: onRound),
          const SizedBox(height: 10),
          _StartRow(
              dark: false,
              icon: Icons.emoji_events_outlined,
              title: 'New tournament',
              sub: 'Cup, trip or field event',
              onTap: onTournament),
          if (again.isNotEmpty) ...[
            const _SectionLabel('Play it again'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final a in again)
                ActionChip(
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Halved.cardBorder),
                  avatar: const Icon(Icons.replay, size: 18, color: Halved.pine),
                  label: Text('${a['label']} · ${a['sub']}',
                      style: Halved.body(weight: FontWeight.w700)),
                  onPressed: () => onAgain(a),
                ),
            ]),
          ],
        ],
      );
}

class _StartRow extends StatelessWidget {
  final bool dark;
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  const _StartRow(
      {required this.dark,
      required this.icon,
      required this.title,
      required this.sub,
      required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: dark ? Halved.deepPine : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: dark ? null : Border.all(color: Halved.pine, width: 1.5),
          ),
          child: Row(children: [
            CircleAvatar(
                radius: 16,
                backgroundColor: dark ? Halved.brightMint : Halved.surface,
                child: Icon(icon, color: Halved.deepPine)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: _head(17, color: dark ? Colors.white : Halved.pine)),
                Text(sub,
                    style: Halved.body(
                        color: dark ? Colors.white70 : Halved.muted)),
              ]),
            ),
          ]),
        ),
      );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final String? trailing;
  final VoidCallback? onTrailing;
  const _SectionLabel(this.text, {this.trailing, this.onTrailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 22, 2, 8),
        child: Row(children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: Halved.body(color: Halved.pine, weight: FontWeight.w800)),
          ),
          if (trailing != null)
            InkWell(
              onTap: onTrailing,
              child: Text(trailing!,
                  style: Halved.body(color: Halved.pine, weight: FontWeight.w700)),
            ),
        ]),
      );
}

BoxDecoration _cardBox() => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: Halved.cardBorder));

class _LiveRow extends StatelessWidget {
  final Map row;
  final VoidCallback onTap;
  const _LiveRow({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: _cardBox(),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                  color: Halved.deepPine, borderRadius: BorderRadius.circular(12)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('THRU',
                    style: TextStyle(
                        fontSize: 9,
                        color: Colors.white.withValues(alpha: .7),
                        fontWeight: FontWeight.w700)),
                Text('${row['thru']}',
                    style: _head(20, color: Halved.brightMint)),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row['title'] as String,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: _head(16)),
                Text(row['sub'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Halved.body(color: Halved.muted)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                  color: const Color(0xFFE1F2E8),
                  borderRadius: BorderRadius.circular(20)),
              child: Text('Watch ›',
                  style: Halved.body(color: Halved.pine, weight: FontWeight.w800)),
            ),
          ]),
        ),
      );
}

class _ComingRow extends StatelessWidget {
  final Map row;
  final VoidCallback onTap;
  const _ComingRow({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(14),
          decoration: _cardBox(),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row['title'] as String, style: _head(16)),
                Text(row['sub'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Halved.body(color: Halved.muted)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: const Color(0xFFE1F2E8),
                  borderRadius: BorderRadius.circular(20)),
              child: Text('In',
                  style: Halved.body(color: Halved.pine, weight: FontWeight.w800)),
            ),
          ]),
        ),
      );
}

class _RecentRow extends StatelessWidget {
  final Map row;
  final VoidCallback onTap;
  const _RecentRow({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final money = (row['money'] as num?)?.toDouble();
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: _cardBox(),
        child: Row(children: [
          SizedBox(
              width: 62,
              child: Text(row['date'] as String,
                  style: Halved.body(color: Halved.muted))),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(row['title'] as String,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: _head(16)),
              Text(
                  '${row['sub']}${row['gross'] != null ? ' · ${row['gross']}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Halved.body(color: Halved.muted)),
            ]),
          ),
          if (money != null && money != 0)
            Text(_signed(money),
                style: _head(16, color: money > 0 ? Halved.pine : Halved.owe)),
        ]),
      ),
    );
  }
}

String _signed(double v) {
  final n = v.abs();
  final s = n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(2);
  return '${v < 0 ? '−' : '+'}\$$s';
}

class _StatsCard extends StatelessWidget {
  final Map<String, dynamic> stats;
  const _StatsCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    if (stats['enough'] != true) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: _cardBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your stats start here', style: _head(18)),
          const SizedBox(height: 4),
          Text('Finish two rounds and your average, money and a bar for each '
              'round show up here.',
              style: Halved.body(color: Halved.muted)),
        ]),
      );
    }
    final rounds = (stats['rounds'] as List).cast<Map>();
    final money = (stats['money'] as num?)?.toDouble();
    final best = (stats['best'] as Map);
    final ntp = rounds.map((r) => (r['net_to_par'] as num).toDouble()).toList();
    final lo = ntp.reduce((a, b) => a < b ? a : b);
    final hi = ntp.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo) == 0 ? 1.0 : (hi - lo);
    String avg(num v) => v == 0 ? 'E' : (v > 0 ? '+$v' : '−${v.abs()}');

    Widget tile(String k, String v, String sub, {Color? vc}) => Expanded(
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Halved.surface, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k.toUpperCase(),
                  style: Halved.body(color: Halved.muted, weight: FontWeight.w700)),
              Text(v, style: _head(22, color: vc ?? Halved.deepPine)),
              Text(sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Halved.body(color: Halved.muted)),
            ]),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _cardBox(),
      child: Column(children: [
        Row(children: [
          tile('Avg net', avg(stats['avg_net'] as num), 'best ${best['label']}'),
          if (money != null)
            tile('Money', _signed(money), 'won ${stats['won']} of ${stats['count']}',
                vc: money >= 0 ? Halved.pine : Halved.owe),
          tile('Index', '${stats['index']}', 'current'),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 130,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < rounds.length; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text(rounds[i]['label'] as String,
                        style: Halved.body(weight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    // A better (lower) net to par is taller.
                    Container(
                      height: 22 + 44 * ((hi - ntp[i]) / span),
                      decoration: BoxDecoration(
                          color: rounds[i]['best'] == true
                              ? Halved.pine
                              : const Color(0xFFBFDCC6),
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    const SizedBox(height: 4),
                    Text(_short(rounds[i]['date'] as String),
                        style: Halved.body(color: Halved.muted)),
                  ]),
                ),
              ),
          ]),
        ),
        if ((stats['fact'] as String? ?? '').isNotEmpty) ...[
          const Divider(height: 22),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(stats['fact'] as String, style: Halved.body()),
          ),
        ],
      ]),
    );
  }

  static String _short(String d) {
    final dt = DateTime.tryParse(d);
    return dt == null ? d : '${const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ][dt.month - 1]} ${dt.day}';
  }
}

class _Dock extends StatelessWidget {
  final VoidCallback onRound, onTournament;
  const _Dock({required this.onRound, required this.onTournament});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: Halved.deepPine,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16))),
                  onPressed: onRound,
                  icon: const Icon(Icons.add),
                  label: const Text('New round'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Halved.pine,
                      side: const BorderSide(color: Halved.pine, width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16))),
                  onPressed: onTournament,
                  icon: const Icon(Icons.emoji_events_outlined),
                  label: const Text('New tournament'),
                ),
              ),
            ),
          ]),
        ),
      );
}

/// The home's skeleton: the same shape, grey blocks. Only on a first launch
/// that is slower than the hold.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    Widget block(double h) => Container(
        height: h,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
            color: const Color(0xFFE2EAE4),
            borderRadius: BorderRadius.circular(18)));
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: Halved.deepPine, borderRadius: BorderRadius.circular(11))),
        ]),
        const SizedBox(height: 14),
        block(230),
        block(70),
        block(70),
        block(200),
      ],
    );
  }
}
