/// The tournament director's Overview and Groups screens, and the one
/// function that moves between the Director bar's destinations.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/director_bar.dart';
import '../widgets/error_view.dart';
import '../widgets/round_start.dart' show teeShort;
import 'dream_round_setup_screen.dart';
import 'round_side_games_screen.dart';
import 'setup_round_players_screen.dart';
import 'tee_times_screen.dart';
import 'tournament_leaderboard_screen.dart';
import 'tournament_low_net_setup_screen.dart';
import 'tournament_list_screen.dart' show TournamentRoundRow;
import 'tournament_settlement_screen.dart';

TextStyle _head(double size, {Color color = Halved.deepPine}) =>
    GoogleFonts.schibstedGrotesk(
        fontSize: size, fontWeight: FontWeight.w700, color: color);

/// Move to a Director bar destination. [fromDirector] is true on the Overview
/// and Groups screens, which replace each other rather than stacking.
void directorGo(
  BuildContext context,
  DirectorTab tab, {
  required int tournamentId,
  required String tournamentName,
  required int roundId,
  required bool fromDirector,
}) {
  final nav = Navigator.of(context);
  void push(Widget w) => nav.push(MaterialPageRoute(builder: (_) => w));
  void show(Widget w) => fromDirector
      ? nav.pushReplacement(MaterialPageRoute(builder: (_) => w))
      : nav.push(MaterialPageRoute(builder: (_) => w));
  switch (tab) {
    case DirectorTab.round:
      nav.popUntil((r) => r.settings.name == '/round' || r.isFirst);
    case DirectorTab.overview:
      show(DirectorOverviewScreen(
          tournamentId: tournamentId, roundId: roundId));
    case DirectorTab.groups:
      show(DirectorGroupsScreen(
          tournamentId: tournamentId,
          tournamentName: tournamentName,
          roundId: roundId));
    case DirectorTab.teeTimes:
      push(TeeTimesScreen(roundId: roundId, tournamentName: tournamentName));
    case DirectorTab.formats:
      push(RoundSideGamesScreen(roundId: roundId));
    case DirectorTab.board:
      push(TournamentLeaderboardScreen(
          tournamentId: tournamentId, tournamentName: tournamentName));
    case DirectorTab.settle:
      push(TournamentSettlementScreen(
          tournamentId: tournamentId, tournamentName: tournamentName));
  }
}

class _DirectorTag extends StatelessWidget {
  final String text;
  const _DirectorTag(this.text);

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
              color: const Color(0xFFFBF0D6),
              borderRadius: BorderRadius.circular(18)),
          child: Text('★ ${text.toUpperCase()}',
              style: Halved.body(color: Halved.role, weight: FontWeight.w800)
                  .copyWith(letterSpacing: 0.6)),
        ),
      );
}

Widget _tile(IconData icon, String title, String sub, VoidCallback onTap,
        {String? action, Color? titleColor, Color? iconBg}) =>
    InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: iconBg ?? const Color(0xFFE3F1E8),
                borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: titleColor ?? Halved.pine),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: _head(16, color: titleColor ?? Halved.deepPine)),
              if (sub.isNotEmpty)
                Text(sub, style: Halved.body(color: Halved.muted)),
            ]),
          ),
          if (action != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(action,
                  style: Halved.body(
                      color: Halved.muted, weight: FontWeight.w700)),
            ),
          const Icon(Icons.chevron_right, color: Halved.muted),
        ]),
      ),
    );

Widget _card(List<Widget> rows) => Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Halved.cardBorder)),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: Halved.cardBorder),
          rows[i],
        ]
      ]),
    );

Widget _label(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
      child: Text(t.toUpperCase(),
          style: Halved.body(color: Halved.muted, weight: FontWeight.w800)),
    );

// ── Overview ─────────────────────────────────────────────────────────────────

class DirectorOverviewScreen extends StatefulWidget {
  final int tournamentId;
  final int roundId;
  const DirectorOverviewScreen(
      {super.key, required this.tournamentId, required this.roundId});

