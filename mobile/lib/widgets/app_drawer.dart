import 'package:flutter/material.dart';
// Hide google_fonts' own `Config` — it collides with our app's Config.
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/client.dart';
import '../theme/halved_brand.dart';
import '../config.dart';
import '../providers/auth_provider.dart';
import '../api/models.dart';
import '../screens/profile_screen.dart';
import '../screens/stats_screen.dart';

/// The ☰ menu (handoff-home-menu): opens from the right, 316pt wide, over a
/// dimmed screen. Hosts pass it as an `endDrawer`.
///
/// The "you" row opens Profile, so Profile is not a line of its own. Counts
/// and pills that need data the host has ([liveRound], [tournamentsToday])
/// are passed in; the golfer count is fetched here.
class AppDrawer extends StatefulWidget {
  final String? playerName;
  /// Back to the home. Null on the home itself, which has no use for it.
  final VoidCallback? onHomeTap;
  final VoidCallback onTournamentsTap;
  final VoidCallback onCasualRoundsTap;
  final VoidCallback onPlayersTap;
  final VoidCallback onSettingsTap;
  final VoidCallback onLogout;
  /// A live round is on: Rounds wears a LIVE pill.
  final bool liveRound;
  /// Tournaments with a round today; 0 draws nothing.
  final int tournamentsToday;

  const AppDrawer({
    super.key,
    this.onHomeTap,
    required this.onTournamentsTap,
    required this.onCasualRoundsTap,
    required this.onPlayersTap,
    required this.onSettingsTap,
    required this.onLogout,
    this.playerName,
    this.liveRound = false,
    this.tournamentsToday = 0,
  });

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  int? _golfers;

  @override
  void initState() {
    super.initState();
    // Halved members only: a guest is not saved, and a count that included
    // people who cannot be reached would oversell the invite card below it.
    context.read<AuthProvider>().client.getPlayers().then((l) {
      if (mounted) setState(() => _golfers = l.where((p) => p.isOnApp).length);
    }).catchError((_) {});
  }

  void _close() => Navigator.of(context).pop();

