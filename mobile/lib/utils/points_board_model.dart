import '../api/models.dart';

/// One shape for the Points 5-3-1 board.
///
/// `~/Downloads/handoff-points-leaderboard`: *"one widget used by every
/// Points 5-3-1 leaderboard. Do not draw a second Points board."*
///
/// ### The money is READ, never computed
///
/// The packet's reference carries a `money()` with three modes — vs Average,
/// Above you, Just leader — and `(points − 3 × holes) × stake` for the first.
/// That is right for the game it draws and wrong for ours: `services/
/// points_531.py` settles through the shared wager engine, which also offers
/// a **pool** style and an optional **loss cap** that clips the losers and
/// rescales the winners pro-rata.
///
/// A real round in the local database proves the gap rather than implying it.
/// Foursome 257 finished 58 · 57 · 47 over 18 holes against a target of 54,
/// so the formula says `+$4 / +$3 / −$7`; the $6 cap settles it
/// **`+$3.43 / +$2.57 / −$6.00`**. A board that did its own arithmetic would
/// have shown four golfers a figure nobody was paid.
///
/// So this reads `player.money`. Same rule as the skins board, `gross_to_par`
/// and the skin-rules chip: one place decides, everywhere else renders.
///
/// ### Target is three a hole, over the holes IN PLAY
///
/// The reference hardcodes 54, which is its own 18-hole assumption. A nine-
/// hole round's target is 27 and a group thru 7 is playing to 21. Both come
/// from `par_per_hole × holes`, which are two facts the server already sends
/// — arithmetic over them, not a second copy of the rule.
class PointsBoardData {
  const PointsBoardData({
    required this.golfers,
    required this.holes,
    required this.stake,
    required this.pointsPerHole,
    required this.holesInPlay,
    required this.roundOver,
    this.currentHole = 0,
    this.parByHole = const {},
  });

  /// In ROSTER order, which is what the colours follow.
  final List<PointsBoardGolfer> golfers;

  /// The holes that have been scored, by hole number.
  final Map<int, PointsBoardHole> holes;

  final double stake;

  /// Points handed out to one golfer on an average hole — 3, since each hole
  /// pays 9 between three. The server's `par_per_hole`.
  final int pointsPerHole;

  /// Every hole the round plays, in PLAY order.
  final List<int> holesInPlay;

  final bool roundOver;

  /// The last hole PLAYED, in play order. 0 before the round starts.
  final int currentHole;

  /// Par for every hole in play — from the scorecard block, which covers the
  /// unplayed holes too. The grid's own `holes` only reach as far as the
  /// scores do, and the hero card has to name the NEXT hole's par.
  final Map<int, int> parByHole;

  int get holesPlayed => holes.length;

  int get holesLeft => holesInPlay.length - holesPlayed;

  /// `3 × holes played` — what a golfer is measured against right now.
  int get target => pointsPerHole * holesPlayed;

  /// `3 × holes in play` — the round's finishing line, 54 on a full round.
  int get fullTarget => pointsPerHole * holesInPlay.length;

  /// The next hole in PLAY order, or null once the round is over.
  ///
  /// Play order, never `currentHole + 1`: off a shotgun from the 7th the hole
  /// after the 18th is the 1st.
  int? get nextHole {
    if (roundOver) return null;
    if (currentHole == 0) {
      return holesInPlay.isEmpty ? null : holesInPlay.first;
    }
    final i = holesInPlay.indexOf(currentHole);
    if (i < 0 || i + 1 >= holesInPlay.length) return null;
    return holesInPlay[i + 1];
  }

  PointsBoardHole? get lastHole => holes[currentHole];

  double pointsFor(int playerId) {
    for (final g in golfers) {
      if (g.playerId == playerId) return g.points;
    }
    return 0;
  }

  /// Points less target — the figure the ledger leads on, because it is what
  /// the money is made of.
  double toTarget(PointsBoardGolfer g) => g.points - target;

