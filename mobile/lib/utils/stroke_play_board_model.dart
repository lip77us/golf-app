/// One shape for the Stroke Play board, whatever produced it.
///
/// Built from `~/Downloads/handoff-stroke-play-leaderboard`, whose scope line
/// is the one that matters: *"one widget used by every stroke play
/// leaderboard, casual and tournament. Do not draw a second stroke play
/// table."*
///
/// ### What is derived and what is taken verbatim
///
/// Ranks, ties, payouts and net-to-par are the SERVER's — the packet says
/// *"net, to-par, ranks, ties and prize splits are derived"* of its own
/// reference implementation, which is a browser toy with the whole field in
/// a local array. We have an engine that already decides all of it, and the
/// standing rule on these boards is that a client which recomputes money is
/// a second opinion about money.
///
/// What IS derived here is layout: the gross total a row has actually made,
/// which places are PAID (so the badge and the tint go on the right rows),
/// and which nine a hole belongs to.
library;

/// The COUNTED net on a hole — post-cap, which is what the total is built
/// from.
///
/// **The two adjusted figures are easy to read the wrong way round**, and the
/// board read the wrong one: `net` is the UNCAPPED score and `capped` is the
/// one the engine totals, so a card summing `net` printed a net total that
/// disagreed with the Tot box beside it. It also read a `net_adj` key the
/// server has never sent, which is how it went unnoticed — the fallback was
/// always taken.
int? strokeHoleNet(Map<String, dynamic> h) =>
    (h['capped'] as num?)?.toInt() ?? (h['net'] as num?)?.toInt();

/// The net double bogey took a stroke off this hole, so the card keeps the
/// score and the total counts the ceiling.
bool strokeHoleCapped(Map<String, dynamic> h) {
  final counted = (h['capped'] as num?)?.toInt();
  final raw = (h['net'] as num?)?.toInt();
  return counted != null && raw != null && counted != raw;
}

/// `E` for level, a sign otherwise, an em dash for nothing played.
///
/// Here rather than on the board because the score-entry tray reports the
/// same figure in the same words, and two spellings of `E` is how one board
/// comes to say `EVEN`.
String strokeToPar(int? v) {
  if (v == null) return '—';
  if (v == 0) return 'E';
  return v > 0 ? '+$v' : '$v';
}

/// A round column.
///
/// Empty on a one-round board, which shows `Thru · Gross · Tot` instead.
class StrokeRoundCol {
  const StrokeRoundCol({
    required this.index,
    required this.label,
    this.live = false,
    this.complete = false,
  });

  /// 0-based, matching the per-round lists on each row.
  final int index;
  /// `R1`, `R2` — and the tab's own `Round 1`.
  final String label;
  /// The round being played now: its tab opens first and carries the dot.
  final bool live;
  final bool complete;

  String get tabLabel => 'Round ${index + 1}';
}

/// How the round columns are laid out, which is purely a question of how
/// many there are (Design's table):
///
/// | Rounds | Columns |
/// | --- | --- |
/// | One | `# · Player · Thru · Gross · Tot · Prize` |
/// | Two | `# · Player · R1 · R2 · Tot · Thru · Prize` |
/// | Three or more | `# · Player · Prev · R(live) · Tot · Thru · Prize` |
///
/// Three or more collapses every earlier COUNTED round into `Prev`, which
/// is what keeps the table readable at six rounds — and what makes best-4-
/// of-6 legible, since `Prev` is the best counted rounds so far rather than
/// all of them.
enum StrokeLayout { single, twoRounds, prevAndLive }

class StrokePlayBoardData {
  const StrokePlayBoardData({
    required this.rows,
    required this.basisLabel,
    this.entryFee = 0,
    this.purse = 0,
    this.hasPot = false,
    this.holePars = const {},
    this.holeStrokeIndex = const {},
    this.holesInPlay = const [],
    this.showNet = true,
    this.rounds = const [],
  });

  final List<StrokePlayRow> rows;

  /// `Net`, `Net 90%`, `Gross`, `Strokes off` — the basis the board ranks
  /// on. Read by nothing on the board itself: the settings strip above it
  /// states the rules, and the selector states the mode. Kept because the
  /// unwired tournament half still needs a basis of its own.
  final String basisLabel;

  final double entryFee;

  /// What the payout table pays out in total — the ledger's `Pool $580`.
  /// The SERVER's figure: a client adding a money column up is a client with
  /// an opinion about money.
  final double purse;

  /// Whether anything is being paid. **Not `entryFee > 0`**: a round can
  /// collect an entry and pay nobody yet, and the Prize column is about
  /// whether money is being paid at all.
  final bool hasPot;

  final Map<int, int> holePars;
  final Map<int, int> holeStrokeIndex;
  final List<int> holesInPlay;

  /// A gross-only round has no adjusted column, so `Tot` carries gross.
  final bool showNet;

  final List<StrokeRoundCol> rounds;

  StrokeLayout get layout => rounds.length <= 1
      ? StrokeLayout.single
      : rounds.length == 2
          ? StrokeLayout.twoRounds
          : StrokeLayout.prevAndLive;

