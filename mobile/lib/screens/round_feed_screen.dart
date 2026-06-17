/// screens/round_feed_screen.dart
///
/// The per-round message feed: a chronological mix of human chat and server
/// event cards (birdie, skin, lead change …). Compose box queues offline via
/// SyncService (see MessageProvider). Reached from the round screen, the
/// leaderboard, and a watcher's shared-round view.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/message_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/error_view.dart';

class RoundFeedScreen extends StatefulWidget {
  final int roundId;
  final String? title;

  const RoundFeedScreen({super.key, required this.roundId, this.title});

  @override
  State<RoundFeedScreen> createState() => _RoundFeedScreenState();
}

class _RoundFeedScreenState extends State<RoundFeedScreen> {
  final _composeCtrl = TextEditingController();
  final _scrollCtrl  = ScrollController();
  bool _sending = false;
  int  _lastCount = 0;
  MessageProvider? _mp; // captured so dispose() needn't touch a stale context

  @override
  void initState() {
    super.initState();
    // Defer until after the first frame so provider.notifyListeners() during
    // open() doesn't fire mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final mp = context.read<MessageProvider>();
      _mp = mp;
      await mp.open(widget.roundId);
      if (!mounted) return;
      _markReadAndScroll(mp);
    });
  }

  @override
  void dispose() {
    // Close the feed (stop polling) on the way out.
    _mp?.close();
    _composeCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _markReadAndScroll(MessageProvider mp) {
    if (mp.unread > 0) mp.markAllRead();
    _scrollToBottom();
  }

  void _scrollToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final max = _scrollCtrl.position.maxScrollExtent;
      if (animate) {
        _scrollCtrl.animateTo(max,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      } else {
        _scrollCtrl.jumpTo(max);
      }
    });
  }

  Future<void> _send() async {
    final text = _composeCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _composeCtrl.clear();
    await context.read<MessageProvider>().send(text);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollToBottom(animate: true);
  }

  @override
  Widget build(BuildContext context) {
    final mp = context.watch<MessageProvider>();

    // Auto-mark-read + auto-scroll when new messages arrive while we're open.
    final count = mp.messages.length;
    if (count != _lastCount) {
      _lastCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (mp.unread > 0) mp.markAllRead();
        _scrollToBottom(animate: true);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Round chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => mp.refresh(),
          ),
        ],
      ),
      body: Column(
        children: [
          const _OfflineBanner(),
          Expanded(child: _buildFeed(mp)),
          _Composer(
            controller: _composeCtrl,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }

  Widget _buildFeed(MessageProvider mp) {
    if (mp.loading && mp.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (mp.error != null && mp.messages.isEmpty) {
      return ErrorView(message: mp.error!, onRetry: () => mp.refresh());
    }
    if (mp.messages.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => mp.refresh(),
        child: ListView(
          children: const [
            SizedBox(height: 120),
            Icon(Icons.sms_outlined, size: 56, color: Colors.grey),
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'No messages yet. Say hello — everyone in this round (and any '
                'watchers) will see it here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }

    final msgs = mp.messages;
    return RefreshIndicator(
      onRefresh: () => mp.refresh(),
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        itemCount: msgs.length,
        itemBuilder: (_, i) {
          final m = msgs[i];
          if (m.isEvent) return _EventCard(message: m);
          final isMine = m.authorId != null && m.authorId == mp.myPlayerId;
          // Show the author label only when it changes from the previous
          // (non-event) message, to keep consecutive messages tidy.
          final prev = i > 0 ? msgs[i - 1] : null;
          final showAuthor = !isMine &&
              (prev == null || prev.isEvent || prev.authorId != m.authorId);
          return _ChatBubble(
            message: m,
            isMine: isMine,
            showAuthor: showAuthor,
          );
        },
      ),
    );
  }
}

// ── Offline banner ────────────────────────────────────────────────────────────

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final queued = sync.pendingMessageCount;
    if (sync.isOnline && queued == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = !sync.isOnline
        ? (queued > 0
            ? "You're offline — $queued message${queued == 1 ? '' : 's'} will "
                'send when you reconnect.'
            : "You're offline — messages will send when you reconnect.")
        : 'Sending $queued queued message${queued == 1 ? '' : 's'}…';
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(sync.isOnline ? Icons.sync : Icons.cloud_off,
              size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSecondaryContainer)),
          ),
        ],
      ),
    );
  }
}

