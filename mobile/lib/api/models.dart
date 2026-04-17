/// api/models.dart
/// Dart data classes mirroring the Django API responses.
/// All fromJson constructors handle null-safety explicitly.

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class AuthResult {
  final String token;
  final int? playerId;
  final String? name;
  final String? handicapIndex;

  const AuthResult({
    required this.token,
    this.playerId,
    this.name,
    this.handicapIndex,
  });

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        token: j['token'] as String,
        playerId: j['player_id'] as int?,
        name: j['name'] as String?,
        handicapIndex: j['handicap_index'] as String?,
      );
}

// ---------------------------------------------------------------------------
// Reference data
// ---------------------------------------------------------------------------

class PlayerProfile {
  final int id;
  final String name;
  final String handicapIndex;
  final bool isPhantom;
  final String email;
  final String phone;

  const PlayerProfile({
    required this.id,
    required this.name,
    required this.handicapIndex,
    required this.isPhantom,
    required this.email,
    this.phone = '',
  });

  factory PlayerProfile.fromJson(Map<String, dynamic> j) => PlayerProfile(
        id: j['id'] as int,
        name: j['name'] as String,
        handicapIndex: j['handicap_index']?.toString() ?? '0.0',
        isPhantom: j['is_phantom'] as bool? ?? false,
        email: j['email'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
      );
}

class TeeInfo {
  final int id;
  final String courseName;
  final String teeName;
  final int slope;
  final double courseRating;
  final int par;

  const TeeInfo({
    required this.id,
    required this.courseName,
    required this.teeName,
    required this.slope,
    required this.courseRating,
    required this.par,
  });

  factory TeeInfo.fromJson(Map<String, dynamic> j) => TeeInfo(
        id: j['id'] as int,
        courseName: j['course_name'] as String,
        teeName: j['tee_name'] as String,
        slope: j['slope'] as int,
        courseRating: double.parse(j['course_rating'].toString()),
        par: j['par'] as int,
      );

  String get display => '$courseName — $teeName';
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

  const Tournament({
    required this.id,
    required this.name,
    required this.startDate,
    this.endDate,
    required this.rounds,
  });

  factory Tournament.fromJson(Map<String, dynamic> j) => Tournament(
        id: j['id'] as int,
        name: j['name'] as String,
        startDate: j['start_date'] as String,
        endDate: j['end_date'] as String?,
        rounds: (j['rounds'] as List? ?? [])
            .map((r) => RoundSummary.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}

class Membership {
  final int id;
  final PlayerProfile player;
  final int courseHandicap;
  final int playingHandicap;

  const Membership({
    required this.id,
    required this.player,
    required this.courseHandicap,
    required this.playingHandicap,
  });

  factory Membership.fromJson(Map<String, dynamic> j) => Membership(
        id: j['id'] as int,
        player: PlayerProfile.fromJson(j['player'] as Map<String, dynamic>),
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

  const Foursome({
    required this.id,
    required this.groupNumber,
    required this.hasPhantom,
    required this.pinkBallOrder,
    required this.memberships,
  });

  factory Foursome.fromJson(Map<String, dynamic> j) => Foursome(
        id: j['id'] as int,
        groupNumber: j['group_number'] as int,
        hasPhantom: j['has_phantom'] as bool? ?? false,
        pinkBallOrder: List<int>.from(j['pink_ball_order'] as List? ?? []),
        memberships: (j['memberships'] as List? ?? [])
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
  final TeeInfo course;
  final String status;
  final List<String> activeGames;
  final double betUnit;
  final List<Foursome> foursomes;

  const Round({
    required this.id,
    required this.roundNumber,
    required this.date,
    required this.course,
    required this.status,
    required this.activeGames,
    required this.betUnit,
    required this.foursomes,
  });

  factory Round.fromJson(Map<String, dynamic> j) => Round(
        id: j['id'] as int,
        roundNumber: j['round_number'] as int,
        date: j['date'] as String,
        course: TeeInfo.fromJson(j['course'] as Map<String, dynamic>),
        status: j['status'] as String,
        activeGames: List<String>.from(j['active_games'] as List? ?? []),
        betUnit: double.parse(j['bet_unit'].toString()),
        foursomes: (j['foursomes'] as List? ?? [])
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
  final int? grossScore;
  final int handicapStrokes;
  final int? netScore;
  final int? stablefordPoints;

  const HoleScoreEntry({
    required this.playerId,
    required this.playerName,
    required this.holeNumber,
    this.grossScore,
    required this.handicapStrokes,
    this.netScore,
    this.stablefordPoints,
  });

  factory HoleScoreEntry.fromJson(Map<String, dynamic> j) => HoleScoreEntry(
        playerId: j['player_id'] as int? ?? 0,
        playerName: j['player_name'] as String? ?? '',
        holeNumber: j['hole_number'] as int? ?? 0,
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

  const SixesSummary({
    required this.segments,
    required this.team1Wins,
    required this.team2Wins,
    required this.halves,
  });

  factory SixesSummary.fromJson(Map<String, dynamic> j) {
    final overall = j['overall'] as Map<String, dynamic>? ?? {};
    return SixesSummary(
      segments: (j['segments'] as List? ?? [])
          .map((s) => SixesSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
      team1Wins: overall['team1_wins'] as int? ?? 0,
      team2Wins: overall['team2_wins'] as int? ?? 0,
      halves:    overall['halves']     as int? ?? 0,
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

  const Leaderboard({
    required this.roundId,
    required this.roundDate,
    required this.course,
    required this.status,
    required this.activeGames,
    required this.games,
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
    );
  }
}