  /// The live round, or the last one — a finished event has none in play.
  StrokeRoundCol? get liveRound {
    for (final r in rounds) {
      if (r.live) return r;
    }
    return rounds.isEmpty ? null : rounds.last;
  }

  /// Golfers part-way round — what the ledger's footer counts, and what
  /// makes its money PROJECTED rather than final.
  int get onCourse =>
      rows.where((r) => r.thru > 0 && r.thru < 18).length;

  /// Everybody who started has finished, so the money is settled.
  ///
  /// A golfer who has not teed off does not hold it open: on a big field
  /// somebody is always entered and absent, and a board that said
  /// `Projected` all evening because of him would never say anything else.
  bool get allIn {
    final started = rows.where((r) => r.thru > 0);
    return started.isNotEmpty && started.every((r) => r.thru >= 18);
  }

  /// The paid rows, in board order — the ledger's lines.
  List<StrokePlayRow> get paidRows =>
      [for (final r in rows) if ((r.payout ?? 0) > 0) r];

  /// Which ranks are PAID, so the badge and the tint land on the same rows
  /// the money does.
  ///
  /// Read off the rows rather than off the payout table: a tie splits the
  /// places it occupies, so the number of paid ROWS is not the number of
  /// paid PLACES, and the server has already resolved that.
  Set<int> get paidRanks => {
        for (final r in rows)
          if ((r.payout ?? 0) > 0) r.rank,
      };

  /// Tinted rows: the paid places, or the leader when nothing is paid.
  ///
  /// Both of Design's boards agree on this — the one with a pot tints its
  /// three paid rows, the casual one tints the leader alone.
  Set<int> get tintedRanks =>
      paidRanks.isNotEmpty ? paidRanks : (rows.isEmpty ? {} : {rows.first.rank});
}

class StrokePlayRow {
  const StrokePlayRow({
    required this.playerId,
    required this.rank,
    required this.name,
    required this.handicapLabel,
    required this.toPar,
    required this.grossTotal,
    required this.thru,
    required this.holes,
    this.payout,
    this.prizeRank,
    this.excluded = false,
    this.strokePlan = const {},
    this.roundToPar = const [],
    this.roundCounts = const [],
    this.roundHoles = const [],
  });

  final int? playerId;
  final int rank;
  final String name;
  /// The index where we have one, the playing handicap where we do not.
  final String handicapLabel;

  /// The figure the board RANKS on, to par. In a gross round that is gross
  /// to par, which is why there is no separate strokes-off column: in that
  /// mode this IS the strokes-off value.
  final int? toPar;

  /// Raw strokes made so far — what the GROSS column shows. Mid-round it is
  /// read against `thru`, which is why the two sit together.
  final int? grossTotal;

  final int thru;
  final List<Map<String, dynamic>> holes;
  final double? payout;

  /// The rank the PAYOUT was assigned to, which is not always the rank on
  /// the board: an excluded golfer holds a place and is skipped for the
  /// money, so the man behind him is paid 2nd while standing 3rd.
  final int? prizeRank;

  final bool excluded;
  final Map<int, int> strokePlan;

  /// Per-round to-par, for the multi-round columns. Empty on one round.
  final List<int?> roundToPar;

  /// Whether each round COUNTS toward the total, under best-N-of-M. A round
  /// that does not is struck through rather than hidden — the golfer played
  /// it, and hiding it invites the question of where it went.
  final List<bool> roundCounts;

  /// Each round's own holes, for that round's tab in the open card.
  final List<List<Map<String, dynamic>>> roundHoles;

  /// `Prev` — every earlier COUNTED round collapsed into one figure.
  ///
  /// Null when none of them counts yet, which is a different thing from
  /// level par and has to read as one.
  int? prevToPar(int liveIndex) {
    var any = false, total = 0;
    for (var i = 0; i < roundToPar.length && i < liveIndex; i++) {
      final counts = i < roundCounts.length ? roundCounts[i] : true;
      final v = roundToPar[i];
      if (!counts || v == null) continue;
      any = true;
      total += v;
    }
    return any ? total : null;
  }

  bool countsRound(int i) =>
      i < roundCounts.length ? roundCounts[i] : true;

  /// Is there a card to open? Per-round holes count: on a multi-round board
  /// the row's own `holes` is the aggregate and may be empty while each
  /// round has its own.
  bool get hasCard =>
      holes.isNotEmpty ||
      strokePlan.isNotEmpty ||
      roundHoles.any((h) => h.isNotEmpty);

  /// `F` once the round is done, `—` before anybody tees off.
  String get thruLabel {
    if (holes.isEmpty && thru == 0) return '—';
    return thru >= 18 ? 'F' : '$thru';
  }

  /// `T2` for a shared place. The server gives tied rows the same rank, so
  /// the `T` is a reading of the field rather than a second ranking.
  String rankLabel(List<StrokePlayRow> all) {
    final shared = all.where((r) => r.rank == rank).length > 1;
    return shared ? 'T$rank' : '$rank';
  }
}
