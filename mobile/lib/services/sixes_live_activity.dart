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

  final ApiClient _client;

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
  /// [state] is the server's five slots — the same object the push carries, so
  /// the opening frame and every frame after it come from one place.
  Future<void> start({
    required int roundId,
    required String courseName,
    required Map<String, dynamic> state,
  }) async {
    if (_started.contains(roundId)) return;
    if (!await isSupported) return;
    try {
      await _channel.invokeMethod('start', {
        'roundId'   : roundId,
        'courseName': courseName,
        'state'     : jsonEncode(state),
      });
      _started.add(roundId);
    } on PlatformException catch (e) {
      // A lock-screen extra never breaks scoring. The round carries on.
      debugPrint('Live Activity start failed: ${e.message}');
    }
  }

  /// End it on round sign, with the one personal state — what you won and who
  /// to see. iOS dismisses it a few minutes later.
  Future<void> end({
    required int roundId,
    Map<String, dynamic>? finalState,
  }) async {
    if (!await isSupported) return;
    try {
      await _channel.invokeMethod('end', {
        'roundId': roundId,
        if (finalState != null) 'state': jsonEncode(finalState),
      });
    } on PlatformException catch (e) {
      debugPrint('Live Activity end failed: ${e.message}');
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