  @override
  State<DirectorOverviewScreen> createState() => _DirectorOverviewScreenState();
}

class _DirectorOverviewScreenState extends State<DirectorOverviewScreen> {
  Tournament? _t;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await context
          .read<AuthProvider>()
          .client
          .getTournament(widget.tournamentId);
      if (mounted) setState(() => _t = t);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _delete(Tournament t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete tournament?'),
        content: Text('Delete "${t.name}", all its rounds and every score? '
            'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Halved.warning),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AuthProvider>().client.deleteTournament(t.id);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final course = (t != null && t.rounds.isNotEmpty) ? t.rounds.first.courseName : '';
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        centerTitle: true,
        title: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t?.name ?? 'Tournament', style: _head(18)),
          if (t != null)
            Text('Director · $course',
                style: Halved.body(color: Halved.muted)),
        ]),
      ),
      bottomNavigationBar: DirectorBar(
        active: DirectorTab.overview,
        onTap: (tab) => directorGo(context, tab,
            tournamentId: widget.tournamentId,
            tournamentName: t?.name ?? '',
            roundId: widget.roundId,
            fromDirector: true),
      ),
      body: _error != null
          ? ErrorView(message: _error!, isNetwork: false, onRetry: _load)
          : t == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      children: _body(t)),
                ),
    );
  }

  List<Widget> _body(Tournament t) {
    final nav = Navigator.of(context);
    final offer = t.dreamRoundOffer['offer'] == true &&
        t.dreamRoundOffer['available'] == true;
    return [
      const _DirectorTag('You’re the director'),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Halved.cardBorder)),
        child: Column(children: [
          for (final r in t.rounds)
            TournamentRoundRow(
              round: r,
              isStaff: true,
              inPlay: r.status == 'in_progress' &&
                  r.date.startsWith(DateTime.now().toIso8601String().substring(0, 10)),
              onOpen: () => nav.pushNamed('/round', arguments: r.id),
              onSetup: () => nav
                  .push(MaterialPageRoute(
                      builder: (_) => SetupRoundPlayersScreen(roundId: r.id)))
                  .then((_) => _load()),
            ),
        ]),
      ),
      _label('Boards'),
      _card([
        if (t.activeGames.contains('low_net'))
          _tile(Icons.emoji_events_outlined, 'Stroke Play Championship',
              'Leaderboard · net and gross',
              () => nav.push(MaterialPageRoute(
                  builder: (_) => TournamentLowNetSetupScreen(tournamentId: t.id))),
              action: 'Configure'),
        if (offer)
          _tile(Icons.auto_awesome_outlined, 'Dream Round',
              'Best to par per hole across the rounds',
              () => nav
                  .push(MaterialPageRoute(
                      builder: (_) => DreamRoundSetupScreen(tournamentId: t.id)))
                  .then((_) => _load()),
              action: t.dreamRoundOffer['configured'] == true ? 'Configure' : 'Set up'),
        _tile(Icons.receipt_long_outlined, 'Settle up & receipts',
            t.rounds.length > 1 ? 'After the last round' : 'When the round is in',
            () => nav.push(MaterialPageRoute(
                builder: (_) => TournamentSettlementScreen(
                    tournamentId: t.id, tournamentName: t.name)))),
      ]),
      const SizedBox(height: 16),
      _card([
        _tile(Icons.delete_outline, 'Delete tournament',
            t.rounds.length > 1
                ? 'Removes all ${t.rounds.length} rounds and every score'
                : 'Removes the round and every score',
            () => _delete(t),
            titleColor: Halved.warning,
            iconBg: const Color(0xFFFBE3DC)),
      ]),
    ];
  }
}

// ── Groups ───────────────────────────────────────────────────────────────────

class DirectorGroupsScreen extends StatefulWidget {
  final int tournamentId;
  final String tournamentName;
  final int roundId;
  const DirectorGroupsScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
    required this.roundId,
  });

  @override
  State<DirectorGroupsScreen> createState() => _DirectorGroupsScreenState();
}

