/// sync/sync_service.dart
///
/// Monitors network connectivity and drains the local pending-score queue
/// whenever the device is online.
///
/// Responsibilities
///   • Track whether the device currently has a network connection.
///   • Expose [pendingCount] so the UI can show an unsynced-score badge.
///   • [drainQueue] — attempt to submit every queued score to the API,
///     oldest first. Stops on a network error (will retry next time
///     connectivity is restored). Any other API error (4xx) is treated as
///     permanent and cleared from the queue to avoid infinite retries.
///   • Automatically calls [drainQueue] when connectivity is restored.
///
/// Wire-up
///   SyncService lives in the Provider tree (see main.dart). RoundProvider
///   receives a reference to it so it can call [enqueue] and read [isOnline].

import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../local/local_database.dart';

enum SyncState {
  idle,     // nothing pending or all synced
  pending,  // items queued, not yet attempting (offline)
  syncing,  // actively sending to server
  error,    // last attempt had a non-network failure
}

class SyncService extends ChangeNotifier {
  final LocalDatabase _db;
  ApiClient           _client;

  SyncService({required LocalDatabase db, required ApiClient client})
      : _db     = db,
        _client = client {
    _init();
  }

  // ── Public state ──────────────────────────────────────────────────────────

  bool      _isOnline    = false; // pessimistic default; _init() sets the real value
  int       _pendingCount = 0;
  SyncState _state       = SyncState.idle;

  bool      get isOnline     => _isOnline;
  int       get pendingCount => _pendingCount;
  SyncState get state        => _state;
  bool      get hasPending   => _pendingCount > 0;

  // ── Internals ─────────────────────────────────────────────────────────────

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _retryTimer;
  bool _draining = false;

  // Retry interval — short enough to feel responsive, long enough not to spam.
  static const _retryInterval = Duration(seconds: 15);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> _init() async {
    // Establish initial connectivity state
    final results = await Connectivity().checkConnectivity();
    _isOnline = _anyConnected(results);

    // Stream: connectivity_plus v6+ emits List<ConnectivityResult>
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final wasOffline = !_isOnline;
      _isOnline = _anyConnected(results);
      notifyListeners();

      // Back online — flush the queue
      if (wasOffline && _isOnline) {
        drainQueue();
      }
    });

    // Refresh badge and attempt initial sync
    await _refreshCount();
    if (_isOnline && _pendingCount > 0) {
      drainQueue();
    }
  }

  bool _anyConnected(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  // ── Called by RoundProvider when the auth token changes ──────────────────

  void updateClient(ApiClient client) {
    _client = client;
  }

  /// Re-check connectivity right now and drain if online.
  ///
  /// Call this when the user taps the sync badge or returns to a screen —
  /// covers cases where connectivity_plus missed the transition event.
  Future<void> recheck() async {
    // Don't call checkConnectivity() — it returns stale data on iOS and
    // causes _isOnline to flip incorrectly. The HTTP call in drainQueue is
    // the only reliable connectivity test: success → _isOnline=true,
    // NetworkException → _isOnline=false.
    if (_pendingCount > 0 && !_draining) {
      drainQueue();
    }
  }

  // ── Enqueue ───────────────────────────────────────────────────────────────

  /// Save a hole submission to the local queue and attempt an immediate sync.
  /// Returns instantly — the caller can treat the save as done.
  Future<void> enqueue({
    required int foursomeId,
    required int holeNumber,
    required List<Map<String, int>> scores,
    bool pinkBallLost = false,
  }) async {
    await _db.enqueueScore(
      foursomeId:   foursomeId,
      holeNumber:   holeNumber,
      scores:       scores,
      pinkBallLost: pinkBallLost,
    );
    await _refreshCount();

    if (_isOnline) {
      drainQueue(); // fire-and-forget
    } else {
      // Start the retry timer so we pick up the moment the server
      // is reachable again, even without a connectivity event.
      _scheduleRetry();
    }
  }

  // ── Drain ─────────────────────────────────────────────────────────────────

  /// Attempt to submit all pending scores to the API, oldest first.
  ///
  /// Design decisions:
  ///   • [NetworkException] → stop draining, leave items queued, try again
  ///     when connectivity returns.
  ///   • [ApiException] with 4xx status → permanent failure for that item;
  ///     remove it so we don't loop forever (a score the server rejects
  ///     can't be fixed by retrying).
  ///   • Only one drain runs at a time ([_draining] guard).
  Future<void> drainQueue() async {
    if (_draining) return;
    _draining = true;

    final pending = await _db.allPending();
    if (pending.isEmpty) {
      _draining = false;
      return;
    }

    _state = SyncState.syncing;
    notifyListeners();

    bool networkFailed = false;

    for (final item in pending) {
      // No _isOnline guard here — we let the HTTP call determine real
      // connectivity. A successful call proves we're online; a
      // NetworkException proves we're not. The platform flag can lag.
      try {
        await _client.submitScores(
          foursomeId:   item.foursomeId,
          holeNumber:   item.holeNumber,
          scores:       item.scores,
          pinkBallLost: item.pinkBallLost,
        );
        // Success — remove from queue and confirm we're online.
        await _db.deletePending(item.id);
        _isOnline = true;
      } on NetworkException {
        // Transient — stop and wait for next connectivity event.
        // Correct _isOnline: a real HTTP failure is more reliable than
        // the connectivity_plus interface-state report.
        await _db.incrementRetry(item.id);
        _isOnline = false;
        networkFailed = true;
        break;
      } on ApiException catch (e) {
        // Permanent server-side error (e.g. 400 bad request) — log and discard
        // so it doesn't block the rest of the queue.
        debugPrint(
          'SyncService: server rejected '
          'foursome=${item.foursomeId} hole=${item.holeNumber}: $e',
        );
        await _db.deletePending(item.id);
      }
    }

    await _refreshCount();

    _state = networkFailed
        ? (_pendingCount > 0 ? SyncState.pending : SyncState.idle)
        : SyncState.idle;

    _draining = false;
    notifyListeners();

    if (!networkFailed && _isOnline && _pendingCount > 0) {
      // Items enqueued mid-drain — run another pass immediately.
      drainQueue();
    } else if (networkFailed && _pendingCount > 0) {
      // Drain failed — start the retry timer so we pick up when server returns.
      _scheduleRetry();
    } else {
      // Queue empty — stop the timer.
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _refreshCount() async {
    _pendingCount = await _db.pendingCount();
    notifyListeners();
  }

  /// Start a repeating retry timer while there are pending items.
  /// Cancelled when the queue empties or the service is disposed.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(_retryInterval, (_) {
      if (_pendingCount == 0) {
        _retryTimer?.cancel();
        _retryTimer = null;
      } else if (!_draining) {
        drainQueue();
      }
    });
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }
}
