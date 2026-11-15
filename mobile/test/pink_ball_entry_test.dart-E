// A tournament group that has the ball game AND scores on Stroke Play or
// Stableford enters on the shared screen — with the rotation sheet reachable
// from there. Before this the hub sent every group with `pink_ball` to the old
// `/pink-ball` screen, so the tray's carrier badge and lost-ball switch could
// not be reached by them at all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/widgets/pink_ball_order_sheet.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('the hub', () {
    final src = _read('lib/screens/round_screen.dart');

    test('only sends a ball round to /pink-ball when the round has no scoring game',
        () {
      expect(src.contains("fsGames.contains('pink_ball') &&\n"
          '                        round.scoringGame == null &&\n'
          "                        !fsGames.contains('low_net_round') &&\n"
          "                        !fsGames.contains('stableford')"),
          isTrue);
    });
  });

  group('score entry', () {
    final src = _read('lib/screens/score_entry_screen.dart');

    test('opens the rotation on the first tee and offers it in a banner', () {
      expect(src.contains('_maybeOpenPinkBallOrder();'), isTrue);
      expect(src.contains('_pinkBallBanner(ctx, rp),'), isTrue);
      expect(src.contains('openPinkBallOrder(context,'), isTrue);
    });

    test('an unset order is the only thing that prompts', () {
      final i = src.indexOf('void _maybeOpenPinkBallOrder()');
      final body = src.substring(i, src.indexOf('Future<void> _openPinkBallOrder'));
      expect(body.contains('fs.hasAnyScore'), isTrue);
      expect(body.contains('_pinkOrderOwed(rp)'), isTrue);
    });

    test('a Stableford round carries the ball marks too', () {
      final i = src.indexOf('StrokePlayHoleCard? _sideGameMarks');
      final body = src.substring(i, src.indexOf('bool _pinkOrderPrompted'));
      expect(body.contains('rp.stablefordHole(_selectedHole)'), isTrue);
    });
  });

  group('who owns the entry', () {
    test('Stroke Play beats the ball game as the primary', () {
      expect(primaryGameOf(['pink_ball', 'low_net_round']),
          GameIds.strokePlay);
      expect(primaryGameOf(['low_net_round', 'pink_ball']),
          GameIds.strokePlay);
    });
    test('Stableford does too', () {
      expect(primaryGameOf(['pink_ball', 'stableford']), GameIds.stableford);
    });
    test('a ball-only round still has the ball as its primary', () {
      expect(primaryGameOf(['pink_ball']), GameIds.pinkBall);
    });
  });

  group('the locked count', () {
    // The count is a function of scored holes, so it is pure enough to pin.
    test('nothing scored locks nothing', () {
      expect(pinkBallLockedCount(const [], null), 0);
    });
  });

  test('the old screen shares the sheet instead of owning a copy', () {
    final src = _read('lib/screens/pink_ball_screen.dart');
    expect(src.contains('class _OrderSetupSheet'), isFalse);
    expect(src.contains('PinkBallOrderSheet('), isTrue);
  });
}
