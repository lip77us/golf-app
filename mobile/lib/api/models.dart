/// api/models.dart
/// Dart data classes mirroring the Django API responses.
/// All fromJson constructors handle null-safety explicitly.

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

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

/// Account that the logged-in user belongs to.  The tenant boundary —
/// every Player / Course / Tournament / Round the API returns is owned
/// by this Account.
class AccountInfo {
  final int    id;
  final String name;

  const AccountInfo({required this.id, required this.name});

  factory AccountInfo.fromJson(Map<String, dynamic> j) => AccountInfo(
        id:   j['id']   as int,
        name: j['name'] as String,
      );
}

/// One row from /api/account/members/.  Represents an active or
/// inactive user in the current account; admins use this to manage
/// roster + roles.
class Member {
  final int     id;
  final String  username;
  final String  email;
  final String  firstName;
  final String  lastName;
  final bool    isAccountAdmin;
  final bool    isActive;
  final bool    hasPlayerProfile;
  final String? dateJoined;
  final String? lastLogin;

  const Member({
    required this.id,
    required this.username,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.isAccountAdmin,
    required this.isActive,
    required this.hasPlayerProfile,
    this.dateJoined,
    this.lastLogin,
  });

  String get displayName {
    final full = ('$firstName $lastName').trim();
    return full.isEmpty ? username : full;
  }

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        id:               j['id']               as int,
        username:         j['username']         as String,
        email:            j['email']            as String? ?? '',
        firstName:        j['first_name']       as String? ?? '',
        lastName:         j['last_name']        as String? ?? '',
        isAccountAdmin:   j['is_account_admin'] as bool?   ?? false,
        isActive:         j['is_active']        as bool?   ?? true,
        hasPlayerProfile: j['has_player_profile'] as bool? ?? false,
        dateJoined:       j['date_joined']      as String?,
        lastLogin:        j['last_login']       as String?,
      );
}

class AuthResult {
  final String token;
  /// Login id (Django User.username).  Surfaced so the drawer can
  /// render "Paul Lipkin (paul)" without an extra /auth/me/ round-trip.
  final String username;

  /// Full player profile for this user, included directly in the login
  /// response so we don't have to follow up with a /auth/me/ call.  Null
  /// when the authenticated user has no linked Player (admin/staff).
  final PlayerProfile? player;

  /// True when the Django User has is_staff=True. Staff can create/delete
  /// tournaments regardless of whether they also have a linked player.
  final bool isStaff;

  /// True when this user is an admin within their Account.  Distinct from
  /// is_staff (Django admin site access).  Used to gate the future Manage
  /// Members screen.
  final bool isAccountAdmin;

  /// True for Halved support staff — unlocks the read-only "Support: open
  /// round" tool for diagnosing reported issues across accounts.
  final bool isSupport;

  /// The Account this user belongs to.
  final AccountInfo account;

  /// True when this verify call just SELF-CREATED a brand-new account (the
  /// phone wasn't known before).  The phone-login flow uses it to route a new
  /// user through profile setup instead of straight to the tournaments list.
  /// Always false for password login.
  final bool isNewAccount;

  const AuthResult({
    required this.token,
    required this.username,
    required this.account,
    this.player,
    this.isStaff        = false,
    this.isAccountAdmin = false,
    this.isSupport      = false,
    this.isNewAccount   = false,
  });

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        token:          j['token']    as String,
        username:       j['username'] as String? ?? '',
        isStaff:        j['is_staff']         as bool? ?? false,
        isAccountAdmin: j['is_account_admin'] as bool? ?? false,
        isSupport:      j['is_support']       as bool? ?? false,
        isNewAccount:   j['is_new_account']   as bool? ?? false,
        account:        AccountInfo.fromJson(
                          j['account'] as Map<String, dynamic>),
        player:         j['player'] is Map<String, dynamic>
            ? PlayerProfile.fromJson(j['player'] as Map<String, dynamic>)
            : null,
      );
}

/// Result of GET /api/auth/me/.
class MeResult {
  final String username;
  final bool isStaff;
  final bool isAccountAdmin;
  final bool isSupport;
  final AccountInfo account;
  final PlayerProfile? player;

  const MeResult({
    required this.username,
    required this.account,
    this.isStaff        = false,
    this.isAccountAdmin = false,
    this.isSupport      = false,
    this.player,
  });

  factory MeResult.fromJson(Map<String, dynamic> j) => MeResult(
        username:       j['username'] as String? ?? '',
        isStaff:        j['is_staff']         as bool? ?? false,
        isAccountAdmin: j['is_account_admin'] as bool? ?? false,
        isSupport:      j['is_support']       as bool? ?? false,
        account:        AccountInfo.fromJson(
                          j['account'] as Map<String, dynamic>),
        player:         j['player'] is Map<String, dynamic>
            ? PlayerProfile.fromJson(j['player'] as Map<String, dynamic>)
            : null,
      );
}

/// Result of GET /api/invite/ — the user's personal invite link + a
/// ready-to-send message for the native share sheet.
class InviteInfo {
  final String code;
  final String url;
  final String shareText;

  const InviteInfo({
    required this.code,
    required this.url,
    required this.shareText,
  });

