import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';
import '../game_catalog.dart';

/// What the home screen draws, as plain JSON-able maps.
///
/// **Decide, then draw.** The hero is worked out ONCE, here, from every list
/// at the same time ([buildHome]); the screen only renders. Plain maps because
/// the last home is saved to the device and drawn on the next launch before
/// the server answers, so the whole thing has to survive a round trip through
/// JSON. A tap is stored as data (`{'round': 12}`), never as a closure.
///
/// The hero rules, first match wins (handoff-home-startup):
///   1 playing and started      2 a tournament round today
///   3 playing, not started     4 scheduled in the next 7 days     5 nothing
/// A round the golfer only WATCHES never takes the hero — it goes under Live
/// now.
const _kCacheKey = 'home_cache_v1';

String _two(int n) => n.toString().padLeft(2, '0');
String ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

DateTime? _parse(String s) =>
    DateTime.tryParse(s.length >= 10 ? s.substring(0, 10) : s);

const _days = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];
const _mons = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

String dayLabel(String date, DateTime now) {
  final d = _parse(date);
  if (d == null) return date;
  final diff = DateTime(d.year, d.month, d.day)
      .difference(DateTime(now.year, now.month, now.day))
      .inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff > 1 && diff < 7) return _days[d.weekday - 1];
  return '${_mons[d.month - 1]} ${d.day}';
}

String greeting(DateTime now, String? name) {
  final first = (name ?? '').trim().split(' ').first;
  final part =
      now.hour < 12 ? 'Morning' : (now.hour < 18 ? 'Afternoon' : 'Evening');
  return first.isEmpty ? part : '$part, $first';
}

String gamesLine(List<String> games, {String? primary, bool match18 = false}) {
  final ids = [
    if (primary != null && games.contains(primary)) primary,
    ...games.where((g) => g != primary),
  ];
  final names = ids
      .map((g) => g == 'nassau' && match18 ? '18-Hole Match' : gameDisplayName(g))
      .toList();
  return names.take(2).join(' + ') +
      (names.length > 2 ? ' +${names.length - 2}' : '');
}

String _money(double v) =>
    v == v.roundToDouble() ? '\$${v.toInt()}' : '\$${v.toStringAsFixed(2)}';

