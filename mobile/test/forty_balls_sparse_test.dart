/// test/forty_balls_sparse_test.dart
/// --------------------------------
/// **Sparse 40 Balls: a subset of the GROUPS.**
///
/// A sixty-player event run on paper in another system can still have a
/// 40 Balls side game between four of its fifteen groups. 40 Balls ranks
/// groups, so a subset here is a subset of the groups — where the skins
/// pool's subset is of the golfers.
///
/// Two things are worth pinning rather than the chrome: the POOL follows the
/// selection (it is the money, and a table set against the wrong field is how
/// a TD ends up paying the difference), and the ball picker does not come up
/// for a group that is not playing.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/client.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/providers/auth_provider.dart';
import 'package:golf_mobile/screens/forty_balls_setup_screen.dart';
import 'package:golf_mobile/widgets/forty_balls_board.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _group(int id, int n, String players,
        {bool inPool = true, int size = 4}) =>
    {
      'foursome_id': id,
      'group_number': n,
      'size': size,
      'budget': size * 10,
      'in_pool': inPool,
      'label': 'Group $n',
      'players': players,
    };

const _rosters = [
  'Ann Smith, Bea Jones, Cal Brown, Dee White',
  'Eve Black, Fay Green, Gus Grey, Hal Stone',
  'Ivy Reed, Jon Shaw, Kay Boyd, Lee Nash',
  'Mae Ford, Ned Hart, Oly Page, Pat Wood',
];

/// Serves a four-group round and records the POST.
class _SpyClient extends ApiClient {
  _SpyClient({this.inPool = const [true, true, true, true]})
      : super(token: 't');
  final List<bool> inPool;
  Map<String, dynamic>? posted;

  List<Map<String, dynamic>> get _groups => [
        for (var i = 0; i < 4; i++)
          _group(10 + i, i + 1, _rosters[i], inPool: inPool[i]),
      ];

  @override
  Future<Map<String, dynamic>> getFortyBallsSetup(int roundId) async => {
        'groups': _groups,
        'num_players': 4 * inPool.where((v) => v).length,
        'n_in_pool': inPool.where((v) => v).length,
        'sparse': inPool.contains(false),
        'scoring_locked': false,
        'scoring_lock_note': '',
        'configured': false,
        'handicap_mode': 'net',
        'net_percent': 100,
        'net_max_double_bogey': true,
        'entry_fee': 10,
        'payouts': const [],
      };

  @override
  Future<Map<String, dynamic>> postFortyBallsSetup(
    int roundId, {
    required String handicapMode,
    required int netPercent,
    required bool netMaxDoubleBogey,
    required double entryFee,
    required List<Map<String, dynamic>> payouts,
    List<int>? groupIds,
  }) async {
    posted = {'group_ids': groupIds, 'entry_fee': entryFee};
    return getFortyBallsSetup(roundId);
  }
}

class _FakeAuth extends AuthProvider {
  _FakeAuth(this._c);
  final ApiClient _c;
  @override
  ApiClient get client => _c;
}

