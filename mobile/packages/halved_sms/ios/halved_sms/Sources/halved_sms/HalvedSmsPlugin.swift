import Flutter
import MessageUI
import UIKit

/// Presents the system message composer over Halved.
///
/// `MFMessageComposeViewController` is the whole reason this plugin exists in
/// preference to `url_launcher`'s `sms:` scheme: it appears as a sheet ON TOP of
/// Halved, so sending or cancelling returns the user straight back to where they
/// were. The `sms:` route switches to Messages and leaves them to find their own
/// way back, and it requires URL-encoding a body that routinely contains a link.
///
/// We never send anything. The composer is the user's — they press Send, or they
/// don't. iOS gives no way to send silently, which is correct.
public class HalvedSmsPlugin: NSObject, FlutterPlugin {

  /// The presented composer's delegate. UIKit holds only a weak reference to
  /// it, so without this the delegate is deallocated the moment the method
  /// returns and the sheet can never report a result — it just hangs there.
  private var pendingDelegate: ComposerDelegate?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "us.lipkin.halved/sms",
      binaryMessenger: registrar.messenger())
    let instance = HalvedSmsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall,
                     result: @escaping FlutterResult) {
    switch call.method {
    case "canSendSms":
      result(MFMessageComposeViewController.canSendText())

    case "sendSms":
      guard MFMessageComposeViewController.canSendText() else {
        // Simulator, an iPad with no Messages, no SMS-capable SIM. A normal
        // answer, not an error — the caller falls back to showing the link.
        result(false)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let message = args["message"] as? String,
        let recipients = args["recipients"] as? [String]
      else {
        result(FlutterError(code: "bad_args",
                            message: "message and recipients are required",
                            details: nil))
        return
      }
      presentComposer(message: message, recipients: recipients, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentComposer(message: String,
                               recipients: [String],
                               result: @escaping FlutterResult) {
    guard let presenter = Self.topViewController() else {
      result(false)
      return
    }

    let composer = MFMessageComposeViewController()
    composer.body = message          // handed over natively — no URL-encoding
    composer.recipients = recipients

    let delegate = ComposerDelegate { [weak self] in
      self?.pendingDelegate = nil
      // True means "the composer ran", not "a message was sent". The user is
      // entitled to cancel, and the caller has no business treating that
      // differently from sending — either way we did our part.
      result(true)
    }
    pendingDelegate = delegate
    composer.messageComposeDelegate = delegate

    presenter.present(composer, animated: true, completion: nil)
  }

  /// The view controller currently on screen.
  ///
  /// Walks past anything already presented (an open sheet, an alert) so the
  /// composer doesn't try to present from a controller that is itself covered —
  /// which UIKit refuses, leaving nothing on screen and no error the user can
  /// make sense of. The invite flows run from bottom sheets, so this is the
  /// normal case here, not an edge one.
  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first

    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

/// Dismisses the composer and reports back exactly once.
private class ComposerDelegate: NSObject, MFMessageComposeViewControllerDelegate {
  private var onFinished: (() -> Void)?

  init(onFinished: @escaping () -> Void) {
    self.onFinished = onFinished
  }

  func messageComposeViewController(
    _ controller: MFMessageComposeViewController,
    didFinishWith result: MessageComposeResult
  ) {
    controller.dismiss(animated: true) { [weak self] in
      // Nil it first: a FlutterResult invoked twice is a hard crash, and this
      // delegate outlives the callback by however long dismissal takes.
      let callback = self?.onFinished
      self?.onFinished = nil
      callback?()
    }
  }
}
