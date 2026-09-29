/// test/overflow_menu_test.dart
/// ---------------------------
/// **The watcher invite is reachable from both overflow menus, and no menu
/// item anywhere in the app is inert.**
///
/// "Invite a watcher" was only on the leaderboard's overflow, which is a
/// detour from score entry — the one screen a scorer is on all day. Adding it
/// there made it one action with two doors, and this is what stops the two
/// drifting apart or either one silently doing nothing.
///
/// Source-level, like `standing_row_coverage_test`, and for the same reason:
/// what is asserted is that a screen HAS an entry point. Nothing in the repo
/// pumps `ScoreEntryScreen` — 9k lines behind a wall of providers — so a
/// widget test would cover the newer of two copies of one action and leave
/// the older untested, which is the arrangement that produced the gap.
///
/// **The inert-item half is the general guard.** A `PopupMenuItem` whose
/// value no handler matches draws normally, highlights on tap and does
/// nothing: it cannot throw, cannot be caught by `analyze`, and looks exactly
/// like a working item. That is the failure mode a typo in a menu produces,
/// and it is the one this test exists to make loud.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `PopupMenuItem(value: 'x')`, allowing a type argument, an `enabled:` line
/// before the value, and the aligned `value  :` spelling this codebase uses.
///
/// Only STRING-literal values: `cup_round_setup_screen` builds
/// `PopupMenuItem<int>(value: t.id)` from the tee list, which is dispatched by
/// id rather than by a name and has nothing to be out of step with.
final _itemValue = RegExp(
    r"PopupMenuItem(?:<[^>]*>)?\(\s*(?:enabled\s*:[^,]*,\s*)?value\s*:\s*'([^']+)'");

final _anyItem = RegExp(r'PopupMenuItem(?:<[^>]*>)?\(');

/// Both dispatch styles in use. `switch` in the big screens, `if (v == 'x')`
/// in Sequoya 3s and the tournament list — checking only for `case` reported
/// those two as broken when they are fine, which is why both are here.
Iterable<String> _handled(String src) => [
      ...RegExp(r"case\s*'([^']+)'").allMatches(src).map((m) => m[1]!),
      ...RegExp(r"==\s*'([^']+)'").allMatches(src).map((m) => m[1]!),
    ];

/// Every file that draws an overflow menu, found rather than listed — a menu
/// added on a new screen tomorrow is in scope the day it is written.
List<File> _filesWithMenus() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => f.readAsStringSync().contains('PopupMenuButton'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  String read(String f) => File('lib/screens/$f').readAsStringSync();

  /// The two screens that offer the watcher invite. Both, always — the whole
  /// point is that it is not one place.
  const watcherScreens = [
    'score_entry_screen.dart',
    'leaderboard_screen.dart',
  ];

  group('invite a watcher', () {
    test('is offered on both the score-entry and leaderboard overflows', () {
      for (final f in watcherScreens) {
        final src = read(f);
        final values = _itemValue.allMatches(src).map((m) => m[1]!).toList();
        expect(values, contains('invite'),
            reason: '$f has no menu item offering the watcher invite');
        expect(_handled(src), contains('invite'),
            reason: '$f offers the item but nothing handles it');
        expect(src, contains('inviteWatcher('),
            reason: '$f handles the item but never opens the invite flow');
      }
    });

    test('the item is in the ONE overflow menu, not a second one', () {
      // What makes the test above meaningful: with exactly one
      // `PopupMenuButton` per file, an item declared in that file is an item
      // in that menu. A second menu could otherwise host `invite` and keep
      // this green while the overflow lost it.
      for (final f in watcherScreens) {
        expect(
            RegExp('PopupMenuButton').allMatches(read(f)).length, 1,
            reason: '$f now has more than one menu — this test can no longer '
                'tell which one carries the invite');
      }
    });

    test('reads the same on both, so it is one action and not two', () {
      // A golfer who learned it on the board must not have to recognise it
      // again on score entry. Same words, same glyph.
      for (final f in watcherScreens) {
        expect(read(f), contains("Text('Invite a watcher')"),
            reason: '$f words the invite differently');
        expect(read(f), contains('Icons.visibility_outlined'),
            reason: '$f draws the invite with a different glyph');
      }
    });
  });

  group('no menu item is inert', () {
    test('every popup value in the app has a handler', () {
      final broken = <String>[];
      for (final file in _filesWithMenus()) {
        final src = file.readAsStringSync();
        final handled = _handled(src).toSet();
        for (final v in _itemValue.allMatches(src).map((m) => m[1]!)) {
          if (!handled.contains(v)) {
            broken.add('${file.path}: value \'$v\' is never handled');
          }
        }
      }
      expect(broken, isEmpty,
          reason: 'these menu items draw and tap but do nothing:\n'
              '${broken.join('\n')}');
    });

    test('the scan actually reaches the menus it claims to', () {
      // A regex that matched nothing would make the test above vacuously
      // green. These are the counts as they stand; the numbers are not the
      // point, a scan that finds no items at all is.
      final files = _filesWithMenus();
      expect(files.length, greaterThanOrEqualTo(10),
          reason: 'expected to find the app\'s overflow menus');

      var items = 0, valued = 0;
      for (final file in files) {
        final src = file.readAsStringSync();
        items += _anyItem.allMatches(src).length;
        valued += _itemValue.allMatches(src).length;
      }
      expect(items, greaterThanOrEqualTo(30));
      // Every item but the tee picker's `PopupMenuItem<int>` is name-valued,
      // so the two counts track each other closely. A gap opening up means a
      // new spelling the value regex is walking straight past.
      expect(items - valued, lessThanOrEqualTo(1),
          reason: 'a PopupMenuItem is declared in a way the value scan does '
              'not recognise — it would be exempt from the check above');
    });
  });
}