  void _push(Widget page) {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _web(String url) async {
    Navigator.of(context).pop();
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final me = auth.player;
    return Drawer(
      width: 316,
      backgroundColor: Halved.surface,
      shape: const RoundedRectangleBorder(),
      child: Column(children: [
        _header(me),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            children: [
              _label('Your golf'),
              _card([
                _Row(
                    icon: Icons.flag_outlined,
                    title: 'Rounds',
                    trailing: widget.liveRound ? const _LivePill() : null,
                    onTap: widget.onCasualRoundsTap),
                _Row(
                    icon: Icons.emoji_events_outlined,
                    title: 'Tournaments',
                    trailing: widget.tournamentsToday > 0
                        ? _Muted('${widget.tournamentsToday} today')
                        : null,
                    onTap: widget.onTournamentsTap),
                _Row(
                    icon: Icons.groups_outlined,
                    title: 'My golfers',
                    trailing: _golfers == null ? null : _Muted('$_golfers'),
                    onTap: widget.onPlayersTap),
                _Row(
                    icon: Icons.bar_chart_rounded,
                    title: 'Your stats',
                    onTap: () => _push(const StatsScreen())),
              ]),
              const SizedBox(height: 12),
              _inviteCard(),
              _label('Halved'),
              _card([
                _Row(
                    icon: Icons.menu_book_outlined,
                    title: 'Games on Halved',
                    sub: 'Explore and learn how to play',
                    trailing: const Icon(Icons.open_in_new,
                        size: 18, color: Halved.muted),
                    onTap: () => _web('https://halved.golf/games/')),
                _Row(
                    icon: Icons.lightbulb_outline,
                    title: 'Suggest a game',
                    onTap: () {
                      final nav = Navigator.of(context);
                      nav.pop();
                      nav.pushNamed('/suggest-game');
                    }),
                _Row(
                    icon: Icons.help_outline,
                    title: 'Help & support',
                    onTap: () => _web('https://halved.golf/support')),
                // Support staff only — read-only cross-account round lookup.
                if (auth.isSupport)
                  _Row(
                      icon: Icons.support_agent_outlined,
                      title: 'Support: Open Round',
                      onTap: () {
                        final nav = Navigator.of(context);
                        nav.pop();
                        nav.pushNamed('/support-lookup');
                      }),
              ]),
              if (auth.isAdmin) ...[
                _label('Admin'),
                _card([
                  _Row(
                      icon: Icons.golf_course_outlined,
                      title: 'Manage courses',
                      trailing: const _AdminTag(),
                      onTap: () {
                        final nav = Navigator.of(context);
                        nav.pop();
                        nav.pushNamed('/manage-courses');
                      }),
                ]),
              ],
            ],
          ),
        ),
        _foot(),
      ]),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 16, 6, 8),
        child: Text(t.toUpperCase(),
            style: GoogleFonts.schibstedGrotesk(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.1,
                color: Halved.muted)),
      );

  Widget _card(List<Widget> rows) => Container(
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Halved.cardBorder)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: Halved.cardBorder),
            rows[i],
          ]
        ]),
      );

  /// Deep pine; the × sits alone top right and the "you" row below it, so
  /// nothing overlaps. The whole row opens Profile.
  Widget _header(PlayerProfile? me) {
    final top = MediaQuery.of(context).padding.top;
    final name = me?.name ?? widget.playerName ?? '';
    final course = me?.homeCourseName ?? '';
    const amber = Color(0xFFF2B860);
    Widget line;
    if (course.isEmpty) {
      line = _amber('Set your home course ›', amber);
    } else {
      line = Text(course,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.schibstedGrotesk(
              fontSize: 12, color: const Color(0xFFF3F1EA).withOpacity(.62)));
    }
    return Container(
      color: Halved.deepPine,
      padding: EdgeInsets.fromLTRB(16, top + 8, 16, 18),
      child: Column(children: [
        Align(
          alignment: Alignment.centerRight,
          child: InkResponse(
            onTap: _close,
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Color(0x14FFFFFF)),
              child: const Icon(Icons.close, size: 16, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 14),
        InkWell(
          onTap: () => _push(const ProfileScreen()),
          child: Row(children: [
            SizedBox(
              width: 52,
              height: 62,
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned(
                  top: 0,
                  left: 2,
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: Halved.brightMint,
                    child: Text(initialsOf(name),
                        style: GoogleFonts.schibstedGrotesk(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Halved.deepPine)),
                  ),
                ),
                if ((me?.handicapIndex ?? '').isNotEmpty)
                  Positioned(
                    bottom: 0,
                    left: 4,
                    right: 4,
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8)),
                      child: Text(me!.handicapIndex,
                          style: GoogleFonts.schibstedGrotesk(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Halved.deepPine)),
                    ),
                  ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.schibstedGrotesk(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFFF3F1EA))),
                    const SizedBox(height: 2),
                    line,
                  ]),
            ),
            Text('Profile ›',
                style: GoogleFonts.schibstedGrotesk(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Halved.brightMint)),
          ]),
        ),
      ]),
    );
  }

  Widget _amber(String text, Color amber) => Row(children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: amber, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.schibstedGrotesk(
                  fontSize: 12, fontWeight: FontWeight.w600, color: amber)),
        ),
      ]);

  /// Golfers not on Halved are guests for one round only and aren't saved, so
  /// the menu keeps a standing reason to invite them.
  Widget _inviteCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Halved.pine, width: 1.5)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Halved.brightMint),
            child: const Icon(Icons.add_comment_outlined,
                size: 18, color: Halved.deepPine),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Get your group on Halved',
                      style: GoogleFonts.schibstedGrotesk(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Halved.pine)),
                  const SizedBox(height: 3),
                  Text(
                      'Every skin, press and dollar, live on their phone. '
                      'And the receipt, so nobody argues on 18.',
                      style: Halved.body(color: Halved.muted)
                          .copyWith(fontSize: 12)),
                  const SizedBox(height: 10),
                  Builder(
                    builder: (btn) => FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Halved.brightMint,
                          foregroundColor: Halved.deepPine,
                          shape: const StadiumBorder(),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8)),
                      onPressed: () {
                        // Capture before popping: the context is gone after.
                        final auth = context.read<AuthProvider>();
                        final messenger = ScaffoldMessenger.of(context);
                        final origin = shareOriginFrom(btn);
                        Navigator.of(context).pop();
                        shareInvite(auth, messenger, origin: origin);
                      },
                      child: Text('Text an invite',
                          style: GoogleFonts.schibstedGrotesk(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
          ),
        ]),
      );

  Widget _foot() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
          child: Row(children: [
            InkWell(
              onTap: widget.onLogout,
              child: Row(children: [
                const Icon(Icons.logout, size: 18, color: Color(0xFFA04A2A)),
                const SizedBox(width: 8),
                Text('Sign out',
                    style: GoogleFonts.schibstedGrotesk(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFA04A2A))),
              ]),
            ),
            const Spacer(),
            Text('Halved ${Config.appVersion} · ',
                style: Halved.body(color: Halved.muted).copyWith(fontSize: 12)),
            InkWell(
              onTap: () => _web('https://halved.golf/privacy'),
              child: Text('Privacy',
                  style: Halved.body(color: Halved.muted).copyWith(
                      fontSize: 12, decoration: TextDecoration.underline)),
            ),
          ]),
        ),
      );
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? sub;
  final Widget? trailing;
  final VoidCallback onTap;
  const _Row(
      {required this.icon,
      required this.title,
      required this.onTap,
      this.sub,
      this.trailing});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: sub == null ? 14 : 10),
          child: Row(children: [
            Icon(icon, size: 20, color: Halved.pine),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: GoogleFonts.schibstedGrotesk(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Halved.deepPine)),
                    if (sub != null)
                      Text(sub!,
                          style: Halved.body(color: Halved.muted)
                              .copyWith(fontSize: 12)),
                  ]),
            ),
            if (trailing != null) trailing!,
          ]),
        ),
      );
}