  factory InviteInfo.fromJson(Map<String, dynamic> j) => InviteInfo(
        code:      j['code']       as String? ?? '',
        url:       j['url']        as String? ?? '',
        shareText: j['share_text'] as String? ?? '',
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
  /// The index to DISPLAY: for a connected (On Halved) golfer this is their
  /// self-maintained index from their own profile; otherwise == handicapIndex.
  /// Only populated by GET /api/players/ (and watcher-candidates).
  final String effectiveHandicapIndex;
  /// True when the displayed index is the golfer's OWN (they set a real value)
  /// — a friend's copy is then read-only. False when it falls back to local.
  final bool handicapIsAuthoritative;
  final bool isPhantom;
  final String email;
  final String phone;
  /// 'M' or 'W' — picks the default tee during round setup. Older
  /// server responses without the field fall back to 'M'.
  final String sex;
  /// ID of the Account member linked to this Player (so they can log
  /// in and record their own scores), or null when the Player has no
  /// linked login.  Editing this via PATCH /api/players/{id}/ is how
  /// the player form's "Linked App User" picker rebinds.
  final int? userId;

  /// True when this golfer has signed up (a registered user's verified phone
  /// matches this golfer's phone). Only populated by GET /api/players/.
  final bool isOnApp;

  const PlayerProfile({
    required this.id,
    required this.name,
    this.shortName = '',
    required this.handicapIndex,
    this.effectiveHandicapIndex = '',
    this.handicapIsAuthoritative = false,
    required this.isPhantom,
    required this.email,
    this.phone = '',
    this.sex = 'M',
    this.userId,
    this.isOnApp = false,
  });

  factory PlayerProfile.fromJson(Map<String, dynamic> j) => PlayerProfile(
        id: j['id'] as int,
        name: j['name'] as String,
        shortName: (j['short_name'] as String?) ?? '',
        handicapIndex: j['handicap_index']?.toString() ?? '0.0',
        effectiveHandicapIndex:
            j['effective_handicap_index']?.toString() ?? '',
        handicapIsAuthoritative:
            j['handicap_is_authoritative'] as bool? ?? false,
        isPhantom: j['is_phantom'] as bool? ?? false,
        email: j['email'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        sex: j['sex'] as String? ?? 'M',
        userId: j['user_id'] as int?,
        isOnApp: j['is_on_app'] as bool? ?? false,
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

  /// Index to show in the UI — a connected golfer's authoritative index when
  /// the list endpoint supplied it, else the local value.
  String get displayHandicap =>
      effectiveHandicapIndex.isNotEmpty ? effectiveHandicapIndex : handicapIndex;
}

class CourseInfo {
  final int id;
  final String name;
  final String city;
  final String state;
  /// Tees configured on this course.  Populated by GET /courses/
  /// (which prefetches them); empty when this CourseInfo was
  /// inflated from a thinner payload (e.g. round.course).
  final List<CourseTeeSummary> tees;

  const CourseInfo({
    required this.id,
    required this.name,
    this.city = '',
    this.state = '',
    this.tees = const [],
  });

  /// "City, ST" (or '' when unknown) for display/disambiguation.
  String get location =>
      [city, state].where((s) => s.isNotEmpty).join(', ');

  factory CourseInfo.fromJson(Map<String, dynamic> j) => CourseInfo(
        id: j['id'] as int,
        name: j['name'] as String,
        city: j['city'] as String? ?? '',
        state: j['state'] as String? ?? '',
        tees: (j['tees'] as List? ?? const [])
            .map((t) => CourseTeeSummary.fromJson(t as Map<String, dynamic>))
            .toList(),
      );

  @override
  bool operator ==(Object other) => other is CourseInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A course in the shared catalog (GET /api/catalog/courses/).
class CatalogCourse {
  final int id;
  final String name;
  final String city;
  final String state;
  final int teeCount;
  final bool alreadyInAccount;

  const CatalogCourse({
    required this.id,
    required this.name,
    this.city = '',
    this.state = '',
    this.teeCount = 0,
    this.alreadyInAccount = false,
  });

  String get location =>
      [city, state].where((s) => s.isNotEmpty).join(', ');

  factory CatalogCourse.fromJson(Map<String, dynamic> j) => CatalogCourse(
        id: j['id'] as int,
        name: j['name'] as String,
        city: j['city'] as String? ?? '',
        state: j['state'] as String? ?? '',
        teeCount: j['tee_count'] as int? ?? 0,
        alreadyInAccount: j['already_in_account'] as bool? ?? false,
      );
}


/// Compact tee shape nested inside CourseInfo for the manage-courses
/// screen.  No `holes` payload — pull that via `getTees()` if you
/// actually need per-hole par/SI/yards.
class CourseTeeSummary {
  final int     id;
  final String  teeName;
  final int     slope;
  final double  courseRating;
  final int     par;
  final String? sex;
  final int     sortPriority;

  const CourseTeeSummary({
    required this.id,
    required this.teeName,
    required this.slope,
    required this.courseRating,
    required this.par,
    this.sex,
    this.sortPriority = 100,
  });

  factory CourseTeeSummary.fromJson(Map<String, dynamic> j) => CourseTeeSummary(
        id:           j['id'] as int,
        teeName:      j['tee_name'] as String,
        slope:        j['slope'] as int,
        courseRating: double.parse(j['course_rating'].toString()),
        par:          j['par'] as int,
        sex:          j['sex'] as String?,
        sortPriority: j['sort_priority'] as int? ?? 100,
      );
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
  /// Per-hole data: 18 dicts with {number, par, stroke_index, yards}.
  /// Populated by GET /api/tees/{id}/; empty when this TeeInfo was
  /// inflated from a list payload (which omits the blob to keep the
  /// list response small).
  final List<Map<String, dynamic>> holes;

  const TeeInfo({
    required this.id,
    required this.course,
    required this.teeName,
    required this.slope,
    required this.courseRating,
    required this.par,
    this.sex,
    this.sortPriority = 100,
    this.holes = const [],
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
        holes: (j['holes'] as List? ?? const [])
            .map((h) => Map<String, dynamic>.from(h as Map))
            .toList(),
      );

  String get display => '${course.name} — $teeName';
}

// ---------------------------------------------------------------------------
// Tournament / Round hierarchy
// ---------------------------------------------------------------------------

class RoundSummary {
  final int id;
  final int courseId;
  final int roundNumber;
  final String date;
  final String courseName;
  final String status;
  final List<String> activeGames;
  final double betUnit;
  /// Cup point values per game type, e.g. {'nassau': 1.0, 'singles': 2.0}.
  /// Set at wizard time; applied automatically in CupRoundSetupScreen.
  final Map<String, double> gamePointValues;

  const RoundSummary({
    required this.id,
    required this.courseId,
    required this.roundNumber,
    required this.date,
    required this.courseName,
    required this.status,
    required this.activeGames,
    required this.betUnit,
    this.gamePointValues = const {},
  });

  factory RoundSummary.fromJson(Map<String, dynamic> j) => RoundSummary(
        id             : j['id'] as int,
        courseId       : j['course_id'] as int? ?? 0,
        roundNumber    : j['round_number'] as int,
        date           : j['date'] as String,
        courseName     : j['course_name'] as String? ?? '',
        status         : j['status'] as String,
        activeGames    : List<String>.from(j['active_games'] as List? ?? []),
        betUnit        : double.parse(j['bet_unit'].toString()),
        gamePointValues: (j['game_point_values'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, (v as num).toDouble())),
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

/// A read-only round from ANOTHER account that a friend added you to
/// (GET /api/rounds/shared-with-me/). Tapping it opens the leaderboard.
class SharedRoundSummary {
  final int    id;
  final String date;
  final String courseName;
  final String status;
  final List<String> activeGames;
  /// Source group label — the round creator's name, or the account name.
  final String groupLabel;
  /// The name of the player (in that group) that matched your phone.
  final String yourName;
  /// True when [id] is a TOURNAMENT id (a whole event you're watching) rather
  /// than a single round — routes to the tournament leaderboard.
  final bool isTournament;

  const SharedRoundSummary({
    required this.id,
    required this.date,
    required this.courseName,
    required this.status,
    required this.activeGames,
    required this.groupLabel,
    required this.yourName,
    this.isTournament = false,
  });

  factory SharedRoundSummary.fromJson(Map<String, dynamic> j) =>
      SharedRoundSummary(
        id:           j['id'] as int,
        date:         j['date'] as String? ?? '',
        courseName:   j['course_name'] as String? ?? '',
        status:       j['status'] as String? ?? '',
        activeGames:  List<String>.from(j['active_games'] as List? ?? []),
        groupLabel:   j['group_label'] as String? ?? '',
        yourName:     j['your_name'] as String? ?? '',
        isTournament: j['is_tournament'] as bool? ?? false,
      );
}

/// A round in ANOTHER account that a TD designated me to score
/// (GET /api/rounds/scoring-for-me/). Opening it goes to the round screen.
class ScoringRound {
  final int    id;
  final String date;
  final String courseName;
  final String status;
  final List<String> activeGames;
  final String groupLabel;
  final bool   isTournament;
  /// The foursome I'm scoring.
  final int    yourFoursomeId;

  const ScoringRound({
    required this.id,
    required this.date,
    required this.courseName,
    required this.status,
    required this.activeGames,
    required this.groupLabel,
    required this.isTournament,
    required this.yourFoursomeId,
  });

  factory ScoringRound.fromJson(Map<String, dynamic> j) => ScoringRound(
        id:             j['id'] as int,
        date:           j['date'] as String? ?? '',
        courseName:     j['course_name'] as String? ?? '',
        status:         j['status'] as String? ?? '',
        activeGames:    List<String>.from(j['active_games'] as List? ?? []),
        groupLabel:     j['group_label'] as String? ?? '',
        isTournament:   j['is_tournament'] as bool? ?? false,
        yourFoursomeId: j['your_foursome_id'] as int? ?? 0,
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
  /// Cup TournamentTeam colour name (e.g. "Red", "Tilden Blue", "Green")
  /// when the player is assigned to a team in the round's tournament.
  /// Null on casual rounds or for unaffiliated players.  Mobile resolves
  /// to a Color via resolveTripleCupTeamColor().
  final String? cupTeamColour;
  /// Cup TournamentTeam display name — same null-rules as cupTeamColour.
  final String? cupTeamName;
  /// True when this member is the designated scorer for the foursome
  /// (delegated cross-account score entry, Friends Phase 2b).
  final bool isScorer;

  const Membership({
    required this.id,
    required this.player,
    this.tee,
    required this.courseHandicap,
    required this.playingHandicap,
    this.cupTeamColour,
    this.cupTeamName,
    this.isScorer = false,
  });

  factory Membership.fromJson(Map<String, dynamic> j) => Membership(
        id: j['id'] as int,
        player: PlayerProfile.fromJson(j['player'] as Map<String, dynamic>),
        tee: j['tee'] != null ? TeeInfo.fromJson(j['tee'] as Map<String, dynamic>) : null,
        courseHandicap: j['course_handicap'] as int? ?? 0,
        playingHandicap: j['playing_handicap'] as int? ?? 0,
        cupTeamColour: j['cup_team_colour'] as String?,
        cupTeamName:   j['cup_team_name']   as String?,
        isScorer:      j['is_scorer'] as bool? ?? false,
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
  /// Scheduled tee time, e.g. "08:00" or null if not set.
  final String? teeTime;
  /// True iff at least one hole has been scored for this foursome.
  /// Used to hide the "Confirm Tee Boxes" entry point on the Round
  /// screen once scoring has begun — server refuses the tee change
  /// in that case anyway.
  final bool hasAnyScore;
  /// True when the viewer is a designated (phone-matched) scorer of THIS
  /// foursome — so a cross-account scorer can score + edit tees for their group.
  final bool youScore;

  const Foursome({
    required this.id,
    required this.groupNumber,
    required this.hasPhantom,
    required this.pinkBallOrder,
    required this.memberships,
    this.activeGames     = const [],
    this.configuredGames = const [],
    this.teeTime,
    this.hasAnyScore     = false,
    this.youScore        = false,
  });

  factory Foursome.fromJson(Map<String, dynamic> j) => Foursome(
        id:              j['id'] as int,
        groupNumber:     j['group_number'] as int,
        hasPhantom:      j['has_phantom'] as bool? ?? false,
        pinkBallOrder:   List<int>.from(j['pink_ball_order'] as List? ?? []),
        activeGames:     List<String>.from(j['active_games'] as List? ?? []),
        configuredGames: List<String>.from(j['configured_games'] as List? ?? []),
        teeTime:         j['tee_time'] as String?,
        hasAnyScore:     j['has_any_score'] as bool? ?? false,
        youScore:        j['you_score'] as bool? ?? false,
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
  /// USGA-style max score: when true, every per-hole score is capped at
  /// net par + 2 for game scoring (Net and Strokes-Off only; Gross mode
  /// games ignore the cap).  Stored gross scores are unaffected.
  final bool netMaxDoubleBogey;
  final List<Foursome> foursomes;
  /// True when this round has been configured via CupRoundSetupScreen
  /// (i.e. a RyderCupRoundConfig exists on the backend).
  /// When true, score entry skips all game setup screens.
  final bool isCupRound;
  /// Irish Rumble balls-per-segment config — list of
  /// {start_hole, end_hole, balls_to_count} maps.  Empty when IR is not active.
  final List<Map<String, dynamic>> irBallsConfig;
  /// Short token used by the public spectator URL (/watch/<token>/).
  /// Null on legacy rounds that haven't been re-saved post-migration.
  final String? watchToken;
  /// True only for this round's TD/organizer (round is in the viewer's account
  /// and they're an admin). A cross-account designated scorer gets false, so
  /// the app hides TD config and shows only score entry + tee editing.
  final bool canManage;

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
    this.netMaxDoubleBogey = true,
    required this.foursomes,
    this.isCupRound    = false,
    this.irBallsConfig = const [],
    this.watchToken,
    this.canManage     = false,
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
        netMaxDoubleBogey: j['net_max_double_bogey'] as bool? ?? true,
        isCupRound:   j['is_cup_round']  as bool?   ?? false,
        watchToken:   j['watch_token']   as String?,
        canManage:    j['can_manage']    as bool?   ?? false,
        irBallsConfig: (j['ir_balls_config'] as List? ?? [])
            .map((s) => Map<String, dynamic>.from(s as Map))
            .toList(),
        foursomes:    (j['foursomes'] as List? ?? [])
            .map((f) => Foursome.fromJson(f as Map<String, dynamic>))
            .toList(),
      );

  /// Returns the balls-to-count for a given hole number, or null if not configured.
  int? irBallsForHole(int hole) {
    for (final seg in irBallsConfig) {
      final start = seg['start_hole'] as int? ?? 0;
      final end   = seg['end_hole']   as int? ?? 0;
      if (hole >= start && hole <= end) return seg['balls_to_count'] as int?;
    }
    return null;
  }
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
// Sixes
// ---------------------------------------------------------------------------

class SixesHoleResult {
  final int hole;
  final int? t1Net;
  final int? t2Net;
  /// High-Low only: the higher of team 1's two nets on this hole.  Null
  /// for classic scoring, where only best-net matters.
  final int? t1Worst;
  /// High-Low only: the higher of team 2's two nets on this hole.
  final int? t2Worst;
  /// Points awarded this hole: 0 or 1 in classic, 0-2 in high_low.
  final int t1Points;
  final int t2Points;
  final String? winner; // 'T1', 'T2', or 'Halved'
  final int margin;     // positive = team1 leading after this hole
  /// High-Low only: false for holes played after the segment closed out.
  /// True for every hole in classic.
  final bool counts;

  const SixesHoleResult({
    required this.hole,
    this.t1Net,
    this.t2Net,
    this.t1Worst,
    this.t2Worst,
    this.t1Points = 0,
    this.t2Points = 0,
    this.winner,
    required this.margin,
    this.counts = true,
  });

  factory SixesHoleResult.fromJson(Map<String, dynamic> j) => SixesHoleResult(
        hole:     j['hole']    as int,
        t1Net:    j['t1_net']  as int?,
        t2Net:    j['t2_net']  as int?,
        t1Worst:  j['t1_worst'] as int?,
        t2Worst:  j['t2_worst'] as int?,
        t1Points: j['t1_pts']  as int? ?? 0,
        t2Points: j['t2_pts']  as int? ?? 0,
        winner:   j['winner']  as String?,
        margin:   j['margin']  as int? ?? 0,
        counts:   j['counts']  as bool? ?? true,
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
  /// Running point totals for this segment.  In classic these match the
  /// "holes won" count; in high_low they reflect the 2-pt-per-hole split
  /// and skip any holes played after the segment closed out.
  final int t1Points;
  final int t2Points;

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
    this.t1Points = 0,
    this.t2Points = 0,
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
        t1Points: j['t1_points'] as int? ?? 0,
        t2Points: j['t2_points'] as int? ?? 0,
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

  /// 'per_segment' (legacy default — spread SO across 3 matches) or
  /// 'full_round' (allocate strokes by round-wide stroke index).  Only
  /// meaningful when handicapMode == 'strokes_off'.
  final String handicapAllocation;

  /// 'classic' (best-ball, 1 pt/hole, with extras) or 'high_low'
  /// (best+worst, 2 pts/hole, 3 segments only, strict closeout).
  final String scoringFormat;

  const SixesSummary({
    required this.segments,
    required this.team1Wins,
    required this.team2Wins,
    required this.halves,
    required this.handicapMode,
    required this.netPercent,
    this.handicapAllocation = 'per_segment',
    this.scoringFormat      = 'classic',
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';
  bool get isHighLow    => scoringFormat == 'high_low';
  bool get isClassic    => scoringFormat == 'classic';

  factory SixesSummary.fromJson(Map<String, dynamic> j) {
    final overall = j['overall']  as Map<String, dynamic>? ?? {};
    final hcap    = j['handicap'] as Map<String, dynamic>? ?? {};
    return SixesSummary(
      segments: (j['segments'] as List? ?? [])
          .map((s) => SixesSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
      team1Wins:          overall['team1_wins']  as int? ?? 0,
      team2Wins:          overall['team2_wins']  as int? ?? 0,
      halves:             overall['halves']      as int? ?? 0,
      handicapMode:       hcap['mode']           as String? ?? 'net',
      netPercent:         hcap['net_percent']    as int?    ?? 100,
      handicapAllocation: hcap['allocation']     as String? ?? 'per_segment',
      scoringFormat:      j['scoring_format']    as String? ?? 'classic',
    );
  }
}

// ---------------------------------------------------------------------------
// Triple Cup (One Round Ryder Cup)
// ---------------------------------------------------------------------------

/// Default team accent colours used by *casual* Triple Cup (the
/// admin / player never picks colours for casual games).  Cup rounds
/// carry the real TournamentTeam.colour string on the summary and
/// resolve to whatever the cup admin chose; see
/// [resolveTripleCupTeamColor].
// Calmer burgundy / slate (matches GolfTokens.teamRed / teamBlue in
// lib/theme/tokens.dart).  Defined as literals here to keep models.dart
// free of theme imports; keep the two files in sync.  Per the May 2026
// design audit (D-04), team identity colors stay distinct from the
// loud Material reds reserved for errors and destructive actions.
// Casual Triple Cup team colours — the color standard's blue (team 1) / orange
// (team 2). Matches GameColors.team1/team2 (blue.shade700 / orange.shade800).
// Cup mode overrides these with the TD's configured team colours.
const Color kTripleCupTeam1Color = Color(0xFF1976D2); // blue  (team 1)
const Color kTripleCupTeam2Color = Color(0xFFEF6C00); // orange (team 2)

/// Map a cup colour name (case-insensitive — "Red", "blue", "Gold",
/// "Tilden Green", etc.) to a flat Material colour.  Falls back to
/// [fallback] when the string is null, empty, or unrecognised — use
/// the appropriate casual default so the casual UI keeps its
/// existing red/blue identity.
Color resolveTripleCupTeamColor(String? colourName, Color fallback) {
  if (colourName == null) return fallback;
  switch (colourName.toLowerCase().trim()) {
    case 'red':    return const Color(0xFFB71C1C);
    case 'blue':   return const Color(0xFF0D47A1);
    case 'green':  return const Color(0xFF1B5E20);
    case 'gold':
    case 'yellow': return const Color(0xFFF57F17);
    case 'orange': return const Color(0xFFE65100);
    case 'purple': return const Color(0xFF4A148C);
    case 'black':  return const Color(0xFF212121);
    case 'white':  return const Color(0xFF424242); // dark grey for readability
    default:       return fallback;
  }
}


class TripleCupPlayerHoleScore {
  final int  playerId;
  final int? gross;
  final int  strokes;
  final int? net;

  const TripleCupPlayerHoleScore({
    required this.playerId,
    this.gross,
    required this.strokes,
    this.net,
  });

  factory TripleCupPlayerHoleScore.fromJson(Map<String, dynamic> j) =>
      TripleCupPlayerHoleScore(
        playerId: j['player_id'] as int,
        gross:    j['gross']     as int?,
        strokes:  j['strokes']   as int? ?? 0,
        net:      j['net']       as int?,
      );
}

class TripleCupHole {
  final int hole;
  final int? par;
  final int? strokeIndex;
  final int? t1Net;
  final int? t2Net;
  final int? t1TeamGross;   // foursomes only — recorded team gross
  final int? t2TeamGross;
  final int? t1TeamStrokes; // foursomes only — alt-shot team allocation
  final int? t2TeamStrokes;
  final String winner;  // 'T1' | 'T2' | 'Halved'
  final int margin;
  final List<TripleCupPlayerHoleScore> scores;

  const TripleCupHole({
    required this.hole,
    this.par,
    this.strokeIndex,
    this.t1Net,
    this.t2Net,
    this.t1TeamGross,
    this.t2TeamGross,
    this.t1TeamStrokes,
    this.t2TeamStrokes,
    required this.winner,
    required this.margin,
    this.scores = const [],
  });

  factory TripleCupHole.fromJson(Map<String, dynamic> j) => TripleCupHole(
        hole:          j['hole']            as int,
        par:           j['par']             as int?,
        strokeIndex:   j['stroke_index']    as int?,
        t1Net:         j['t1_net']          as int?,
        t2Net:         j['t2_net']          as int?,
        t1TeamGross:   j['t1_team_gross']   as int?,
        t2TeamGross:   j['t2_team_gross']   as int?,
        t1TeamStrokes: j['t1_team_strokes'] as int?,
        t2TeamStrokes: j['t2_team_strokes'] as int?,
        winner:        j['winner']          as String? ?? 'Halved',
        margin:        j['margin']          as int? ?? 0,
        scores: (j['scores'] as List? ?? [])
            .map((s) => TripleCupPlayerHoleScore.fromJson(
                s as Map<String, dynamic>))
            .toList(),
      );
}

class TripleCupMatchPlayer {
  final int    playerId;
  final String name;
  final String shortName;
  final int    teamNumber;  // 1 or 2
  final bool   isPhantom;
  /// Playing handicap (full-net allowance).  Null when unknown.
  final int?   playingHandicap;
  /// Strokes-off baseline differential for THIS match in SO mode.
  /// Null in non-SO modes.  For most matches this is hcp − foursome
  /// low; for the singles-without-foursome-low override it's hcp −
  /// pair low.  Mobile uses it for the "(SO N)" badge.
  final int?   strokesOff;
  /// {hole: strokes} — expected strokes this player gets on each
  /// hole of THIS match's range, per the segment's rule.  Foursomes
  /// shares the same team allocation between both partners; fourball
  /// and singles use the per-player path.  Read by both the
  /// score-entry top-card dots and the leaderboard detail grid.
  final Map<int, int> strokesByHole;

  const TripleCupMatchPlayer({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.teamNumber,
    this.isPhantom = false,
    this.playingHandicap,
    this.strokesOff,
    this.strokesByHole = const {},
  });

  factory TripleCupMatchPlayer.fromJson(Map<String, dynamic> j) {
    final raw = j['strokes_by_hole'] as Map?;
    final byHole = <int, int>{};
    if (raw != null) {
      raw.forEach((k, v) {
        final hole = int.tryParse(k.toString());
        final strokes = v is int
            ? v
            : int.tryParse(v.toString()) ?? 0;
        if (hole != null) byHole[hole] = strokes;
      });
    }
    return TripleCupMatchPlayer(
      playerId:        j['player_id']        as int,
      name:            j['name']             as String? ?? '',
      shortName:       j['short_name']       as String? ?? '',
      teamNumber:      j['team_number']      as int? ?? 1,
      isPhantom:       j['is_phantom']       as bool? ?? false,
      playingHandicap: j['playing_handicap'] as int?,
      strokesOff:      j['strokes_off']      as int?,
      strokesByHole:   byHole,
    );
  }
}

class TripleCupTeamInfo {
  final List<String> players;  // display names
  final List<String> shorts;   // short labels for chips

  const TripleCupTeamInfo({required this.players, required this.shorts});

  factory TripleCupTeamInfo.fromJson(Map<String, dynamic> j) =>
      TripleCupTeamInfo(
        players: List<String>.from(j['players'] as List? ?? []),
        shorts:  List<String>.from(j['shorts']  as List? ?? []),
      );

  bool get hasPlayers => players.isNotEmpty;
}

class TripleCupMatch {
  final int matchNumber;
  final String segment;        // 'fourball' | 'foursomes' | 'singles'
  final String label;
  final int startHole;
  final int endHole;
  final int displayEndHole;
  final String status;         // 'pending' | 'in_progress' | 'complete' | 'halved'
  final String? result;        // 'team1' | 'team2' | 'halved' | null
  final int? finishedOnHole;
  final int holesUpFinal;      // signed, +ve = team1
  final String winnerLabel;    // 'Team 1' | 'Team 2' | 'Halved' | '—'
  final TripleCupTeamInfo team1;
  final TripleCupTeamInfo team2;
  /// Foursomes-only: which player on each team tees off the first
  /// segment hole.  The partner takes the next; they alternate by
  /// hole parity.  Null on non-foursomes matches and on the solo
  /// side of 2v1 (no alternation).
  final int? team1FirstTeeId;
  final int? team2FirstTeeId;
  final List<TripleCupMatchPlayer> players;
  final List<TripleCupHole> holes;

  const TripleCupMatch({
    required this.matchNumber,
    required this.segment,
    required this.label,
    required this.startHole,
    required this.endHole,
    required this.displayEndHole,
    required this.status,
    this.result,
    this.finishedOnHole,
    required this.holesUpFinal,
    required this.winnerLabel,
    required this.team1,
    required this.team2,
    this.team1FirstTeeId,
    this.team2FirstTeeId,
    this.players = const [],
    required this.holes,
  });

  factory TripleCupMatch.fromJson(Map<String, dynamic> j) => TripleCupMatch(
        matchNumber:     j['match_number']      as int? ?? 0,
        segment:         j['segment']           as String? ?? 'singles',
        label:           j['label']             as String? ?? '',
        startHole:       j['start_hole']        as int? ?? 1,
        endHole:         j['end_hole']          as int? ?? 6,
        displayEndHole:  j['display_end_hole']  as int? ?? (j['end_hole'] as int? ?? 6),
        status:          j['status']            as String? ?? 'pending',
        result:          j['result']            as String?,
        finishedOnHole:  j['finished_on_hole']  as int?,
        holesUpFinal:    j['holes_up_final']    as int? ?? 0,
        winnerLabel:     j['winner_label']      as String? ?? '—',
        team1FirstTeeId: j['team1_first_tee_id'] as int?,
        team2FirstTeeId: j['team2_first_tee_id'] as int?,
        team1: TripleCupTeamInfo.fromJson(
            j['team1'] as Map<String, dynamic>? ?? {}),
        team2: TripleCupTeamInfo.fromJson(
            j['team2'] as Map<String, dynamic>? ?? {}),
        players: (j['players'] as List? ?? [])
            .map((p) => TripleCupMatchPlayer.fromJson(
                p as Map<String, dynamic>))
            .toList(),
        holes: (j['holes'] as List? ?? [])
            .map((h) => TripleCupHole.fromJson(h as Map<String, dynamic>))
            .toList(),
      );

  /// For the current hole inside this foursomes match, return the
  /// player ID whose turn it is to play on *team*.  Mirrors the
  /// backend's TripleCupMatch.active_player_id.  Returns null when
  /// not a foursomes match, when no first-tee player is set, or
  /// when the hole is outside the match's range.
  int? activePlayerId(int teamNumber, int holeNumber) {
    if (segment != 'foursomes') return null;
    final first = teamNumber == 1 ? team1FirstTeeId : team2FirstTeeId;
    if (first == null) return null;
    if (holeNumber < startHole || holeNumber > endHole) return null;
    final teamPlayers = players
        .where((p) => p.teamNumber == teamNumber && !p.isPhantom)
        .map((p) => p.playerId)
        .toList();
    if (teamPlayers.length < 2) {
      // Solo side has no alternation — the lone real player is always active.
      return teamPlayers.isEmpty ? null : teamPlayers.first;
    }
    if (!teamPlayers.contains(first)) return null;
    final position = holeNumber - startHole;
    if (position % 2 == 0) return first;
    return teamPlayers.firstWhere((p) => p != first);
  }

  int get totalHoles => endHole - startHole + 1;

  /// Human-friendly match status: "1 UP thru 3", "4 and 2", "AS", etc.
  String get statusDisplay {
    if (!team1.hasPlayers || !team2.hasPlayers) return 'Pending';
    if (holes.isEmpty) return '—';
    final played    = holes.length;
    final margin    = holes.last.margin;
    final absMargin = margin.abs();
    final left      = totalHoles - played;
    if (status == 'complete' || status == 'halved' || result != null) {
      if (result == 'halved') return 'Halved';
      if (left > 0) return '$absMargin and $left';
      return absMargin > 0 ? '$absMargin UP' : 'Halved';
    }
    if (status == 'in_progress') {
      if (margin == 0) return 'AS thru $played';
      return '$absMargin UP thru $played';
    }
    return '—';
  }
}

class TripleCupPlayerMoney {
  final String name;
  final double amount;

  const TripleCupPlayerMoney({required this.name, required this.amount});

  factory TripleCupPlayerMoney.fromJson(Map<String, dynamic> j) =>
      TripleCupPlayerMoney(
        name:   j['name']   as String? ?? '',
        amount: (j['amount'] as num? ?? 0).toDouble(),
      );
}

class TripleCupSummary {
  final String status;       // 'pending' | 'in_progress' | 'complete'
  final int groupSize;       // 2 | 3 | 4
  final String handicapMode; // 'net' | 'gross' | 'strokes_off'
  final int netPercent;
  final int altShotLowPct;
  final int altShotHighPct;
  /// Cup TournamentTeam colour names (e.g. "Red", "Blue", "Green").
  /// Null on casual rounds (no cup teams).  Use [team1Color] /
  /// [team2Color] to resolve to actual Color values with a sensible
  /// casual-mode fallback.
  final String? team1ColourName;
  final String? team2ColourName;
  /// Cup TournamentTeam names — handy for headers in cup mode.
  final String? team1Name;
  final String? team2Name;
  final List<TripleCupMatch> matches;
  final int team1Wins;
  final int team2Wins;
  final int halves;
  final double team1Points;
  final double team2Points;
  final int pointsAvailable;
  final double betUnit;
  final List<TripleCupPlayerMoney> money;
  /// Cross-foursome phantom info for 2v1 fourball — null when not 2v1.
  /// Same shape Nassau exposes; reused so the score-entry UI can label
  /// the phantom row with the current hole's donor and show a
  /// "Waiting for Glenn..." placeholder when the donor hasn't posted.
  final NassauPhantomInfo? phantom;

  const TripleCupSummary({
    required this.status,
    required this.groupSize,
    required this.handicapMode,
    required this.netPercent,
    required this.altShotLowPct,
    required this.altShotHighPct,
    this.team1ColourName,
    this.team2ColourName,
    this.team1Name,
    this.team2Name,
    required this.matches,
    required this.team1Wins,
    required this.team2Wins,
    required this.halves,
    required this.team1Points,
    required this.team2Points,
    required this.pointsAvailable,
    required this.betUnit,
    required this.money,
    this.phantom,
  });

  bool get isPending  => status == 'pending';
  bool get isStarted  => matches.any((m) => m.holes.isNotEmpty);

  /// Team 1 accent colour for this summary.  In cup mode this resolves
  /// to the configured cup TournamentTeam.colour; in casual mode it
  /// falls back to the historical red.
  Color get team1Color =>
      resolveTripleCupTeamColor(team1ColourName, kTripleCupTeam1Color);
  /// Team 2 accent colour — cup colour in cup mode, blue in casual.
  Color get team2Color =>
      resolveTripleCupTeamColor(team2ColourName, kTripleCupTeam2Color);

  factory TripleCupSummary.fromJson(Map<String, dynamic> j) {
    final hcap    = j['handicap'] as Map<String, dynamic>? ?? {};
    final overall = j['overall']  as Map<String, dynamic>? ?? {};
    final money   = j['money']    as Map<String, dynamic>? ?? {};
    return TripleCupSummary(
      status:           j['status']     as String? ?? 'pending',
      groupSize:        j['group_size'] as int? ?? 4,
      handicapMode:     hcap['mode']                as String? ?? 'net',
      netPercent:       hcap['net_percent']         as int?    ?? 100,
      altShotLowPct:    hcap['alt_shot_low_pct']    as int?    ?? 50,
      altShotHighPct:   hcap['alt_shot_high_pct']   as int?    ?? 50,
      team1ColourName: j['team1_colour'] as String?,
      team2ColourName: j['team2_colour'] as String?,
      team1Name:       j['team1_name']   as String?,
      team2Name:       j['team2_name']   as String?,
      matches: (j['matches'] as List? ?? [])
          .map((m) => TripleCupMatch.fromJson(m as Map<String, dynamic>))
          .toList(),
      team1Wins:       overall['team1_wins']       as int?    ?? 0,
      team2Wins:       overall['team2_wins']       as int?    ?? 0,
      halves:          overall['halves']           as int?    ?? 0,
      team1Points:    (overall['team1_points']    as num? ?? 0).toDouble(),
      team2Points:    (overall['team2_points']    as num? ?? 0).toDouble(),
      // `num?` then truncate — defensive in case future formats
      // introduce a fractional match value (e.g. tie-break play-in).
      // Today the backend always sums to a whole number, but a `as
      // int` cast on a double would crash the whole summary parse.
      pointsAvailable: ((overall['points_available'] as num?) ?? 0).toInt(),
      betUnit:        (money['bet_unit']           as num? ?? 0).toDouble(),
      money: (money['by_player'] as List? ?? [])
          .map((m) => TripleCupPlayerMoney.fromJson(m as Map<String, dynamic>))
          .toList(),
      phantom: () {
        // Defensive parse: a malformed phantom block must never block
        // the rest of the TC summary from rendering.
        final raw = j['phantom'];
        if (raw is Map<String, dynamic>) {
          try { return NassauPhantomInfo.fromJson(raw); }
          catch (_) { return null; }
        }
        return null;
      }(),
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
// Wolf
// ---------------------------------------------------------------------------

/// Per-player running total for a Wolf game.
class WolfPlayerTotal {
  final int    playerId;
  final String name;
  final String shortName;
  final double points;
  final int    holesPlayed;
  final double money;
  final int    phcpInPlay;

  const WolfPlayerTotal({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.points,
    required this.holesPlayed,
    required this.money,
    required this.phcpInPlay,
  });

  factory WolfPlayerTotal.fromJson(Map<String, dynamic> j) => WolfPlayerTotal(
        playerId:    j['player_id']    as int,
        name:        j['name']         as String? ?? '',
        shortName:   j['short_name']   as String? ?? '',
        points:      (j['points']      as num?)?.toDouble() ?? 0.0,
        holesPlayed: j['holes_played'] as int? ?? 0,
        money:       (j['money']       as num?)?.toDouble() ?? 0.0,
        phcpInPlay:  j['phcp_in_play'] as int? ?? 0,
      );
}

/// One player's slot in a hole's reverse-honors tee order.  [isWolf] marks
/// the player pinned last (the Wolf); [orderNum] is 1-based for non-Wolf
/// players and null for the Wolf.
class WolfTeeSlot {
  final int    playerId;
  final String shortName;
  final String name;
  final bool   isWolf;
  final int?   orderNum;

  const WolfTeeSlot({
    required this.playerId,
    required this.shortName,
    required this.name,
    required this.isWolf,
    required this.orderNum,
  });

  factory WolfTeeSlot.fromJson(Map<String, dynamic> j) => WolfTeeSlot(
        playerId:  j['player_id']  as int,
        shortName: j['short_name'] as String? ?? '',
        name:      j['name']       as String? ?? '',
        isWolf:    j['is_wolf']    as bool? ?? false,
        orderNum:  j['order_num']  as int?,
      );
}

/// One player's computed entry on a Wolf hole.
class WolfHoleEntry {
  final int    playerId;
  final String name;
  final String shortName;
  final String role;       // 'wolf' | 'partner' | 'opponent'
  final int    netScore;
  final int?   gross;
  final double points;

  const WolfHoleEntry({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.role,
    required this.netScore,
    required this.gross,
    required this.points,
  });

  factory WolfHoleEntry.fromJson(Map<String, dynamic> j) => WolfHoleEntry(
        playerId:  j['player_id']  as int,
        name:      j['name']       as String? ?? '',
        shortName: j['short_name'] as String? ?? '',
        role:      j['role']       as String? ?? 'opponent',
        netScore:  j['net_score']  as int? ?? 0,
        gross:     j['gross']      as int?,
        points:    (j['points']    as num?)?.toDouble() ?? 0.0,
      );
}

/// One hole of a Wolf game — the assigned Wolf, the decision, the tee
/// order, and (once scored) the per-player results.
class WolfHole {
  final int    hole;
  final int?   par;
  final int    wolfId;
  final String wolfShort;
  final String decision;        // 'pending' | 'partner' | 'lone' | 'blind'
  final int?   partnerId;
  final String? partnerShort;
  final bool   partnerLocked;   // true → Wolf must go Lone/Blind (no partner)
  final String? winningSide;    // 'wolf' | 'opponents' | 'tie' | null
  final double pot;
  final List<WolfTeeSlot>  teeOrder;
  final List<WolfHoleEntry> entries;

  const WolfHole({
    required this.hole,
    required this.par,
    required this.wolfId,
    required this.wolfShort,
    required this.decision,
    required this.partnerId,
    required this.partnerShort,
    required this.partnerLocked,
    required this.winningSide,
    required this.pot,
    required this.teeOrder,
    required this.entries,
  });

  bool get isDecided => decision == 'partner' || decision == 'lone' || decision == 'blind';
  bool get isScored  => entries.isNotEmpty;

  factory WolfHole.fromJson(Map<String, dynamic> j) => WolfHole(
        hole:         j['hole'] as int? ?? 0,
        par:          j['par']  as int?,
        wolfId:       j['wolf_id'] as int? ?? 0,
        wolfShort:    j['wolf_short'] as String? ?? '',
        decision:     j['decision'] as String? ?? 'pending',
        partnerId:    j['partner_id'] as int?,
        partnerShort: j['partner_short'] as String?,
        partnerLocked: j['partner_locked'] as bool? ?? false,
        winningSide:  j['winning_side'] as String?,
        pot:          (j['pot'] as num?)?.toDouble() ?? 0.0,
        teeOrder: (j['tee_order'] as List? ?? [])
            .map((t) => WolfTeeSlot.fromJson(t as Map<String, dynamic>))
            .toList(),
        entries: (j['entries'] as List? ?? [])
            .map((e) => WolfHoleEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Full summary for a Wolf game — mirrors services.wolf.wolf_summary().
class WolfSummary {
  final String status;
  final String handicapMode;
  final int    netPercent;
  // Point config / options.
  final int    loneWolfPoints;
  final int    blindWolfPoints;
  final int    teamWinPoints;
  final bool   wolfLosesTies;
  final bool   nonWolfBonus;
  final bool   lastPlaceWolf1718;
  final bool   requireLoneOrBlind;
  final List<int>             wolfOrder;
  final List<WolfPlayerTotal> players;
  final List<WolfHole>        holes;
  final double betUnit;

  const WolfSummary({
    required this.status,
    required this.handicapMode,
    required this.netPercent,
    required this.loneWolfPoints,
    required this.blindWolfPoints,
    required this.teamWinPoints,
    required this.wolfLosesTies,
    required this.nonWolfBonus,
    required this.lastPlaceWolf1718,
    required this.requireLoneOrBlind,
    required this.wolfOrder,
    required this.players,
    required this.holes,
    required this.betUnit,
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';

  /// The hole record for [hole] (1-based), or null if absent.
  WolfHole? holeFor(int hole) {
    for (final h in holes) {
      if (h.hole == hole) return h;
    }
    return null;
  }

  factory WolfSummary.fromJson(Map<String, dynamic> j) {
    final hcap   = j['handicap'] as Map<String, dynamic>? ?? {};
    final pts    = j['points']   as Map<String, dynamic>? ?? {};
    final money  = j['money']    as Map<String, dynamic>? ?? {};
    return WolfSummary(
      status:            j['status'] as String? ?? 'pending',
      handicapMode:      hcap['mode']        as String? ?? 'net',
      netPercent:        hcap['net_percent'] as int?    ?? 100,
      loneWolfPoints:    pts['lone_wolf']  as int? ?? 3,
      blindWolfPoints:   pts['blind_wolf'] as int? ?? 6,
      teamWinPoints:     pts['team_win']   as int? ?? 1,
      wolfLosesTies:      pts['wolf_loses_ties']       as bool? ?? false,
      nonWolfBonus:       pts['non_wolf_bonus']        as bool? ?? false,
      lastPlaceWolf1718:  pts['last_place_wolf_1718']  as bool? ?? true,
      requireLoneOrBlind: pts['require_lone_or_blind'] as bool? ?? false,
      wolfOrder: (j['wolf_order'] as List? ?? [])
          .map((e) => e as int).toList(),
      players: (j['players'] as List? ?? [])
          .map((p) => WolfPlayerTotal.fromJson(p as Map<String, dynamic>))
          .toList(),
      holes: (j['holes'] as List? ?? [])
          .map((h) => WolfHole.fromJson(h as Map<String, dynamic>))
          .toList(),
      betUnit: (money['bet_unit'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

// ---------------------------------------------------------------------------
// Rabbit
// ---------------------------------------------------------------------------

/// Per-player running total for a Rabbit game.
class RabbitPlayerTotal {
  final int    playerId;
  final String name;
  final String shortName;
  final double money;
  final int    segmentsWon;
  final int    phcpInPlay;

  const RabbitPlayerTotal({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.money,
    required this.segmentsWon,
    required this.phcpInPlay,
  });

  factory RabbitPlayerTotal.fromJson(Map<String, dynamic> j) =>
      RabbitPlayerTotal(
        playerId:    j['player_id']    as int,
        name:        j['name']         as String? ?? '',
        shortName:   j['short_name']   as String? ?? '',
        money:       (j['money']       as num?)?.toDouble() ?? 0.0,
        segmentsWon: j['segments_won'] as int? ?? 0,
        phcpInPlay:  j['phcp_in_play'] as int? ?? 0,
      );
}

/// One segment of a Rabbit match (1×18, 2×9, or 3×6).
class RabbitSegment {
  final int    index;
  final int    startHole;
  final int    endHole;
  final int?   holderId;
  final String? holderShort;
  final int    lead;
  final bool   complete;
  final double payout;

  const RabbitSegment({
    required this.index,
    required this.startHole,
    required this.endHole,
    required this.holderId,
    required this.holderShort,
    required this.lead,
    required this.complete,
    required this.payout,
  });

  factory RabbitSegment.fromJson(Map<String, dynamic> j) => RabbitSegment(
        index:       j['index']       as int? ?? 0,
        startHole:   j['start_hole']  as int? ?? 0,
        endHole:     j['end_hole']    as int? ?? 0,
        holderId:    j['holder_id']   as int?,
        holderShort: j['holder_short'] as String?,
        lead:        j['lead']        as int? ?? 0,
        complete:    j['complete']    as bool? ?? false,
        payout:      (j['payout']     as num?)?.toDouble() ?? 0.0,
      );
}

/// One player's score on a Rabbit hole.
class RabbitHoleEntry {
  final int    playerId;
  final String shortName;
  final String name;
  final int?   netScore;
  final int?   gross;
  final bool   isWinner;
  final bool   isHolder;

  const RabbitHoleEntry({
    required this.playerId,
    required this.shortName,
    required this.name,
    required this.netScore,
    required this.gross,
    required this.isWinner,
    required this.isHolder,
  });

  factory RabbitHoleEntry.fromJson(Map<String, dynamic> j) => RabbitHoleEntry(
        playerId:  j['player_id']  as int,
        shortName: j['short_name'] as String? ?? '',
        name:      j['name']       as String? ?? '',
        netScore:  j['net_score']  as int?,
        gross:     j['gross']      as int?,
        isWinner:  j['is_winner']  as bool? ?? false,
        isHolder:  j['is_holder']  as bool? ?? false,
      );
}

/// One hole of a Rabbit game — outright winner, rabbit holder + lead.
class RabbitHole {
  final int    hole;
  final int    segment;
  final int?   par;
  final int?   winnerId;
  final String? winnerShort;
  final int?   holderId;
  final String? holderShort;
  final int    lead;
  final String? event;
  final List<RabbitHoleEntry> entries;

  const RabbitHole({
    required this.hole,
    required this.segment,
    required this.par,
    required this.winnerId,
    required this.winnerShort,
    required this.holderId,
    required this.holderShort,
    required this.lead,
    required this.event,
    required this.entries,
  });

  bool get isScored => entries.any((e) => e.netScore != null);

  factory RabbitHole.fromJson(Map<String, dynamic> j) => RabbitHole(
        hole:        j['hole']        as int? ?? 0,
        segment:     j['segment']     as int? ?? 1,
        par:         j['par']         as int?,
        winnerId:    j['winner_id']   as int?,
        winnerShort: j['winner_short'] as String?,
        holderId:    j['holder_id']   as int?,
        holderShort: j['holder_short'] as String?,
        lead:        j['lead']        as int? ?? 0,
        event:       j['event']       as String?,
        entries: (j['entries'] as List? ?? [])
            .map((e) => RabbitHoleEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Full summary for a Rabbit game — mirrors services.rabbit.rabbit_summary().
class RabbitSummary {
  final String status;
  final String handicapMode;
  final int    netPercent;
  final bool   accumulate;
  final int    numSegments;
  final List<RabbitSegment>     segments;
  final List<RabbitPlayerTotal> players;
  final List<RabbitHole>        holes;
  // Current live state.
  final int?   currentHolderId;
  final String? currentHolderShort;
  final int    currentLead;
  final int    currentSegment;
  final double betUnit;
  final double entry;     // per-player buy-in
  final double pot;       // n_players × entry
  final double segValue;

  const RabbitSummary({
    required this.status,
    required this.handicapMode,
    required this.netPercent,
    required this.accumulate,
    required this.numSegments,
    required this.segments,
    required this.players,
    required this.holes,
    required this.currentHolderId,
    required this.currentHolderShort,
    required this.currentLead,
    required this.currentSegment,
    required this.betUnit,
    required this.entry,
    required this.pot,
    required this.segValue,
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';

  RabbitHole? holeFor(int hole) {
    for (final h in holes) {
      if (h.hole == hole) return h;
    }
    return null;
  }

  factory RabbitSummary.fromJson(Map<String, dynamic> j) {
    final hcap    = j['handicap'] as Map<String, dynamic>? ?? {};
    final money   = j['money']    as Map<String, dynamic>? ?? {};
    final current = j['current']  as Map<String, dynamic>? ?? {};
    return RabbitSummary(
      status:       j['status'] as String? ?? 'pending',
      handicapMode: hcap['mode']        as String? ?? 'net',
      netPercent:   hcap['net_percent'] as int?    ?? 100,
      accumulate:   j['accumulate']   as bool? ?? true,
      numSegments:  j['num_segments'] as int?  ?? 1,
      segments: (j['segments'] as List? ?? [])
          .map((s) => RabbitSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
      players: (j['players'] as List? ?? [])
          .map((p) => RabbitPlayerTotal.fromJson(p as Map<String, dynamic>))
          .toList(),
      holes: (j['holes'] as List? ?? [])
          .map((h) => RabbitHole.fromJson(h as Map<String, dynamic>))
          .toList(),
      currentHolderId:    current['holder_id']    as int?,
      currentHolderShort: current['holder_short'] as String?,
      currentLead:        current['lead']         as int? ?? 0,
      currentSegment:     current['segment']      as int? ?? 1,
      betUnit:  (money['bet_unit']  as num?)?.toDouble() ?? 1.0,
      entry:    (money['entry']     as num?)?.toDouble()
                ?? (money['bet_unit'] as num?)?.toDouble() ?? 1.0,
      pot:      (money['pot']       as num?)?.toDouble() ?? 1.0,
      segValue: (money['seg_value'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

// ---------------------------------------------------------------------------
// Multi-Foursome Skins (round-scoped)
// ---------------------------------------------------------------------------

class MultiSkinsPlayerTotal {
  final int    playerId;
  final String name;
  final String shortName;
  final int    foursomeId;
  final int    groupNumber;
  final int    skinsWon;
  final double payout;
  /// Highest hole number with a gross_score on file for this player.
  /// 0 means no scores yet.
  final int    thru;

  const MultiSkinsPlayerTotal({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.foursomeId,
    required this.groupNumber,
    required this.skinsWon,
    required this.payout,
    this.thru = 0,
  });

  factory MultiSkinsPlayerTotal.fromJson(Map<String, dynamic> j) =>
      MultiSkinsPlayerTotal(
        playerId:    j['player_id']    as int,
        name:        j['name']         as String? ?? '',
        shortName:   j['short_name']   as String? ?? '',
        foursomeId:  j['foursome_id']  as int?    ?? 0,
        groupNumber: j['group_number'] as int?    ?? 0,
        skinsWon:    j['skins_won']    as int?    ?? 0,
        payout:      (j['payout']      as num?)?.toDouble() ?? 0.0,
        thru:        j['thru']         as int?    ?? 0,
      );
}

class MultiSkinsHoleScore {
  final int playerId;
  final int gross;
  final int strokes;

  const MultiSkinsHoleScore({
    required this.playerId,
    required this.gross,
    required this.strokes,
  });

  factory MultiSkinsHoleScore.fromJson(Map<String, dynamic> j) =>
      MultiSkinsHoleScore(
        playerId: j['player_id'] as int,
        gross:    j['gross']     as int? ?? 0,
        strokes:  j['strokes']   as int? ?? 0,
      );

  int get net => gross - strokes;
}

class MultiSkinsHole {
  final int     hole;
  final int?    par;
  final int?    strokeIndex;
  final int?    winnerId;
  final String? winnerShort;
  final bool    isDead;
  /// Per-player gross + handicap-strokes for this hole.  Populated for
  /// every participant that has a score on file (so the leaderboard can
  /// render a full scorecard grid).  Empty until any participant has
  /// scored the hole.
  final List<MultiSkinsHoleScore> scores;

  const MultiSkinsHole({
    required this.hole,
    this.par,
    this.strokeIndex,
    required this.winnerId,
    required this.winnerShort,
    required this.isDead,
    this.scores = const [],
  });

  factory MultiSkinsHole.fromJson(Map<String, dynamic> j) => MultiSkinsHole(
        hole:        j['hole']         as int? ?? 0,
        par:         j['par']          as int?,
        strokeIndex: j['stroke_index'] as int?,
        winnerId:    j['winner_id']    as int?,
        winnerShort: j['winner_short'] as String?,
        isDead:      j['is_dead']      as bool? ?? false,
        scores: (j['scores'] as List? ?? [])
            .map((s) => MultiSkinsHoleScore.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class MultiSkinsSummary {
  final String status;
  final String handicapMode;
  final int    netPercent;
  final List<MultiSkinsPlayerTotal> players;
  final List<MultiSkinsHole>        holes;
  final double betUnit;
  final double pool;
  final int    totalSkins;

  const MultiSkinsSummary({
    required this.status,
    required this.handicapMode,
    required this.netPercent,
    required this.players,
    required this.holes,
    required this.betUnit,
    required this.pool,
    required this.totalSkins,
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';

  factory MultiSkinsSummary.fromJson(Map<String, dynamic> j) {
    final hcap  = j['handicap'] as Map<String, dynamic>? ?? {};
    final money = j['money']    as Map<String, dynamic>? ?? {};
    return MultiSkinsSummary(
      status:       j['status']        as String? ?? 'pending',
      handicapMode: hcap['mode']        as String? ?? 'net',
      netPercent:   hcap['net_percent'] as int?    ?? 100,
      players: (j['players'] as List? ?? [])
          .map((p) => MultiSkinsPlayerTotal.fromJson(p as Map<String, dynamic>))
          .toList(),
      holes: (j['holes'] as List? ?? [])
          .map((h) => MultiSkinsHole.fromJson(h as Map<String, dynamic>))
          .toList(),
      betUnit:    (money['bet_unit']    as num?)?.toDouble() ?? 0.0,
      pool:       (money['pool']        as num?)?.toDouble() ?? 0.0,
      totalSkins: (money['total_skins'] as num?)?.toInt()    ?? 0,
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
  final int     hole;
  final String? winner;   // 'team1' | 'team2' | 'halved' | null
  final int?    t1Net;
  final int?    t2Net;
  // 2nd-ball scores (tiebreak_2nd + claremont variants only)
  final int?    t12ndNet;
  final int?    t22ndNet;
  // Top margins
  final int?    front9Margin;
  final int?    back9Margin;
  final int?    overallMargin;
  // Claremont bottom
  final int?    bottomDelta;          // net points for T1 this hole: -2..+2
  final int?    bottomFront9Margin;
  final int?    bottomBack9Margin;
  final int?    bottomOverallMargin;

  const NassauHoleData({
    required this.hole,
    this.winner,
    this.t1Net,
    this.t2Net,
    this.t12ndNet,
    this.t22ndNet,
    this.front9Margin,
    this.back9Margin,
    this.overallMargin,
    this.bottomDelta,
    this.bottomFront9Margin,
    this.bottomBack9Margin,
    this.bottomOverallMargin,
  });

  factory NassauHoleData.fromJson(Map<String, dynamic> j) => NassauHoleData(
        hole:                j['hole']                   as int,
        winner:              j['winner']                 as String?,
        t1Net:               j['t1_net']                 as int?,
        t2Net:               j['t2_net']                 as int?,
        t12ndNet:            j['t1_2nd_net']             as int?,
        t22ndNet:            j['t2_2nd_net']             as int?,
        front9Margin:        j['front9_margin']          as int?,
        back9Margin:         j['back9_margin']           as int?,
        overallMargin:       j['overall_margin']         as int?,
        bottomDelta:         j['bottom_delta']           as int?,
        bottomFront9Margin:  j['bottom_front9_margin']   as int?,
        bottomBack9Margin:   j['bottom_back9_margin']    as int?,
        bottomOverallMargin: j['bottom_overall_margin']  as int?,
      );
}

/// Minimal bet result for Claremont bottom (no decided_margin needed there).
class NassauBottomBetResult {
  final String? result;    // 'team1' | 'team2' | 'halved' | null
  final int     margin;    // running points margin (+ve = T1 leading)
  final int     holesPlayed;

  const NassauBottomBetResult({
    required this.result,
    required this.margin,
    required this.holesPlayed,
  });

  factory NassauBottomBetResult.fromJson(Map<String, dynamic> j) =>
      NassauBottomBetResult(
        result:      j['result']       as String?,
        margin:      j['margin']       as int? ?? 0,
        holesPlayed: j['holes_played'] as int? ?? 0,
      );

  bool get isComplete => result != null;

  String statusLabel({String t1Label = 'T1', String t2Label = 'T2'}) {
    if (isComplete) {
      if (result == 'halved') return 'Halved';
      return '${result == 'team1' ? t1Label : t2Label} wins';
    }
    if (holesPlayed == 0) return 'Not started';
    final abs = margin.abs();
    if (margin == 0) return 'All Square thru $holesPlayed';
    final leader = margin > 0 ? t1Label : t2Label;
    return '$leader +$abs thru $holesPlayed';
  }
}

/// Full summary for a Nassau game — mirrors nassau_summary() output.
class NassauSummary {
  final String status;           // 'pending' | 'in_progress' | 'complete'
  final String variant;          // 'none' | 'tiebreak_2nd' | 'claremont'
  final String handicapMode;
  final int    netPercent;
  final String pressMode;        // 'none' | 'manual' | 'auto' | 'both'
  final double betUnit;
  final double pressUnit;

  // Which of the three bets are live (Front+Back off = an 18-hole match).
  final bool playFront;
  final bool playBack;
  final bool playOverall;

  // Teams
  final List<NassauPlayerInfo> team1;
  final List<NassauPlayerInfo> team2;

  // Top bet results
  final NassauBetResult front9;
  final NassauBetResult back9;
  final NassauBetResult overall;

  // Top presses
  final List<NassauPressResult> presses;

  // Claremont bottom bet results (null when variant != 'claremont')
  final NassauBottomBetResult? bottomFront9;
  final NassauBottomBetResult? bottomBack9;
  final NassauBottomBetResult? bottomOverall;

  // Bottom presses (empty when variant != 'claremont')
  final List<NassauPressResult> bottomPresses;

  // Payouts (+ve = team1 wins that dollar amount)
  final double payoutFront9;
  final double payoutBack9;
  final double payoutOverall;
  final double payoutPresses;
  final double payoutTopTotal;
  final double payoutBottomFront9;
  final double payoutBottomBack9;
  final double payoutBottomOverall;
  final double payoutBottomPresses;
  final double payoutBottomTotal;
  final double payoutTotal;

  // Hole-by-hole data
  final List<NassauHoleData> holes;

  // Press button availability
  final bool    canPress;
  final String? pressAvailableNine;  // 'front' | 'back' | null

  // Four Ball phantom info (null when no cross-foursome phantom)
  final NassauPhantomInfo? phantom;

  // Team colours from cup config (default Red / Blue)
  final String team1Colour;
  final String team2Colour;

  const NassauSummary({
    required this.status,
    required this.variant,
    required this.handicapMode,
    required this.netPercent,
    required this.pressMode,
    required this.betUnit,
    required this.pressUnit,
    this.playFront   = true,
    this.playBack    = true,
    this.playOverall = true,
    required this.team1,
    required this.team2,
    required this.front9,
    required this.back9,
    required this.overall,
    required this.presses,
    this.bottomFront9,
    this.bottomBack9,
    this.bottomOverall,
    required this.bottomPresses,
    required this.payoutFront9,
    required this.payoutBack9,
    required this.payoutOverall,
    required this.payoutPresses,
    required this.payoutTopTotal,
    required this.payoutBottomFront9,
    required this.payoutBottomBack9,
    required this.payoutBottomOverall,
    required this.payoutBottomPresses,
    required this.payoutBottomTotal,
    required this.payoutTotal,
    required this.holes,
    required this.canPress,
    this.pressAvailableNine,
    this.phantom,
    this.team1Colour = 'Red',
    this.team2Colour = 'Blue',
  });

  bool get isNet        => handicapMode == 'net';
  bool get isGross      => handicapMode == 'gross';
  bool get isStrokesOff => handicapMode == 'strokes_off';
  bool get isClaremont    => variant == 'claremont';
  bool get isTiebreak2nd  => variant == 'tiebreak_2nd';
  /// Overall-only (Front + Back off) = a straight 18-hole match.
  bool get isEighteenHoleMatch => !playFront && !playBack && playOverall;
  bool get allowsManualPress => pressMode == 'manual' || pressMode == 'both';

  String get t1Label => team1.isNotEmpty ? team1.first.shortName : 'T1';
  String get t2Label => team2.isNotEmpty ? team2.first.shortName : 'T2';

  String betLabel(NassauBetResult bet) =>
      bet.statusLabel(useTeamNames: true, t1Label: t1Label, t2Label: t2Label);

  String bottomBetLabel(NassauBottomBetResult bet) =>
      bet.statusLabel(t1Label: t1Label, t2Label: t2Label);

  factory NassauSummary.fromJson(Map<String, dynamic> j) {
    final teams   = j['teams']   as Map<String, dynamic>? ?? {};
    final payouts = j['payouts'] as Map<String, dynamic>? ?? {};
    final bf9Raw  = j['bottom_front9']  as Map<String, dynamic>?;
    final bb9Raw  = j['bottom_back9']   as Map<String, dynamic>?;
    final bovRaw  = j['bottom_overall'] as Map<String, dynamic>?;
    return NassauSummary(
      status:       j['status']        as String? ?? 'pending',
      variant:      j['variant']       as String? ?? 'none',
      handicapMode: j['handicap_mode'] as String? ?? 'net',
      netPercent:   j['net_percent']   as int?    ?? 100,
      pressMode:    j['press_mode']    as String? ?? 'none',
      betUnit:      (j['bet_unit']     as num?)?.toDouble() ?? 1.0,
      pressUnit:    (j['press_unit']   as num?)?.toDouble() ?? 0.0,
      playFront:    j['play_front']    as bool?   ?? true,
      playBack:     j['play_back']     as bool?   ?? true,
      playOverall:  j['play_overall']  as bool?   ?? true,
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
      bottomFront9:  bf9Raw != null ? NassauBottomBetResult.fromJson(bf9Raw) : null,
      bottomBack9:   bb9Raw != null ? NassauBottomBetResult.fromJson(bb9Raw) : null,
      bottomOverall: bovRaw != null ? NassauBottomBetResult.fromJson(bovRaw) : null,
      bottomPresses: ((j['bottom_presses'] as List?) ?? [])
          .map((p) => NassauPressResult.fromJson(p as Map<String, dynamic>))
          .toList(),
      payoutFront9:        (payouts['front9']          as num?)?.toDouble() ?? 0.0,
      payoutBack9:         (payouts['back9']           as num?)?.toDouble() ?? 0.0,
      payoutOverall:       (payouts['overall']         as num?)?.toDouble() ?? 0.0,
      payoutPresses:       (payouts['presses']         as num?)?.toDouble() ?? 0.0,
      payoutTopTotal:      (payouts['top_total']       as num?)?.toDouble() ?? 0.0,
      payoutBottomFront9:  (payouts['bottom_front9']   as num?)?.toDouble() ?? 0.0,
      payoutBottomBack9:   (payouts['bottom_back9']    as num?)?.toDouble() ?? 0.0,
      payoutBottomOverall: (payouts['bottom_overall']  as num?)?.toDouble() ?? 0.0,
      payoutBottomPresses: (payouts['bottom_presses']  as num?)?.toDouble() ?? 0.0,
      payoutBottomTotal:   (payouts['bottom_total']    as num?)?.toDouble() ?? 0.0,
      payoutTotal:         (payouts['total']           as num?)?.toDouble() ?? 0.0,
      holes: ((j['holes'] as List?) ?? [])
          .map((h) => NassauHoleData.fromJson(h as Map<String, dynamic>))
          .toList(),
      canPress:           j['can_press']            as bool?   ?? false,
      pressAvailableNine: j['press_available_nine'] as String?,
      phantom: () {
        // Defensive parse so a phantom type-cast error never breaks the summary.
        final raw = j['phantom'];
        if (raw == null) return null;
        try {
          return NassauPhantomInfo.fromJson(raw as Map<String, dynamic>);
        } catch (e, st) {
          debugPrint('NassauPhantomInfo.fromJson FAILED: $e\n$st');
          return null;
        }
      }(),
      team1Colour: j['team1_colour'] as String? ?? 'Red',
      team2Colour: j['team2_colour'] as String? ?? 'Blue',
    );
  }
}

// ---------------------------------------------------------------------------
// Nassau phantom info (Four Ball cross-foursome phantom)
// ---------------------------------------------------------------------------

/// Per-hole donor info for the cross-foursome phantom.
class NassauPhantomDonorHole {
  final int    playerId;
  final String playerName;
  final bool   hasScore;

  const NassauPhantomDonorHole({
    required this.playerId,
    required this.playerName,
    required this.hasScore,
  });

  factory NassauPhantomDonorHole.fromJson(Map<String, dynamic> j) =>
      NassauPhantomDonorHole(
        playerId:   j['player_id']   as int,
        playerName: j['player_name'] as String? ?? '',
        hasScore:   j['has_score']   as bool?   ?? false,
      );
}

/// Phantom info attached to a NassauSummary when a cross-foursome phantom
/// is active (Four Ball, one team has 3 players across all foursomes).
class NassauPhantomInfo {
  final int                              phantomPlayerId;
  final int                              phantomPlayingHcp;
  final Map<int, NassauPhantomDonorHole> byHole;  // hole 1-18

  const NassauPhantomInfo({
    required this.phantomPlayerId,
    required this.phantomPlayingHcp,
    required this.byHole,
  });

  factory NassauPhantomInfo.fromJson(Map<String, dynamic> j) {
    final rawByHole = j['by_hole'] as Map<String, dynamic>? ?? {};
    final byHole = rawByHole.map((k, v) => MapEntry(
      int.parse(k),
      NassauPhantomDonorHole.fromJson(v as Map<String, dynamic>),
    ));
    return NassauPhantomInfo(
      phantomPlayerId:  j['phantom_player_id']   as int? ?? 0,
      phantomPlayingHcp: j['phantom_playing_hcp'] as int? ?? 0,
      byHole: byHole,
    );
  }

  /// Returns donor info for [hole], or null if not configured.
  NassauPhantomDonorHole? donorForHole(int hole) => byHole[hole];

  /// True if the phantom's donor has scored [hole].
  bool donorHasScoredHole(int hole) => byHole[hole]?.hasScore ?? false;

  /// Name of the donor player for [hole].
  String donorNameForHole(int hole) => byHole[hole]?.playerName ?? 'Donor';
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
  final bool isCupRound;
  final List<String> activeGames;
  final Map<String, LeaderboardGame> games;
  final int? tournamentId;
  final String? tournamentName;
  /// The cup-competition display name (TeamTournament.cup_name) — e.g.
  /// "ETC Cup" or "Bandon Cup".  Distinct from [tournamentName], which
  /// is the underlying Tournament's name.  Null when the round isn't
  /// part of a cup competition.
  final String? cupName;
  final List<String> tournamentActiveGames;
  /// The account that owns this round. Lets the app flag a cross-account
  /// (support / shared) read-only view. Null on older backends.
  final int? accountId;
  final String? accountName;

  const Leaderboard({
    required this.roundId,
    required this.roundDate,
    required this.course,
    required this.status,
    this.isCupRound = false,
    required this.activeGames,
    required this.games,
    this.tournamentId,
    this.tournamentName,
    this.cupName,
    this.tournamentActiveGames = const [],
    this.accountId,
    this.accountName,
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
      roundId:    j['round_id']  as int,
      roundDate:  j['round_date'] as String,
      course:     j['course']     as String,
      status:     j['status']     as String,
      isCupRound: j['is_cup_round'] as bool? ?? false,
      activeGames: List<String>.from(j['active_games'] as List? ?? []),
      games: games,
      tournamentId: j['tournament_id'] as int?,
      tournamentName: j['tournament_name'] as String?,
      cupName: j['cup_name'] as String?,
      tournamentActiveGames: List<String>.from(
          j['tournament_active_games'] as List? ?? []),
      accountId:   j['account_id']   as int?,
      accountName: j['account_name'] as String?,
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
// Team Tournament (Ryder Cup / named Cup)
// ---------------------------------------------------------------------------

/// A player on a team roster.
class CupPlayer {
  final int    id;
  final String name;
  final String shortName;

  const CupPlayer({required this.id, required this.name, required this.shortName});

  factory CupPlayer.fromJson(Map<String, dynamic> j) => CupPlayer(
        id:        j['player_id'] as int,
        name:      j['name']      as String,
        shortName: j['short_name'] as String? ?? '',
      );
}

/// A team inside a cup — includes roster and accumulated points.
class CupTeam {
  final int          teamId;
  final int          teamNumber;
  final String       name;
  final String       colour;
  final String       shortCode;
  final double       totalPoints;
  final List<CupPlayer> players;

  const CupTeam({
    required this.teamId,
    required this.teamNumber,
    required this.name,
    required this.colour,
    required this.shortCode,
    required this.totalPoints,
    required this.players,
  });

  factory CupTeam.fromJson(Map<String, dynamic> j) => CupTeam(
        teamId:      j['team_id']      as int? ?? 0,
        teamNumber:  j['team_number']  as int,
        name:        j['name']         as String,
        colour:      j['colour']       as String? ?? '',
        shortCode:   j['short_code']   as String? ?? '',
        totalPoints: (j['total_points'] as num? ?? 0).toDouble(),
        players: (j['players'] as List? ?? [])
            .map((p) => CupPlayer.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
}

/// F9 / B9 / Overall segment result for one match.
class CupSegmentResult {
  final String  segment;   // 'front9', 'back9', 'overall'
  final String? result;    // 'team1', 'team2', 'halved', null
  final double  t1Points;
  final double  t2Points;

  const CupSegmentResult({
    required this.segment,
    this.result,
    required this.t1Points,
    required this.t2Points,
  });

  factory CupSegmentResult.fromJson(Map<String, dynamic> j) => CupSegmentResult(
        segment:  j['segment']  as String,
        result:   j['result']   as String?,
        t1Points: (j['t1_pts'] as num? ?? 0).toDouble(),
        t2Points: (j['t2_pts'] as num? ?? 0).toDouble(),
      );

  String get segmentLabel {
    switch (segment) {
      case 'front9':  return 'F9';
      case 'back9':   return 'B9';
      case 'overall': return '18';
      default:        return segment;
    }
  }
}

/// One logical match (foursome or singles) with its three Nassau segments.
class CupMatch {
  final String  gameType;
  final int?    group;     // foursome group_number, null for singles
  final String  team1;
  final String  team2;
  final String? player1;  // short_name for singles, null for foursome
  final String? player2;
  final List<CupSegmentResult> segments;

  const CupMatch({
    required this.gameType,
    this.group,
    required this.team1,
    required this.team2,
    this.player1,
    this.player2,
    required this.segments,
  });

  factory CupMatch.fromJson(Map<String, dynamic> j) => CupMatch(
        gameType: j['game_type'] as String,
        group:    j['group']    as int?,
        team1:    j['team1']    as String,
        team2:    j['team2']    as String,
        player1:  j['player1'] as String?,
        player2:  j['player2'] as String?,
        segments: (j['segments'] as List? ?? [])
            .map((s) => CupSegmentResult.fromJson(s as Map<String, dynamic>))
            .toList(),
      );

  String get displayLabel {
    if (player1 != null && player2 != null) return '$player1 vs $player2';
    if (group != null) return 'Group $group';
    return '$team1 vs $team2';
  }
}

/// Per-round breakdown — team points + match details.
class CupRound {
  final int    roundId;
  final int    roundNumber;
  final String date;
  final String course;
  final double nassauPointValue;
  final double pointMultiplier;
  final String notes;
  final List<Map<String, dynamic>> teamPoints;  // [{team_name, points}, ...]
  final List<CupMatch> matches;

  const CupRound({
    required this.roundId,
    required this.roundNumber,
    required this.date,
    required this.course,
    required this.nassauPointValue,
    required this.pointMultiplier,
    required this.notes,
    required this.teamPoints,
    required this.matches,
  });

  factory CupRound.fromJson(Map<String, dynamic> j) => CupRound(
        roundId:          j['round_id']           as int,
        roundNumber:      j['round_number']        as int,
        date:             j['date']                as String,
        course:           j['course']              as String,
        nassauPointValue: (j['nassau_point_value'] as num? ?? 1).toDouble(),
        pointMultiplier:  (j['point_multiplier']   as num? ?? 1).toDouble(),
        notes:            j['notes']               as String? ?? '',
        teamPoints: (j['team_points'] as List? ?? [])
            .map((t) => Map<String, dynamic>.from(t as Map))
            .toList(),
        matches: (j['matches'] as List? ?? [])
            .map((m) => CupMatch.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

/// Full team-tournament summary (GET /api/tournaments/<id>/team-tournament/).
class TeamTournamentSummary {
  final String          tournamentName;
  final String          cupName;
  final bool            draftComplete;
  final List<CupTeam>   teams;
  final List<CupRound>  rounds;

  const TeamTournamentSummary({
    required this.tournamentName,
    required this.cupName,
    required this.draftComplete,
    required this.teams,
    required this.rounds,
  });

  factory TeamTournamentSummary.fromJson(Map<String, dynamic> j) =>
      TeamTournamentSummary(
        tournamentName: j['tournament_name'] as String,
        cupName:        j['cup_name']        as String? ?? 'Cup',
        draftComplete:  j['draft_complete']  as bool?   ?? false,
        teams: (j['teams'] as List? ?? [])
            .map((t) => CupTeam.fromJson(t as Map<String, dynamic>))
            .toList(),
        rounds: (j['rounds'] as List? ?? [])
            .map((r) => CupRound.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}

// ---------------------------------------------------------------------------
// Quota Nassau
// ---------------------------------------------------------------------------

class QuotaNassauPlayerInfo {
  final int    playerId;
  final String name;
  final String shortName;
  final int    quota;

  const QuotaNassauPlayerInfo({
    required this.playerId,
    required this.name,
    required this.shortName,
    required this.quota,
  });

  factory QuotaNassauPlayerInfo.fromJson(Map<String, dynamic> j) =>
      QuotaNassauPlayerInfo(
        playerId  : j['player_id']  as int,
        name      : j['name']       as String? ?? '',
        shortName : j['short_name'] as String? ?? '',
        quota     : j['quota']      as int? ?? 0,
      );
}

class QuotaNassauSegment {
  final String? result;   // 'player1' | 'player2' | 'halved' | null
  final double  margin;   // +ve = player1 ahead in quota pts

  const QuotaNassauSegment({required this.result, required this.margin});

  factory QuotaNassauSegment.fromJson(Map<String, dynamic> j) =>
      QuotaNassauSegment(
        result: j['result'] as String?,
        margin: (j['margin'] as num?)?.toDouble() ?? 0.0,
      );
}

class QuotaNassauHoleResult {
  final int    hole;
  final int    p1Stableford;
  final int    p2Stableford;
  final double? p1VsQuota;
  final double? p2VsQuota;
  final double? front9Margin;
  final double? back9Margin;
  final double? overallMargin;

  const QuotaNassauHoleResult({
    required this.hole,
    required this.p1Stableford,
    required this.p2Stableford,
    this.p1VsQuota,
    this.p2VsQuota,
    this.front9Margin,
    this.back9Margin,
    this.overallMargin,
  });

  factory QuotaNassauHoleResult.fromJson(Map<String, dynamic> j) =>
      QuotaNassauHoleResult(
        hole           : j['hole']           as int,
        p1Stableford   : j['p1_stableford']  as int? ?? 0,
        p2Stableford   : j['p2_stableford']  as int? ?? 0,
        p1VsQuota      : (j['p1_vs_quota']   as num?)?.toDouble(),
        p2VsQuota      : (j['p2_vs_quota']   as num?)?.toDouble(),
        front9Margin   : (j['front9_margin'] as num?)?.toDouble(),
        back9Margin    : (j['back9_margin']  as num?)?.toDouble(),
        overallMargin  : (j['overall_margin'] as num?)?.toDouble(),
      );
}

class QuotaNassauMatchSummary {
  final QuotaNassauPlayerInfo player1;
  final QuotaNassauPlayerInfo player2;
  final QuotaNassauSegment    front9;
  final QuotaNassauSegment    back9;
  final QuotaNassauSegment    overall;
  final List<QuotaNassauHoleResult> holes;

  const QuotaNassauMatchSummary({
    required this.player1,
    required this.player2,
    required this.front9,
    required this.back9,
    required this.overall,
    required this.holes,
  });

  factory QuotaNassauMatchSummary.fromJson(Map<String, dynamic> j) =>
      QuotaNassauMatchSummary(
        player1 : QuotaNassauPlayerInfo.fromJson(j['player1'] as Map<String, dynamic>),
        player2 : QuotaNassauPlayerInfo.fromJson(j['player2'] as Map<String, dynamic>),
        front9  : QuotaNassauSegment.fromJson(j['front9']  as Map<String, dynamic>),
        back9   : QuotaNassauSegment.fromJson(j['back9']   as Map<String, dynamic>),
        overall : QuotaNassauSegment.fromJson(j['overall'] as Map<String, dynamic>),
        holes   : (j['holes'] as List? ?? [])
            .map((h) => QuotaNassauHoleResult.fromJson(h as Map<String, dynamic>))
            .toList(),
      );

  int get holesPlayed => holes.length;
  String get status {
    if (holesPlayed == 0) return 'pending';
    if (holesPlayed >= 18) return 'complete';
    return 'in_progress';
  }
}

class QuotaNassauSummary {
  final String status;
  final List<QuotaNassauMatchSummary> matches;
  final NassauPhantomInfo? phantom;
  final String team1Colour;
  final String team2Colour;

  const QuotaNassauSummary({
    required this.status,
    required this.matches,
    this.phantom,
    this.team1Colour = 'Red',
    this.team2Colour = 'Blue',
  });

  factory QuotaNassauSummary.fromJson(Map<String, dynamic> j) {
    final rawPhantom = j['phantom_info'] as Map<String, dynamic>?;
    return QuotaNassauSummary(
      status      : j['status'] as String? ?? 'pending',
      matches     : (j['matches'] as List? ?? [])
          .map((m) => QuotaNassauMatchSummary.fromJson(m as Map<String, dynamic>))
          .toList(),
      phantom     : rawPhantom != null ? NassauPhantomInfo.fromJson(rawPhantom) : null,
      team1Colour : j['team1_colour'] as String? ?? 'Red',
      team2Colour : j['team2_colour'] as String? ?? 'Blue',
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
