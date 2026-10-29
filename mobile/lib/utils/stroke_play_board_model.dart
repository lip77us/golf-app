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

/// A round column. One entry for a single-round board; several once the
/// tournament half lands.
class StrokeRoundCol {
  const StrokeRoundCol({required this.label, required this.live});

  final String label;
  /// The round being played now — its tab opens first and carries the dot.
  final bool live;
}

class StrokePlayBoardData {
  const StrokePlayBoardData({
    required this.rows,
    required this.basisLabel,
    required this.countingLabel,
    this.entryFee = 0,
    this.hasPot = false,
    this.stakeLabel = '',
    this.holePars = const {},
    this.holeStrokeIndex = const {},
    this.holesInPlay = const [],
    this.showNet = true,
    this.rounds = const [],
  });

  final List<StrokePlayRow> rows;

  /// `Net`, `Net 90%`, `Gross`, `Strokes off` — the basis the board ranks on.
  final String basisLabel;
  /// `single round`, `best of 2 rounds` — empty when there is nothing to say.
  final String countingLabel;

  final double entryFee;
  /// Whether anything is being paid. **Not `entryFee > 0`**: a round can
  /// collect an entry and pay nobody yet, and the Prize column is about
  /// whether money is being paid at all.
  final bool hasPot;
  /// A casual round's own stake line (`$1 a stroke`), when it has one.
  final String stakeLabel;

  final Map<int, int> holePars;
  final Map<int, int> holeStrokeIndex;
  final List<int> holesInPlay;

  /// A gross-only round has no adjusted column, so `Tot` carries gross.
  final bool showNet;

  final List<StrokeRoundCol> rounds;

  /// The meta line's right half: the entry, or that there is no pot.
  String get potLabel {
    if (entryFee > 0) {
      final f = entryFee;
      return 'Entry \$${f % 1 == 0 ? f.toStringAsFixed(0) : f.toStringAsFixed(2)}';
    }
    return hasPot ? '' : 'No pot';
  }

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
    this.excluded = false,
    this.strokePlan = const {},
    this.roundToPar = const [],
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
  final bool excluded;
  final Map<int, int> strokePlan;

  /// Per-round to-par, for the multi-round columns. Empty on one round.
  final List<int?> roundToPar;

  bool get hasCard => holes.isNotEmpty || strokePlan.isNotEmpty;

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
