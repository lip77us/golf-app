/// widgets/round_chat_button.dart
///
/// An app-bar chat icon for a round, with an unread-count badge. Reused on the
/// round screen, the leaderboard, and the shared-round view. It fetches the
/// unread count once on mount (and again when returning from the feed) via the
/// messages endpoint — independent of the MessageProvider so it works even when
/// the feed isn't open.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../screens/round_feed_screen.dart';

class RoundChatButton extends StatefulWidget {
  final int roundId;
  /// Shown as the feed screen's title (e.g. the course name).
  final String? title;

  const RoundChatButton({super.key, required this.roundId, this.title});

  @override
  State<RoundChatButton> createState() => _RoundChatButtonState();
}

class _RoundChatButtonState extends State<RoundChatButton> {
  int _unread = 0;
  Timer? _poll;

  // Chat has no push (in-app only by design), so the badge IS the notification.
  // Poll while mounted so a message that lands while you're sitting on the
  // scoring screen still lights up the badge. A tiny GET; gentle interval.
  static const _pollInterval = Duration(seconds: 25);

  @override
  void initState() {
    super.initState();
    _loadUnread();
    _poll = Timer.periodic(_pollInterval, (_) => _loadUnread());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadUnread() async {
    try {
      final res =
          await context.read<AuthProvider>().client.getMessages(widget.roundId);
      if (mounted) setState(() => _unread = res.unread);
    } on ApiException {
      // Best-effort badge — leave it as-is on any error (offline, 404, …).
    }
  }

  Future<void> _open() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          RoundFeedScreen(roundId: widget.roundId, title: widget.title),
    ));
    // The feed advances the read marker; refresh the badge on return.
    if (mounted) _loadUnread();
  }

  @override
  Widget build(BuildContext context) {
    final icon = IconButton(
      icon: const Icon(Icons.sms_outlined),
      tooltip: 'Round chat',
      onPressed: _open,
    );
    if (_unread <= 0) return icon;
    return Stack(
      alignment: Alignment.center,
      children: [
        icon,
        Positioned(
          right: 6,
          top: 6,
          child: Container(
            padding: const EdgeInsets.all(2),
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _unread > 99 ? '99+' : '$_unread',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onError,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
