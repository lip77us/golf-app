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
  /// A singleton, and it has to be.
  ///
  /// `setMethodCallHandler` replaces the handler for a channel NAME globally,
  /// so a second instance would silently steal every token callback from the
  /// first. One owner also matches what this actually is: the lock screen
  /// belongs to the session, not to whichever round happens to be open.
  static final SixesLiveActivity instance = SixesLiveActivity._();

  SixesLiveActivity._() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel('halved/sixes_live_activity');

  /// Null until a session exists. Every call below is a no-op without one —
  /// there is nowhere to register a token.
  ApiClient? _apiClient;

  ApiClient get _client => _apiClient ?? const ApiClient();

  /// The client is swapped when the auth token changes, same as SyncService.
  void updateClient(ApiClient client) => _apiClient = client;

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

  /// Start listening for the push-to-start token, and register it.
  ///
  /// This is what lets a golfer who is NOT entering scores get the board. An
  /// activity can only be started locally from the foreground, so before this
  /// the one man with a lock screen was the one holding the phone to score —
  /// the one who least needs it. The server addresses this token to raise a
  /// card on a phone that has done nothing.
  ///
  /// Call on sign-in and app start; it is idempotent on both sides. Returns
  /// false on anything below iOS 17.2, where push-to-start does not exist —
  /// those phones keep today's behaviour rather than losing anything.
  Future<bool> observeStartToken() async {
    // Narrated at every decision point. Each of these used to fail into a
    // silent catch, which made "iOS never issued a token" and "we never asked"
    // indistinguishable from the server side — and a release build has no
    // console unless the app says something out loud.
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;

    // Reported to the SERVER, not just printed. A release build's debugPrint
    // never reaches `flutter logs`, so the console is not a channel we have —
    // and every one of these outcomes otherwise looks identical from the
    // server: an absent row.
    Future<bool> report(String status, {bool ok = false}) async {
      debugPrint('[LA] $status');
      try {
        // `ok` doubles as "this is the healthy path" — armed and waiting on
        // iOS, which is normal, not a fault.
        await _client.reportLiveActivityStatus(status, waiting: ok);
      } catch (_) {}
      return ok;
    }

    try {
      final enabled = await _channel.invokeMethod<bool>('isSupported') ?? false;
      if (!enabled) {
        return report('Live Activities are OFF for Halved '
            '(Settings > Halved > Live Activities), or iOS < 16.2');
      }
      final armed =
          await _channel.invokeMethod<bool>('observeStartToken') ?? false;
      return armed
          ? await report('observers installed — waiting for iOS to issue a '
              'push-to-start token', ok: true)
          : await report('observers installed, but push-to-start is '
              'unavailable (needs iOS 17.2+)');
    } on MissingPluginException catch (e) {
      // NOT a PlatformException, so the original catch missed it entirely.
      return report('platform channel is not registered: $e');
    } on PlatformException catch (e) {
      return report('start-token observe failed: $e');
    }
  }

  /// Drop the push-to-start token. Called on sign-out: the token outlives a
  /// session, and a board raised on a phone whose owner has signed out is a
  /// stranger's match on a lock screen.
  Future<void> forgetStartToken() async {
    try {
      await _client.clearLiveActivityStartToken();
    } catch (e) {
      debugPrint('Live Activity start-token clear failed: $e');
    }
  }

  /// The native side pushes tokens up as iOS issues them, and again on every
  /// reissue. Two kinds arrive here:
  ///
  ///  * `pushToken` — addresses ONE running activity, so it is per round. Sent
  ///    for a card this phone started AND for one the server raised remotely;
  ///    without registering the latter, a remotely-started board would sit
  ///    frozen on the hole it arrived at.
  ///  * `pushToStartToken` — addresses the app itself, so it is not round
  ///    scoped. It is how the server reaches a phone with nothing running.
  Future<dynamic> _onNativeCall(MethodCall call) async {
    final args = call.arguments == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(call.arguments as Map);
    // The card died on the phone — swiped away, or ended by iOS. Drop the
    // server's copy of the token, or it goes on addressing an activity that is
    // not there, AND goes on counting this golfer as already carrying a board,
    // which blocks him from ever being sent another one for this round.
    if (call.method == 'activityEnded') {
      final roundId = args['roundId'] as int?;
      if (roundId == null) return null;
      _started.remove(roundId);
      await _forget(roundId);
      return null;
    }

    final token = args['token'] as String?;
    if (token == null) return null;

    switch (call.method) {
      case 'pushToken':
        final roundId = args['roundId'] as int?;
        if (roundId == null) return null;
        // A remote start is the first this side hears of the activity, so keep
        // the guard set true — otherwise a later score would start a second.
        _started.add(roundId);
        try {
          await _client.registerLiveActivityToken(
              roundId: roundId, token: token);
        } catch (e) {
          // Without the token the activity simply never updates remotely. It is
          // still correct as started, and the next round will try again.
          debugPrint('Live Activity token registration failed: $e');
        }
        return null;

      case 'pushToStartToken':
        debugPrint('[LA] iOS issued a push-to-start token — registering');
        try {
          await _client.registerLiveActivityStartToken(token: token);
          debugPrint('[LA] start token registered with the server');
        } catch (e) {
          debugPrint('[LA] start-token registration failed: $e');
        }
        return null;
    }
    return null;
  }
}
