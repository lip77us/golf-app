import '../api/models.dart';

/// One shape for the skins board, whatever produced it.
///
/// The packet asks for ONE widget on every skins leaderboard — the casual
/// card, the cross-round pool, the side-game tab — and those are fed by two
/// different summary types. Converting both into this is what makes that one
/// widget possible without it learning either.
///
/// ### What is DERIVED here and what is not
///
/// Only the things the server does not already answer: which hole is next,
/// which holes carried into it, how many skins are riding, and how far round
/// the group is. **The money and the per-hole value are taken verbatim.**
///
/// The design reference derives the money as
/// `stake × (golfers × won − total)`. That is correct for per-point/all with
/// no junk, no withdrawal and no loss cap, and wrong for pool mode — which we
/// also support. `skins_summary` already emits a signed, zero-sum `net` that
/// accounts for all of it, so a board that recomputed would be a second
/// opinion about money. Same rule as `gross_to_par` and the skin-rules chip:
/// one place decides, everywhere else renders.
///
/// ### Order
///
/// The hole list arrives in PLAY order (`services.skins` walks
/// `hole_plan.play_order`), so the walk below is shotgun-safe. The GRID draws
/// by hole number, which is a different question and the widget's to answer.
class SkinsBoardData {
  const SkinsBoardData({
    required this.golfers,
    required this.holes,
    required this.stake,
    required this.carry,
    required this.basis,
    this.showNext = true,
    this.rulesLine = '',
  });

  final List<SkinsBoardGolfer> golfers;
  /// In PLAY order.
  final List<SkinsBoardHole> holes;
  final double stake;
  final bool carry;
  /// 'Net' | 'Gross' | 'Strokes off' — a label, never a calculation.
  final String basis;
  /// False where a carry cannot happen, so the card would say "No carry"
  /// eighteen times. The cross-round pool is that case.
  final bool showNext;
  /// The validation rules in force, in the server's words. '' when none.
  final String rulesLine;

  // ── the walk ─────────────────────────────────────────────────────────────

  List<SkinsBoardHole> get _played =>
      holes.where((h) => h.played).toList(growable: false);

  int get holesPlayed => _played.length;
  bool get roundOver => holes.isNotEmpty && holesPlayed >= holes.length;
  int get holesLeft => holes.length - holesPlayed;

  /// The next hole in PLAY order, or null once the round is over.
  SkinsBoardHole? get nextHole {
    for (final h in holes) {
      if (!h.played) return h;
    }
    return null;
  }

  /// Holes whose skin carried INTO the next one — the trailing run, in play
  /// order. Empty when the last hole was won, or when carry is off.
  List<int> get carriedInHoles {
    if (!carry) return const [];
    final out = <int>[];
    for (var i = _played.length - 1; i >= 0; i--) {
      if (!_played[i].isCarry) break;
      out.insert(0, _played[i].hole);
    }
    return out;
  }

  /// Skins riding on the next hole.
  ///
  /// NOT re-counted from the carried run: a carried hole's `value` is already
  /// the pot *including itself* (`services.skins` adds 1 for the hole, then
  /// stores the running pot), so the next hole is that plus its own one. Two
  /// carried holes therefore ride as three, which is what the design draws.
  int get skinsRiding {
    if (roundOver) return 0;
    final p = _played;
    if (p.isEmpty || !p.last.isCarry) return 1;
    return p.last.value + 1;
  }

  /// Skins that died on the last holes because the round ran out.
  int get unclaimedAtEnd {
    if (!roundOver) return 0;
    final p = _played;
    if (p.isEmpty || !p.last.isCarry) return 0;
    return p.last.value;
  }

  int get totalSkinsWon =>
      golfers.fold(0, (a, g) => a + g.totalSkins);

