/// api/models.dart
/// Dart data classes mirroring the Django API responses.
/// All fromJson constructors handle null-safety explicitly.

// ---------------------------------------------------------------------------
// Shared formatting helpers
// ---------------------------------------------------------------------------

extension BetUnitFormat on num {
  /// Show whole-dollar amounts without cents ("5"), fractions with two
  /// decimal places ("2.50").  Used on every bet-unit display in the app.
  String formatBet() =>
      this % 1 == 0 ? toInt().toString() : toStringAsFixed(2);
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class AuthResult {
  final String token;

  /// Full player profile for this user, included directly in the login
  /// response so we don't have to follow up with a /auth/me/ call.  Null
  /// when the authenticated user has no linked Player (admin/staff).
  final PlayerProfile? player;

  /// True when the Django User has is_staff=True. Staff can create/delete
  /// tournaments regardless of whether they also have a linked player.
  final bool isStaff;

  const AuthResult({
    required this.token,
    this.player,
    this.isStaff = false,
  });

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        token:   j['token'] as String,
        isStaff: j['is_staff'] as bool? ?? false,
        player:  j['player'] is Map<String, dynamic>
            ? PlayerProfile.fromJson(j['player'] as Map<String, dynamic>)
            : null,
      );
}

/// Result of GET /api/auth/me/ — is_staff flag plus optional player profile.
class MeResult {
  final bool isStaff;
  final PlayerProfile? player;

  const MeResult({this.isStaff = false, this.player});

  factory MeResult.fromJson(Map<String, dynamic> j) => MeResult(
        isStaff: j['is_staff'] as bool? ?? false,
        player:  j['player'] is Map<String, dynamic>
            ? PlayerProfile.fromJson(j['player'] as Map<String, dynamic>)
            : null,
      );
}

// ---------------------------------------------------------------------------
// Reference data
// ---------------------------------------------------------------------------

class PlayerProfile {
  final int id;
  final String name;
  /// Short display label (≤ 5 chars) used wherever the UI would otherwise
  /// compute initials on the fly (e.g. Sixes team abbreviations).  The
  /// server auto-fills this from the player's initials when left blank,
  /// so it should always be present on responses; local cache / older
  /// payloads fall back to a computed initials string via [displayShort].
  final String shortName;
  final String handicapIndex;
  final bool isPhantom;
  final String email;
  final String phone;
  /// 'M' or 'W' — picks the default tee during round setup. Older
  /// server responses without the field fall back to 'M'.
  final String sex;

  const PlayerProfile({
    required this.id,
    required this.name,
    this.shortName = '',
    required this.handicapIndex,
    required this.isPhantom,
    required this.email,
    this.phone = '',
    this.sex = 'M',
  });

  factory PlayerProfile.fromJson(Map<String, dynamic> j) => PlayerProfile(
        id: j['id'] as int,
        name: j['name'] as String,
        shortName: (j['short_name'] as String?) ?? '',
        handicapIndex: j['handicap_index']?.toString() ?? '0.0',
        isPhantom: j['is_phantom'] as bool? ?? false,
        email: j['email'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        sex: j['sex'] as String? ?? 'M',
      );

  /// Compute a safe fallback initials string from a full name.  Matches
  /// the server-side Player.default_short_name_for() algorithm: first
  /// letters of up to the first two whitespace-separated words,
  /// uppercase, clamped to 5 characters.
  static String computeInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final take = parts.take(2).where((p) => p.isNotEmpty);
    final s = take.map((p) => p[0].toUpperCase()).join();
    return s.length > 5 ? s.substring(0, 5) : s;
  }

  /// Preferred short label for this player.  Returns [shortName] if set,
  /// otherwise falls back to computed initials — keeps old cached rows
  /// and offline-drafted players working until the next server sync.
  String get displayShort =>
      shortName.isNotEmpty ? shortName : computeInitials(name);
}

class CourseInfo {
  final int id;
  final String name;

  const CourseInfo({
    required this.id,
    required this.name,
  });

  factory CourseInfo.fromJson(Map<String, dynamic> j) => CourseInfo(
        id: j['id'] as int,
        name: j['name'] as String,
      );

  @override
  bool operator ==(Object other) => other is CourseInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class TeeInfo {
  final int id;
  final CourseInfo course;
  final String teeName;
  final int slope;
  final double courseRating;
  final int par;
  /// 'M', 'W', or null (unisex — playable by either sex).  Used to
  /// filter the default-tee picker during round setup.
  final String? sex;
  /// Lower = more default.  Among tees matching a player's sex (plus
  /// unisex tees), the one with the lowest sort_priority is the
  /// pre-selected default.  Defaults to 100 for backward compatibility.
  final int sortPriority;

  const TeeInfo({
    required this.id,
    required this.course,
    required this.teeName,
    required this.slope,
    required this.courseRating,
    required this.par,
    this.sex,
    this.sortPriority = 100,
  });

  factory TeeInfo.fromJson(Map<String, dynamic> j) => TeeInfo(
        id: j['id'] as int,
        course: CourseInfo.fromJson(j['course'] as Map<String, dynamic>),
        teeName: j['tee_name'] as String,
        slope: j['slope'] as int,
        courseRating: double.parse(j['course_rating'].toString()),
        par: j['par'] as int,
        sex: j['sex'] as String?,
        sortPriority: j['sort_priority'] as int? ?? 100,
      );

  String get display => '${course.name} — $teeName';
}

// ---------------------------------------------------------------------------
// Tournament / Round hierarchy
// ---------------------------------------------------------------------------

class RoundSummary {
  final int id;
  final int roundNumber;
  final String date;
  final String courseName;
  final String status;
  final List<String> activeGames;
  final double betUnit;

  const RoundSummary({
    required this.id,
    required this.roundNumber,
    required this.date,
    required this.courseName,
    required this.status,
    required this.activeGames,
    required this.betUnit,
  });

