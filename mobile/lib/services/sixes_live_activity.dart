/// services/sixes_live_activity.dart
/// --------------------------------
/// The Dart side of the Sixes lock screen
/// (docs/design-review/handoff-sixes-lock/SPEC.md).
///
/// The app's job is **start, hand over the push token, and end**. It does not
/// compute the board and it does not update it hole by hole: the server owns
/// the five slots and APNs delivers them, because the other three golfers'
/// phones have to move when any one of them posts a score.
///
/// **It starts on the first score posted**, not at the tee time. That buys back
/// the half hour in the car park and on the range against the eight-hour iOS
/// cap, and an abandoned round never leaves a ghost on a lock screen.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';

class SixesLiveActivity {
  SixesLiveActivity(this._client) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel('halved/sixes_live_activity');

  ApiClient _client;

  /// The client is swapped when the auth token changes, same as SyncService.
  void updateClient(ApiClient client) => _client = client;

  /// Rounds this device has already started an activity for, so a second score
  /// on the same round does not ask again. The native side is also idempotent;
  /// this just saves the round trip.
  final Set<int> _started = {};

  /// True only on an iOS build new enough, with the user's Live Activities
  /// switched on. Everything below is a no-op otherwise — Android included.
  Future<bool> get isSupported async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Start the activity for [roundId], if this round is a Sixes round and one
  /// is not already running.
  ///
  /// The opening frame is fetched here rather than passed in, so that every
  /// call site is one fire-and-forget line and the server stays the only place
  /// that knows what the five slots say.  A round that is not eligible answers
  /// with nothing and no activity starts.
  Future<void> start({required int roundId}) async {
    if (_started.contains(roundId)) return;
    if (!await isSupported) return;

    // Claim the round before the await, so two scores landing together cannot
    // both get past the guard and raise two activities for one round.
    _started.add(roundId);
    try {
      final frame = await _client.getLiveActivityState(roundId: roundId);
      if (frame == null) {
        _started.remove(roundId);
        return;
      }
      await _channel.invokeMethod('start', {
        'roundId'    : roundId,
        'courseName' : frame['course_name'] ?? '',
        'state'      : jsonEncode(frame['state']),
        // How long this frame stays believable. The server owns the number so
        // the opening frame and every push after it agree.
        'staleAfter' : frame['stale_after_seconds'],
      });
    } catch (e) {
      // A lock-screen extra never breaks scoring. The round carries on, and
      // the next score posted tries again.
      _started.remove(roundId);
      debugPrint('Live Activity start failed: $e');
    }
  }

  /// End it on round sign, with the one personal state — what you won and who
  /// to see. iOS dismisses it a few minutes later.
  ///
  /// Deliberately NOT gated on [_started]: that set is in-memory, so after an
  /// app restart mid-round it is empty while the activity is still on the lock
  /// screen.  The native side finds it by round id, and finds nothing when
  /// there is nothing — which is the honest answer either way.
  Future<void> end({required int roundId}) async {
    if (!await isSupported) return;
    try {
      final frame = await _client.getLiveActivityState(roundId: roundId,
                                                       isFinal: true);
      await _channel.invokeMethod('end', {
        'roundId': roundId,
        if (frame != null) 'state': jsonEncode(frame['state']),
      });
    } catch (e) {
      debugPrint('Live Activity end failed: $e');
    } finally {
      _started.remove(roundId);
      await _forget(roundId);
    }
  }

  /// Tear every activity down. Used when a round stops being a Sixes round —
  /// Sixes needs exactly four, and a player dropping makes the whole
  /// composition wrong.
  Future<void> endAll() async {
    if (!await isSupported) return;
    try {
      await _channel.invokeMethod('endAll');
    } on PlatformException {
      // Nothing to do — there is no state to leave inconsistent.
    } finally {
      final rounds = _started.toList();
      _started.clear();
      for (final roundId in rounds) {
        await _forget(roundId);
      }
    }
  }

  /// Drop the server's copy of the token. A push to an ended activity is
  /// discarded by APNs, so this only saves the work — it is never load-bearing,
  /// and a failure here is not worth surfacing.
  Future<void> _forget(int roundId) async {
    try {
      await _client.clearLiveActivityToken(roundId: roundId);
    } catch (e) {
      debugPrint('Live Activity token clear failed: $e');
    }
  }

  /// The native side pushes the activity's APNs token up as it is issued, and
  /// again whenever iOS reissues it.
  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method != 'pushToken') return null;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final roundId = args['roundId'] as int?;
    final token = args['token'] as String?;
    if (roundId == null || token == null) return null;
    try {
      await _client.registerLiveActivityToken(roundId: roundId, token: token);
    } catch (e) {
      // Without the token the activity simply never updates remotely. It is
      // still correct as started, and the next round will try again.
      debugPrint('Live Activity token registration failed: $e');
    }
    return null;
  }
}