  /// High first, then by name so a tie is stable rather than query-ordered.
  List<SkinsBoardGolfer> get ledger {
    final out = [...golfers];
    out.sort((a, b) {
      final c = b.totalSkins.compareTo(a.totalSkins);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  // ── conversions ──────────────────────────────────────────────────────────

  static const _basisLabel = {
    'net': 'Net',
    'gross': 'Gross',
    'strokes_off': 'Strokes off',
  };

  /// The per-foursome game (casual primary, or a side-game tab).
  factory SkinsBoardData.fromSkins(SkinsSummary s) {
    final ids = <int>[for (final p in s.players) p.playerId];
    return SkinsBoardData(
      golfers: [
        for (var i = 0; i < s.players.length; i++)
          SkinsBoardGolfer(
            playerId:  s.players[i].playerId,
            name:      s.players[i].name,
            colourIndex: i,
            skinsWon:  s.players[i].skinsWon,
            junkSkins: s.players[i].junkSkins,
            net:       s.players[i].net,
          ),
      ],
      holes: [
        for (final h in s.holes)
          SkinsBoardHole(
            hole:     h.hole,
            par:      h.par,
            winnerId: h.winnerId,
            value:    h.skinsValue,
            isCarry:  h.isCarry,
            // A hole with a winner, a carry or a dead skin has been played.
            // `skinsValue` alone is not the test: a killed hole still carries
            // the 1 that died.
            played:   h.winnerId != null || h.isCarry || h.skinsValue > 0,
            colourOf: h.winnerId == null ? null : ids.indexOf(h.winnerId!),
          ),
      ],
      stake:     s.betUnit,
      carry:     s.carryover,
      basis:     _basisLabel[s.handicapMode] ?? 'Net',
      rulesLine: s.skinRules,
    );
  }

  /// The cross-round pool.
  ///
  /// `showNext: false` because a pool NEVER carries — a tied hole kills the
  /// skin — so the card could only ever read "No carry · 1 skin".
  factory SkinsBoardData.fromPool(MultiSkinsSummary s) {
    final ids = <int>[for (final p in s.players) p.playerId];
    return SkinsBoardData(
      golfers: [
        for (var i = 0; i < s.players.length; i++)
          SkinsBoardGolfer(
            playerId:  s.players[i].playerId,
            name:      s.players[i].name,
            colourIndex: i,
            skinsWon:  s.players[i].skinsWon,
            junkSkins: 0,          // the pool has no junk
            net:       s.players[i].payout,
          ),
      ],
      holes: [
        for (final h in s.holes)
          SkinsBoardHole(
            hole:     h.hole,
            par:      h.par,
            winnerId: h.winnerId,
            value:    h.winnerId == null ? 0 : 1,
            isCarry:  false,       // never
            played:   h.winnerId != null || h.isDead,
            colourOf: h.winnerId == null ? null : ids.indexOf(h.winnerId!),
          ),
      ],
      stake:     s.betUnit,
      carry:     false,
      basis:     _basisLabel[s.handicapMode] ?? 'Net',
      showNext:  false,
      rulesLine: s.skinRules,
    );
  }
}

class SkinsBoardGolfer {
  const SkinsBoardGolfer({
    required this.playerId,
    required this.name,
    required this.colourIndex,
    required this.skinsWon,
    required this.junkSkins,
    required this.net,
  });

  final int playerId;
  final String name;
  /// Position in the roster, which decides the colour — stable as the LEDGER
  /// re-sorts, so a golfer does not change colour when he wins a skin.
  final int colourIndex;
  /// Skins won on holes.
  final int skinsWon;
  /// Junk shares. A junk is one share of the same pot, so it counts here and
  /// is drawn differently rather than left out — a ledger whose ticks do not
  /// add up to what a golfer is paid on is worse than no ticks.
  final int junkSkins;
  /// The SERVER's signed, zero-sum net. Never recomputed.
  final double net;

  int get totalSkins => skinsWon + junkSkins;
}

class SkinsBoardHole {
  const SkinsBoardHole({
    required this.hole,
    required this.par,
    required this.winnerId,
    required this.value,
    required this.isCarry,
    required this.played,
    required this.colourOf,
  });

  final int hole;
  final int? par;
  final int? winnerId;
  /// Skins this hole paid (or, while carrying, the pot it is holding).
  final int value;
  final bool isCarry;
  final bool played;
  /// Roster position of the winner, for the colour. Null when nobody won.
  final int? colourOf;

  bool get isWon => winnerId != null;
}
