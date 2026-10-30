/// One shape for the Sequoya 3s board.
///
/// Built from `~/Downloads/handoff-sequoya-leaderboard`: *"one widget used by
/// every Sequoya 3s leaderboard. Do not draw a second Sequoya board."*
///
/// ### Nothing here is derived that the engine already decided
///
/// The packet's `bet()` replays match play in the browser, because its
/// reference holds nothing but a list of hole winners.
/// `services/sequoya_threes.py` already emits every bet's holes, margin,
/// result and close-out, each golfer's money and his net per match. So this
/// reads; what it works out is layout — which match is live, which hole is
/// next, and how a bet is worded.
class SequoyaBoardData {
  const SequoyaBoardData({
    required this.golfers,
    required this.matches,
    required this.holes,
    required this.stake,
    required this.handicapMode,
    required this.netPercent,
    required this.roundOver,
    this.nextHole,
    this.holesLeft = 0,
  });

  /// Sorted by the money shown, because that is what the ledger ranks on.
  final List<SequoyaBoardGolfer> golfers;
  final List<SequoyaBoardMatch> matches;
  /// In PLAY order, so a shotgun round's next hole is the right one.
  final List<SequoyaBoardHole> holes;
  final double stake;
  final String handicapMode;
  final int netPercent;
  final bool roundOver;
  final int? nextHole;
  final int holesLeft;

  SequoyaBoardHole? hole(int number) {
    for (final h in holes) {
      if (h.number == number) return h;
    }
    return null;
  }

  SequoyaBoardMatch? get liveMatch {
    final n = nextHole;
    if (n == null) return null;
    for (final m in matches) {
      if (n >= m.startHole && n <= m.endHole) return m;
    }
    return null;
  }

  int get settled => matches.where((m) => m.settled).length;

  /// Bets in matches that have begun — a match that has not teed off has
  /// opened nothing yet.
  int get betCount => matches
      .where((m) => m.started)
      .fold(0, (n, m) => n + m.bets.length);

  /// The short names of whoever gets a stroke on [hole], in roster order.
  List<String> strokesOn(int hole) {
    final h = this.hole(hole);
    if (h == null) return const [];
    return [
      for (final g in rosterOrder)
        if ((h.strokes[g.playerId] ?? 0) > 0) g.shortName,
    ];
  }

  List<SequoyaBoardGolfer> get rosterOrder =>
      [...golfers]..sort((a, b) => a.rosterIndex.compareTo(b.rosterIndex));

  String shortName(int playerId) {
    for (final g in golfers) {
      if (g.playerId == playerId) return g.shortName;
    }
    return '?';
  }

  static SequoyaBoardData fromSummary(Map<String, dynamic> s) {
    final card = (s['scorecard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final holes = [
      for (final h in (card['holes'] as List? ?? const []))
        SequoyaBoardHole.fromJson((h as Map).cast<String, dynamic>()),
    ];
    final roster = <int, int>{
      for (final (i, p) in (card['players'] as List? ?? const []).indexed)
        (p as Map)['player_id'] as int: i,
    };
    final golfers = [
      for (final p in (s['players'] as List? ?? const []))
        SequoyaBoardGolfer.fromJson(
            (p as Map).cast<String, dynamic>(), roster),
    ];
    // List.sort is not stable, and level golfers should keep the server's
    // order (its tie-break is the bet record) rather than swap on a refresh.
    final order = {for (final (i, g) in golfers.indexed) g.playerId: i};
    golfers.sort((a, b) {
      final c = b.money.compareTo(a.money);
      return c != 0 ? c : order[a.playerId]!.compareTo(order[b.playerId]!);
    });

    final next = holes.where((h) => !h.played).firstOrNull;
    final hcap = (s['handicap'] as Map?) ?? const {};
    return SequoyaBoardData(
      golfers: golfers,
      matches: [
        for (final m in (s['matches'] as List? ?? const []))
          SequoyaBoardMatch.fromJson((m as Map).cast<String, dynamic>()),
      ],
      holes: holes,
      stake: (s['bet_amount'] as num?)?.toDouble() ?? 0,
      handicapMode: hcap['mode']?.toString() ?? 'net',
      netPercent: (hcap['net_percent'] as num?)?.toInt() ?? 100,
      // A TD can close a round with holes unplayed; "complete" wins over them.
      roundOver: s['status'] == 'complete' || next == null,
      nextHole: s['status'] == 'complete' ? null : next?.number,
      holesLeft: holes.where((h) => !h.played).length,
    );
  }
}

class SequoyaBoardHole {
  const SequoyaBoardHole({
    required this.number,
    required this.played,
    this.par,
    this.winnerSide,
    this.strokes = const {},
  });

  final int number;
  final bool played;
  final int? par;
  /// 1 or 2; null on a halved hole, which [played] tells from an unplayed one.
  final int? winnerSide;
  final Map<int, int> strokes;

  factory SequoyaBoardHole.fromJson(Map<String, dynamic> h) {
    final scores = (h['scores'] as List? ?? const []).cast<Map>();
    return SequoyaBoardHole(
      number: h['hole'] as int,
      par: (h['par'] as num?)?.toInt(),
      played: h['played'] as bool? ??
          (scores.isNotEmpty && scores.every((e) => e['gross'] != null)),
      winnerSide: (h['winner_team'] as num?)?.toInt(),
      strokes: {
        for (final e in scores)
          e['player_id'] as int: (e['strokes'] as num?)?.toInt() ?? 0,
      },
    );
  }
}

class SequoyaBoardBet {
  const SequoyaBoardBet({
    required this.kind,
    required this.holes,
    required this.played,
    required this.margin,
    this.result,
    this.closedOn,
    this.calledByShort,
  });

