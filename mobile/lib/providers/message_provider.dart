/// providers/message_provider.dart
///
/// Drives the per-round message feed (chat + server event cards).
///
/// Offline-first, mirroring [RoundProvider]:
///   • [open]   — load the cached thread instantly, then catch up from the
///                server and start a light poll while the feed is on screen.
///   • [send]   — never fails: the message is queued in [LocalDatabase] via
///                [SyncService] and shown immediately as an optimistic
///                "sending…" bubble. SyncService delivers it (and retries on
///                reconnect); when the server copy arrives the optimistic
///                bubble is replaced.
///   • [markAllRead] — advance the read marker so the unread badge clears.
///
/// The feed shown to the UI ([messages]) is the server thread (cached or live)
/// with any still-queued outbound messages appended. The provider is global
/// but holds one round at a time — [open] switches rounds, [close] clears.

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../local/local_database.dart';
import '../sync/sync_service.dart';

class MessageProvider extends ChangeNotifier {
  ApiClient           _client;
  final LocalDatabase _localDb;
  final SyncService   _sync;

  MessageProvider(this._client, this._localDb, this._sync) {
    _sync.addListener(_onSyncChanged);
  }

  /// Called by ProxyProvider when the auth token changes.
  void updateClient(ApiClient client) => _client = client;

  @override
  void dispose() {
    _sync.removeListener(_onSyncChanged);
    _poll?.cancel();
    super.dispose();
  }

  // ── State ───────────────────────────────────────────────────────────────────

  int?    _roundId;
  /// Confirmed server messages (oldest first), keyed for incremental sync.
  List<ChatMessage> _serverMessages = [];
  /// Outbound messages still queued locally (optimistic "sending…" bubbles).
  List<ChatMessage> _pendingMessages = [];
  int?    _myPlayerId;
  int     _unread = 0;
  bool    _loading = false;
  String? _error;

  int?    get roundId    => _roundId;
  int?    get myPlayerId => _myPlayerId;
  int     get unread     => _unread;
  bool    get loading    => _loading;
  String? get error      => _error;

  /// The feed for the UI: confirmed server messages followed by any queued
  /// outbound ones (which always sort last — they're the newest).
  List<ChatMessage> get messages =>
      [..._serverMessages, ..._pendingMessages];

  /// Highest confirmed server id we hold (for `since=` catch-up).
  int get _highestServerId =>
      _serverMessages.isEmpty ? 0 : _serverMessages.last.id;

  Timer? _poll;
  int    _lastSyncPending = 0;
  static const _pollInterval = Duration(seconds: 12);

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Begin showing the feed for [roundId]: load the cache, fetch from the
  /// server, then poll while on screen. Safe to call again for the same round
  /// (just refreshes); switching rounds resets state.
  Future<void> open(int roundId) async {
    if (_roundId != roundId) {
      _roundId        = roundId;
      _serverMessages = [];
      _pendingMessages = [];
      _unread         = 0;
      _error          = null;
      _lastSyncPending = _sync.pendingMessageCount;
      // Show whatever we cached last time, instantly.
      final cached = await _localDb.getCachedMessages(roundId);
      if (cached != null) {
        _serverMessages =
            cached.map((m) => ChatMessage.fromJson(m)).toList();
      }
      notifyListeners();
    }
    await _refreshPending();
    await refresh();
    _startPolling();
  }

  /// Stop polling and drop the active round (call from the screen's dispose).
  void close() {
    _poll?.cancel();
    _poll = null;
    _roundId = null;
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) {
      if (_roundId != null) refresh(silent: true);
    });
  }

  // ── Loading ───────────────────────────────────────────────────────────────

  /// Fetch new messages from the server (incremental via `since=`) and merge.
  /// [silent] suppresses the loading spinner / error surfacing for the
  /// background poll. Falls back to cache on a network error.
  Future<void> refresh({bool silent = false}) async {
    final rid = _roundId;
    if (rid == null) return;

    if (!silent) {
      _loading = true;
      notifyListeners();
    }
    try {
      final res = await _client.getMessages(rid, since: _highestServerId);
      _myPlayerId = res.myPlayerId ?? _myPlayerId;
      if (res.messages.isNotEmpty) {
        _mergeServer(res.messages);
        await _localDb.cacheMessages(
            rid, _serverMessages.map((m) => m.toCacheJson()).toList());
      }
      _unread = res.unread;
      _error  = null;
    } on NetworkException catch (e) {
      // Offline — keep showing the cache; surface the error only on an
      // explicit (non-silent) load with nothing to show.
      if (!silent && _serverMessages.isEmpty) _error = e.message;
    } on ApiException catch (e) {
      if (!silent) _error = e.message;
    } finally {
      _loading = false;
      await _refreshPending();
      notifyListeners();
    }
  }

  /// Merge a batch of server messages, de-duping by id (the poll can overlap a
  /// just-confirmed send).
  void _mergeServer(List<ChatMessage> incoming) {
    final byId = {for (final m in _serverMessages) m.id: m};
    for (final m in incoming) {
      byId[m.id] = m;
    }
    _serverMessages = byId.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  // ── Sending ─────────────────────────────────────────────────────────────────

  /// Queue an outbound message. Never throws — it's persisted locally and
  /// delivered by [SyncService]. Shows up immediately as a "sending…" bubble.
  Future<void> send(String body) async {
    final rid = _roundId;
    final text = body.trim();
    if (rid == null || text.isEmpty) return;
    await _sync.enqueueMessage(roundId: rid, body: text);
    _lastSyncPending = _sync.pendingMessageCount;
    await _refreshPending();
    notifyListeners();
  }

  /// Rebuild the optimistic-bubble list from the local outbound queue.
  Future<void> _refreshPending() async {
    final rid = _roundId;
    if (rid == null) {
      _pendingMessages = [];
      return;
    }
    final queued = await _localDb.pendingMessagesForRound(rid);
    _pendingMessages = queued
        .map((p) => ChatMessage(
              // Negative synthetic id keeps optimistic bubbles distinct from
              // (and sorted after) server ids; they're always the newest.
              id:        -p.id,
              kind:      'user',
              authorId:  _myPlayerId,
              body:      p.body,
              createdAt: p.createdAt,
              pending:   true,
            ))
        .toList();
  }

  // ── Read state ──────────────────────────────────────────────────────────────

  /// Advance the read marker to the newest confirmed message so the unread
  /// badge clears. No-op offline (the marker re-advances on next refresh).
  Future<void> markAllRead() async {
    final rid = _roundId;
    if (rid == null) return;
    final lastId = _highestServerId;
    if (lastId <= 0) {
      _unread = 0;
      notifyListeners();
      return;
    }
    _unread = 0;
    notifyListeners();
    try {
      _unread = await _client.markMessagesRead(rid, lastId);
      notifyListeners();
    } on ApiException {
      // Offline / transient — local badge already cleared; the server marker
      // re-syncs on the next successful refresh.
    }
  }

  // ── Sync reactions ────────────────────────────────────────────────────────

  void _onSyncChanged() {
    if (_roundId == null) return;
    final current = _sync.pendingMessageCount;
    if (current == _lastSyncPending) return;
    final drained = current < _lastSyncPending;
    _lastSyncPending = current;
    // Queue changed (a message was just delivered or newly enqueued) — refresh
    // the optimistic bubbles, and when one drained pull the confirmed server
    // copy so the "sending…" bubble is replaced by the real message.
    _refreshPending().then((_) {
      notifyListeners();
      if (drained) refresh(silent: true);
    });
  }
}
