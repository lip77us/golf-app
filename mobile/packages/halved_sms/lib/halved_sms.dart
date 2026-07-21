/// halved_sms
///
/// The native message composer, pre-addressed and pre-filled.
///
/// Replaces the `flutter_sms` package. That package works, but it never adopted
/// Swift Package Manager, and after the rest of the plugins moved across it was
/// the only thing left holding CocoaPods into the iOS build. Flutter also warns
/// that a plugin without SPM support "will become an error in a future
/// version". The behaviour we actually depended on is two functions, so owning
/// them costs less than carrying a build system for them.
///
/// The contract deliberately matches what the app already relied on:
///
/// * iOS presents `MFMessageComposeViewController` as a sheet OVER Halved. The
///   user taps Send or Cancel themselves — we cannot send on their behalf, by
///   design — and dismissing returns them to Halved with no app switch. This is
///   why `url_launcher`'s `sms:` scheme was rejected: it leaves the app.
/// * The body is handed over natively, so it needs no URL-encoding, which is
///   what made the `sms:` route fragile for messages containing links.
/// * Nothing here reports whether a message was actually SENT. iOS does tell us,
///   but the app never needed it and treating "composer opened" as success
///   keeps the two platforms honest about the same thing.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('us.lipkin.halved/sms');

/// Whether this device can send text messages at all.
///
/// False on the Simulator, on an iPad without Messages, and on anything with no
/// SMS-capable SIM. Callers use it to decide whether to offer a text or fall
/// back to showing the link — so a false answer is a normal outcome, not an
/// error. Any platform failure answers false for the same reason.
Future<bool> canSendSms() async {
  try {
    return await _channel.invokeMethod<bool>('canSendSms') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Open the composer addressed to [recipients], with [message] pre-filled.
///
/// Returns true once the composer has been presented and dismissed, false if it
/// could not be shown. It does NOT mean a message was sent: the user may have
/// cancelled, which is a legitimate thing to do and not a failure worth
/// reporting differently.
///
/// Throws nothing — callers treat this as best-effort.
Future<bool> sendSms({
  required String message,
  required List<String> recipients,
}) async {
  try {
    final ok = await _channel.invokeMethod<bool>('sendSms', {
      'message': message,
      'recipients': recipients,
    });
    return ok ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
