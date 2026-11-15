// The Groups screen has to be REACHABLE, which is the failure this repo keeps
// hitting: the casual receipt no round could open, the setup-edit button gated
// on the rule it replaced, and — found while building this one — a
// `_roundLevelEditTargets` entry for Multi-Group Skins that could never draw,
// because that list only renders on a single-foursome round and a pool is
// never one.
//
// A widget test would need the whole provider stack; what actually breaks is
// the wiring, so the wiring is what is checked.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('the hub can open it', () {
    test('round_screen pushes /round-groups', () {
      expect(_read('lib/screens/round_screen.dart'), contains("'/round-groups'"));
    });

    test('from the Multi-Group Skins card, not the single-foursome list', () {
      // The card is round-level and drawn once; the other list is inside a
      // foursome card behind `allFoursomes.length == 1`.
      final src = _read('lib/screens/round_screen.dart');
      final card = src.indexOf('if (hasMultiSkins && canManage)');
      final push = src.indexOf("'/round-groups'");
      final setupCard = src.indexOf("Text('Game Setup'");
      expect(card, isNonNegative);
      expect(push, greaterThan(card));
      expect(push, lessThan(setupCard),
          reason: 'the button has drifted out of the skins card');
    });

    test('main registers the route', () {
      final src = _read('lib/main.dart');
      expect(src, contains("case '/round-groups':"));
      expect(src, contains('RoundGroupsScreen('));
    });
  });

  group('the screen can do both jobs', () {
    final screen = _read('lib/screens/round_groups_screen.dart');

    test('it re-draws the groups through round setup', () {
      expect(screen, contains('setupRound('));
    });

    test('and adds a golfer through the endpoint that works mid-round', () {
      expect(screen, contains('addPlayerToRound('));
    });

    test('the client posts to the route the server serves', () {
      expect(_read('lib/api/client.dart'),
          contains("/rounds/\$roundId/add-player/"));
    });
  });
}
