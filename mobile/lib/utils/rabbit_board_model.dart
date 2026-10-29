import '../api/models.dart';

/// One shape for the Rabbit board.
///
/// Built from `~/Downloads/handoff-rabbit-leaderboard`: *"one widget used by
/// every Rabbit leaderboard. Do not draw a second Rabbit board."*
///
/// ### Nothing here is derived that the engine already decided
///
/// The packet says *"holders, leads, locks, rabbit ranges after rolling,
/// carries and money are all derived"* — true of its own reference, which is
/// a browser toy replaying the holes in a local array. `services/rabbit.py`
/// already walks the round and emits every one of them: each segment's real
/// range after rolling, who held it, the lead, the hole it was decided on,
/// its stake and its payout.
///
/// So this reads. What it derives is layout: which rabbit is live, which
/// hole is next, and the per-rabbit mark on a golfer's ledger row.
class RabbitBoardData {
  const RabbitBoardData({
    required this.golfers,
    required this.rabbits,
    required this.holes,
    required this.stake,
    required this.accumulate,
    required this.carry,
    required this.roundOver,
    this.currentHolderId,
    this.currentLead = 0,
    this.currentSegment = 0,
    this.nextHole,
    this.nextPar,
    this.holesLeft = 0,
  });

  final List<RabbitBoardGolfer> golfers;
  final List<RabbitBoardLeg> rabbits;
  /// 18 entries by hole number, or fewer on a partial round.
  final List<RabbitBoardHole> holes;

  final double stake;
  final bool accumulate;
  /// A loose rabbit rolls its stake into the next one.
  final bool carry;
  final bool roundOver;

  final int? currentHolderId;
  final int currentLead;
  final int currentSegment;
  final int? nextHole;
  final int? nextPar;
  final int holesLeft;

  /// The rabbit being played, or null once the round is over.
  RabbitBoardLeg? get liveLeg {
    for (final r in rabbits) {
      if (!r.complete) return r;
    }
    return null;
  }

  int get settled => rabbits.where((r) => r.complete).length;

  /// `+$20` — what the holder takes from every OTHER golfer.
  ///
  /// The server's `payout` is the leg's total; the packet draws the winner's
  /// net win, which is that same figure. Read, never multiplied out here:
  /// a withdrawal changes who pays, and the engine knows.
  double legWin(RabbitBoardLeg leg) => leg.payout;

  /// Colour index for a golfer, in roster order — identity, not standing.
  int colourOf(int? playerId) {
    if (playerId == null) return -1;
    for (var i = 0; i < golfers.length; i++) {
      if (golfers[i].playerId == playerId) return i;
    }
    return -1;
  }

  factory RabbitBoardData.fromSummary(RabbitSummary s) {
    final byHole = {for (final h in s.holes) h.hole: h};

    // The hole in play: the first in the round's holes that nobody has
    // scored. The summary emits a row for EVERY hole in play, scored or
    // not — that is deliberate there, so the stroke dots do not snap
    // around, and it means a row existing is not evidence it was played.
    int? next;
    for (final h in s.holes) {
      final played = h.entries.any((e) => e.gross != null);
      if (!played) { next = h.hole; break; }
    }
    final over = s.status == 'complete';

    return RabbitBoardData(
      golfers: [
        for (var i = 0; i < s.players.length; i++)
          RabbitBoardGolfer(
            playerId: s.players[i].playerId,
            name: s.players[i].name,
            shortName: s.players[i].shortName,
            colourIndex: i,
            money: s.players[i].money,
          ),
      ],
      rabbits: [
        for (final g in s.segments)
          RabbitBoardLeg(
            index: g.index,
            isExtra: g.isExtra,
            startHole: g.startHole,
            endHole: g.endHole,
            holes: g.holes,
            holderId: g.holderId,
            holderShort: g.holderShort,
            lead: g.lead,
            complete: g.complete,
            decidedOn: g.decidedOn,
            value: g.value,
            carriedIn: g.carriedIn,
            payout: g.payout,
          ),
      ],
      holes: [
        for (final h in s.holes)
          RabbitBoardHole(
            hole: h.hole,
            segment: h.segment,
            par: h.par,
            holderId: h.holderId,
            lead: h.lead,
            played: h.entries.any((e) => e.gross != null),
          ),
      ],
      stake: s.segValue,
      accumulate: s.accumulate,
      carry: s.carry,
      roundOver: over,
      currentHolderId: s.currentHolderId,
      currentLead: s.currentLead,
      currentSegment: s.currentSegment,
      nextHole: over ? null : next,
      nextPar: over || next == null ? null : byHole[next]?.par,
      holesLeft: over
          ? 0
          : s.holes.where((h) => !h.entries.any((e) => e.gross != null)).length,
    );
  }
}

class RabbitBoardGolfer {
  const RabbitBoardGolfer({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.colourIndex,
    required this.money,
  });

  final int playerId;
  final String name;
  final String shortName;
  final int colourIndex;
  final double money;

  /// `Lipkin` — the surname, muted, after the first name. Empty when the
  /// golfer has only one name to go on.
  String get surname {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.length > 1 ? parts.last : '';
  }
}

/// One rabbit — a leg of the round, and its own bet.
class RabbitBoardLeg {
  const RabbitBoardLeg({
    required this.index,
    required this.isExtra,
    required this.startHole,
    required this.endHole,
    required this.holes,
    required this.lead,
    required this.complete,
    required this.value,
    required this.carriedIn,
    required this.payout,
    this.holderId,
    this.holderShort,
    this.decidedOn,
  });

  final int index;
  final bool isExtra;
  final int startHole;
  final int endHole;
  final int holes;
  final int? holderId;
  final String? holderShort;
  final int lead;
  final bool complete;
  final int? decidedOn;
  /// The leg's stake INCLUDING anything carried into it.
  final double value;
  /// What rolled in from loose rabbits before it — 0 without carry.
  final double carriedIn;
  final double payout;

  /// `R1` / `Extra`.
  String get label => isExtra ? 'Extra' : 'R$index';
  String get range => startHole == endHole
      ? '$startHole'
      : '$startHole–$endHole';

  /// Nobody held it at the end — it pays nothing.
  bool get loose => complete && holderId == null;

  /// A one-hole extra plays for half the stake, which is the only place a
  /// leg is worth something other than the round's own figure.
  bool get halfStake => isExtra && holes == 1;

  /// One golfer's mark on the ledger: held it, lost it, loose, not started.
  RabbitMark markFor(int playerId) {
    if (!complete && holderId == null && lead == 0) {
      // Live and nobody has caught it yet — but the leg HAS started if any
      // hole in it has been played; the board decides that, not this.
      return RabbitMark.loose;
    }
    if (holderId == playerId) return RabbitMark.held;
    if (holderId == null) return RabbitMark.loose;
    return RabbitMark.lost;
  }
}

enum RabbitMark { held, lost, loose, notStarted }

class RabbitBoardHole {
  const RabbitBoardHole({
    required this.hole,
    required this.segment,
    required this.lead,
    required this.played,
    this.par,
    this.holderId,
  });

  final int hole;
  final int segment;
  final int? par;
  final int? holderId;
  final int lead;
  final bool played;
}