class _Muted extends StatelessWidget {
  final String text;
  const _Muted(this.text);
  @override
  Widget build(BuildContext context) =>
      Text(text, style: Halved.body(color: Halved.muted));
}

class _LivePill extends StatelessWidget {
  const _LivePill();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
            color: Halved.brightMint, borderRadius: BorderRadius.circular(10)),
        child: Text('LIVE',
            style: GoogleFonts.schibstedGrotesk(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: Halved.deepPine)),
      );
}

class _AdminTag extends StatelessWidget {
  const _AdminTag();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: const Color(0xFFFBF1DA),
            borderRadius: BorderRadius.circular(6)),
        child: Text('ADMIN',
            style: GoogleFonts.schibstedGrotesk(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF8A6D1F))),
      );
}

/// The anchor rect from a tapped widget's render box, for the iOS share-sheet
/// popover (`sharePositionOrigin`). iOS *requires* a non-zero rect or it throws
/// "sharePositionOrigin: argument must be set". Compute this BEFORE popping the
/// drawer (while the widget is still laid out); null if unavailable.
Rect? shareOriginFrom(BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(Offset.zero) & box.size;
  }
  return null;
}

/// Fetches the caller's personal invite link and opens the native share sheet
/// so they can text it to friends from their own phone (TCPA / App Store safe).
/// Provider + messenger are passed in (captured before the drawer popped) to
/// avoid using a deactivated BuildContext across the await.  [origin] anchors
/// the iOS share popover (see [shareOriginFrom]).
Future<void> shareInvite(
  AuthProvider auth,
  ScaffoldMessengerState messenger, {
  Rect? origin,
  String? inviteeName,
}) async {
  try {
    final info = await auth.client.getInvite();
    final name = inviteeName?.trim() ?? '';
    final text = name.isEmpty
        ? info.shareText
        : '$name, join me on Halved — the easiest way to track our golf '
          'bets. ${info.url}';
    try {
      await Share.share(
        text,
        subject: 'Join me on Halved',
        // iOS needs a valid, non-zero anchor; fall back to a 1×1 rect if the
        // caller couldn't supply one (it's only the popover anchor on iPad —
        // iPhone shows a bottom sheet regardless).
        sharePositionOrigin: origin ?? const Rect.fromLTWH(0, 0, 1, 1),
      );
    } catch (e) {
      // The link was fetched fine; only the share sheet failed (e.g. the
      // native plugin isn't registered after a hot reload — cold-restart the
      // app). Surface the real error and the link so it's still usable.
      messenger.showSnackBar(
        SnackBar(content: Text('Share unavailable ($e). Link: ${info.url}')),
      );
    }
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not create your invite link: $e')),
    );
  }
}

/// Shows an About dialog that displays the local app version and fetches
/// the server version for comparison.
void showAppAboutDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => _AboutDialog(),
  );
}

class _AboutDialog extends StatefulWidget {
  @override
  State<_AboutDialog> createState() => _AboutDialogState();
}

class _AboutDialogState extends State<_AboutDialog> {
  String? _serverVersion;
  bool    _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchServerVersion();
  }

  Future<void> _fetchServerVersion() async {
    try {
      final data = await const ApiClient().getVersion();
      if (mounted) {
        setState(() {
          _serverVersion = data['server_version'] as String?;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return AlertDialog(
      title: const Text('Halved'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('App version: ',
                style: TextStyle(fontWeight: FontWeight.w500)),
            Text(Config.appVersion),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            const Text('Server version: ',
                style: TextStyle(fontWeight: FontWeight.w500)),
            if (_loading)
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(_serverVersion ?? '—'),
          ]),
          if (auth.account != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Text('Account: ',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              Flexible(child: Text(auth.account!.name,
                  overflow: TextOverflow.ellipsis)),
            ]),
          ],
          if (auth.player != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Text('Signed in as: ',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              Flexible(child: Text(auth.player!.name,
                  overflow: TextOverflow.ellipsis)),
            ]),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
