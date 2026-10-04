/// test/cup_group_sizes_test.dart
/// ------------------------------
/// The TD's group-size override on a CUP round.
///
/// Reported during a 46-golfer Ryder Cup build-up: the TD wanted 11 foursomes
/// and a twosome and got 10 foursomes and two threesomes, with no control
/// anywhere to say otherwise. The editor existed — privately, inside
/// `new_round_wizard.dart`, a wizard the cup flow never enters, because a cup
/// ends at Review and hands round setup to `setup_round_players_screen.dart`.
///
/// Source-level for the wiring, like the other wizard guards: what is at risk
/// is a control that renders but posts nothing, which is the exact shape of
/// the bug being fixed.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/grouping.dart';

void main() {
  group('assignGroupNumbers — the client half of the slice', () {
    test('11 foursomes and a twosome is expressible for 46', () {
      final sizes = [...List.filled(11, 4), 2];
      expect(sizes.fold<int>(0, (a, b) => a + b), 46);

      final nos = assignGroupNumbers(46, sizes);
      expect(nos.length, 46);
      expect(nos.first, 1);
      expect(nos.last, 12, reason: 'the 46th golfer is in the twosome');
      // Every group holds exactly the size asked for.
      for (var g = 1; g <= 12; g++) {
        expect(nos.where((n) => n == g).length, sizes[g - 1],
            reason: 'group $g');
      }
    });

    test('it matches the auto-balance when handed the auto-balance', () {
      // 46 auto-balances to ten fours and two threes; feeding that back must
      // reproduce it, or the override path and the default path disagree.
      final auto = groupSizes(46);
      expect(auto, [...List.filled(10, 4), 3, 3]);
      final nos = assignGroupNumbers(46, auto);
      for (var g = 1; g <= auto.length; g++) {
        expect(nos.where((n) => n == g).length, auto[g - 1]);
      }
    });

    test('order is preserved — the TD decides who is in which group', () {
      // Positions are assigned in roster order, so reordering the roster is
      // what moves a golfer between groups.
      expect(assignGroupNumbers(9, [4, 3, 2]),
             [1, 1, 1, 1, 2, 2, 2, 3, 3]);
    });

    test('a short size list does not lose a golfer', () {
      // The editor refuses a total that does not match, but a dropped golfer
      // would be worse than a last group that runs long.
      expect(assignGroupNumbers(6, [2]), [1, 1, 1, 1, 1, 1]);
      expect(assignGroupNumbers(0, [4]), isEmpty);
      expect(assignGroupNumbers(3, const []), [1, 1, 1]);
    });
  });

  group('the cup setup screen is actually wired', () {
    final src =
        File('lib/screens/setup_round_players_screen.dart').readAsStringSync();

    test('it posts group_number, which is what the backend branches on', () {
      // `round_setup.py` takes the explicit-groups path on
      // `any('group_number' in p)`. Without this the screen could only ever
      // auto-balance — the reported bug.
      expect(src.contains("entry['group_number']"), isTrue);
      expect(src.contains('assignGroupNumbers('), isTrue);
    });

    test('it offers the editor, and the editor is the shared one', () {
      expect(src.contains('GroupSizeEditor('), isTrue);
      expect(src.contains("import '../widgets/group_size_editor.dart';"),
          isTrue);
      expect(src.contains('_GroupSizeEditor'), isFalse,
          reason: 'a private second copy is how the two flows drift apart');
    });

    test('a twosome is reachable: minSize 2 on a cup round', () {
      // 2 is not cosmetic — a Triple Cup twosome rebuilds to 1v1 and plays
      // three matches.
      expect(src.contains('minSize: 2'), isTrue);
    });

    test('omitting the override leaves the default path untouched', () {
      // The field is sent ONLY when the TD set sizes, so an untouched cup
      // round posts exactly what it always did.
      expect(src.contains('if (override != null) entry[\'group_number\']'),
          isTrue);
    });

    test('every roster change drops the override', () {
      // 11 fours and a two does not fit 45 golfers; a stale list would post a
      // total that no longer adds up.
      expect(src.contains('_dropSizeOverride()'), isTrue);
      expect(RegExp(r'_dropSizeOverride\(\)').allMatches(src).length,
          greaterThanOrEqualTo(5),
          reason: 'declaration + All + None + toggle + newly-created golfer');
    });
  });
}
