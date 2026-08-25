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

      do {
        let state = try decodeState(stateJson)
        let attrs = SixesActivityAttributes(
          roundId: roundId,
          courseName: (args["courseName"] as? String) ?? ""
        )
        let activity = try Activity.request(
          attributes: attrs,
          content: .init(state: state, staleDate: nil),
          pushType: .token
        )
        // The token is what the server addresses its updates to, and it can be
        // reissued at any time — so this listens for the life of the activity
        // rather than reading it once.
        Task {
          for await data in activity.pushTokenUpdates {
            let token = data.map { String(format: "%02x", $0) }.joined()
            channel.invokeMethod("pushToken",
                                 arguments: ["roundId": roundId, "token": token])
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

    default:
      result(FlutterMethodNotImplemented)
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
