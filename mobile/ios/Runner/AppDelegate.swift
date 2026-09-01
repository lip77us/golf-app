import ActivityKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  /// The Sixes lock screen (docs/design-review/handoff-sixes-lock/SPEC.md).
  ///
  /// The app's whole job here is **start, hand over the push token, and end**.
  /// It does not compute the board and it does not update it hole by hole —
  /// the server owns the five slots and APNs delivers them, because the other
  /// three golfers' phones have to move when any one of them posts a score.
  private static let channelName = "halved/sixes_live_activity"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerSixesChannel(with: engineBridge.pluginRegistry)
  }

  private func registerSixesChannel(with registry: FlutterPluginRegistry) {
    guard let messenger = registry.registrar(forPlugin: "SixesLiveActivity")?.messenger()
    else { return }

    let channel = FlutterMethodChannel(name: AppDelegate.channelName,
                                       binaryMessenger: messenger)

    // At LAUNCH, not when Dart gets around to asking.
    //
    // iOS background-launches the app when a push starts a Live Activity,
    // precisely so it can observe the new activity and hand back the token
    // that lets the server address it. That launch is brief. Waiting for
    // Flutter to boot, restore a session and call in would miss it — and
    // missing it is not a small loss: the card appears and then never moves,
    // for exactly the golfer this feature exists for, the one whose phone
    // stays in his pocket all round.
    //
    // Anything produced before Dart is listening is buffered, not dropped.
    if #available(iOS 16.2, *) { self.installObservers(channel) }

    channel.setMethodCallHandler { [weak self] call, result in
      guard #available(iOS 16.2, *) else {
        // The app supports iOS 15; Live Activities start at 16.1 and the
        // staleDate this uses at 16.2. Below that the feature simply is not
        // there — Dart asks and gets an honest no, rather than a crash.
        result(FlutterError(code: "unsupported",
                            message: "Live Activities need iOS 16.2",
                            details: nil))
        return
      }
      self?.handle(call, result: result, channel: channel)
    }
  }

  @available(iOS 16.2, *)
  private func handle(_ call: FlutterMethodCall,
                      result: @escaping FlutterResult,
                      channel: FlutterMethodChannel) {
    switch call.method {

    case "isSupported":
      result(ActivityAuthorizationInfo().areActivitiesEnabled)

    case "start":
      guard let args = call.arguments as? [String: Any],
            let roundId = args["roundId"] as? Int,
            let stateJson = args["state"] as? String
      else { return result(argumentError()) }

      // One activity per round. Sixes is the game with news, so if the group is
      // also running skins, skins does not get one — and a second start for the
      // same round is a no-op rather than a duplicate on the lock screen.
      if currentActivity(for: roundId) != nil { return result(nil) }

      // Past this, iOS flips context.isStale and the card fades and says so.
      // Every push carries a fresh one, so the clock only runs out when the
      // group has genuinely stopped scoring.
      let staleDate = (args["staleAfter"] as? Int).map {
        Date.now.addingTimeInterval(TimeInterval($0))
      }

      do {
        let state = try decodeState(stateJson)
        let attrs = SixesActivityAttributes(
          roundId: roundId,
          courseName: (args["courseName"] as? String) ?? ""
        )
        let activity = try Activity.request(
          attributes: attrs,
          content: .init(state: state, staleDate: staleDate),
          pushType: .token
        )
        // The token is what the server addresses its updates to, and it can be
        // reissued at any time — so this listens for the life of the activity
        // rather than reading it once.
        Task {
          for await data in activity.pushTokenUpdates {
            let token = data.map { String(format: "%02x", $0) }.joined()
            AppDelegate.send(channel, "pushToken",
                             ["roundId": roundId, "token": token])
          }
        }
        result(activity.id)
      } catch {
        result(FlutterError(code: "start_failed",
                            message: error.localizedDescription, details: nil))
      }

    case "end":
      guard let args = call.arguments as? [String: Any],
            let roundId = args["roundId"] as? Int
      else { return result(argumentError()) }

      guard let activity = currentActivity(for: roundId) else { return result(nil) }
      Task {
        // The final state is the one personal thing — what you won and who to
        // see — and it holds a few minutes before dismissing itself.
        let finalState: SixesActivityAttributes.ContentState
        if let json = args["state"] as? String,
           let decoded = try? decodeState(json) {
          finalState = decoded
        } else {
          finalState = activity.content.state
        }
        await activity.end(.init(state: finalState, staleDate: nil),
                           dismissalPolicy: .after(.now.addingTimeInterval(5 * 60)))
        result(nil)
      }

    case "endAll":
      // Used when a round converts away from Sixes — a player dropping leaves
      // three, and the whole composition is wrong. Ending is honest; switching
      // game would silently change what the lock screen is reporting.
      Task {
        for activity in Activity<SixesActivityAttributes>.activities {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
        result(nil)
      }

    case "observeStartToken":
      // Two observers, installed once, that between them let a phone which has
      // done nothing carry the board.
      //
      //  * pushToStartTokenUpdates gives the server an address to raise a card
      //    at.  iOS 17.2+; below that this answers false and the phone keeps
      //    today's behaviour — a board if it scores, nothing if it doesn't.
      //  * activityUpdates catches a card the SERVER started.  Without it that
      //    card would never move: its update token is only offered through the
      //    activity object, and nothing on this phone ever asked for one.
      installObservers(channel)          // idempotent; already run at launch
      AppDelegate.flush(channel)
      if #available(iOS 17.2, *) {
        result(ActivityAuthorizationInfo().areActivitiesEnabled)
      } else {
        result(false)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Guards against a second registration stacking a duplicate stream — Dart
  /// calls this on every sign-in, not only the first.
  private static var observing = false

  @available(iOS 16.2, *)
  private func installObservers(_ channel: FlutterMethodChannel) {
    guard !AppDelegate.observing else { return }
    AppDelegate.observing = true

    if #available(iOS 17.2, *) {
      Task {
        for await data in Activity<SixesActivityAttributes>
                            .pushToStartTokenUpdates {
          let token = data.map { String(format: "%02x", $0) }.joined()
          AppDelegate.send(channel, "pushToStartToken", ["token": token])
        }
      }
    }

    // Activities that ALREADY exist when we begin observing.
    //
    // `activityUpdates` only yields activities that start FROM NOW ON — it does
    // not replay what is already running. A card raised by a push while the app
    // was not running is therefore invisible to it forever, so that card hands
    // its token over never, and the board paints once and freezes on whatever
    // hole it arrived at. Which is worse than no board: it reads as broken
    // rather than absent.
    for existing in Activity<SixesActivityAttributes>.activities {
      observeToken(existing, channel)
    }

    // ...and the ones that start while we are alive.
    Task {
      for await activity in Activity<SixesActivityAttributes>.activityUpdates {
        // One card per round, enforced here because it cannot be enforced at
        // the source: a start push is addressed to the app, not to an
        // activity, so the server cannot see what is already on the lock
        // screen and iOS raises a second card rather than replacing the first.
        // The local `start` path has its own guard; this is the remote one.
        // Keep the newest and end the rest — the newest carries the freshest
        // frame, and the server is about to address it.
        let roundId = activity.attributes.roundId
        for stale in Activity<SixesActivityAttributes>.activities
        where stale.attributes.roundId == roundId && stale.id != activity.id {
          Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        observeToken(activity, channel)
      }
    }
  }

  /// Report one activity's push token, now and on every reissue — and report
  /// when it dies.
  ///
  /// The current token is sent up front rather than waited for: for an activity
  /// that started before this app process did, `pushTokenUpdates` has already
  /// delivered its first value to nobody.
  @available(iOS 16.2, *)
  private func observeToken(_ activity: Activity<SixesActivityAttributes>,
                            _ channel: FlutterMethodChannel) {
    let roundId = activity.attributes.roundId
    if let data = activity.pushToken {
      let token = data.map { String(format: "%02x", $0) }.joined()
      AppDelegate.send(channel, "pushToken", ["roundId": roundId, "token": token])
    }
    Task {
      for await data in activity.pushTokenUpdates {
        let token = data.map { String(format: "%02x", $0) }.joined()
        AppDelegate.send(channel, "pushToken",
                         ["roundId": roundId, "token": token])
      }
    }
    // Tell the server when this card dies — swiped away, or ended by iOS.
    //
    // Without this the server holds a token addressing an activity that no
    // longer exists. It is not merely a wasted push: the token is also how the
    // server decides who is ALREADY carrying a card, so a dead one silently
    // blocks that golfer from ever being sent another board for this round.
    // Dismiss the card once and the round goes dark for you.
    Task {
      for await state in activity.activityStateUpdates {
        if state == .ended || state == .dismissed {
          AppDelegate.send(channel, "activityEnded", ["roundId": roundId])
          break
        }
      }
    }
  }

  /// Tokens produced before Dart set its handler.  A dropped one is a board
  /// that never updates, so they wait rather than vanish.
  private static var pending: [(String, [String: Any])] = []
  private static var dartReady = false

  /// Flutter method channels must be touched on the platform thread; these
  /// callbacks all arrive on a Task's own executor.
  private static func send(_ channel: FlutterMethodChannel,
                           _ method: String,
                           _ arguments: [String: Any]) {
    DispatchQueue.main.async {
      if dartReady {
        channel.invokeMethod(method, arguments: arguments)
      } else {
        pending.append((method, arguments))
      }
    }
  }

  /// Dart has a handler installed — deliver anything that arrived first.
  private static func flush(_ channel: FlutterMethodChannel) {
    DispatchQueue.main.async {
      dartReady = true
      let queued = pending
      pending = []
      for (method, arguments) in queued {
        channel.invokeMethod(method, arguments: arguments)
      }
    }
  }

  @available(iOS 16.2, *)
  private func currentActivity(for roundId: Int) -> Activity<SixesActivityAttributes>? {
    Activity<SixesActivityAttributes>.activities
      .first { $0.attributes.roundId == roundId }
  }

  @available(iOS 16.2, *)
  private func decodeState(_ json: String)
    throws -> SixesActivityAttributes.ContentState {
    try JSONDecoder().decode(SixesActivityAttributes.ContentState.self,
                             from: Data(json.utf8))
  }

  private func argumentError() -> FlutterError {
    FlutterError(code: "bad_args", message: "Missing roundId or state", details: nil)
  }
}
