// **The app must draw a first frame no matter what startup does.**
//
// Apple rejected 2.11.0 (48), Guideline 2.1(a): "when we launched the app It
// got frozen with a white screen", on an iPad Air running iPadOS 27.2.
//
// That is the shape of a `main()` that awaits before `runApp`. Nothing is
// drawn until every await returns, so one call that never returns is a frozen
// white screen — no crash, no error, nothing on screen to explain it. A
// `try/catch` does not help: it catches a throw, and a hang is not a throw.
// `PushService.initFirebase` was wrapped in one and awaited before the first
// frame, and this app has never once registered an iOS FCM token in
// production — so its behaviour on a fresh review device was precisely the
// unknown that could hold the UI hostage.
//
// Source-level, because the thing being asserted is the ORDER of statements
// in `main()`. Pumping the app proves nothing: the failure is a call that
// never returns, which a test would wait on exactly as the iPad did.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/main.dart').readAsStringSync();
  // The body of main(), which is where the ordering matters.
  final body = src.substring(src.indexOf('void main() async {'));

  group('startup cannot freeze the first frame', () {
    test('every pre-runApp await is timeboxed', () {
      final upToRunApp = body.substring(0, body.indexOf('runApp('));
      final bare = RegExp(r'^\s*await (?!_boot\()(.+);$', multiLine: true)
          .allMatches(upToRunApp)
          .map((m) => m[1]!.trim())
          .toList();
      expect(bare, isEmpty,
          reason: 'these run before the first frame with no timeout — any one '
              'of them hanging is the white screen Apple rejected:\n'
              '  ${bare.join('\n  ')}\n'
              'Wrap them in _boot(), which times out and carries on.');
    });

    test('_boot has a timeout and swallows the failure', () {
      expect(src, contains('.timeout('),
          reason: '_boot without a timeout is just an await');
      expect(src, contains('catch'),
          reason: 'a startup step that throws must not stop the app drawing');
    });

    test('Firebase is initialised AFTER runApp', () {
      // The likeliest thing to sit there, and not needed to draw a screen.
      expect(body.indexOf('runApp('),
          lessThan(body.indexOf('initFirebase')),
          reason: 'Firebase blocks the first frame again');
    });

    test('runApp is reached unconditionally', () {
      // No `if`, no `return` guarding it — the app always draws something.
      expect(RegExp(r'\n  runApp\(').hasMatch(body), isTrue,
          reason: 'runApp must sit at the top level of main(), not inside a '
              'branch that some device might not take');
    });
  });
}