Future<void> _pump(WidgetTester tester, _SpyClient c) async {
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ChangeNotifierProvider<AuthProvider>.value(
      value: _FakeAuth(c),
      child: const FortyBallsSetupScreen(roundId: 1),
    ),
  ));
  await tester.pumpAndSettle();
}

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('the groups card', () {
    testWidgets('one tickable row per group, named in full', (t) async {
      final c = _SpyClient();
      await _pump(t, c);
      expect(find.text('Which groups are playing'), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(4));
      // **Full names.** `Group 7` alone tells a TD nothing about which of
      // fifteen groups he is ticking.
      expect(find.text(_rosters[0]), findsOneWidget);
      expect(find.text(_rosters[3]), findsOneWidget);
    });

    testWidgets('it counts them in the header', (t) async {
      await _pump(t, _SpyClient(inPool: const [true, false, true, false]));
      expect(find.text('2 of 4'), findsOneWidget);
    });

    testWidgets('a left-out group reads not playing, not 40 balls',
        (t) async {
      await _pump(t, _SpyClient(inPool: const [true, false, true, true]));
      expect(find.text('not playing'), findsOneWidget);
      expect(find.text('40 balls'), findsNWidgets(3));
    });

    testWidgets('unticking one drops it out', (t) async {
      final c = _SpyClient();
      await _pump(t, c);
      await t.tap(find.byType(Checkbox).first);
      await t.pump();
      expect(find.text('3 of 4'), findsOneWidget);
    });

    testWidgets('All groups and None', (t) async {
      await _pump(t, _SpyClient(inPool: const [true, false, false, false]));
      expect(find.text('1 of 4'), findsOneWidget);
      await t.tap(find.text('All groups'));
      await t.pump();
      expect(find.text('4 of 4'), findsOneWidget);
      await t.tap(find.text('None'));
      await t.pump();
      expect(find.text('0 of 4'), findsOneWidget);
    });
  });

  group('the pool follows the selection', () {
    testWidgets('sixteen golfers at ten is a hundred and sixty', (t) async {
      await _pump(t, _SpyClient());
      expect(find.text('Pool: \$160'), findsOneWidget);
    });

    testWidgets('and two groups is eighty, before anything is saved',
        (t) async {
      // The whole point of computing it on the client: the TD is still
      // ticking, so a figure read off the payload would be the old pool.
      await _pump(t, _SpyClient());
      await t.tap(find.byType(Checkbox).at(0));
      await t.tap(find.byType(Checkbox).at(1));
      await t.pump();
      expect(find.text('Pool: \$80'), findsOneWidget);
    });

    testWidgets('the entry line names the pool count, not the field',
        (t) async {
      await _pump(t, _SpyClient(inPool: const [true, true, false, false]));
      expect(find.text('\$10 × 8'), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('two groups is the floor, and the button says so', (t) async {
      final c = _SpyClient(inPool: const [true, false, false, false]);
      await _pump(t, c);
      expect(find.text('Pick at least two groups'), findsOneWidget);
    });

    testWidgets('a narrowing is sent as the list', (t) async {
      final c = _SpyClient();
      await _pump(t, c);
      await t.tap(find.byType(Checkbox).at(3));
      await t.pump();
      await t.tap(find.text('Save game'));
      await t.pumpAndSettle();
      expect((c.posted!['group_ids'] as List).toSet(), {10, 11, 12});
    });

    testWidgets('the whole field is sent as an empty list, never omitted',
        (t) async {
      // **`[]` is the field and ABSENT is "leave it alone".** A screen that
      // omitted the key when everything was ticked could never widen a pool
      // back out again.
      final c = _SpyClient(inPool: const [true, false, true, true]);
      await _pump(t, c);
      await t.tap(find.text('All groups'));
      await t.pump();
      await t.tap(find.text('Save game'));
      await t.pumpAndSettle();
      expect(c.posted!['group_ids'], isEmpty);
      expect(c.posted!['group_ids'], isNotNull);
    });
  });

  group('the board says which groups', () {
    FortyBallsBoard board(Map<String, dynamic> extra) => FortyBallsBoard(
          data: {
            'handicap_mode': 'net',
            'net_percent': 100,
            'net_max_double_bogey': true,
            'entry_fee': 10.0,
            'pool': 160.0,
            'payouts': const [],
            'n_groups': 4,
            'results': [
              {
                'foursome_id': 10, 'group_number': 1, 'group_size': 4,
                'rank': 1, 'tied': false, 'payout': 0.0,
                'per_person_payout': 0.0, 'split_ways': 4,
                'budget': 40, 'spent': 34, 'left': 6, 'slack': 6,
                'holes_left': 3, 'thru': 2, 'capacity': 12, 'dq': false,
                'total': -5, 'ranking_total': -5.0, 'factor': null,
                'players': const [
                  {'player_id': 1, 'short_name': 'Ann', 'name': 'Ann Smith'},
                ],
                'holes': const [
                  {'hole': 1, 'par': 4, 'stroke_index': 7, 'count': 2,
                   'app_set': false, 'result': -1, 'counted_ids': [1],
                   'scores': {'1': 3}, 'gross': {'1': 3},
                   'strokes': {'1': 0}},
                ],
                'holes_in_play': const [1],
              },
            ],
            ...extra,
          },
          names: const {1: 'Ann'},
        );

    testWidgets('a full field states the budget', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: board({'n_field_groups': 4, 'sparse': false}))));
      await t.pumpAndSettle();
      expect(find.text('40 a group'), findsOneWidget);
    });

    testWidgets('a sparse pool states which groups', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: board({'n_field_groups': 15, 'sparse': true}))));
      await t.pumpAndSettle();
      expect(find.text('4 of 15 groups'), findsOneWidget);
    });
  });

  group('the picker does not come up for a group that is out', () {
    test('a foursome with no flag plays, so an older server is unchanged', () {
      final fs = Foursome.fromJson({
        'id': 1, 'group_number': 1, 'has_phantom': false,
        'pink_ball_order': const [], 'memberships': const [],
      });
      expect(fs.playsFortyBalls, isTrue);
    });

    test('and the server can say otherwise', () {
      final fs = Foursome.fromJson({
        'id': 1, 'group_number': 1, 'has_phantom': false,
        'pink_ball_order': const [], 'memberships': const [],
        'plays_forty_balls': false,
      });
      expect(fs.playsFortyBalls, isFalse);
    });

    test('score entry asks the question in exactly ONE place', () {
      // It was five, and four read `active_games` alone — the shape that
      // leaves a control reachable from one screen and not another.
      final src = _src('lib/screens/score_entry_screen.dart');
      final hits = RegExp(r"contains\('forty_balls'\)").allMatches(src);
      expect(hits.length, 1,
          reason: 'every 40 Balls gate goes through _fortyBallsRound');
    });

    test('and that one place reads the flag', () {
      final src = _src('lib/screens/score_entry_screen.dart');
      final i = src.indexOf('bool _fortyBallsRound(');
      expect(i, greaterThan(0));
      final body = src.substring(i, src.indexOf('bool _keypadRound(', i));
      expect(body, contains('playsFortyBalls'));
      expect(body, contains('widget.foursomeId'));
    });
  });
}
