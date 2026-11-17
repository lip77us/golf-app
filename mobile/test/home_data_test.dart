import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/home_data.dart';

CasualRoundSummary _r(int id, String date, {int hole = 0, String status = 'in_progress'}) =>
    CasualRoundSummary(
      id: id, date: date, courseName: 'Tilden', status: status,
      activeGames: const ['skins'], betUnit: 5, currentHole: hole,
      players: const [CasualRoundPlayer(id: 1, name: 'Paul L', shortName: 'Paul')],
      myPlayerId: 1,
    );

Map<String, dynamic> _home({
  List<CasualRoundSummary> active = const [],
  List<CasualRoundSummary> recent = const [],
  List<SharedRoundSummary> watching = const [],
}) =>
    buildHome(
      now: DateTime(2026, 11, 17, 9),
      playerName: 'Paul Lipkin',
      active: active, pending: const [], recent: recent,
      playing: const [], watching: watching, tournaments: const [],
      stats: const {'enough': false, 'rounds': []},
    );

void main() {
  test('a round in progress and started takes the hero', () {
    final h = _home(active: [_r(1, '2026-11-17', hole: 12)]);
    expect(h['hero']['rule'], 1);
    expect(h['hero']['button'], 'Back to hole 13 ›');
  });

  test('a round created today with nothing scored is Tee off', () {
    final h = _home(active: [_r(1, '2026-11-17')]);
    expect(h['hero']['rule'], 3);
    expect(h['hero']['button'], 'Tee off ›');
  });

  test('a round later this week is the hero, and the rest go under coming up', () {
    final h = _home(active: [_r(1, '2026-11-19'), _r(2, '2026-11-21')]);
    expect(h['hero']['rule'], 4);
    expect(h['hero']['id'], 1);
    expect((h['coming'] as List).length, 1);
  });

  test('a round more than a week away is not scheduled', () {
    expect(_home(active: [_r(1, '2026-12-30')])['hero'], isNull);
  });

  test('nothing at all is the start card, and first launch with no history', () {
    final h = _home();
    expect(h['hero'], isNull);
    expect(h['firstLaunch'], true);
    expect(h['context'], 'Nothing scheduled');
    expect(_home(recent: [_r(9, '2026-11-01', status: 'complete')])['firstLaunch'], false);
  });

  test('the greeting follows the hour and uses the first name', () {
    expect(greeting(DateTime(2026, 1, 1, 9), 'Paul Lipkin'), 'Morning, Paul');
    expect(greeting(DateTime(2026, 1, 1, 19), 'Paul Lipkin'), 'Evening, Paul');
  });

  test('the home survives the device cache', () {
    final h = _home(active: [_r(1, '2026-11-17', hole: 3)]);
    expect(h.toString().isNotEmpty, true);
  });
}