// ── Chat bubble ───────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  final bool showAuthor;

  const _ChatBubble({
    required this.message,
    required this.isMine,
    required this.showAuthor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor =
        isMine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final textColor =
        isMine ? scheme.onPrimaryContainer : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showAuthor)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 2),
              child: Text(
                message.authorName ?? 'Someone',
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600),
              ),
            ),
          Align(
            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message.body, style: TextStyle(color: textColor)),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          DateFormat.jm().format(message.createdAt),
                          style: TextStyle(
                              fontSize: 10,
                              color: textColor.withValues(alpha: 0.6)),
                        ),
                        if (message.pending) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.schedule,
                              size: 11,
                              color: textColor.withValues(alpha: 0.6)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Event card ────────────────────────────────────────────────────────────────

class _EventCard extends StatelessWidget {
  final ChatMessage message;
  const _EventCard({required this.message});

  /// Pick an icon for the event type carried in `data['type']`. Stick to icons
  /// that are reliably present in the bundled Material font (no flutter_dash —
  /// its glyph is missing in this SDK and renders as a tofu box).
  IconData _iconFor(String? type) {
    switch (type) {
      case 'birdie':
      case 'eagle':
      case 'albatross':
      case 'hole_in_one':
        return Icons.celebration;
      case 'skin':
      case 'skin_won':
      case 'carryover':
        return Icons.attach_money;
      case 'match_result':
        return Icons.sports_golf;
      case 'lead_change':
      case 'leader':
      case 'front9':
        return Icons.trending_up;
      case 'withdrawal':
        return Icons.person_off;
      case 'round_started':
        return Icons.flag;
      case 'round_complete':
        return Icons.emoji_events;
      case 'score_report':
        return Icons.scoreboard_outlined;
      default:
        return Icons.campaign;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = message.data['type'] as String?;

    // The end-of-round gross recap renders as a small ranked table instead of
    // one long sentence.
    final players = message.data['players'];
    if (type == 'score_report' && players is List && players.isNotEmpty) {
      return _scoreReportCard(context, scheme, players);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_iconFor(type),
                size: 16, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message.body,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scoreReportCard(
      BuildContext context, ColorScheme scheme, List players) {
    final onColor = scheme.onTertiaryContainer;
    final dim = onColor.withValues(alpha: 0.7);

    Widget row(Widget left, Widget right) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: left),
            right,
          ]),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.scoreboard_outlined, size: 16, color: onColor),
              const SizedBox(width: 6),
              Text('Final scores',
                  style: TextStyle(
                      color: onColor, fontWeight: FontWeight.w700, fontSize: 13)),
              const Spacer(),
              Text('front-back-total',
                  style: TextStyle(color: dim, fontSize: 10)),
            ]),
            const SizedBox(height: 6),
            for (final p in players)
              row(
                Text((p['name'] ?? '') as String,
                    style: TextStyle(color: onColor, fontSize: 12.5),
                    overflow: TextOverflow.ellipsis),
                Text(
                  p['withdrew'] == true
                      ? 'WD'
                      : '${p['front']}-${p['back']}-${p['total']}',
                  style: TextStyle(
                      color: p['withdrew'] == true ? dim : onColor,
                      fontSize: 12.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Composer ──────────────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Message the group…',
                  counterText: '',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              icon: const Icon(Icons.send),
              onPressed: sending ? null : onSend,
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}
