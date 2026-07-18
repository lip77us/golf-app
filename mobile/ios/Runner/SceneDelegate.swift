import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    // Cold-launch universal link handling.
    //
    // When the app is fully CLOSED and the user taps a watch link
    // (https://link.halved.golf/watch/<token>/), iOS launches the app and hands
    // the initiating NSUserActivity to `connectionOptions.userActivities` here —
    // NOT via `scene(_:continue:)`, which only fires when the app is already
    // running. Flutter's own deep linking is intentionally off
    // (FlutterDeepLinkingEnabled = NO in Info.plist) so the app_links plugin is
    // the single deep-link handler, but app_links only observes the warm
    // `continue` path. So a cold tap was being dropped and the app booted
    // straight to the rounds hub instead of the round's leaderboard.
    //
    // Re-dispatch the cold-launch web activity through that same `continue`
    // path, so app_links captures it as the initial link and DeepLinkService
    // opens the leaderboard. (Warm taps are unaffected — they never reach here.)
    if let userActivity = connectionOptions.userActivities.first(where: {
      $0.activityType == NSUserActivityTypeBrowsingWeb && $0.webpageURL != nil
    }) {
      self.scene(scene, continue: userActivity)
    }
  }
}