  factory RoundSummary.fromJson(Map<String, dynamic> j) => RoundSummary(
        id: j['id'] as int,
        roundNumber: j['round_number'] as int,
        date: j['date'] as String,
        courseName: j['course_name'] as String? ?? '',
        status: j['status'] as String,
        activeGames: List<String>.from(j['active_games'] as List? ?? []),
        betUnit: double.parse(j['bet_unit'].toString()),
      );

  String get statusLabel {
    switch (status) {
      case 'in_progress': return 'In Progress';
      case 'complete':    return 'Complete';
      default:            return 'Pending';
    }
  }
}

class Tournament {
  final int id;
  final String name;
  final String startDate;
  final String? endDate;
  final List<RoundSummary> rounds;
  final int totalRounds;
  final List<String> activeGames;

  const Tournament({
    required this.id,
    required this.name,
    required this.startDate,
    this.endDate,
    required this.rounds,
    this.totalRounds = 1,
    this.activeGames = const [],
  });

  factory Tournament.fromJson(Map<String, dynamic> j) => Tournament(
        id: j['id'] as int,
        name: j['name'] as String,
        startDate: j['start_date'] as String,
        endDate: j['end_date'] as String?,
        rounds: (j['rounds'] as List? ?? [])
            .map((r) => RoundSummary.fromJson(r as Map<String, dynamic>))
            .toList(),
        totalRounds: j['total_rounds'] as int? ?? 1,
        activeGames: (j['active_games'] as List? ?? [])
            .map((g) => g as String)
            .toList(),
      );
}

/// Low Net Championship configuration (tournament-level).
class LowNetChampionshipSetup {
  final String handicapMode;
  final int netPercent;
  final double entryFee;
  final List<Map<String, dynamic>> payouts;

  const LowNetChampionshipSetup({
    required this.handicapMode,
    required this.netPercent,
    required this.entryFee,
    required this.payouts,
  });

  factory LowNetChampionshipSetup.fromJson(Map<String, dynamic> j) =>
      LowNetChampionshipSetup(
        handicapMode: j['handicap_mode'] as String? ?? 'net',
        netPercent: j['net_percent'] as int? ?? 100,
        entryFee: (j['entry_fee'] as num? ?? 0).toDouble(),
        payouts: (j['payouts'] as List? ?? [])
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'handicap_mode': handicapMode,
        'net_percent': netPercent,
        'entry_fee': entryFee,
        'payouts': payouts,
      };
}

/// Lightweight summary of an in-progress casual round, used in the
/// Casual Rounds list screen.
class CasualRoundSummary {
  final int    id;
  final String date;
  final String courseName;
  final String status;
  final List<String> activeGames;
  final double betUnit;
  /// Highest hole number with any score entered; 0 = not started yet.
  final int    currentHole;
  /// Player ID of whoever created the round; null for legacy rounds.
  final int?   createdByPlayerId;
  /// The single foursome for this casual round; null if not yet set up.
  final int?   foursomeId;
  /// All real players across all foursomes.
  final List<CasualRoundPlayer> players;

  const CasualRoundSummary({
    required this.id,
    required this.date,
    required this.courseName,
    required this.status,
    required this.activeGames,
    required this.betUnit,
    required this.currentHole,
    this.createdByPlayerId,
    this.foursomeId,
    required this.players,
  });