  /// `match`, `auto_press` or `manual_press`.
  final String kind;
  final List<int> holes;
  final int played;
  final int margin;
  /// 1 or 2 for a side, 0 halved, null still live.
  final int? result;
  final int? closedOn;
  final String? calledByShort;

  bool get isMatch => kind == 'match';
  bool get done => result != null;
  bool get started => played > 0;

  /// The side this bet is won by, or up for. Null when level.
  int? get lead {
    if (result != null) return result == 0 ? null : result;
    if (!started || margin == 0) return null;
    return margin > 0 ? 1 : 2;
  }

  String get range =>
      holes.length == 1 ? '${holes.first}' : '${holes.first}–${holes.last}';

  /// `2&1`, `1 UP` or `AS`.
  ///
  /// A close-out is read off the hole it CLOSED ON, never the margin: the
  /// holes after one are usually still played, because a press runs over
  /// them, so the margin keeps moving and would turn a 2&1 into `1 UP`.
  String get value {
    if (!started) return 'AS';
    final c = closedOn;
    if (c != null) {
      final left = holes.length - holes.indexOf(c) - 1;
      // The margin crosses the holes left by exactly one.
      if (left > 0) return '${left + 1}&$left';
    }
    return margin == 0 ? 'AS' : '${margin.abs()} UP';
  }

  factory SequoyaBoardBet.fromJson(Map<String, dynamic> b) => SequoyaBoardBet(
        kind: b['kind']?.toString() ?? 'match',
        holes: (b['holes'] as List? ?? const []).cast<int>(),
        played: (b['played'] as num?)?.toInt() ?? 0,
        margin: (b['margin'] as num?)?.toInt() ?? 0,
        result: (b['result'] as num?)?.toInt(),
        closedOn: (b['closed_on'] as num?)?.toInt(),
        calledByShort: b['called_by_short']?.toString(),
      );
}

class SequoyaBoardMatch {
  const SequoyaBoardMatch({
    required this.index,
    required this.startHole,
    required this.endHole,
    required this.side1,
    required this.side2,
    required this.side1Ids,
    required this.side2Ids,
    required this.bets,
  });

  final int index;
  final int startHole;
  final int endHole;
  /// Short names, in the order the engine lists the pair.
  final List<String> side1;
  final List<String> side2;
  final List<int> side1Ids;
  final List<int> side2Ids;
  /// The match bet first, then its presses.
  final List<SequoyaBoardBet> bets;

  SequoyaBoardBet get head => bets.first;
  List<SequoyaBoardBet> get presses => bets.skip(1).toList();
  bool get started => head.started;
  bool get settled => bets.every((b) => b.done);
  bool get anyPressLive => presses.any((b) => !b.done);

  String names(int side) => (side == 1 ? side1 : side2).join(' & ');

  factory SequoyaBoardMatch.fromJson(Map<String, dynamic> m) {
    List<String> shorts(String key) => [
          for (final p in (m[key] as List? ?? const []))
            (p as Map)['short_name']?.toString() ?? '?',
        ];
    List<int> ids(String key) => [
          for (final p in (m[key] as List? ?? const []))
            (p as Map)['player_id'] as int,
        ];
    return SequoyaBoardMatch(
      index: m['index'] as int,
      startHole: m['start_hole'] as int,
      endHole: m['end_hole'] as int,
      side1: shorts('side1'),
      side2: shorts('side2'),
      side1Ids: ids('side1'),
      side2Ids: ids('side2'),
      bets: [
        for (final b in (m['bets'] as List? ?? const []))
          SequoyaBoardBet.fromJson((b as Map).cast<String, dynamic>()),
      ],
    );
  }
}

/// A golfer's result in one match: up, down or level across ALL its bets, so
/// a match won with its press lost reads level.
class SequoyaBoardMark {
  const SequoyaBoardMark({
    required this.net,
    required this.started,
    required this.settled,
  });

  final double net;
  final bool started;
  final bool settled;

  String get glyph => !started ? '·' : net > 0 ? '+' : net < 0 ? '−' : '=';
}

class SequoyaBoardGolfer {
  const SequoyaBoardGolfer({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.money,
    required this.marks,
    required this.rosterIndex,
  });

  final int playerId;
  final String name;
  final String shortName;
  /// "If it ended here", which at the finish is the settled figure.
  final double money;
  final List<SequoyaBoardMark> marks;
  final int rosterIndex;

  String get firstName => name.trim().split(RegExp(r'\s+')).first;

  /// Empty for a one-word name.
  String get surname {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.length > 1 ? parts.last : '';
  }

  factory SequoyaBoardGolfer.fromJson(
          Map<String, dynamic> p, Map<int, int> roster) =>
      SequoyaBoardGolfer(
        playerId: p['player_id'] as int,
        name: p['name']?.toString() ?? '',
        shortName: p['short_name']?.toString() ?? '',
        money: ((p['live_money'] ?? p['money']) as num?)?.toDouble() ?? 0,
        rosterIndex: roster[p['player_id']] ?? 99,
        marks: [
          for (final m in (p['by_match'] as List? ?? const []))
            SequoyaBoardMark(
              net: ((m as Map)['net'] as num?)?.toDouble() ?? 0,
              started: m['started'] == true,
              settled: m['settled'] == true,
            ),
        ],
      );
}
