/// The Add players body, the All golfers sheet and the New golfer sheet
/// (`handoff-add-players`), against stubbed server calls.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/client.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/providers/auth_provider.dart';
import 'package:golf_mobile/utils/add_players.dart';
import 'package:golf_mobile/widgets/add_players_body.dart';
import 'package:golf_mobile/widgets/all_golfers_sheet.dart';
import 'package:golf_mobile/widgets/index_tap_field.dart';
import 'package:golf_mobile/widgets/new_golfer_sheet.dart';
import 'package:golf_mobile/widgets/pool_sheet.dart';
import 'package:provider/provider.dart';

PlayerProfile g(int id, String name,
        {String phone = '', String index = '10.0', bool onApp = false}) =>
    PlayerProfile(
        id: id,
        name: name,
        handicapIndex: index,
        isPhantom: false,
        email: '',
        phone: phone,
        isOnApp: onApp);

class _Stub extends ApiClient {
  _Stub() : super(token: 't');

  List<Map<String, dynamic>> nameHits = [];
  Map<String, dynamic> phoneHit = {'found': false};
  final created = <Map<String, String>>[];
  int addedFromHalved = -1;

  @override
  Future<List<Map<String, dynamic>>> searchHalvedUsersByName(String q) async =>
      nameHits;

  @override
  Future<Map<String, dynamic>> lookupHalvedUser(String phone) async => phoneHit;

  @override
  Future<PlayerProfile> addHalvedUserToRoster(int id) async {
    addedFromHalved = id;
    return g(900 + id, 'Samir Patel', onApp: true);
  }

  @override
  Future<PlayerProfile> createPlayer({
    required String name,
    required String handicapIndex,
    String email = '',
    String phone = '',
    String sex = 'M',
    String? shortName,
    int? userId,
    String? username,
    String? password,
  }) async {
    created.add({'name': name, 'index': handicapIndex, 'phone': phone});
    return g(800 + created.length, name, phone: phone, index: handicapIndex);
  }
}

class _Auth extends AuthProvider {
  _Auth(this._c);
  final ApiClient _c;
  @override
  ApiClient get client => _c;
}

final _me = g(1, 'Paul Lipkin', onApp: true);

/// 12 golfers: Dave..Gil are regulars (most rounds first), Pete is not.
final _roster = [
  _me,
  g(2, 'Dave Moran', index: '12.4', phone: '(415) 555-0101'),
  g(3, 'Sam Lee', index: '8.0'),
  g(4, 'Al Ortiz', index: '18.2'),
  g(5, 'Pete Lane', index: '15.2', phone: '(510) 555-0166'),
  g(6, 'Gabe Ortiz', index: '9.9', phone: '(925) 555-0142'),
];

final _counts = <int, SharedRounds>{
  2: SharedRounds(9, DateTime(2026, 11, 1)),
  3: SharedRounds(5, DateTime(2026, 11, 1)),
  4: SharedRounds(2, DateTime(2026, 10, 1)),
  5: SharedRounds(1, DateTime(2026, 9, 1)),
};

class _Host extends StatefulWidget {
  final _Stub stub;
  final int? seats;
  final List<PlayerProfile> startSeated;
  final List<String> log;
  const _Host(this.stub, this.log,
      {this.seats = 4, this.startSeated = const []});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<PlayerProfile> seated = [_me, ...widget.startSeated];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AddPlayersBody(
            me: _me,
            seated: seated,
            seats: widget.seats,
            minSeated: widget.seats == null ? 2 : null,
            gameLabel: widget.seats == null ? 'Multi-Group Skins' : 'Skins',
            roster: _roster,
            counts: _counts,
            onAdd: (p) => setState(() {
              widget.log.add('add ${p.name}');
              seated = [...seated, p];
            }),
            onRemove: (p) => setState(() {
              widget.log.add('remove ${p.name}');
              seated = [for (final s in seated) if (s.id != p.id) s];
            }),
            onHalvedAdded: (p) => widget.log.add('halved ${p.name}'),
            onNewGolfer: (q) => widget.log.add('new "$q"'),
            onAllGolfers: () => widget.log.add('all'),
          ),
        ),
      );
}

Future<_Stub> open(WidgetTester t, List<String> log,
    {int? seats = 4,
    List<PlayerProfile> seated = const [],
    _Stub? stub}) async {
  final s = stub ?? _Stub();
  await t.binding.setSurfaceSize(const Size(390, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
    value: _Auth(s),
    child: MaterialApp(home: _Host(s, log, seats: seats, startSeated: seated)),
  ));
  await t.pump();
  return s;
}