  /// The ledger's order: points desc, then name so a tie is stable rather
  /// than query-ordered.
  List<PointsBoardGolfer> get ledger {
    final out = [...golfers];
    out.sort((a, b) {
      final c = b.points.compareTo(a.points);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// The winner once the round is over — most points, ties broken by name so
  /// the card names somebody rather than nobody.
  PointsBoardGolfer? get winner => golfers.isEmpty ? null : ledger.first;

  /// Whether the winner shares the lead. The card says so rather than
  /// crowning one of two.
  bool get winnerIsTied {
    if (golfers.length < 2) return false;
    final l = ledger;
    return l[0].points == l[1].points;
  }

  factory PointsBoardData.fromSummary(Points531Summary s) {
    // **Roster order, not standings order.** `summary['players']` is sorted
    // by money for the leaderboard, so taking the colour from it would make
    // a golfer change colour the moment he went ahead — and the hole tiles
    // would stop matching the ledger swatches. The scorecard block's player
    // list is the membership order, which is the order the names appear on
    // the card.
    final roster = s.scorecardPlayers.isNotEmpty
        ? [
            for (final p in s.scorecardPlayers)
              (
                id: (p['player_id'] as num).toInt(),
                name: p['name']?.toString() ?? '',
                short: p['short_name']?.toString() ?? '',
              ),
          ]
        : [
            for (final p in s.players)
              (id: p.playerId, name: p.name, short: p.shortName),
          ];

    final totals = {for (final p in s.players) p.playerId: p};

    // The grid's own holes carry par, but only as far as the scores reach;
    // the scorecard block covers every hole in play, which is what lets the
    // hero card name the NEXT hole's par. Both come from one `par_by_hole`
    // on the server, so where they overlap they agree.
    final parByHole = <int, int>{
      for (final h in s.holes)
        if (h.par != null) h.hole: h.par!,
      for (final h in s.scorecardHoles)
        if (h['par'] != null)
          (h['hole'] as num).toInt(): (h['par'] as num).toInt(),
    };

    final holesInPlay = s.holesInPlay.isNotEmpty
        ? s.holesInPlay
        : (s.scorecardHolesInPlay.isNotEmpty
            ? s.scorecardHolesInPlay
            : [for (final h in s.holes) h.hole]);

    return PointsBoardData(
      golfers: [
        for (var i = 0; i < roster.length; i++)
          PointsBoardGolfer(
            playerId: roster[i].id,
            name: roster[i].name,
            shortName: roster[i].short,
            colourIndex: i,
            points: totals[roster[i].id]?.points ?? 0,
            money: totals[roster[i].id]?.money ?? 0,
          ),
      ],
      holes: {
        for (final h in s.holes)
          h.hole: PointsBoardHole(
            hole: h.hole,
            par: h.par ?? parByHole[h.hole],
            entries: [
              for (final e in h.entries)
                PointsBoardEntry(
                  playerId: e.playerId,
                  shortName: e.shortName,
                  net: e.netScore,
                  points: e.points,
                  // **A tie is equal NET, not equal points.** Two golfers on
                  // the same net share the places they cover, which is what
                  // makes 4 and 4 out of 5 and 3 — but a 4 can also be one
                  // golfer's share of second and third, so reading the points
                  // back would call an outright second a tie.
                  tied: h.entries
                          .where((o) => o.netScore == e.netScore)
                          .length >
                      1,
                ),
            ],
          ),
      },
      stake: s.betUnit,
      pointsPerHole: s.parPerHole,
      holesInPlay: holesInPlay,
      roundOver: s.status == 'complete',
      currentHole: s.currentHole,
      parByHole: parByHole,
    );
  }
}

class PointsBoardGolfer {
  const PointsBoardGolfer({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.colourIndex,
    required this.points,
    required this.money,
  });

  final int playerId;
  final String name;
  final String shortName;

  /// Position in the ROSTER, which decides the colour — stable as the ledger
  /// re-sorts.
  final int colourIndex;

  final double points;

  /// The SERVER's signed figure, honouring pool, pay-above, pay-leader and
  /// the loss cap. Never recomputed here.
  final double money;

  /// The surname, when the full name carries one the short name does not.
  ///
  /// **A short name that already ends in it gets none.** A real golfer in the
  /// local database is `Tyler Law`, short `TYLaw`, and the ledger read
  /// `TYLaw Law` — the muted surname is there to tell two Pauls apart, and
  /// repeating a syllable already on the row does the opposite.
  String get surname {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return '';
    final last = parts.last;
    if (shortName.toLowerCase().endsWith(last.toLowerCase())) return '';
    return last;
  }
}

class PointsBoardHole {
  const PointsBoardHole({
    required this.hole,
    required this.par,
    required this.entries,
  });

  final int hole;
  final int? par;

  /// Winner first — the server sorts by points desc.
  final List<PointsBoardEntry> entries;

  /// Low net first, which is the order the hero card reads in. The server
  /// sorts by POINTS, and on a tied hole two golfers share a figure, so
  /// sorting by net is what keeps the two tied rows adjacent.
  List<PointsBoardEntry> get byNet {
    final out = [...entries];
    out.sort((a, b) {
      final c = a.net.compareTo(b.net);
      return c != 0 ? c : a.shortName.compareTo(b.shortName);
    });
    return out;
  }

  double pointsFor(int playerId) {
    for (final e in entries) {
      if (e.playerId == playerId) return e.points;
    }
    return 0;
  }

  bool has(int playerId) => entries.any((e) => e.playerId == playerId);
}

class PointsBoardEntry {
  const PointsBoardEntry({
    required this.playerId,
    required this.shortName,
    required this.net,
    required this.points,
    required this.tied,
  });

  final int playerId;
  final String shortName;
  final int net;
  final double points;
  final bool tied;
}

/// `5`, `4.5`, `3` — a tie split can halve a point, and a trailing `.0` on
/// every other tile would be noise.
String formatPoints(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
