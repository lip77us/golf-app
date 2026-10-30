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
/// also support. The server's figures account for all of it, so a board that
/// recomputed would be a second opinion about money. Same rule as
/// `gross_to_par` and the skin-rules chip: one place decides, everywhere else
/// renders.
///
/// **Which figure depends on the style, and that is the whole point of it.**
/// In a POOL the column is each golfer's share of the pot, so it adds up to
/// the pool printed above it: three winners of a $60 pool read $20 each, the
/// rest $0. Per skin there is no pot, and the column is the signed net, which
/// adds up to zero. The per-group board used to show the net in a pool too —
/// +$10 / −$10 under "$60 pool", which sums to nothing anybody can check
/// (Paul, 29 Oct 2026). The cross-group pool was already showing shares.
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
    this.perPointMode = 'first',
    required this.carry,
    required this.basis,
    this.showNext = true,
    this.rulesLine = '',
    this.rulesNote = '',
    this.payoutStyle = 'pool',
    this.pool = 0,
    this.skinMinimum = 'none',
    this.birdieSteal = false,
  });

  final List<SkinsBoardGolfer> golfers;
  /// In PLAY order.
  final List<SkinsBoardHole> holes;
  final double stake;
  /// `average`, `all` or `first`. Decides what winning one skin pays below.
  final String perPointMode;

  /// What one more skin pays its winner, with the field level on skins:
  /// `rate` from each other golfer, except against the average, where
  /// `(pts − total/n) × rate` leaves him `(n − 1)/n` of a rate.
  double get skinWorth {
    final others = golfers.length - 1;
    if (perPointMode == 'average' && golfers.isNotEmpty) {
      return stake * others / golfers.length;
    }
    return stake * others;
  }
  final bool carry;
  /// 'Net' | 'Gross' | 'Strokes off' — a label, never a calculation.
  final String basis;
  /// False where a carry cannot happen, so the card would say "No carry"
  /// eighteen times. The cross-round pool is that case.
  final bool showNext;
  /// The validation rules in force, in the server's words. '' when none.
  final String rulesLine;
  /// The server's consequence sentence — rendered, never derived.
  final String rulesNote;

  /// How the money is paid, and the pot when it is a pool.
  ///
  /// **With a pool there is no price per skin** (Design, 28 Oct 2026): a
  /// skin is worth `pool / skins won`, which changes every time another one
  /// is won. The board quoted `$10 a skin` out of the ante, which is a
  /// number nobody is paid.
  final String payoutStyle;
  final double pool;

  bool get isPool => payoutStyle == 'pool';

  /// The rule SLUGS, beside the phrase, because the two answer different
  /// questions. [rulesLine] is what is in force and is the server's wording;
  /// these say WHICH rule, which is what decides the consequence sentence —
  /// a minimum can leave a hole unwon with nobody tied, and a steal never
  /// can. Reading that off the phrase would be parsing prose for logic.
  final String skinMinimum;
  final bool   birdieSteal;

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
            money:     s.payoutStyle == 'pool'
                ? s.players[i].payout : s.players[i].net,
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
      // A per-skin game has its OWN rate. `betUnit` is the ROUND's stake,
      // which belongs to the primary game: on an Annandale Friday with $5
      // skins the board read `$10 a skin` off the $10 Nassau.
      stake:     s.payoutStyle == 'per_point' ? s.perPointRate : s.betUnit,
      perPointMode: s.perPointMode,
      carry:     s.carryover,
      basis:     _basisLabel[s.handicapMode] ?? 'Net',
      rulesLine: s.skinRules,
      rulesNote: s.skinRulesNote,
      payoutStyle: s.payoutStyle,
      pool: s.pool,
      skinMinimum: s.skinMinimum,
      birdieSteal: s.birdieSteal,
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
            money:     s.players[i].payout,   // a share of the pool
            thru:      s.players[i].thru,
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
      rulesNote: s.skinRulesNote,
      // A cross-round pool is a pool by construction — there is no
      // per-skin price to choose, which is why the summary has no
      // style to read.
      payoutStyle: 'pool',
      pool: s.pool,
      skinMinimum: s.skinMinimum,
      birdieSteal: s.birdieSteal,
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
    required this.money,
    this.thru,
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
  /// The money column, verbatim from the server, never recomputed: his SHARE
  /// of the pot in a pool (the column sums to the pool), his signed net per
  /// skin (the column sums to zero).
  final double money;
  /// How far round this golfer is — pool only, null in a single foursome.
  ///
  /// A cross-round pool spans groups playing at different paces, so a board
  /// that hid it would be quietly misleading about who still has holes to
  /// come. In one foursome everybody is on the same hole and the line would
  /// be noise, so it is absent rather than repeated four times.
  final int? thru;

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