class _DirectorGroupsScreenState extends State<DirectorGroupsScreen> {
  Round? _round;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r =
          await context.read<AuthProvider>().client.getRound(widget.roundId);
      if (mounted) setState(() => _round = r);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  void _go(DirectorTab tab) => directorGo(context, tab,
      tournamentId: widget.tournamentId,
      tournamentName: widget.tournamentName,
      roundId: widget.roundId,
      fromDirector: true);

  Future<void> _courseHandicaps(Round r) async {
    final fs = await showModalBottomSheet<Foursome>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Whose handicaps?', style: _head(18)),
          ),
          for (final f in r.foursomes)
            ListTile(
              title: Text(f.label),
              subtitle: Text(f.realPlayers
                  .map((m) => m.player.name.split(' ').first)
                  .join(', ')),
              onTap: () => Navigator.pop(c, f),
            ),
        ]),
      ),
    );
    if (fs == null || !mounted) return;
    await Navigator.of(context).pushNamed('/confirm-tees', arguments: fs.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final r = _round;
    final golfers =
        r?.foursomes.fold<int>(0, (n, f) => n + f.realPlayers.length) ?? 0;
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        centerTitle: true,
        title: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('R${r?.roundNumber ?? ''} · Groups', style: _head(18)),
          Text(widget.tournamentName, style: Halved.body(color: Halved.muted)),
        ]),
      ),
      bottomNavigationBar:
          DirectorBar(active: DirectorTab.groups, onTap: _go),
      body: _error != null
          ? ErrorView(message: _error!, isNetwork: false, onRetry: _load)
          : r == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      const _DirectorTag('Director'),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12, left: 4),
                        child: Text(
                            '$golfers golfers · ${r.foursomes.length} groups'
                            '${r.canRegroup ? ' · groups can change until the first tee' : ''}',
                            style: Halved.body(color: Halved.muted)
                                .copyWith(fontSize: 15)),
                      ),
                      for (final f in r.foursomes) _groupCard(r, f),
                      const SizedBox(height: 4),
                      _card([
                        _tile(Icons.schedule, 'Tee times',
                            'Set the first group, the rest fill forward',
                            () => _go(DirectorTab.teeTimes)),
                        _tile(Icons.lock_outline, 'Course handicaps',
                            'Locked for golfers · only you change CH',
                            () => _courseHandicaps(r)),
                      ]),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                        child: Text(
                            'A round’s groups are locked once a group has '
                            'scored. Swap a no-show from the group’s own card.',
                            style: Halved.body(color: Halved.muted)),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _groupCard(Round r, Foursome f) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Halved.cardBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(f.label, style: _head(20)),
            if (teeShort(f.teeTime) != null) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Halved.cardBorder)),
                child: Text('🕘 ${teeShort(f.teeTime)}',
                    style: Halved.body(
                        color: Halved.deepPine, weight: FontWeight.w700)),
              ),
            ],
            const Spacer(),
            if (r.canRegroup)
              InkWell(
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(
                        builder: (_) => SetupRoundPlayersScreen(roundId: r.id)))
                    .then((_) => _load()),
                child: Text('Edit ›',
                    style: Halved.body(
                        color: Halved.pine, weight: FontWeight.w800)),
              ),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in f.realPlayers)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                    color: Halved.surface,
                    borderRadius: BorderRadius.circular(14)),
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: _short(m.player.name),
                      style: Halved.body(
                          color: Halved.deepPine, weight: FontWeight.w700)),
                  TextSpan(
                      text: ' ${m.courseHandicap}',
                      style: Halved.body(color: Halved.muted)),
                ])),
              ),
          ]),
        ]),
      );

  /// `Alan Pierce` → `Alan P.`
  String _short(String name) {
    final p = name.trim().split(RegExp(r'\s+'));
    return p.length < 2 ? name : '${p.first} ${p.last[0]}.';
  }
}