String _initials(String name) {
  final p =
      name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (p.isEmpty) return '?';
  return (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase();
}

Map<String, dynamic> _avatars(List<CasualRoundPlayer> ps, int? me) => {
      'avatars': ps
          .take(4)
          .map((p) => {'i': _initials(p.name), 'me': p.id == me})
          .toList(),
      'names': ps.map((p) => p.shortName).take(4).join(', '),
    };

/// Builds the whole home. [now] is a parameter so the rules are testable.
Map<String, dynamic> buildHome({
  required DateTime now,
  required String? playerName,
  required List<CasualRoundSummary> active,
  required List<CasualRoundSummary> pending,
  required List<CasualRoundSummary> recent,
  required List<ScoringRound> playing,
  required List<SharedRoundSummary> watching,
  required List<Tournament> tournaments,
  required Map<String, dynamic> stats,
}) {
  final today = ymd(now);
  final weekOut = ymd(now.add(const Duration(days: 7)));

  Map<String, dynamic> casual(CasualRoundSummary r, {required bool started}) => {
        'kind': started ? 'playing' : 'notStarted',
        'id': r.id,
        'date': r.date,
        'title': r.courseName,
        'sub': gamesLine(r.activeGames,
                primary: r.primaryGame, match18: r.isEighteenHoleMatch) +
            (r.betUnit > 0 ? ' · ${_money(r.betUnit)}' : ''),
        'thru': r.currentHole,
        ..._avatars(r.players, r.myPlayerId),
        'tiles': started
            ? [
                {'k': 'Thru', 'v': '${r.currentHole}'},
                {'k': 'Golfers', 'v': '${r.players.length}'},
                {'k': 'Stake', 'v': r.betUnit > 0 ? _money(r.betUnit) : 'Fun'},
              ]
            : <Map<String, String>>[],
        'action': {'round': r.id},
      };

  final started = <Map<String, dynamic>>[];
  final notStarted = <Map<String, dynamic>>[];
  for (final r in active) {
    (r.currentHole > 0 ? started : notStarted)
        .add(casual(r, started: r.currentHole > 0));
  }
  for (final r in pending) {
    notStarted.add(casual(r, started: false));
  }
  for (final r in playing.where((r) => !r.isTournament && r.status != 'complete')) {
    final s = (r.currentHole ?? 0) > 0;
    (s ? started : notStarted).add({
      'kind': s ? 'playing' : 'notStarted',
      'id': r.id,
      'date': r.date,
      'title': r.courseName,
      'sub': gamesLine(r.activeGames, match18: r.isEighteenHoleMatch),
      'thru': r.currentHole ?? 0,
      'avatars': <Map<String, dynamic>>[],
      'names': r.groupLabel,
      'tiles': s
          ? [
              {'k': 'Thru', 'v': '${r.currentHole}'}
            ]
          : <Map<String, String>>[],
      'action': {'round': r.id},
    });
  }

  // Tournament rounds the golfer is in: today, and the next seven days.
  final tToday = <Map<String, dynamic>>[];
  final upcoming = <Map<String, dynamic>>[];
  for (final t in tournaments) {
    for (final r in t.rounds) {
      if (r.status == 'complete') continue;
      final entry = {
        'kind': 'tournament',
        'id': r.id,
        'date': r.date,
        'title': t.name,
        'sub': 'Round ${r.roundNumber} · ${r.courseName}',
        'tag': 'Round ${r.roundNumber}',
        'avatars': <Map<String, dynamic>>[],
        'names': t.rounds.length > 1 ? '${t.rounds.length} rounds' : '',
        'tiles': <Map<String, String>>[],
        'action': {'round': r.id},
      };
      final d = r.date.length >= 10 ? r.date.substring(0, 10) : r.date;
      if (d == today) {
        tToday.add(entry);
      } else if (d.compareTo(today) > 0 && d.compareTo(weekOut) <= 0) {
        upcoming.add(entry);
      }
    }
  }
  for (final r in notStarted) {
    final d = (r['date'] as String);
    if (d.compareTo(today) > 0 && d.compareTo(weekOut) <= 0) upcoming.add(r);
  }
  upcoming
      .sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));

  Map<String, dynamic>? hero;
  if (started.isNotEmpty) {
    hero = {
      ...started.first,
      'rule': 1,
      'tag': 'Live · thru ${started.first['thru']}',
      'dot': 'live',
      'button': 'Back to hole ${(started.first['thru'] as int) + 1} ›',
    };
  } else if (tToday.isNotEmpty) {
    final t = tToday.first;
    hero = {
      ...t,
      'rule': 2,
      'tag': 'Today · ${t['tag']}',
      'dot': 'soon',
      'button': 'Open ${t['title']} ›',
    };
  } else {
    final todays = notStarted
        .where((r) => (r['date'] as String).startsWith(today))
        .toList();
    if (todays.isNotEmpty) {
      hero = {
        ...todays.first,
        'rule': 3,
        'tag': 'Today · not started',
        'dot': 'soon',
        'button': 'Tee off ›',
      };
    } else if (upcoming.isNotEmpty) {
      final n = upcoming.first;
      hero = {
        ...n,
        'rule': 4,
        'tag': dayLabel(n['date'] as String, now),
        'dot': 'soon',
        'button': 'See the round ›',
        'light': true,
      };
      upcoming.removeAt(0);
    }
  }
  final coming = upcoming
      .take(3)
      .map((e) => {
            'title': e['title'],
            'sub': '${dayLabel(e['date'] as String, now)} · ${e['sub']}',
            'action': e['action'],
          })
      .toList();

  final live = watching
      .where((w) => w.status == 'in_progress' && (w.currentHole ?? 0) > 0)
      .take(3)
      .map((w) => {
            'title':
                '${w.courseName} · ${gamesLine(w.activeGames, match18: w.isEighteenHoleMatch)}',
            'sub': w.groupLabel,
            'thru': w.currentHole,
            'watchId': w.id,
            'isTournament': w.isTournament,
          })
      .toList();

  final ctx = hero != null
      ? (hero['rule'] == 2
          ? '${hero['title']} today'
          : '${dayLabel(hero['date'] as String, now)} at ${hero['title']}')
      : 'Nothing scheduled';

  final done = recent
      .take(2)
      .map((r) => {
            'date': dayLabel(r.date, now),
            'title': r.courseName,
            'sub': gamesLine(r.activeGames,
                    primary: r.primaryGame, match18: r.isEighteenHoleMatch) +
                (r.players.length > 1 ? ' · ${r.players.length} golfers' : ''),
            'gross': r.myGross,
            'money': r.myNet,
            'action': {'round': r.id},
          })
      .toList();

  return {
    'greeting': greeting(now, playerName),
    'context': ctx,
    'hero': hero,
    'live': live,
    'coming': coming,
    'stats': stats,
    'recent': done,
    // First launch: no history anywhere, nothing in progress.
    'firstLaunch': hero == null && recent.isEmpty && stats['enough'] != true,
    'savedAt': now.millisecondsSinceEpoch,
  };
}

Future<void> saveHome(Map<String, dynamic> home) async {
  try {
    (await SharedPreferences.getInstance())
        .setString(_kCacheKey, jsonEncode(home));
  } catch (_) {}
}

Future<Map<String, dynamic>?> loadSavedHome() async {
  try {
    final s = (await SharedPreferences.getInstance()).getString(_kCacheKey);
    return (s == null || s.isEmpty) ? null : (jsonDecode(s) as Map).cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

/// Signing out must not leave the last golfer's home on the device.
Future<void> clearSavedHome() async {
  try {
    await (await SharedPreferences.getInstance()).setString(_kCacheKey, '');
  } catch (_) {}
}