void main() {
  group('the seats', () {
    testWidgets('you first, the header counts, and open seats are drawn',
        (t) async {
      final log = <String>[];
      await open(t, log, seated: [_roster[1], _roster[2]]);
      expect(find.text('SKINS · 3 of 4'), findsOneWidget);
      expect(find.text('Add 1 more'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets('a full table says Full and draws no open seat', (t) async {
      await open(t, [], seated: [_roster[1], _roster[2], _roster[3]]);
      expect(find.text('Full'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
    });

    testWidgets('tapping a seated golfer takes them out, you included',
        (t) async {
      final log = <String>[];
      await open(t, log, seated: [_roster[1]]);
      await t.tap(find.text('You'));
      await t.pump();
      expect(log, ['remove ${_roster[0].name}']);
      log.clear();
      await t.tap(find.descendant(
          of: find.byType(Wrap).first, matching: find.text('Dave')));
      await t.pump();
      expect(log, ['remove Dave Moran']);
    });

    testWidgets('three seats for a threesome, six for five or six', (t) async {
      await open(t, [], seats: 3);
      expect(find.text('SKINS · 1 of 3'), findsOneWidget);
      expect(find.text('Open'), findsNWidgets(2));
    });
  });

  group('an open-ended round (Multi-Group Skins)', () {
    testWidgets('counts golfers instead of seats, and says how many it needs',
        (t) async {
      await open(t, [], seats: null);
      expect(find.text('MULTI-GROUP SKINS · 1 golfer'), findsOneWidget);
      expect(find.text('Add 1 more'), findsOneWidget,
          reason: 'a pool needs two');
    });

    testWidgets('there is never a Full, and one open seat is always on offer',
        (t) async {
      await open(t, [], seats: null,
          seated: [_roster[1], _roster[2], _roster[3], _roster[4]]);
      expect(find.text('MULTI-GROUP SKINS · 5 golfers'), findsOneWidget);
      expect(find.text('Full'), findsNothing);
      expect(find.text('Add 1 more'), findsNothing,
          reason: 'it has the two it needs');
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets('golfers can be added past any count', (t) async {
      final log = <String>[];
      await open(t, log, seats: null,
          seated: [_roster[1], _roster[2], _roster[3]]);
      await t.enterText(find.byType(TextField), 'gab');
      await t.pump();
      await t.tap(find.text('Add'));
      await t.pump();
      expect(log, ['add Gabe Ortiz']);
    });

    testWidgets('it has the same regulars, search and dark card', (t) async {
      await open(t, [], seats: null);
      expect(find.text('YOUR REGULARS'), findsOneWidget);
      expect(find.text('SEARCH'), findsOneWidget);
      expect(find.text('Add a new golfer'), findsOneWidget);
    });
  });

  group('a big pool keeps the seats to two rows', () {
    final many = [
      for (var i = 0; i < 12; i++) g(100 + i, 'Pool${String.fromCharCode(65 + i)} Player'),
    ];

    testWidgets('up to nine golfers show in full, with no +N tile', (t) async {
      await open(t, [], seats: null, seated: many.take(8).toList());
      expect(find.text('more'), findsNothing);
      expect(find.text('MULTI-GROUP SKINS · 9 golfers'), findsOneWidget);
    });

    testWidgets('eleven golfers collapse to a +N more tile', (t) async {
      await open(t, [], seats: null, seated: many.take(10).toList());
      expect(find.text('MULTI-GROUP SKINS · 11 golfers'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget);
      expect(find.text('more'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget,
          reason: 'the open seat is still on offer');
    });

    testWidgets('you and the newest golfers stay visible', (t) async {
      await open(t, [], seats: null, seated: many.take(10).toList());
      final seats = find.byType(Wrap).first;
      expect(find.descendant(of: seats, matching: find.text('You')),
          findsOneWidget);
      // The last one added is on screen, not buried behind the tile.
      expect(find.descendant(of: seats, matching: find.text('PoolJ')),
          findsOneWidget);
      // The first one added is the one that collapsed.
      expect(find.descendant(of: seats, matching: find.text('PoolA')),
          findsNothing);
    });

    testWidgets('the tile opens Your pool, listing everyone', (t) async {
      await open(t, [], seats: null, seated: many.take(10).toList());
      await t.tap(find.text('+3'));
      await t.pumpAndSettle();
      expect(find.text('Your pool'), findsOneWidget);
      expect(find.text('11 golfers. Remove anyone who is not playing.'),
          findsOneWidget);
      expect(find.text('Paul Lipkin (you)'), findsOneWidget);
      expect(find.text('PoolA Player'), findsOneWidget,
          reason: 'the collapsed ones are in the list');
    });

    testWidgets('removing from the sheet removes the golfer', (t) async {
      final log = <String>[];
      await open(t, log, seats: null, seated: many.take(10).toList());
      await t.tap(find.text('+3'));
      await t.pumpAndSettle();
      await t.tap(find.text('Remove').first);
      await t.pumpAndSettle();
      expect(log, ['remove PoolA Player']);
      expect(find.text('10 golfers. Remove anyone who is not playing.'),
          findsOneWidget, reason: 'the sheet follows who is seated');
    });

    testWidgets('you cannot remove yourself from the sheet', (t) async {
      await open(t, [], seats: null, seated: many.take(10).toList());
      await t.tap(find.text('+3'));
      await t.pumpAndSettle();
      final yourRow = find
          .ancestor(
              of: find.text('Paul Lipkin (you)'),
              matching: find.byType(Container))
          .first;
      expect(
          find.descendant(of: yourRow, matching: find.text('Remove')),
          findsNothing);
      expect(find.text('Remove'), findsWidgets,
          reason: 'everyone else can be removed');
    });

    testWidgets('review and remove only: no way to add from the sheet',
        (t) async {
      await open(t, [], seats: null, seated: many.take(10).toList());
      await t.tap(find.text('+3'));
      await t.pumpAndSettle();
      final sheet = find.byType(PoolSheet);
      expect(find.descendant(of: sheet, matching: find.text('Add')),
          findsNothing);
      expect(find.descendant(of: sheet, matching: find.byType(TextField)),
          findsNothing);
    });

    testWidgets('a fixed-size round never collapses', (t) async {
      await open(t, [], seats: 6,
          seated: [_roster[1], _roster[2], _roster[3], _roster[4]]);
      expect(find.text('more'), findsNothing);
    });
  });

  group('your regulars', () {
    testWidgets('most rounds first, then All golfers with the count',
        (t) async {
      await open(t, []);
      expect(find.text('YOUR REGULARS'), findsOneWidget);
      expect(find.text('tap to add'), findsOneWidget);
      // Dave (9), Sam (5), Al (2), Pete (1) — four regulars, then the tile.
      final dave = t.getTopLeft(find.text('Dave').last).dx;
      final sam = t.getTopLeft(find.text('Sam').last).dx;
      expect(dave, lessThan(sam));
      expect(find.text('All golfers'), findsOneWidget);
      expect(find.text('5'), findsWidgets, reason: 'five others in My Golfers');
    });

    testWidgets('tapping a regular seats them', (t) async {
      final log = <String>[];
      await open(t, log);
      await t.tap(find.text('Sam').last);
      await t.pump();
      expect(log, ['add Sam Lee']);
    });

    testWidgets('a seated regular leaves the grid', (t) async {
      await open(t, []);
      final grid = find.byType(GridView);
      expect(find.descendant(of: grid, matching: find.text('Sam')),
          findsOneWidget);
      await t.tap(find.descendant(of: grid, matching: find.text('Sam')));
      await t.pump();
      expect(find.descendant(of: grid, matching: find.text('Sam')),
          findsNothing,
          reason: 'he is a seat now, not a choice');
      // He is in the seats row instead.
      expect(find.text('Sam'), findsOneWidget);
    });

    testWidgets('taking him out of the seat puts him back in the grid',
        (t) async {
      await open(t, [], seated: [_roster[2]]);
      final grid = find.byType(GridView);
      expect(find.descendant(of: grid, matching: find.text('Sam')),
          findsNothing);
      await t.tap(find.descendant(
          of: find.byType(Wrap).first, matching: find.text('Sam')));
      await t.pump();
      expect(find.descendant(of: grid, matching: find.text('Sam')),
          findsOneWidget);
    });

    testWidgets('a tap on Add when full does nothing', (t) async {
      final log = <String>[];
      await open(t, log, seats: 2, seated: [_roster[1]]);
      await t.tap(find.text('Sam').last);
      await t.pump();
      expect(log, isEmpty);
    });

    testWidgets('All golfers opens the sheet', (t) async {
      final log = <String>[];
      await open(t, log);
      await t.tap(find.text('All golfers'));
      await t.pump();
      expect(log, ['all']);
    });
  });

  group('search', () {
    testWidgets('your golfers by name prefix, regulars included', (t) async {
      await open(t, []);
      await t.enterText(find.byType(TextField), 'p');
      await t.pump();
      expect(find.text('YOUR GOLFERS'), findsOneWidget);
      expect(find.text('Pete Lane'), findsOneWidget,
          reason: 'Pete is a regular, and searching for him still finds him');
      await t.enterText(find.byType(TextField), 'gab');
      await t.pump();
      expect(find.text('YOUR GOLFERS'), findsOneWidget);
      expect(find.text('Gabe Ortiz'), findsOneWidget);
      expect(find.textContaining('not played yet'), findsOneWidget);
    });

    testWidgets('by phone digits', (t) async {
      await open(t, []);
      await t.enterText(find.byType(TextField), '925555');
      await t.pump();
      expect(find.text('Gabe Ortiz'), findsOneWidget);
    });

    testWidgets('a result is Add, and Added once seated, and a tap toggles',
        (t) async {
      final log = <String>[];
      await open(t, log);
      await t.enterText(find.byType(TextField), 'gab');
      await t.pump();
      expect(find.text('Add'), findsOneWidget);
      await t.tap(find.text('Add'));
      await t.pump();
      expect(find.text('Added'), findsOneWidget);
      await t.tap(find.text('Added'));
      await t.pump();
      expect(log, ['add Gabe Ortiz', 'remove Gabe Ortiz']);
    });

    testWidgets('after a pick the query stays, selected, so the next name replaces it',
        (t) async {
      await open(t, []);
      await t.enterText(find.byType(TextField), 'gab');
      await t.pump();
      await t.tap(find.text('Add'));
      await t.pump();
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'gab', reason: 'not cleared');
      expect(field.controller!.selection.baseOffset, 0);
      expect(field.controller!.selection.extentOffset, 3,
          reason: 'selected, so one keystroke replaces it');
    });

    testWidgets('On Halved comes after your golfers, and Add copies them in',
        (t) async {
      final stub = _Stub()
        ..nameHits = [
          {
            'id': 7,
            'name': 'Samir Patel',
            'handicap_index': '8.2',
            'location': 'San Francisco, CA',
            'sex': 'M',
            'short_name': '',
          }
        ];
      final log = <String>[];
      await open(t, log, stub: stub);
      await t.enterText(find.byType(TextField), 'pat');
      await t.pump(const Duration(milliseconds: 600));
      await t.pump();
      expect(find.text('ON HALVED'), findsOneWidget);
      expect(find.text('Samir Patel'), findsOneWidget);
      expect(find.text('Index 8.2 · San Francisco, CA'), findsOneWidget);
      await t.tap(find.text('Add'));
      await t.pump();
      await t.pump();
      expect(stub.addedFromHalved, 7);
      expect(log, ['halved Samir Patel']);
    });

    testWidgets('no match says so, and the dark card carries what was typed',
        (t) async {
      final log = <String>[];
      await open(t, log);
      await t.enterText(find.byType(TextField), 'zz');
      await t.pump();
      expect(find.textContaining('Nobody in your golfers or on Halved'),
          findsOneWidget);
      expect(find.text('Add "Zz" as a new golfer'), findsOneWidget);
      await t.tap(find.text('Add "Zz" as a new golfer'));
      await t.pump();
      expect(log, ['new "zz"']);
    });

    testWidgets('an empty search says what it searches', (t) async {
      await open(t, []);
      expect(find.text('Add a new golfer'), findsOneWidget);
      expect(
          find.text('Your golfers first, then everyone on Halved. '
              'By name or phone.'),
          findsOneWidget);
    });

    testWidgets('a number carries into the dark card as a number', (t) async {
      await open(t, []);
      await t.enterText(find.byType(TextField), '415 555 9999');
      await t.pump();
      expect(find.text('Add a new golfer with this number'), findsOneWidget);
    });
  });

  group('the All golfers sheet', () {
    testWidgets('lists everyone but you, most rounds first, and filters',
        (t) async {
      final seated = <int>{};
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => showAllGolfersSheet(c,
                golfers: allGolfersOf(_roster, _counts, meId: 1),
                counts: _counts,
                seatedIds: () => seated,
                onToggle: (p) => seated.contains(p.id)
                    ? seated.remove(p.id)
                    : seated.add(p.id)),
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('All your golfers'), findsOneWidget);
      expect(find.text('Paul Lipkin'), findsNothing);
      await t.tap(find.text('Add').first);
      await t.pumpAndSettle();
      expect(seated, {2}, reason: 'Dave has the most rounds, so he is first');
      expect(find.text('Added'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'pete');
      await t.pumpAndSettle();
      expect(find.text('Pete Lane'), findsOneWidget);
      expect(find.text('Dave Moran'), findsNothing);
    });
  });

  group('the New golfer sheet', () {
    Future<_Stub> openSheet(WidgetTester t,
        {String seed = '',
        double? myIndex = 10.0,
        _Stub? stub,
        List<PlayerProfile> roster = const [],
        bool allowUseExisting = true}) async {
      final s = stub ?? _Stub();
      await t.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: _Auth(s),
        child: MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async =>
                  _result = await showNewGolferSheet(c,
                      seed: seed,
                      myIndex: myIndex,
                      roster: roster,
                      counts: _counts,
                      allowUseExisting: allowUseExisting),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      _result = null;
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return s;
    }

    TextField field(WidgetTester t, String label) => t.widget<TextField>(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label));

    testWidgets('empty: the title, and a disabled button', (t) async {
      await openSheet(t);
      expect(find.text('New golfer'), findsOneWidget);
      expect(find.text('Enter a name'), findsOneWidget);
      expect(
          find.text('Not on Halved: plays this round only, then isn’t saved.'),
          findsOneWidget);
    });

    testWidgets('the title and the button follow the name', (t) async {
      await openSheet(t);
      await t.enterText(
          find.byWidgetPredicate((w) =>
              w is TextField && w.decoration?.labelText == 'FULL NAME'),
          'jo smith');
      await t.pump();
      expect(find.text('Jo Smith'), findsOneWidget);
      expect(find.text('Add Jo'), findsOneWidget);
    });

    testWidgets('a seeded name opens filled in, capitalised', (t) async {
      await openSheet(t, seed: 'jo');
      expect(field(t, 'FULL NAME').controller!.text, 'Jo');
      expect(find.text('Add Jo'), findsOneWidget);
    });

    testWidgets('a seeded number opens in the mobile field', (t) async {
      await openSheet(t, seed: '4155550100');
      expect(field(t, 'MOBILE').controller!.text, '(415) 555-0100');
    });

    testWidgets('the mobile formats itself and completes the button',
        (t) async {
      await openSheet(t, seed: 'jo');
      await t.enterText(
          find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == 'MOBILE'),
          '4155550100');
      await t.pump();
      expect(field(t, 'MOBILE').controller!.text, '(415) 555-0100');
      expect(find.text('Add Jo & text the game'), findsOneWidget);
    });

    testWidgets('the strokes line is worked out against YOUR index',
        (t) async {
      await openSheet(t, seed: 'jo', myIndex: 10.0);
      expect(find.text('Leave blank and they play off scratch until it is set.'),
          findsOneWidget);
      await _typeIndex(t, '16');
      expect(find.textContaining('strokes from you.', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('Gets ', findRichText: true), findsOneWidget);
    });

    testWidgets('with no round to measure against there is no strokes claim',
        (t) async {
      await openSheet(t, seed: 'jo', myIndex: null);
      await _typeIndex(t, '16');
      expect(find.textContaining('strokes', findRichText: true), findsNothing);
    });

    testWidgets('a guest with one name is saved as {Name} Guest on scratch',
        (t) async {
      final stub = await openSheet(t, seed: 'jo');
      await t.tap(find.text('Add Jo'));
      await t.pumpAndSettle();
      expect(stub.created, [
        {'name': 'Jo Guest', 'index': '0.0', 'phone': ''}
      ]);
      expect(_result!.hasNumber, isFalse);
      expect(_result!.viaAccount, isFalse);
    });

    testWidgets('a number makes it a text-the-game add', (t) async {
      final stub = await openSheet(t, seed: 'jo smith');
      await t.enterText(
          find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == 'MOBILE'),
          '4155550100');
      await t.pump();
      await t.tap(find.text('Add Jo & text the game'));
      await t.pumpAndSettle();
      expect(stub.created.single['name'], 'Jo Smith');
      expect(stub.created.single['phone'], '(415) 555-0100');
      expect(_result!.hasNumber, isTrue);
    });

    testWidgets('a number already on Halved offers the real account',
        (t) async {
      final stub = _Stub()
        ..phoneHit = {
          'found': true,
          'name': 'Mike Torres',
          'handicap_index': '7.1',
          'sex': 'M',
          'short_name': 'MT',
        };
      await openSheet(t, seed: 'mike', stub: stub);
      await t.enterText(
          find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == 'MOBILE'),
          '4155550100');
      await t.pump(const Duration(milliseconds: 500));
      await t.pump();
      expect(find.textContaining('Mike Torres', findRichText: true),
          findsOneWidget);
      expect(find.text('Use account'), findsOneWidget);
      await t.ensureVisible(find.text('Use account'));
      await t.pumpAndSettle();
      await t.tap(find.text('Use account'));
      await t.pumpAndSettle();
      // The real account's name and index, not a guest called Mike Guest.
      expect(stub.created.single['name'], 'Mike Torres');
      expect(stub.created.single['index'], '7.1');
      expect(_result!.viaAccount, isTrue);
    });

    group('a golfer you already have', () {
      final bill = g(30, 'Bill Sinn', index: '12.4', phone: '(415) 555-0199');
      final withBill = [..._roster, bill];

      testWidgets('typing his name warns, and names him', (t) async {
        await openSheet(t, seed: 'bill sinn', roster: withBill);
        expect(find.textContaining('You already have', findRichText: true),
            findsOneWidget);
        expect(find.textContaining('Bill Sinn', findRichText: true),
            findsWidgets);
        expect(find.textContaining('Index 12.4', findRichText: true),
            findsOneWidget);
      });

      testWidgets('no warning for a different name', (t) async {
        await openSheet(t, seed: 'bill smith', roster: withBill);
        expect(find.textContaining('You already have', findRichText: true),
            findsNothing);
      });

      testWidgets('the warning appears as you type, and goes when you change it',
          (t) async {
        await openSheet(t, roster: withBill);
        final name = find.byWidgetPredicate((w) =>
            w is TextField && w.decoration?.labelText == 'FULL NAME');
        await t.enterText(name, 'Bill Sinn');
        await t.pump();
        expect(find.textContaining('You already have', findRichText: true),
            findsOneWidget);
        await t.enterText(name, 'Bill Sinclair');
        await t.pump();
        expect(find.textContaining('You already have', findRichText: true),
            findsNothing);
      });

      testWidgets('Use Bill returns the golfer you already have, creating none',
          (t) async {
        final stub = await openSheet(t, seed: 'bill sinn', roster: withBill);
        await t.tap(find.text('Use Bill'));
        await t.pumpAndSettle();
        expect(_result!.existing, isTrue);
        expect(_result!.player.id, 30);
        expect(stub.created, isEmpty, reason: 'nobody new was written');
      });

      testWidgets('it warns but does not block: adding anyway still works',
          (t) async {
        final stub = await openSheet(t, seed: 'bill sinn', roster: withBill);
        await t.tap(find.text('Add Bill'));
        await t.pumpAndSettle();
        expect(stub.created.single['name'], 'Bill Sinn');
        expect(_result!.existing, isFalse);
      });

      testWidgets('the same mobile blocks the add: a number belongs to one golfer',
          (t) async {
        final stub = await openSheet(t, seed: 'William', roster: withBill);
        await t.enterText(
            find.byWidgetPredicate(
                (w) => w is TextField && w.decoration?.labelText == 'MOBILE'),
            '4155550199');
        await t.pump();
        expect(find.textContaining('That number is already',
                findRichText: true),
            findsWidgets);
        expect(find.text('That number is already in use'), findsOneWidget,
            reason: 'the button says why it is dead');
        await t.tap(find.text('That number is already in use'),
            warnIfMissed: false);
        await t.pumpAndSettle();
        expect(stub.created, isEmpty, reason: 'nothing was written');
        expect(_result, isNull);
      });

      testWidgets('a number you already have still offers Use Bill',
          (t) async {
        final stub = await openSheet(t, seed: 'William', roster: withBill);
        await t.enterText(
            find.byWidgetPredicate(
                (w) => w is TextField && w.decoration?.labelText == 'MOBILE'),
            '(415) 555-0199');
        await t.pump();
        await t.ensureVisible(find.text('Use Bill'));
        await t.pumpAndSettle();
        await t.tap(find.text('Use Bill'));
        await t.pumpAndSettle();
        expect(_result!.existing, isTrue);
        expect(_result!.player.id, 30);
        expect(stub.created, isEmpty);
      });

      testWidgets('a number on Halved is not offered as a second account when it is already yours',
          (t) async {
        final stub = _Stub()
          ..phoneHit = {
            'found': true,
            'name': 'Bill Sinn',
            'handicap_index': '12.4',
            'sex': 'M',
            'short_name': 'BS',
          };
        await openSheet(t, seed: 'bill', roster: withBill, stub: stub);
        await t.enterText(
            find.byWidgetPredicate(
                (w) => w is TextField && w.decoration?.labelText == 'MOBILE'),
            '4155550199');
        await t.pump(const Duration(milliseconds: 500));
        await t.pump();
        expect(find.text('Use account'), findsNothing,
            reason: 'creating him again would be the duplicate');
      });

      testWidgets('a name match alone does not block', (t) async {
        await openSheet(t, seed: 'bill sinn', roster: withBill);
        expect(find.text('That number is already in use'), findsNothing);
        expect(find.text('Add Bill'), findsOneWidget);
      });

      testWidgets('where there is nowhere to seat him it is only a warning',
          (t) async {
        await openSheet(t,
            seed: 'bill sinn', roster: withBill, allowUseExisting: false);
        expect(find.textContaining('You already have', findRichText: true),
            findsOneWidget);
        expect(find.text('Use Bill'), findsNothing);
      });
    });

    testWidgets('Cancel closes with no golfer', (t) async {
      final stub = await openSheet(t, seed: 'jo');
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(_result, isNull);
      expect(stub.created, isEmpty);
    });
  });

  group('the casual screen uses it', () {
    final src = File('lib/screens/casual_round_screen.dart').readAsStringSync();

    test('the Players step is the Add players body for every group size', () {
      expect(src, contains('AddPlayersBody('));
      // Across groups is the same screen with no seat count, not a second one.
      expect(src, contains("_sizeFilter == 'groups'\n      ? null"));
      expect(src, isNot(contains('UnifiedPlayerSearch')));
      expect(src, isNot(contains('_buildRosterSections')));
    });

    test('Next waits for every seat, and says how many are missing', () {
      expect(src, contains('_playersReady'));
      expect(src, contains("return missing > 0 ? 'Add \$missing more' : 'Next';"));
      // A pool with no seats still needs two golfers before Next.
      expect(src, contains('(_seatCount ?? 2)'));
    });

    test('the game is texted at Start round, not when a golfer is added', () {
      final at = src.indexOf('Future<void> _createRound()');
      expect(src.substring(at), contains('textTheGame('));
      final add = src.indexOf('Future<void> _openNewGolfer(');
      final body = src.substring(add, src.indexOf('void _onHalvedAdded'));
      expect(body, isNot(contains('maybeOfferRoundSmsInvite')));
      expect(body, isNot(contains('textTheGame')));
    });

    test('the sheet is given who you already have, so it can warn', () {
      final at = src.indexOf('Future<void> _openNewGolfer(');
      final body = src.substring(at, src.indexOf('void _onHalvedAdded'));
      expect(body, contains('roster: _players'));
      expect(body, contains('result.existing'));
    });

    test('a full table still saves the golfer, and says so', () {
      expect(src, contains('Take someone out to seat them.'));
    });
  });

  group('My Golfers uses the sheet to add', () {
    final src = File('lib/screens/player_list_screen.dart').readAsStringSync();

    test('it warns about a duplicate but has nowhere to seat him', () {
      expect(src, contains('roster: _all'));
      expect(src, contains('allowUseExisting: false'));
    });

    test('a new golfer is the New golfer sheet; an edit is still the form', () {
      expect(src, contains('showNewGolferSheet('));
      expect(src, contains('PlayerFormScreen(player: player'));
    });
  });
}

NewGolferResult? _result;

/// The index field opens the number pad: tap it, key the digits, Save.
Future<void> _typeIndex(WidgetTester t, String digits) async {
  await t.tap(find.byType(IndexTapField));
  await t.pumpAndSettle();
  for (final d in digits.split('')) {
    await t.tap(find.text(d).last);
  }
  await t.pump();
  await t.tap(find.text('Save').last);
  await t.pumpAndSettle();
}