  factory CasualRoundSummary.fromJson(Map<String, dynamic> j) =>
      CasualRoundSummary(
        id:                  j['id'] as int,
        date:                j['date'] as String,
        courseName:          j['course_name'] as String,
        status:              j['status'] as String,
        activeGames:         List<String>.from(j['active_games'] as List? ?? []),
        betUnit:             double.parse(j['bet_unit'].toString()),
        currentHole:         j['current_hole'] as int? ?? 0,
        createdByPlayerId:   j['created_by_player_id'] as int?,
        foursomeId:          j['foursome_id'] as int?,
        players:             (j['players'] as List? ?? [])
            .map((p) => CasualRoundPlayer.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
}

class CasualRoundPlayer {
  final int    id;
  final String name;
  final String shortName;

  const CasualRoundPlayer({
    required this.id,
    required this.name,
    required this.shortName,
  });

  factory CasualRoundPlayer.fromJson(Map<String, dynamic> j) =>
      CasualRoundPlayer(
        id:        j['id'] as int,
        name:      j['name'] as String,
        shortName: (j['short_name'] as String?) ?? '',
      );
}

class Membership {
  final int id;
  final PlayerProfile player;
  final TeeInfo? tee;
  final int courseHandicap;
  final int playingHandicap;

  const Membership({
    required this.id,
    required this.player,
    this.tee,
    required this.courseHandicap,
    required this.playingHandicap,
  });

  factory Membership.fromJson(Map<String, dynamic> j) => Membership(
        id: j['id'] as int,
        player: PlayerProfile.fromJson(j['player'] as Map<String, dynamic>),
        tee: j['tee'] != null ? TeeInfo.fromJson(j['tee'] as Map<String, dynamic>) : null,
        courseHandicap: j['course_handicap'] as int? ?? 0,
        playingHandicap: j['playing_handicap'] as int? ?? 0,
      );
}

class Foursome {
  final int id;
  final int groupNumber;
  final bool hasPhantom;
  final List<int> pinkBallOrder;
  final List<Membership> memberships;
  /// Per-foursome game override.  Empty = inherit from Round.active_games.
  final List<String> activeGames;
  /// Game keys for which a config/model row already exists (read-only,
  /// computed by FoursomeSerializer.get_configured_games).
  final List<String> configuredGames;

  const Foursome({
    required this.id,
    required this.groupNumber,
    required this.hasPhantom,
    required this.pinkBallOrder,
    required this.memberships,
    this.activeGames    = const [],
    this.configuredGames = const [],
  });

  factory Foursome.fromJson(Map<String, dynamic> j) => Foursome(
        id:              j['id'] as int,
        groupNumber:     j['group_number'] as int,
        hasPhantom:      j['has_phantom'] as bool? ?? false,
        pinkBallOrder:   List<int>.from(j['pink_ball_order'] as List? ?? []),
        activeGames:     List<String>.from(j['active_games'] as List? ?? []),
        configuredGames: List<String>.from(j['configured_games'] as List? ?? []),
        memberships:     (j['memberships'] as List? ?? [])
            .map((m) => Membership.fromJson(m as Map<String, dynamic>))
            .toList(),
      );

  List<Membership> get realPlayers =>
      memberships.where((m) => !m.player.isPhantom).toList();

  bool containsPlayer(int playerId) =>
      memberships.any((m) => m.player.id == playerId);

  String get label => 'Group $groupNumber';
}

class Round {
  final int id;
  final int roundNumber;
  final String date;
  final CourseInfo course;
  final String status;
  final List<String> activeGames;
  final double betUnit;
  /// 'gross' | 'net' | 'strokes_off' — set at round level for tournaments.
  final String handicapMode;
  /// Percentage of handicap applied when mode=net (0–200, default 100).
  final int netPercent;
  final List<Foursome> foursomes;

  const Round({
    required this.id,
    required this.roundNumber,
    required this.date,
    required this.course,
    required this.status,
    required this.activeGames,
    required this.betUnit,
    this.handicapMode = 'net',
    this.netPercent   = 100,
    required this.foursomes,
  });

  factory Round.fromJson(Map<String, dynamic> j) => Round(
        id:           j['id'] as int,
        roundNumber:  j['round_number'] as int,
        date:         j['date'] as String,
        course:       CourseInfo.fromJson(j['course'] as Map<String, dynamic>),
        status:       j['status'] as String,
        activeGames:  List<String>.from(j['active_games'] as List? ?? []),
        betUnit:      double.parse(j['bet_unit'].toString()),
        handicapMode: j['handicap_mode'] as String? ?? 'net',
        netPercent:   j['net_percent']   as int?    ?? 100,
        foursomes:    (j['foursomes'] as List? ?? [])
            .map((f) => Foursome.fromJson(f as Map<String, dynamic>))
            .toList(),
      );
}

// ---------------------------------------------------------------------------
// Scorecard
// ---------------------------------------------------------------------------

class HoleScoreEntry {
  final int playerId;
  final String playerName;
  final int holeNumber;
  /// THIS PLAYER'S OWN stroke index on this hole (from their own tee).
  /// Distinct from [ScorecardHole.strokeIndex], which is the shared
  /// first-player SI.  Needed for per-match handicap calculations
  /// (e.g. Strokes-Off) in mixed men's/women's foursomes where a
  /// hole's SI on women's tees may differ from men's.  Falls back to
  /// 18 when missing on legacy payloads.
  final int strokeIndex;
  /// THIS PLAYER'S OWN par for this hole — can differ from
  /// [ScorecardHole.par] on courses where forward tees play a long
  /// par-4 as a par-5 (etc.).  Used by the entry screen's hole header
  /// to show slashed values when players are on different tees.
  final int par;
  /// THIS PLAYER'S OWN yardage for this hole (null if not set on the
  /// tee).  Used by the entry screen's hole header to show slashed
  /// values when players are on different tees.
  final int? yards;
  final int? grossScore;
  final int handicapStrokes;
  final int? netScore;
  final int? stablefordPoints;

  const HoleScoreEntry({
    required this.playerId,
    required this.playerName,
    required this.holeNumber,
    this.strokeIndex = 18,
    this.par = 4,
    this.yards,
    this.grossScore,
    required this.handicapStrokes,
    this.netScore,
    this.stablefordPoints,
  });

  factory HoleScoreEntry.fromJson(Map<String, dynamic> j) => HoleScoreEntry(
        playerId: j['player_id'] as int? ?? 0,
        playerName: j['player_name'] as String? ?? '',
        holeNumber: j['hole_number'] as int? ?? 0,
        strokeIndex: j['stroke_index'] as int? ?? 18,
        par: j['par'] as int? ?? 4,
        yards: j['yards'] as int?,
        grossScore: j['gross_score'] as int?,
        handicapStrokes: j['handicap_strokes'] as int? ?? 0,
        netScore: j['net_score'] as int?,
        stablefordPoints: j['stableford_points'] as int?,
      );
}

class ScorecardHole {
  final int holeNumber;
  final int par;
  final int strokeIndex;
  final int? yards;
  final List<HoleScoreEntry> scores;

  const ScorecardHole({
    required this.holeNumber,
    required this.par,
    required this.strokeIndex,
    this.yards,
    required this.scores,
  });

  factory ScorecardHole.fromJson(Map<String, dynamic> j) => ScorecardHole(
        holeNumber: j['hole_number'] as int,
        par: j['par'] as int? ?? 0,
        strokeIndex: j['stroke_index'] as int? ?? 0,
        yards: j['yards'] as int?,
        scores: (j['scores'] as List? ?? [])
            .map((s) => HoleScoreEntry.fromJson(s as Map<String, dynamic>))
            .toList(),
      );

  HoleScoreEntry? scoreFor(int playerId) =>
      scores.where((s) => s.playerId == playerId).firstOrNull;
}

class PlayerTotals {
  final int playerId;
  final String name;
  final int frontGross;
  final int backGross;
  final int totalGross;
  final int frontNet;
  final int backNet;
  final int totalNet;
  final int totalStableford;

  const PlayerTotals({
    required this.playerId,
    required this.name,
    required this.frontGross,
    required this.backGross,
    required this.totalGross,
    required this.frontNet,
    required this.backNet,
    required this.totalNet,
    required this.totalStableford,
  });

  factory PlayerTotals.fromJson(Map<String, dynamic> j) => PlayerTotals(
        playerId: j['player_id'] as int,
        name: j['name'] as String,
        frontGross: j['front_gross'] as int? ?? 0,
        backGross: j['back_gross'] as int? ?? 0,
        totalGross: j['total_gross'] as int? ?? 0,
        frontNet: j['front_net'] as int? ?? 0,
        backNet: j['back_net'] as int? ?? 0,
        totalNet: j['total_net'] as int? ?? 0,
        totalStableford: j['total_stableford'] as int? ?? 0,
      );
}

class Scorecard {
  final int foursomeId;
  final int groupNumber;
  final List<ScorecardHole> holes;
  final List<PlayerTotals> totals;

  const Scorecard({
    required this.foursomeId,
    required this.groupNumber,
    required this.holes,
    required this.totals,
  });

  factory Scorecard.fromJson(Map<String, dynamic> j) => Scorecard(
        foursomeId: j['foursome_id'] as int,
        groupNumber: j['group_number'] as int,
        holes: (j['holes'] as List? ?? [])
            .map((h) => ScorecardHole.fromJson(h as Map<String, dynamic>))
            .toList(),
        totals: (j['totals'] as List? ?? [])
            .map((t) => PlayerTotals.fromJson(t as Map<String, dynamic>))
            .toList(),
      );

  ScorecardHole? holeData(int holeNumber) =>
      holes.where((h) => h.holeNumber == holeNumber).firstOrNull;

  PlayerTotals? totalsFor(int playerId) =>
      totals.where((t) => t.playerId == playerId).firstOrNull;
}

// ---------------------------------------------------------------------------
// Six's
// ---------------------------------------------------------------------------

class SixesHoleResult {
  final int hole;
  final int? t1Net;
  final int? t2Net;
  final String? winner; // 'T1', 'T2', or 'Halved'
  final int margin;     // positive = team1 leading after this hole

  const SixesHoleResult({
    required this.hole,
    this.t1Net,
    this.t2Net,
    this.winner,
    required this.margin,
  });

  factory SixesHoleResult.fromJson(Map<String, dynamic> j) => SixesHoleResult(
        hole:   j['hole'] as int,
        t1Net:  j['t1_net'] as int?,
        t2Net:  j['t2_net'] as int?,
        winner: j['winner'] as String?,
        margin: j['margin'] as int? ?? 0,
      );
}

class SixesTeamInfo {
  final List<String> players; // player display names
  final String method;

  const SixesTeamInfo({required this.players, required this.method});

  factory SixesTeamInfo.fromJson(Map<String, dynamic> j) => SixesTeamInfo(
        players: List<String>.from(j['players'] as List? ?? []),
        method:  j['method'] as String? ?? '',
      );

  bool get hasPlayers => players.isNotEmpty;
}

class SixesSegment {
  final String label;
  final int startHole;
  final int endHole;
  final bool isExtra;
  final String status;  // 'pending', 'in_progress', 'complete', 'halved'
  final String winner;  // 'Team 1', 'Team 2', 'Halved', '—'
  final SixesTeamInfo team1;
  final SixesTeamInfo team2;
  final List<SixesHoleResult> holes; // holes played so far in this segment

  const SixesSegment({
    required this.label,
    required this.startHole,
    required this.endHole,
    required this.isExtra,
    required this.status,
    required this.winner,
    required this.team1,
    required this.team2,
    required this.holes,
  });

  factory SixesSegment.fromJson(Map<String, dynamic> j) => SixesSegment(
        label:     j['label'] as String? ?? '',
        startHole: j['start_hole'] as int? ?? 1,
        endHole:   j['end_hole'] as int? ?? 6,
        isExtra:   j['is_extra'] as bool? ?? false,
        status:    j['status'] as String? ?? 'pending',
        winner:    j['winner'] as String? ?? '—',
        team1:     SixesTeamInfo.fromJson(j['team1'] as Map<String, dynamic>? ?? {}),
        team2:     SixesTeamInfo.fromJson(j['team2'] as Map<String, dynamic>? ?? {}),
        holes: (j['holes'] as List? ?? [])
            .map((h) => SixesHoleResult.fromJson(h as Map<String, dynamic>))
            .toList(),
      );

  int get totalHoles => endHole - startHole + 1;

  /// Human-readable match status: "1 UP thru 3", "4 and 2", "All Square", etc.
  String get statusDisplay {
    if (!team1.hasPlayers || !team2.hasPlayers) return 'Select Players';
    if (holes.isEmpty) return '—';

    final holesPlayed  = holes.length;
    final lastMargin   = holes.last.margin;
    final absMargin    = lastMargin.abs();
    final holesLeft    = totalHoles - holesPlayed;

    if (status == 'complete' || status == 'halved') {
      if (winner == 'Halved') return 'Halved';
      // Early finish: "X and Y" (e.g. "4 and 2")
      if (holesLeft > 0) return '$absMargin and $holesLeft';
      // All holes played
      return absMargin > 0 ? '$absMargin UP' : 'Halved';
    }

    if (status == 'in_progress') {
      if (lastMargin == 0) return 'All Square thru $holesPlayed';
      return '$absMargin UP thru $holesPlayed';
    }

    return '—';
  }
}

class SixesSummary {
  final List<SixesSegment> segments;
  final int team1Wins;
  final int team2Wins;
  final int halves;

  /// 'net', 'gross', or 'strokes_off'.  Comes from the new handicap block
  /// on the sixes summary response; defaults to 'net' for older backends.
  final String handicapMode;

  /// Percent of playing handicap to apply in net mode (100 = full).
  final int netPercent;

  const SixesSummary({
    required this.segments,
    required this.team1Wins,
    required this.team2Wins,
    required this.halves,
    required this.handicapMode,
    required this.netPercent,
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';

  factory SixesSummary.fromJson(Map<String, dynamic> j) {
    final overall = j['overall']  as Map<String, dynamic>? ?? {};
    final hcap    = j['handicap'] as Map<String, dynamic>? ?? {};
    return SixesSummary(
      segments: (j['segments'] as List? ?? [])
          .map((s) => SixesSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
      team1Wins:    overall['team1_wins'] as int? ?? 0,
      team2Wins:    overall['team2_wins'] as int? ?? 0,
      halves:       overall['halves']     as int? ?? 0,
      handicapMode: hcap['mode']          as String? ?? 'net',
      netPercent:   hcap['net_percent']   as int?    ?? 100,
    );
  }
}

// ---------------------------------------------------------------------------
// Points 5-3-1
// ---------------------------------------------------------------------------

/// Per-player running total for Points 5-3-1 (one row per real player
/// in the foursome).  money = (points − 3 × holesPlayed) × bet_unit.
class Points531PlayerTotal {
  final int    playerId;
  final String name;
  final String shortName;
  final double points;
  final int    holesPlayed;
  final double money;

  const Points531PlayerTotal({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.points,
    required this.holesPlayed,
    required this.money,
  });

  factory Points531PlayerTotal.fromJson(Map<String, dynamic> j) =>
      Points531PlayerTotal(
        playerId:    j['player_id']    as int,
        name:        j['name']         as String? ?? '',
        shortName:   j['short_name']   as String? ?? '',
        points:      (j['points']      as num?)?.toDouble() ?? 0.0,
        holesPlayed: j['holes_played'] as int? ?? 0,
        money:       (j['money']       as num?)?.toDouble() ?? 0.0,
      );
}

/// Per-player entry for a single hole.
class Points531HoleEntry {
  final int    playerId;
  final String name;
  final String shortName;
  final int    netScore;
  final double points;

  const Points531HoleEntry({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.netScore,
    required this.points,
  });

  factory Points531HoleEntry.fromJson(Map<String, dynamic> j) =>
      Points531HoleEntry(
        playerId:  j['player_id']  as int,
        name:      j['name']       as String? ?? '',
        shortName: j['short_name'] as String? ?? '',
        netScore:  j['net_score']  as int? ?? 0,
        points:    (j['points']    as num?)?.toDouble() ?? 0.0,
      );
}

/// One hole in the points grid — [entries] are sorted winner-first.
class Points531Hole {
  final int hole;
  final List<Points531HoleEntry> entries;

  const Points531Hole({required this.hole, required this.entries});

  factory Points531Hole.fromJson(Map<String, dynamic> j) => Points531Hole(
        hole: j['hole'] as int? ?? 0,
        entries: (j['entries'] as List? ?? [])
            .map((e) => Points531HoleEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Full summary for a Points 5-3-1 game — shape mirrors the Python
/// points_531_summary() output.
class Points531Summary {
  /// 'pending' | 'in_progress' | 'complete'.  Matches the MatchStatus
  /// values used by other games.
  final String status;
  final String handicapMode;
  final int    netPercent;
  final List<Points531PlayerTotal> players;
  final List<Points531Hole>        holes;
  final double betUnit;
  final int    parPerHole;

  const Points531Summary({
    required this.status,
    required this.handicapMode,
    required this.netPercent,
    required this.players,
    required this.holes,
    required this.betUnit,
    required this.parPerHole,
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';

  factory Points531Summary.fromJson(Map<String, dynamic> j) {
    final hcap  = j['handicap'] as Map<String, dynamic>? ?? {};
    final money = j['money']    as Map<String, dynamic>? ?? {};
    return Points531Summary(
      status:       j['status'] as String? ?? 'pending',
      handicapMode: hcap['mode']        as String? ?? 'net',
      netPercent:   hcap['net_percent'] as int?    ?? 100,
      players: (j['players'] as List? ?? [])
          .map((p) => Points531PlayerTotal
              .fromJson(p as Map<String, dynamic>))
          .toList(),
      holes: (j['holes'] as List? ?? [])
          .map((h) => Points531Hole.fromJson(h as Map<String, dynamic>))
          .toList(),
      betUnit:    (money['bet_unit']     as num?)?.toDouble() ?? 1.0,
      parPerHole: money['par_per_hole']  as int?    ?? 3,
    );
  }
}

// ---------------------------------------------------------------------------
// Skins
// ---------------------------------------------------------------------------

/// Per-player running total for a Skins game.
class SkinsPlayerTotal {
  final int    playerId;
  final String name;
  final String shortName;
  final int    skinsWon;    // regular per-hole skins
  final int    junkSkins;   // manually entered junk skins
  final int    totalSkins;  // skinsWon + junkSkins
  final double payout;      // share of the pool

  const SkinsPlayerTotal({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.skinsWon,
    required this.junkSkins,
    required this.totalSkins,
    required this.payout,
  });

  factory SkinsPlayerTotal.fromJson(Map<String, dynamic> j) =>
      SkinsPlayerTotal(
        playerId:   j['player_id']   as int,
        name:       j['name']        as String? ?? '',
        shortName:  j['short_name']  as String? ?? '',
        skinsWon:   j['skins_won']   as int? ?? 0,
        junkSkins:  j['junk_skins']  as int? ?? 0,
        totalSkins: j['total_skins'] as int? ?? 0,
        payout:     (j['payout']     as num?)?.toDouble() ?? 0.0,
      );
}

/// A single junk-skin entry on a hole (one player's count).
class SkinsJunkEntry {
  final int    playerId;
  final String shortName;
  final int    count;

  const SkinsJunkEntry({
    required this.playerId,
    required this.shortName,
    required this.count,
  });

  factory SkinsJunkEntry.fromJson(Map<String, dynamic> j) => SkinsJunkEntry(
        playerId:  j['player_id']  as int,
        shortName: j['short_name'] as String? ?? '',
        count:     j['count']      as int? ?? 0,
      );
}

/// Per-hole outcome for the skins grid.
class SkinsHole {
  final int         hole;
  final int?        winnerId;
  final String?     winnerShort;
  final int         skinsValue;  // skins at stake / awarded
  final bool        isCarry;     // true when skin carried (tied, carryover=on)
  /// isCarry=false && winnerId==null → skin was killed (no-carryover tie)
  final List<SkinsJunkEntry> junk;

  const SkinsHole({
    required this.hole,
    required this.winnerId,
    required this.winnerShort,
    required this.skinsValue,
    required this.isCarry,
    required this.junk,
  });

  bool get isDead => !isCarry && winnerId == null;

  factory SkinsHole.fromJson(Map<String, dynamic> j) => SkinsHole(
        hole:        j['hole']         as int? ?? 0,
        winnerId:    j['winner_id']    as int?,
        winnerShort: j['winner_short'] as String?,
        skinsValue:  j['skins_value']  as int? ?? 1,
        isCarry:     j['is_carry']     as bool? ?? false,
        junk: (j['junk'] as List? ?? [])
            .map((e) => SkinsJunkEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Full summary for a Skins game — mirrors the Python skins_summary() shape.
class SkinsSummary {
  /// 'pending' | 'in_progress' | 'complete'.
  final String status;
  final String handicapMode;
  final int    netPercent;
  final bool   carryover;
  final bool   allowJunk;
  final List<SkinsPlayerTotal> players;
  final List<SkinsHole>        holes;
  final double betUnit;
  final double pool;      // num_players × bet_unit
  final int    totalSkins; // grand total skins won (denominator)

  const SkinsSummary({
    required this.status,
    required this.handicapMode,
    required this.netPercent,
    required this.carryover,
    required this.allowJunk,
    required this.players,
    required this.holes,
    required this.betUnit,
    required this.pool,
    required this.totalSkins,
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';

  factory SkinsSummary.fromJson(Map<String, dynamic> j) {
    final hcap  = j['handicap'] as Map<String, dynamic>? ?? {};
    final money = j['money']    as Map<String, dynamic>? ?? {};
    return SkinsSummary(
      status:       j['status']     as String? ?? 'pending',
      handicapMode: hcap['mode']        as String? ?? 'net',
      netPercent:   hcap['net_percent'] as int?    ?? 100,
      carryover:    j['carryover']  as bool? ?? true,
      allowJunk:    j['allow_junk'] as bool? ?? false,
      players: (j['players'] as List? ?? [])
          .map((p) => SkinsPlayerTotal.fromJson(p as Map<String, dynamic>))
          .toList(),
      holes: (j['holes'] as List? ?? [])
          .map((h) => SkinsHole.fromJson(h as Map<String, dynamic>))
          .toList(),
      betUnit:    (money['bet_unit']    as num?)?.toDouble() ?? 1.0,
      pool:       (money['pool']        as num?)?.toDouble() ?? 0.0,
      totalSkins: (money['total_skins'] as num?)?.toInt()   ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Nassau
// ---------------------------------------------------------------------------

/// One player entry inside a Nassau team (for display).
class NassauPlayerInfo {
  final int    playerId;
  final String name;
  final String shortName;

  const NassauPlayerInfo({
    required this.playerId,
    required this.name,
    required this.shortName,
  });

  factory NassauPlayerInfo.fromJson(Map<String, dynamic> j) => NassauPlayerInfo(
        playerId:  j['player_id']  as int,
        name:      j['name']       as String? ?? '',
        shortName: j['short_name'] as String? ?? '',
      );
}

/// Result/margin for one of the three standard bets (front9, back9, overall).
class NassauBetResult {
  /// 'team1' | 'team2' | 'halved' | null (not yet resolved)
  final String? result;
  /// Positive = team1 leading; negative = team2 leading.
  final int     margin;
  final int     holesPlayed;
  /// Frozen margin at the moment the nine was decided (e.g. 5 for "5&4").
  /// Non-null only when the nine was decided before all holes were played.
  final int?    decidedMargin;
  /// Holes remaining when the nine was decided (e.g. 4 for "5&4").
  /// > 0 = early finish; 0 or null = ran to the natural end.
  final int?    decidedRemaining;

  const NassauBetResult({
    required this.result,
    required this.margin,
    required this.holesPlayed,
    this.decidedMargin,
    this.decidedRemaining,
  });

  factory NassauBetResult.fromJson(Map<String, dynamic> j) => NassauBetResult(
        result:           j['result']            as String?,
        margin:           j['margin']            as int? ?? 0,
        holesPlayed:      j['holes_played']      as int? ?? 0,
        decidedMargin:    j['decided_margin']    as int?,
        decidedRemaining: j['decided_remaining'] as int?,
      );

  /// True when the bet has been decided.
  bool get isComplete => result != null;

  /// Human-readable status: "T1 1UP", "All Square", "T2 2UP thru 6", etc.
  String statusLabel({required bool useTeamNames, String t1Label = 'T1', String t2Label = 'T2'}) {
    if (isComplete) {
      if (result == 'halved') return 'Halved';
      final winner = result == 'team1' ? t1Label : t2Label;
      return '$winner wins';
    }
    if (holesPlayed == 0) return 'Not started';
    final abs = margin.abs();
    if (margin == 0) return 'All Square thru $holesPlayed';
    final leader = margin > 0 ? t1Label : t2Label;
    return '$leader $abs UP thru $holesPlayed';
  }
}

/// One press bet result.
class NassauPressResult {
  final String  nine;       // 'front' | 'back'
  final String  pressType;  // 'manual' | 'auto'
  final int     startHole;
  final int     endHole;
  final String? result;     // 'team1' | 'team2' | 'halved' | null
  final int?    margin;
  /// Holes remaining in the press when it closed.  0 = ran to natural end.
  /// > 0 = closed early — used for match-play "4&3" notation.
  final int     holesRemaining;

  const NassauPressResult({
    required this.nine,
    required this.pressType,
    required this.startHole,
    required this.endHole,
    this.result,
    this.margin,
    this.holesRemaining = 0,
  });

  factory NassauPressResult.fromJson(Map<String, dynamic> j) => NassauPressResult(
        nine:           j['nine']            as String? ?? 'front',
        pressType:      j['press_type']      as String? ?? 'auto',
        startHole:      j['start_hole']      as int? ?? 1,
        endHole:        j['end_hole']        as int? ?? 9,
        result:         j['result']          as String?,
        margin:         j['margin']          as int?,
        holesRemaining: j['holes_remaining'] as int? ?? 0,
      );
}

/// Per-hole data for the Nassau grid.
class NassauHoleData {
  final int    hole;
  final String? winner;  // 'team1' | 'team2' | 'halved' | null (not yet played)
  final int?   t1Net;
  final int?   t2Net;
  final int?   front9Margin;
  final int?   back9Margin;
  final int?   overallMargin;

  const NassauHoleData({
    required this.hole,
    this.winner,
    this.t1Net,
    this.t2Net,
    this.front9Margin,
    this.back9Margin,
    this.overallMargin,
  });

  factory NassauHoleData.fromJson(Map<String, dynamic> j) => NassauHoleData(
        hole:          j['hole']           as int,
        winner:        j['winner']         as String?,
        t1Net:         j['t1_net']         as int?,
        t2Net:         j['t2_net']         as int?,
        front9Margin:  j['front9_margin']  as int?,
        back9Margin:   j['back9_margin']   as int?,
        overallMargin: j['overall_margin'] as int?,
      );
}

/// Full summary for a Nassau game — mirrors nassau_summary() output.
class NassauSummary {
  final String status;           // 'pending' | 'in_progress' | 'complete'
  final String handicapMode;
  final int    netPercent;
  final String pressMode;        // 'none' | 'manual' | 'auto' | 'both'
  final double betUnit;
  final double pressUnit;

  // Teams
  final List<NassauPlayerInfo> team1;
  final List<NassauPlayerInfo> team2;

  // Bet results
  final NassauBetResult front9;
  final NassauBetResult back9;
  final NassauBetResult overall;

  // Presses
  final List<NassauPressResult> presses;

  // Payouts (+ve = team1 wins that dollar amount)
  final double payoutFront9;
  final double payoutBack9;
  final double payoutOverall;
  final double payoutPresses;
  final double payoutTotal;

  // Hole-by-hole data
  final List<NassauHoleData> holes;

  // Press button availability
  final bool    canPress;
  final String? pressAvailableNine;  // 'front' | 'back' | null

  const NassauSummary({
    required this.status,
    required this.handicapMode,
    required this.netPercent,
    required this.pressMode,
    required this.betUnit,
    required this.pressUnit,
    required this.team1,
    required this.team2,
    required this.front9,
    required this.back9,
    required this.overall,
    required this.presses,
    required this.payoutFront9,
    required this.payoutBack9,
    required this.payoutOverall,
    required this.payoutPresses,
    required this.payoutTotal,
    required this.holes,
    required this.canPress,
    this.pressAvailableNine,
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';
  bool get allowsManualPress => pressMode == 'manual' || pressMode == 'both';

  /// Short label for team 1 (first player's short name).
  String get t1Label =>
      team1.isNotEmpty ? team1.first.shortName : 'T1';

  /// Short label for team 2 (first player's short name).
  String get t2Label =>
      team2.isNotEmpty ? team2.first.shortName : 'T2';

  /// Display label for a bet result from this game's perspective.
  String betLabel(NassauBetResult bet) =>
      bet.statusLabel(useTeamNames: true, t1Label: t1Label, t2Label: t2Label);

  factory NassauSummary.fromJson(Map<String, dynamic> j) {
    final teams   = j['teams']   as Map<String, dynamic>? ?? {};
    final payouts = j['payouts'] as Map<String, dynamic>? ?? {};
    return NassauSummary(
      status:       j['status']        as String? ?? 'pending',
      handicapMode: j['handicap_mode'] as String? ?? 'net',
      netPercent:   j['net_percent']   as int?    ?? 100,
      pressMode:    j['press_mode']    as String? ?? 'none',
      betUnit:      (j['bet_unit']     as num?)?.toDouble() ?? 1.0,
      pressUnit:    (j['press_unit']   as num?)?.toDouble() ?? 0.0,
      team1: ((teams['team1'] as List?) ?? [])
          .map((p) => NassauPlayerInfo.fromJson(p as Map<String, dynamic>))
          .toList(),
      team2: ((teams['team2'] as List?) ?? [])
          .map((p) => NassauPlayerInfo.fromJson(p as Map<String, dynamic>))
          .toList(),
      front9:  NassauBetResult.fromJson(j['front9']  as Map<String, dynamic>? ?? {}),
      back9:   NassauBetResult.fromJson(j['back9']   as Map<String, dynamic>? ?? {}),
      overall: NassauBetResult.fromJson(j['overall'] as Map<String, dynamic>? ?? {}),
      presses: ((j['presses'] as List?) ?? [])
          .map((p) => NassauPressResult.fromJson(p as Map<String, dynamic>))
          .toList(),
      payoutFront9:   (payouts['front9']   as num?)?.toDouble() ?? 0.0,
      payoutBack9:    (payouts['back9']    as num?)?.toDouble() ?? 0.0,
      payoutOverall:  (payouts['overall']  as num?)?.toDouble() ?? 0.0,
      payoutPresses:  (payouts['presses']  as num?)?.toDouble() ?? 0.0,
      payoutTotal:    (payouts['total']    as num?)?.toDouble() ?? 0.0,
      holes: ((j['holes'] as List?) ?? [])
          .map((h) => NassauHoleData.fromJson(h as Map<String, dynamic>))
          .toList(),
      canPress:           j['can_press']            as bool?   ?? false,
      pressAvailableNine: j['press_available_nine'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// Leaderboard (loosely typed — shape varies by game)
// ---------------------------------------------------------------------------

class LeaderboardGame {
  final String label;
  final dynamic data; // varies by game type — passed through to UI as-is

  const LeaderboardGame({required this.label, required this.data});
}

class Leaderboard {
  final int roundId;
  final String roundDate;
  final String course;
  final String status;
  final List<String> activeGames;
  final Map<String, LeaderboardGame> games;
  final int? tournamentId;
  final String? tournamentName;
  final List<String> tournamentActiveGames;

  const Leaderboard({
    required this.roundId,
    required this.roundDate,
    required this.course,
    required this.status,
    required this.activeGames,
    required this.games,
    this.tournamentId,
    this.tournamentName,
    this.tournamentActiveGames = const [],
  });

  factory Leaderboard.fromJson(Map<String, dynamic> j) {
    final gamesRaw = j['games'] as Map<String, dynamic>? ?? {};
    final games = <String, LeaderboardGame>{};
    for (final entry in gamesRaw.entries) {
      final g = entry.value as Map<String, dynamic>;
      games[entry.key] = LeaderboardGame(
        label: g['label'] as String? ?? entry.key,
        data: g,
      );
    }
    return Leaderboard(
      roundId: j['round_id'] as int,
      roundDate: j['round_date'] as String,
      course: j['course'] as String,
      status: j['status'] as String,
      activeGames: List<String>.from(j['active_games'] as List? ?? []),
      games: games,
      tournamentId: j['tournament_id'] as int?,
      tournamentName: j['tournament_name'] as String?,
      tournamentActiveGames: List<String>.from(
          j['tournament_active_games'] as List? ?? []),
    );
  }
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Three-Person Match
// ---------------------------------------------------------------------------

/// Per-player summary from the phase-1 (5-3-1) standings.
class TpmPlayerSummary {
  final int    playerId;
  final String name;
  final String shortName;
  final double phase1Points;
  final int    phase1Place;
  final double money;

  const TpmPlayerSummary({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.phase1Points,
    required this.phase1Place,
    required this.money,
  });

  factory TpmPlayerSummary.fromJson(Map<String, dynamic> j) => TpmPlayerSummary(
    playerId:     j['player_id']     as int,
    name:         j['name']          as String? ?? '',
    shortName:    j['short_name']    as String? ?? '',
    phase1Points: (j['phase1_points'] as num?)?.toDouble() ?? 0.0,
    phase1Place:  j['phase1_place']  as int?    ?? 0,
    money:        (j['money']        as num?)?.toDouble() ?? 0.0,
  );
}

/// A single hole entry in the phase-1 (5-3-1) grid.
class TpmP1HoleEntry {
  final int    playerId;
  final String shortName;
  final int    netScore;
  final double points;

  const TpmP1HoleEntry({
    required this.playerId,
    required this.shortName,
    required this.netScore,
    required this.points,
  });

  factory TpmP1HoleEntry.fromJson(Map<String, dynamic> j) => TpmP1HoleEntry(
    playerId:  j['player_id']  as int,
    shortName: j['short_name'] as String? ?? '',
    netScore:  j['net_score']  as int,
    points:    (j['points']    as num?)?.toDouble() ?? 0.0,
  );
}

/// Full summary for a Three-Person Match game.
class ThreePersonMatchSummary {
  /// One of: pending | in_progress | tiebreak | phase2 | complete
  final String              status;
  final String              handicapMode;
  final int                 netPercent;
  final List<TpmPlayerSummary> players;
  /// Number of holes scored so far (0–9).
  final int                 holesScored;
  /// Per-hole breakdown for the 5-3-1 phase (holes 1–9).
  final List<Map<String, dynamic>> holes;
  final Map<String, dynamic> money;
  /// Back-9 match play data; null if tiebreak not yet resolved or phase 1 not done.
  final Map<String, dynamic>? phase2;
  /// Tiebreak data; non-null when status == 'tiebreak'.
  final Map<String, dynamic>? tiebreak;

  const ThreePersonMatchSummary({
    required this.status,
    required this.handicapMode,
    required this.netPercent,
    required this.players,
    required this.holesScored,
    required this.holes,
    required this.money,
    this.phase2,
    this.tiebreak,
  });

  bool get isComplete   => status == 'complete';
  bool get isInProgress => status == 'in_progress' || status == 'tiebreak' || status == 'phase2';
  bool get isTiebreak   => status == 'tiebreak';
  bool get isPhase2     => status == 'phase2' || (status == 'complete' && phase2 != null);

  factory ThreePersonMatchSummary.fromJson(Map<String, dynamic> j) {
    final hcap = j['handicap'] as Map<String, dynamic>? ?? {};
    return ThreePersonMatchSummary(
      status:       j['status']       as String? ?? 'pending',
      handicapMode: hcap['mode']       as String? ?? 'net',
      netPercent:   hcap['net_percent'] as int?   ?? 100,
      players: (j['players'] as List? ?? [])
          .map((p) => TpmPlayerSummary.fromJson(p as Map<String, dynamic>))
          .toList(),
      holesScored: j['holes_scored'] as int? ?? 0,
      holes: (j['holes'] as List? ?? [])
          .map((h) => h as Map<String, dynamic>)
          .toList(),
      money:    j['money']    as Map<String, dynamic>? ?? {},
      phase2:   j['phase2']   as Map<String, dynamic>?,
      tiebreak: j['tiebreak'] as Map<String, dynamic>?,
    );
  }
}

// ---------------------------------------------------------------------------
// Phantom player init
// ---------------------------------------------------------------------------

/// Response from POST /api/foursomes/<id>/phantom/init/
///
/// Contains the per-hole source player mapping so the UI can show which
/// real player the phantom is copying on each hole.
class PhantomInitResult {
  final int         phantomPlayerId;
  final int         playingHandicap;
  final String      algorithm;
  /// {hole_number → source_player_id} for holes 1–18.
  final Map<int, int> sourceByHole;

  const PhantomInitResult({
    required this.phantomPlayerId,
    required this.playingHandicap,
    required this.algorithm,
    required this.sourceByHole,
  });

  factory PhantomInitResult.fromJson(Map<String, dynamic> j) {
    final raw = j['source_by_hole'] as Map<String, dynamic>? ?? {};
    final sourceByHole = raw.map(
      (k, v) => MapEntry(int.parse(k), v as int),
    );
    return PhantomInitResult(
      phantomPlayerId: j['phantom_player_id'] as int,
      playingHandicap: j['playing_handicap']  as int,
      algorithm:       j['algorithm']         as String? ?? 'rotating_player_scores',
      sourceByHole:    sourceByHole,
    );
  }
}
