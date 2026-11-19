import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/halved_marks.dart';
import '../widgets/index_sheet.dart';
import 'course_find_screen.dart';
import 'player_list_screen.dart';
import 'stats_screen.dart';

TextStyle _head(double size) => GoogleFonts.schibstedGrotesk(
    fontSize: size, fontWeight: FontWeight.w700, color: Halved.deepPine);

String initialsOf(String name) {
  final p = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (p.isEmpty) return '?';
  return (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase();
}

/// Opened from the avatar on the home. The two things golfers change most
/// (index, home course), a way into Your stats, and the account rows.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    context.read<AuthProvider>().client.getProfileSummary().then((s) {
      if (mounted) setState(() => _summary = s);
    }).catchError((_) {});
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _editIndex() async {
    final auth = context.read<AuthProvider>();
    final me = auth.player;
    if (me == null) return;
    final r = await showIndexSheet(
      context,
      name: me.name,
      currentStored: me.handicapIndex,
      owner: IndexOwner.you,
      myIndex: double.tryParse(me.handicapIndex),
    );
    if (r == null || r.stored == me.handicapIndex) return;
    final value = r.stored;
    try {
      auth.applyPlayer(
          await auth.client.updatePlayer(me.id, handicapIndex: value));
      if (mounted) setState(() {});
    } on ApiException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Could not save your index.');
    }
  }

  Future<void> _changeHome() async {
    final auth = context.read<AuthProvider>();
    final me = auth.player;
    if (me == null) return;
    final r = await Navigator.of(context).push<CourseFindResult>(
        MaterialPageRoute(builder: (_) => const CourseFindScreen()));
    if (r == null) return;
    try {
      auth.applyPlayer(
          await auth.client.updatePlayer(me.id, homeCourseId: r.course.id));
      if (mounted) setState(() {});
    } catch (_) {
      _snack('Could not update your home course.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthProvider>().player;
    final name = me?.name ?? '';
    final rounds = _summary?['rounds'];
    final since = _summary?['since'];
    final sub = [
      if (since != null) 'On Halved since $since',
      if (rounds != null) '$rounds round${rounds == 1 ? '' : 's'}',
    ].join(' · ');

    Widget card(List<Widget> rows) => Container(
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
    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
          child: Text(t.toUpperCase(),
              style: Halved.body(color: Halved.muted, weight: FontWeight.w800)),
        );
    Widget row(Widget lead, String title, String sub,
            {String? action, VoidCallback? onTap}) =>
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              lead,
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: _head(16)),
                  if (sub.isNotEmpty)
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Halved.body(color: Halved.muted)),
                ]),
              ),
              if (action != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                      color: const Color(0xFFE3F1E8),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(action,
                      style: Halved.body(color: Halved.pine, weight: FontWeight.w800)),
                )
              else
                const Icon(Icons.chevron_right, color: Halved.muted),
            ]),
          ),
        );
    Widget tile(Widget child, {bool dark = false}) => Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: dark ? Halved.deepPine : const Color(0xFFE3F1E8),
              borderRadius: BorderRadius.circular(12)),
          child: child,
        );

    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        centerTitle: true,
        title: Text('Profile', style: _head(20)),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Halved.cardBorder)),
          child: Row(children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: Halved.brightMint,
              child: Text(initialsOf(name), style: _head(22)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: _head(22)),
                if (sub.isNotEmpty)
                  Text(sub, style: Halved.body(color: Halved.muted)),
              ]),
            ),
          ]),
        ),
        label('Your game'),
        card([
          row(
              tile(
                  Text(me?.handicapIndex ?? '',
                      style: GoogleFonts.schibstedGrotesk(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Halved.brightMint)),
                  dark: true),
              'Handicap index',
              '',
              action: 'Edit',
              onTap: _editIndex),
          row(
              tile(const Text('⛳', style: TextStyle(fontSize: 20))),
              'Home course',
              (me?.homeCourseName.isNotEmpty ?? false)
                  ? me!.homeCourseName
                  : 'Not set — learned after a couple of rounds',
              action: 'Change',
              onTap: _changeHome),
          row(const StatsMark(size: 44),
              'Your stats', 'Scoring, money, games, courses, who you play',
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const StatsScreen()))),
        ]),
        label('Account'),
        card([
          row(tile(const Icon(Icons.mail_outline, color: Halved.pine)),
              'Mobile and email', me?.phone ?? '',
              onTap: () => Navigator.of(context).pushNamed('/settings')),
          row(tile(const Icon(Icons.notifications_none, color: Halved.pine)),
              'Notifications', 'Invites, tee times, receipts',
              onTap: () => Navigator.of(context).pushNamed('/settings')),
          row(tile(const Icon(Icons.groups_outlined, color: Halved.pine)),
              'My golfers', 'Regulars and everyone you play with',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PlayerListScreen()))),
        ]),
      ]),
    );
  }
}
