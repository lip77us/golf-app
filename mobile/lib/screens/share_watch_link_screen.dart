/// screens/share_watch_link_screen.dart
/// ------------------------------------
/// Preview the message, then send the watch link to a GROUP.
///
/// Paul, 11 Oct 2026: "Can I just jump to my text with the watch link... that
/// would allow me to send to a mix of halved users and non-halved users."
///
/// **A screen, not a share straight off the overflow menu.** The first
/// version shared from `PopupMenuButton.onSelected` and nothing happened at
/// all — no sheet, no error. Every other `Share.share` in the app is called
/// from a button on a screen, and `share_scorecard_screen` says why in its
/// own comment: iOS wants a non-zero source rect, and a popup menu that is
/// busy dismissing itself is not one. Paul pointed at that screen; this is
/// the same shape.
///
/// **The preview earns its place.** It is the same argument the scorecard
/// screen makes: what you are about to put in a group thread is worth seeing
/// first. Here it also answers the question the feature raises — what will
/// the people who are NOT on Halved get — which the sender cannot otherwise
/// know.
///
/// Nobody is recorded as a watcher by sending this. A Halved recipient is
/// filed by `WatchTokenResolveView` when they open the link; anyone else
/// reads the possession-gated web page. `inviteWatcher` is still the tool for
/// inviting one named spectator.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';

class ShareWatchLinkScreen extends StatefulWidget {
  final int? roundId;
  final int? tournamentId;
  const ShareWatchLinkScreen({super.key, this.roundId, this.tournamentId});

  @override
  State<ShareWatchLinkScreen> createState() => _ShareWatchLinkScreenState();
}

class _ShareWatchLinkScreenState extends State<ShareWatchLinkScreen> {
  bool _loading = true;
  bool _sharing = false;
  String? _error;
  String _text = '';
  String _url = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<AuthProvider>().client.getWatchLink(
            roundId: widget.roundId, tournamentId: widget.tournamentId);
      if (!mounted) return;
      setState(() {
        _url = (d['watch_url'] as String?) ?? '';
        _text = (d['share_text'] as String?) ?? _url;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  Future<void> _share() async {
    if (_sharing || _text.isEmpty) return;
    // Captured before any await, and the origin with it: iOS wants a
    // non-zero source rect for the sheet (and it is the iPad popover
    // anchor). See share_scorecard_screen, which learnt this first.
    final box = context.findRenderObject() as RenderBox?;
    final Rect? origin = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    setState(() => _sharing = true);
    try {
      await Share.share(_text, sharePositionOrigin: origin);
    } catch (e) {
      // Say something. Failing silently is what sent somebody back to say
      // "I press it and nothing happens".
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open the share sheet: $e')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const GolfAppBar(title: 'Send the watch link'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('They will get this',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    // The message as it will arrive, in something that reads
                    // like a message bubble rather than a form field.
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(_text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.4)),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Anyone can open it. Someone with Halved lands on the '
                      'live leaderboard; everyone else gets the web page, no '
                      'app needed — so one message covers the whole group.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.45),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _sharing ? null : _share,
                      icon: _sharing
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.ios_share),
                      label: const Text('Send it'),
                    ),
                    const SizedBox(height: 8),
                    // The fallback for a share sheet that will not cooperate,
                    // and for pasting somewhere that is not a message.
                    OutlinedButton.icon(
                      onPressed: _url.isEmpty
                          ? null
                          : () {
                              Clipboard.setData(ClipboardData(text: _text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Copied.')));
                            },
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy the message'),
                    ),
                  ],
                ),
    );
  }
}
