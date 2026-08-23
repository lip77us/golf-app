import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../utils/cup_colors.dart';
import '../providers/round_provider.dart';
import '../utils/grouping.dart';
// Aliased so the top-level groupSizes(n) helper is reachable inside
// _Step3GroupsAndTees, whose `groupSizes` field would otherwise shadow it.
import '../utils/grouping.dart' as gr;
import '../utils/course_handicap.dart';
import '../widgets/team_play/team_drive_step.dart';
import '../widgets/team_play/team_format_step.dart';
import '../widgets/team_play/team_handicap_step.dart';
import '../widgets/team_play/team_payout_step.dart';
import '../utils/team_allowance.dart';
import '../widgets/error_view.dart';
import '../widgets/game_chip.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/inline_message.dart';
import '../widgets/net_double_bogey_card.dart';
import '../utils/add_halved_golfer.dart';
import '../utils/golfer_invite.dart';
import '../widgets/course_search_field.dart';
import '../widgets/payout_config_field.dart';
import '../widgets/section_card.dart';
import '../widgets/tee_assignment.dart';
import 'irish_rumble_setup_screen.dart'; // also exports LowNetSetupScreen
import 'pink_ball_setup_screen.dart';
import 'player_form_screen.dart';
import 'ryder_cup_draft_screen.dart';

// Group badge colours — cycles for > 4 foursomes
const _groupColors = [
  Color(0xFF1565C0), // blue
  Color(0xFF2E7D32), // green
  Color(0xFFB71C1C), // red
  Color(0xFFE65100), // orange
  Color(0xFF6A1B9A), // purple
];

// ---------------------------------------------------------------------------
// Per-round draft for additional rounds (2..N) in a multi-round tournament
// ---------------------------------------------------------------------------

class _RoundDraft {
  int?     courseId;
  DateTime date;
  _RoundDraft({this.courseId, DateTime? date}) : date = date ?? DateTime.now();
}

/// The distinct steps the create-tournament wizard can present.  The actual
/// sequence for a given tournament is `_NewRoundWizardState._stepFlow`, derived
/// from the chosen type — so the order and count live in data, not in a switch
/// keyed on a hardcoded index.
enum _StepKind {
  typeFormat,   // What kind of event — scoring unit + format (asked first)
  eventDetails, // New/existing, name, event course, rounds by date
  handicap,     // Cup: handicap mode (+ net double-bogey cap)
  scoring,      // Individual: method, cap-as-a-rule, allowance, rounds counted
  stablefordPoints, // Individual + Stableford only: the points table
  cupDesign,    // Cup: team count + colours
  cupGamePlan,  // Cup: per-round game plan
  sideGame,     // Cup: field-wide side game (struck when format is exclusive)
  players,      // Non-cup: player selection
  groups,       // Non-cup: group assignment + tees
  payouts,      // Individual: the championship pot, on its own
  games,        // Individual: side games, each with its entry fee
  // Team Play — the third shape (docs/design-review/handoff-team-play).
  // Deliberately the SHORTEST flow of the three: a Saturday scramble is the
  // most common event a club runs and the least complicated thing it does.
  teamFormat,   // Scramble or shamble, and the shamble ball count in place
  teamDrives,   // The four drive rules — three quotas and one schedule
  teamHandicap, // The allowance the format prescribes, worked on their own teams
  teamPayout,   // Fee, places and split — after teams, because it needs both
  review,       // Review → create
}

/// Who is competing — the "scoring unit" the whole flow derives from.  Cup,
/// solo and quad (Team Play) are wired; pair is drawn but staged (no two-golfer
/// scoring engine yet), so the picker shows it disabled.
enum _EventType { cup, solo, pair, quad }

// ---------------------------------------------------------------------------
// Wizard entry point
// ---------------------------------------------------------------------------

class NewRoundWizard extends StatefulWidget {
  const NewRoundWizard({super.key});

  @override
  State<NewRoundWizard> createState() => _NewRoundWizardState();
}

class _NewRoundWizardState extends State<NewRoundWizard> {
  // ---- step flow ----
  // The wizard is a DERIVED, ordered list of steps — not a fixed count.
  // `_step` indexes into `_stepFlow`, which is computed from the tournament
  // type, so the progress indicator ("2 of 5") is always honest and so
  // conditional steps can be added/removed by editing the list rather than
  // renumbering a switch.  Post-creation is terminal (index == length), not a
  // member of the flow.
  int _step = 0;

  bool get _isCupTournament =>
      _createNewTournament &&
      _tournamentActiveGames.contains(GameIds.teamCup);

  /// Team Play — many small teams, ONE round, one leaderboard. Foursomes or
  /// pairs; the size is `_tpTeamSize`.
  bool get _isTeamPlay =>
      _createNewTournament &&
      _tournamentActiveGames.contains(GameIds.teamPlay);

  /// The ordered steps for the current configuration.  Cup and non-cup share
  /// the front (tournament, details) then diverge; team assignment and round
  /// setup happen later from the tournament card, so the cup flow ends at
  /// review.  Phase 1 grows this list (e.g. a dedicated side-game step, struck
  /// when the format is exclusive).
  List<_StepKind> get _stepFlow {
    if (_isCupTournament) {
      return [
        _StepKind.typeFormat,
        _StepKind.eventDetails,
        _StepKind.handicap,
        _StepKind.cupDesign,
        _StepKind.cupGamePlan,
        // No tournament side-game step in cup play — field-wide side games belong
        // to individual tournaments. A cup's point-bearing games (incl. Irish
        // Rumble) are set on the games-by-round plan above.
        _StepKind.review,
      ];
    }
    if (_isTeamPlay) {
      // Eight steps, two of them existing screens reused unchanged: Set tees
      // (groups) and Review. Rounds is not in here at all — one round is
      // STATED, not chosen, and nothing downstream has a round dimension.
      //
      // **Drives drops out when the format has no tee shot to choose.** In
      // best ball and Chapman both golfers drive every hole, so the step had no
      // control on it at all — a page whose only content was a note saying
      // there was nothing to set. Seven steps, and the header count reads this
      // list, so it stays honest.
      return [
        _StepKind.typeFormat,
        _StepKind.eventDetails,
        _StepKind.players,
        _StepKind.groups,          // the existing Set tees screen, unchanged
        _StepKind.teamFormat,
        if (_tpHasDriveStep) _StepKind.teamDrives,
        _StepKind.teamHandicap,
        _StepKind.teamPayout,
        _StepKind.review,
      ];
    }
    // Individual play — the eight steps the create-flow map settles on. Seven
    // show for a one-round stroke-play event: Stableford adds the points
    // table (the max is not a question, so stroke play does not), and the day
    // bet only appears on the side-game step when the event has more than one
    // round. The header count reads this list, so it is always honest.
    return [
      _StepKind.typeFormat,
      _StepKind.eventDetails,
      _StepKind.scoring,
      if (_soloFormat == 'stableford') _StepKind.stablefordPoints,
      _StepKind.players,
      _StepKind.groups,
      _StepKind.payouts,
      _StepKind.games,
      _StepKind.review,
    ];
  }

  // ── Foursome Play helpers ──────────────────────────────────────────────

  /// The teams, as rosters of player ids.
  ///
  /// **There is no separate build-teams step.** The Groups & Tees step already
  /// assigns every golfer to a group — drag to reorder, "Edit sizes" to change
  /// the breakdown — and in this shape the group IS the team. Asking twice
  /// would be the app making the TD do the same job in two places, and the
  /// second answer would silently win.
  ///
  /// **Field size sets the team count, not the reverse**: 23 golfers become
  /// six teams, five of four and one of three, and they moves golfers from there.
  List<List<int>> get _tpRosters {
    final ids   = _orderedPlayerIds;
    final sizes = _effectiveGroupSizes;
    final out   = <List<int>>[];
    var cursor  = 0;
    for (final size in sizes) {
      if (cursor >= ids.length) break;
      final end = (cursor + size).clamp(0, ids.length);
      out.add(ids.sublist(cursor, end));
      cursor = end;
    }
    return out;
  }

  /// The TEAMS, as rosters of player ids.
  ///
  /// **A playing group is not a team in a pairs event.** `_tpRosters` gives
  /// the groups that walk the course together — four golfers, one tee time, one
  /// card — and this splits each of them into the one or two pairs that are
  /// actually scored. A foursome event returns exactly the groups.
  List<List<int>> get _tpTeams {
    if (_tpTeamSize != 2) return _tpRosters;
    return [
      for (final group in _tpRosters)
        ...splitIntoPairs(group, bestBall: _tpFormat == 'best_ball'),
    ];
  }

  /// `Group 1` … `Group 6` for a foursome; **`Maiolini & Yau` for a pair.**
  ///
  /// The wizard has no business inventing names for four golfers — a colour the TD
  /// never chose is one more thing on screen that does not help them. But a
  /// pair's two surnames are not an invented name: they are the only thing
  /// anybody calls it, they fit on a leaderboard row, and golfers say a pair
  /// that way out loud. The server applies the same rule, so the two agree.
  String _tpTeamLabel(int index) {
    final fallback = 'Group ${index + 1}';
    if (_tpTeamSize != 2) return fallback;
    final teams = _tpTeams;
    if (index >= teams.length || teams[index].length != 2) return fallback;
    final surnames = teams[index]
        .map((id) => _tpGolfer(id)?.name.trim() ?? '')
        .where((n) => n.isNotEmpty)
        .map((n) => n.split(' ').last)
        .toList();
    if (surnames.length != 2) return fallback;
    final joined = surnames.join(' & ');
    // Wide enough for two real surnames — `Petersen & Reilly` is seventeen
    // characters. Mirrors PAIR_NAME_MAX on the server.
    return joined.length <= 24 ? joined : fallback;
  }

  /// The tee-shot control does three different jobs, and the FORMAT picks
  /// which (docs/design-review/handoff-team-pairs/SPEC.md §5). Coerce the
  /// drive rule when the format changes, rather than leaving a setting behind
  /// that no longer means anything — the server does the same.
  void _applyTpFormatRules() {
    final rules = _tpDriveRulesAllowed;
    if (!rules.contains(_tpDriveRule)) _tpDriveRule = rules.first;
    // Switching pairs → fours halves what a window can be asked for, so a
    // figure set at the pairs ceiling has to come down with it.
    final cap = _tpMaxDrivesPerGolfer;
    if (_tpDrivesReq > cap) _tpDrivesReq = cap;
    // Picking best ball or Chapman drops the Drives step out of the flow, and
    // `_step` indexes that list. The format is chosen from a step ABOVE the one
    // that disappears, so this cannot bite today — but the flow is derived and
    // the next conditional step might not sit so conveniently.
    final last = _stepFlow.length - 1;
    if (_step > last) _step = last;
  }

  /// Whether the wizard shows a Drives step at all, and which rules it offers.
  /// Both live in `utils/team_allowance.dart` beside the other mirrors of the
  /// server's rules, so they can be unit-tested rather than sealed in wizard
  /// state.
  bool get _tpHasDriveStep => hasDriveStep(_tpTeamSize, _tpFormat);
  List<String> get _tpDriveRulesAllowed =>
      driveRulesFor(_tpTeamSize, _tpFormat);

  /// The most drives one golfer can be asked for in a window: the holes in it,
  /// divided between the golfers.
  ///
  /// Four golfers sharing nine holes tops out at two each, and four each across
  /// eighteen. **Two golfers sharing the same nine top out at four each**, and
  /// nine each across eighteen — every hole spoken for, nothing left over.
  /// Mirrors `TeamPlayConfig.max_drives_per_golfer`; the wizard sets this
  /// before the config row exists, so it cannot ask the server.
  int get _tpMaxDrivesPerGolfer =>
      maxDrivesPerGolfer(_tpTeamSize, _tpDriveRule);

  /// The odd-field block, computed on the roster the Groups & Tees step
  /// produced (docs/design-review/handoff-team-pairs/SPEC.md §3.1).
  ///
  /// **Pairs need an even field**, and there is no phantom partner to paper
  /// over an odd one. The block names the golfer rather than reporting a
  /// count, because the fix is about one golfer and the TD needs to know which
  /// one is standing there.
  ///
  /// A team of three is allowed in **best ball only** — a third ball is
  /// another option to count; alternate shot and Chapman cannot honour it at
  /// all, and in a scramble it is a straight advantage.
  List<String> get _tpPairsProblems {
    if (_tpTeamSize != 2) return const [];
    final out = <String>[];
    final rosters = _tpTeams;
    for (var i = 0; i < rosters.length; i++) {
      final r = rosters[i];
      if (r.isEmpty) continue;
      if (r.length < 2) {
        final name = _tpGolfer(r.first)?.name ?? 'One golfer';
        out.add('$name has no partner.');
      } else if (r.length > 2 && _tpFormat != 'best_ball') {
        out.add('${_tpTeamLabel(i)} has ${r.length} golfers — only best ball '
                'can play a three.');
      }
    }
    return out;
  }

  /// A golfer as the Foursome Play screens need them — name and course handicap
  /// off the tee they were given on the Groups & Tees step.
  ({int playerId, String name, int courseHandicap})? _tpGolfer(int id) {
    final player = _allPlayers.where((p) => p.id == id).firstOrNull;
    if (player == null) return null;
    final tee = _playerTees[id];
    return (
      playerId: id,
      name: player.name,
      courseHandicap: tee == null ? 0 : courseHandicapFor(player, tee),
    );
  }

  /// True when any team plays three — the screens say so rather than being
  /// quietly wrong for one of them.
  bool get _tpHasShortTeam =>
      _tpTeamSize != 2 && _tpRosters.any((r) => r.length == 3);

  /// The TD's own first pair, for the figures printed on the format options.
  ///
  /// **A generic illustration proves nothing.** His own two golfers and their two
  /// percentages are the only numbers they will check, and the point of showing
  /// them before the format is chosen is that the format alone triples the
  /// strokes.
  ({String name, List<int> handicaps})? get _tpSamplePair {
    if (_tpTeamSize != 2) return null;
    final rosters = _tpTeams;
    final full = rosters.where((r) => r.length == 2).firstOrNull;
    if (full == null) return null;
    final golfers = full.map(_tpGolfer).whereType<
        ({int playerId, String name, int courseHandicap})>().toList();
    if (golfers.length != 2) return null;
    golfers.sort((a, b) => a.courseHandicap.compareTo(b.courseHandicap));
    return (
      name      : golfers.map((g) => g.name.split(' ').last).join(' & '),
      handicaps : golfers.map((g) => g.courseHandicap).toList(),
    );
  }

  /// The ball-count average the shamble allowance tracks.
  double get _tpAvgBallCount {
    final pars = _tpParByHole();
    if (pars.isEmpty) return _tpBallFixed.toDouble();
    final counts = resolveBallCounts(
      mode: _tpBallMode, fixed: _tpBallFixed,
      perHole: _tpPerHoleCounts, parByHole: pars,
    );
    if (counts.isEmpty) return _tpBallFixed.toDouble();
    return counts.values.fold<int>(0, (a, b) => a + b) / counts.length;
  }

  /// Par by hole off the first assigned tee — every tee on a course shares its
  /// hole numbering, and par-based counts only need the shape.
  Map<int, int> _tpParByHole() {
    final tee = _playerTees.values.whereType<TeeInfo>().firstOrNull;
    if (tee == null) return {};
    return {
      for (final h in tee.holes)
        (h['number'] as int): (h['par'] as int? ?? 4),
    };
  }

  String get _tpTeeName {
    final tee = _playerTees.values.whereType<TeeInfo>().firstOrNull;
    return tee?.teeName ?? 'chosen';
  }

  /// Number of wizard steps for the current type (excludes post-creation).
  int get _totalSteps => _stepFlow.length;

  /// The kind of the step currently shown.  Clamped against a transient
  /// out-of-range index — the flow length only changes at step 0, where the
  /// index is valid in both variants.
  _StepKind get _currentStep =>
      _stepFlow[_step.clamp(0, _stepFlow.length - 1)];

  /// True on the post-creation confirmation screen (index past the flow).
  bool get _isPostCreate => _step >= _stepFlow.length;

  // ---- Type & format (asked first) ----
  // Who is competing + the format that sets the scoring unit.  Selecting a
  // type/format rewrites the championship entry in _tournamentActiveGames (see
  // _applyTypeFormat).  The cup format is informational for now — per-round
  // "Games by round" remains the source of truth; solo format is functional
  // (it chooses the championship game).
  //
  // **Defaults to Individual stroke play**, which is the ordinary tournament:
  // a field of singles on one card.  A cup is a specific thing a club sets up
  // on purpose, and defaulting to it made every other event start by undoing
  // a choice — including the handicap, since a cup silently brings strokes off
  // the low index with it.
  _EventType _eventType  = _EventType.solo;
  String     _cupFormat  = 'mixed';    // mixed | triple  (triple = exclusive)
  String     _soloFormat = 'stroke';   // stroke | stableford

  // ---- Tournament side game (cup, non-exclusive formats only) ----
  // A field-wide game every group plays, scored across the field.  None is the
  // default (most cups run none); the step is struck for exclusive formats.
  String _tournamentSideGame = 'none';   // none | irish_rumble | pink_ball

  // ---- Step: Tournament (name, rounds, new/existing) ----
  bool              _createNewTournament = true;
  Tournament?       _existingTournament;
  final _nameCtrl   = TextEditingController();
  int               _numRounds           = 1;
  /// Additional round drafts for rounds 2..N (length = _numRounds - 1).
  List<_RoundDraft> _additionalRounds    = [];
  /// Tournament-level games — the championship entry (teamCup /
  /// championshipStrokePlay / championshipStableford) is owned by the type &
  /// format step; low_net may be added later on the Cup Design step.  Seeded to
  /// the cup default so the flow opens on a cup.
  // Seeded to match the default type above — Individual stroke play, whose
  // championship is Stroke Play and which carries no cup marker. Out of step
  // with `_eventType` this is the set that actually gets POSTED, so the first
  // screen would agree with itself and the created tournament would not.
  final Set<String> _tournamentActiveGames = {
    GameIds.championshipStrokePlay,
  };

  // ---- Team Play (four-golfer teams, or pairs) ----
  // One config, set across steps 5–9 and posted once the round exists. The
  // defaults ARE a legitimate event: a one-round scramble with no drive
  // requirement takes every one of them, which is the point of the flow being
  // the shortest of the three.
  //
  // **Pairs are the same flow with the size set to two**
  // (docs/design-review/handoff-team-pairs/SPEC.md §1). They change the format
  // list on the format step and the allowance table on the handicap step, and
  // nothing else knows about them — same groups screen, same payout, same
  // review, same board.
  int    _tpTeamSize      = 4;            // 4 | 2
  String _tpFormat        = 'scramble';   // scramble | shamble | best_ball | …
  String _tpBallMode      = 'fixed';      // fixed | escalating | par_based | per_hole
  int    _tpBallFixed     = 2;            // best 2 of 4 — the answer most rounds want
  final Map<int, int> _tpPerHoleCounts = {};
  String _tpDriveRule     = 'none';
  int    _tpDrivesReq     = 1;
  String _tpDrivePenalty  = 'warn';       // falling short costs nothing by default
  String _tpHandicapMode  = 'net';
  int?   _tpOverridePct;                  // null = the format's table
  int    _tpEntryFee      = 25;
  int    _tpPlacesPaid    = 3;
  List<int> _tpSplit      = [50, 30, 20];

  // ---- Teams (cup tournaments) ----
  // Count, names, badges and colours are all captured here now, so the draft
  // never has to rename.  The cup uses the single tournament name (_nameCtrl)
  // — there is no separate cup-name field.  Names/badges are optional with a
  // real default (Team 1 / Team 2).  Controllers are fixed at the 4-team max;
  // only _cupTeamCount of them are shown.
  int   _cupTeamCount = 2;
  /// Colour name per team index (0-based).  Length always matches
  /// _cupTeamCount; trimmed / extended whenever the team count changes.
  /// Default palette: Red, Blue, Green, Yellow (all unique, so colour locking
  /// starts from a legal state).
  List<String> _cupTeamColours = ['Red', 'Blue'];
  final List<TextEditingController> _teamNameCtrls =
      List.generate(4, (_) => TextEditingController());
  final List<TextEditingController> _teamBadgeCtrls =
      List.generate(4, (_) => TextEditingController());
  /// Whether the user has typed in a team's badge field — once they have, the
  /// badge stops auto-following the name.
  final List<bool> _teamBadgeOwned = List.filled(4, false);

  void _resizeCupTeamColours(int newCount) {
    const defaults = ['Red', 'Blue', 'Green', 'Yellow'];
    if (newCount == _cupTeamColours.length) return;
    final next = <String>[..._cupTeamColours];
    while (next.length < newCount) {
      next.add(defaults[next.length % defaults.length]);
    }
    if (next.length > newCount) next.removeRange(newCount, next.length);
    _cupTeamColours = next;
  }

  /// A one-letter badge derived from a team name: leading "Team " stripped,
  /// first character upper-cased ("Team Bucko" → "B").
  static String _deriveBadge(String s) {
    final t = s.trim().replaceFirst(RegExp(r'^team\s+', caseSensitive: false), '');
    return t.isEmpty ? '' : t[0].toUpperCase();
  }

  /// The team name to persist — the typed name, or the "Team N" default.
  String _effectiveTeamName(int i) {
    final t = _teamNameCtrls[i].text.trim();
    return t.isEmpty ? 'Team ${i + 1}' : t;
  }

  /// The badge to persist — the typed badge, else derived from the name.
  String _effectiveTeamBadge(int i) {
    final b = _teamBadgeCtrls[i].text.trim();
    return b.isNotEmpty ? b.toUpperCase() : _deriveBadge(_effectiveTeamName(i));
  }

  // ---- Cup Round Games (step 3 for cup tournaments) ----
  // Per-round game plan: round index (0 = round 1, 1 = round 2, …) →
  // Cup game types per round.  Each unique game type appears once.
  // e.g. {0: ['nassau', 'irish_rumble']}
  // Group count is NOT entered here — it derives from the draft's side size
  // (see Spine B); the standings projection reads it live off the roster.
  final Map<int, List<String>>        _roundCupGames       = {};
  // Cup point values per game type per round: round index → game_type → pts.
  // e.g. {0: {'nassau': 1.0, 'singles_nassau': 2.0}}  Default 1.0.
  final Map<int, Map<String, double>> _roundCupPoints      = {};
  // Mixed cup: how many UNITS of each game a round runs — foursomes for
  // foursome games, twosomes for singles, 1/0 for a one-match game (Rumble).
  // round index → game_type → count.  The count IS the pick: >0 means it's in
  // the day.  Persisted as Round.cup_group_counts so totals are real.
  final Map<int, Map<String, int>>    _roundCupCounts      = {};
  // Mixed cup: golfers expected per side — the roster meter's target. No prior
  // step supplies a headcount (the draft is later), so the TD sets it here.
  int                                 _cupSideSize         = 16;

  // ---- Step 1: Round details (course, dates, handicap — NO game selection) ----
  List<CourseInfo>  _courses        = [];
  int?              _selectedCourseId;
  DateTime          _date           = DateTime.now();
  // Handicap mode default follows the type: cup formats are foursome-based
  // match play and play off the low index (SO Low), so that's the default while
  // the wizard opens on a cup; individual play defaults to Net.  Once the user
  // picks a mode themselves (_handicapModeTouched), the default stops overriding.
  // Net, matching the default type: strokes off the low index needs a single
  // opponent to anchor to, and a field has none.
  String            _handicapMode   = 'net';
  bool              _handicapModeTouched = false;
  int               _netPercent     = 100;
  bool              _netMaxDoubleBogey = true;

  // ---- Individual play: rounds counted (best N of M) ----
  // Null = every round counts. Only ASKED above two rounds — below that there
  // is no answer worth giving, so the block does not render and the value
  // stays null.
  int? _roundsToCount;

  // ---- Individual play: the Stableford points table ----
  // Chosen per tournament, never a global preference: a club's Sunday game
  // and its member-guest use different scales. Negatives are valid — the TD
  // sets the points as they see fit and the screen reports what an unusual
  // table implies rather than arguing with it.
  static const Map<String, List<int>> _kStablefordPresets = {
    // albatross, eagle, birdie, par, bogey, double+
    'Standard'       : [5, 4, 3, 2, 1, 0],
    'Modified (pro)' : [8, 5, 2, 0, -1, -3],
    'Reward birdies' : [6, 4, 3, 1, 0, -1],
  };
  List<int> _stablefordPoints = const [5, 4, 3, 2, 1, 0];
  String    _stablefordPreset = 'Standard';

  // ---- Step 4: Side-game selection + buy-in config ----
  final Set<String> _activeGames = {}; // no defaults — user picks

  // ---- Individual play: the day bet's money ----
  // Every other side game owns a setup screen that asks for its payout table,
  // and a payout table needs the pool — so those fees live beside them. The
  // day bet has no screen of its own, so its money is set here or nowhere.
  int _dayBetEntryFee   = 0;
  int _dayBetNumPayouts = 3;
  List<int> _dayBetPayouts = const [0, 0, 0, 0];

  // ---- Individual play: Mini Singles Bracket ----
  // Two pots, funded differently. Day 1 is a side bet entered per golfer and
  // paid inside each group — set on the bracket's own setup screen with its
  // payouts. Day 2 is carved off the TOP of the championship pool, which only
  // the tournament can decide, so the percentage and the empty-seat rule are
  // the two things kept here.
  int       _miniCarvePct       = 25;
  String    _miniEmptySeatRule  = 'promote';   // promote | points | short

  // Stroke Play Championship entry fee / payouts entered in Step 4.
  // Applied automatically to the tournament during _createRound().
  int       _lowNetEntryFee      = 0;
  int       _lowNetNumPayouts    = 3;
  List<int> _lowNetPayouts       = const [0, 0, 0, 0];

  // Match Play entry fee / payouts entered in Step 4.
  // Applied automatically to all groups during _createRound().
  int       _matchPlayEntryFee       = 0;
  int       _matchPlayNumPayouts     = 3;
  List<int> _matchPlayPayouts        = const [0, 0, 0, 0];
  // Tracks whether we auto-configured match play so Step 6 can skip it.
  bool      _matchPlayStep6Configured = false;

  // ---- Step 2: Players ----
  List<PlayerProfile> _allPlayers = [];
  final Set<int>      _selectedIds = {};
  String              _search = '';

  // ---- Step 3: Drag-and-drop group assignment + per-player tee ----
  List<int>           _orderedPlayerIds = [];
  Map<int, TeeInfo?>  _playerTees       = {};
  /// Optional TD-set override for how players bucket into groups.
  /// When non-null, this list of sizes is used verbatim instead of
  /// the `groupSizes(n)` auto-balance.  Sum must equal selected player
  /// count and each size must be in {2,3,4}.  Reset to null whenever
  /// the player count changes so we don't keep a stale shape.
  List<int>?          _groupSizesOverride;

  // ---- Step 5: Review / create ----
  bool    _creating    = false;
  String? _createError;

  // ---- Step 6: Game setup (shown after round is created) ----
  Round? _createdRound;
  int?   _createdTournamentId;

  // ---- reference data ----
  List<TeeInfo>    _tees        = [];
  List<Tournament> _tournaments = [];
  bool             _dataLoading = true;
  String?          _dataError;

  // ---- form keys ----
  final _step0Key = GlobalKey<FormState>();

  // ---- derived helpers ----

  List<TeeInfo> get _courseTees => _selectedCourseId == null
      ? []
      : _tees.where((t) => t.course.id == _selectedCourseId).toList();

  CourseInfo? get _selectedCourse =>
      _courses.where((c) => c.id == _selectedCourseId).firstOrNull;

  List<PlayerProfile> get _orderedPlayers => _orderedPlayerIds
      .map((id) => _allPlayers.firstWhere((p) => p.id == id))
      .toList();

  /// Returns the group sizes the wizard should use right now.  Falls
  /// back to the auto-balance when no override is set, or when an
  /// override is set but no longer matches the player count (stale
  /// shape).  Defensive: never returns null.
  List<int> get _effectiveGroupSizes {
    final n  = _selectedIds.length;
    final ov = _groupSizesOverride;
    // A pairs field groups in FOURS — two pairs to a tee time, one scorer,
    // one card — with a twosome on the end when the number of pairs is odd
    // and a trailing ONE when the field is, which is the golfer the block has
    // to name.
    if (_isTeamPlay && _tpTeamSize == 2) {
      if (ov != null && ov.fold<int>(0, (s, x) => s + x) == n
          && ov.every((s) => s >= 1 && s <= 4)) {
        return List<int>.from(ov);
      }
      return pairPlayGroupSizes(n);
    }
    if (ov != null && ov.fold<int>(0, (s, x) => s + x) == n
        && ov.every((s) => s >= 2 && s <= 4)) {
      return List<int>.from(ov);
    }
    return groupSizes(n);
  }

  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(() => setState(() {}));
    _loadReferenceData();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final c in _teamNameCtrls) c.dispose();
    for (final c in _teamBadgeCtrls) c.dispose();
    super.dispose();
  }

  Future<void> _loadReferenceData() async {
    setState(() { _dataLoading = true; _dataError = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final results = await Future.wait([
        client.getTournaments(),
        client.getTees(),
        client.getPlayers(),
      ]);
      if (!mounted) return;

      final rawTees = results[1] as List<TeeInfo>;
      // Sort tees: lower sort_priority first; within same priority, M < null < W
      int sexRank(String? s) => s == 'M' ? 0 : (s == null ? 1 : 2);
      final tees = rawTees
        ..sort((a, b) {
          final pc = a.sortPriority.compareTo(b.sortPriority);
          if (pc != 0) return pc;
          final sc = sexRank(a.sex).compareTo(sexRank(b.sex));
          if (sc != 0) return sc;
          return a.teeName.compareTo(b.teeName);
        });

      // Derive unique courses from tees
      final courseMap = <int, CourseInfo>{};
      for (final t in tees) courseMap[t.course.id] = t.course;
      final courses = courseMap.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      setState(() {
        _tournaments      = results[0] as List<Tournament>;
        _tees             = tees;
        _courses          = courses;
        // No auto-select: leave _selectedCourseId null so the user must
        // explicitly pick a course (avoids surprising defaults like
        // "Augusta National" being pre-filled).
        // Additional round drafts also start with no course pre-selected.
        for (final d in _additionalRounds) {
          d.courseId ??= null; // explicit: remains null until user picks
        }
        _allPlayers       = (results[2] as List<PlayerProfile>)
            .where((p) => !p.isPhantom)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        _dataLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() { _dataError = friendlyError(e); _dataLoading = false; });
      }
    }
  }

  /// Called by the inline [CourseSearchField] once a course is chosen (an
  /// existing account course, or a catalog/API one it just cloned in). Refresh
  /// the wizard's course/tee data (a freshly cloned course brings new tees) and
  /// select it.
  ///
  /// [additionalIndex] null → Round 1. Picking Round 1 also defaults every
  /// extra day that hasn't been set yet to the same course, since most
  /// tournaments play one course (the user can still change a day).
  Future<void> _selectWizardCourse(CourseInfo course,
      {int? additionalIndex}) async {
    final client = context.read<AuthProvider>().client;
    try {
      final rawTees = await client.getTees();
      if (!mounted) return;
      int sexRank(String? s) => s == 'M' ? 0 : (s == null ? 1 : 2);
      final tees = [...rawTees]..sort((a, b) {
          final pc = a.sortPriority.compareTo(b.sortPriority);
          if (pc != 0) return pc;
          final sc = sexRank(a.sex).compareTo(sexRank(b.sex));
          if (sc != 0) return sc;
          return a.teeName.compareTo(b.teeName);
        });
      final courseMap = <int, CourseInfo>{};
      for (final t in tees) courseMap[t.course.id] = t.course;
      final courses = courseMap.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      setState(() {
        _tees    = tees;
        _courses = courses;
        if (additionalIndex == null) {
          _selectedCourseId = course.id;
          // Tee list changed → drop any per-player tee assignments.
          _playerTees.clear();
          // Default the extra days to this course (only those not yet chosen).
          for (final d in _additionalRounds) {
            d.courseId ??= course.id;
          }
        } else {
          _additionalRounds[additionalIndex].courseId = course.id;
        }
      });
    } catch (_) {
      // Non-fatal — leave existing course/tee data in place.
    }
  }

  /// Create a new login-less golfer inline, then select them.
  Future<void> _addGolfer() async {
    final created = await Navigator.of(context).push<PlayerProfile>(
      MaterialPageRoute(builder: (_) => const PlayerFormScreen()),
    );
    _selectCreatedGolfer(created);
    if (created != null && mounted) {
      await maybeOfferRoundSmsInvite(context, created,
          courseName: _selectedCourse?.name);
    }
  }

  /// Add an existing Halved member (not yet in my roster) by phone number,
  /// then select them for the tournament.
  Future<void> _addHalvedGolfer() async {
    final created = await addHalvedGolferByPhone(context);
    _selectCreatedGolfer(created);
  }

  void _selectCreatedGolfer(PlayerProfile? created) {
    if (created == null || !mounted) return;
    setState(() {
      if (!_allPlayers.any((p) => p.id == created.id)) {
        _allPlayers = [..._allPlayers, created]
          ..sort((a, b) => a.name.compareTo(b.name));
      }
      _selectedIds.add(created.id);
      _groupSizesOverride = null;
    });
  }

  // ---- navigation ----

  bool _canAdvance() {
    switch (_currentStep) {
      case _StepKind.typeFormat:
        // A valid type + format is always selected (defaults + only enabled
        // types are tappable), so this step never blocks.
        return true;
      case _StepKind.eventDetails:
        // New: a name and an event course are required.  Additional rounds
        // inherit the event course (the picker never clears to null), so the
        // per-round override needs no separate gate.  A primary game is
        // guaranteed by the type step.
        if (_createNewTournament) {
          return _nameCtrl.text.trim().isNotEmpty && _selectedCourseId != null;
        }
        return _existingTournament != null && _selectedCourseId != null;
      case _StepKind.handicap:
      case _StepKind.scoring:
      case _StepKind.stablefordPoints:
        // Every answer on these steps is valid — the TD sets the points as they
        // sees fit, and there is always a live method and allowance.
        return true;
      case _StepKind.payouts:
        // A tournament can run for a trophy. An unbalanced table is stated in
        // the balance line rather than blocking a keystroke, and settlement
        // refuses to close on it later — with the game named.
        return true;
      case _StepKind.cupDesign:
        // One name (the tournament name) covers the cup, and 2 teams is a
        // valid default — nothing to gate on, so Next is always live here.
        return true;
      case _StepKind.cupGamePlan:
        // Per-round game plan — every round must have at least one game.
        if (_roundCupGames.length < _numRounds) return false;
        return _roundCupGames.values.every((g) => g.isNotEmpty);
      case _StepKind.sideGame:
        // None is a valid (default) answer, so this step never blocks.
        return true;
      case _StepKind.teamFormat:
      case _StepKind.teamDrives:
        // Every answer on these is valid — there is always a live format, a
        // live rule and a live allowance, and the defaults are a real event.
        return true;
      case _StepKind.teamHandicap:
        // Balance is advice, and Next never waits on it. A golfer with no
        // partner is a broken tournament, and this is the one thing it does
        // wait on — the same gate the fours flow puts on an unplaced golfer.
        return _tpPairsProblems.isEmpty;
      case _StepKind.teamPayout:
        // The split has to reach 100 or the pool will not balance at
        // settlement — and the shortfall is named in dollars on the screen
        // rather than the button simply going grey.
        return _tpSplit.take(_tpPlacesPaid).fold(0, (a, b) => a + b) == 100;
      case _StepKind.players:
        return _selectedIds.length >= 2;
      case _StepKind.groups:
        return _orderedPlayerIds.isNotEmpty &&
            _orderedPlayerIds.every((id) => _playerTees[id] != null);
      case _StepKind.games:
        // Require at least ONE game to exist somewhere — either a championship
        // (tournament step) or a side game (this step).  Without this gate a
        // single-round tournament can be created with zero games, which is
        // meaningless.
        return _tournamentActiveGames.isNotEmpty || _activeGames.isNotEmpty;
      case _StepKind.review:
        // Cup: the cup itself is the game (game plan validated each round).
        // Non-cup: re-check the game-required rule before Create fires —
        // _canAdvance() drives the Create button too.
        if (_isCupTournament) return true;
        return _tournamentActiveGames.isNotEmpty || _activeGames.isNotEmpty;
    }
  }

  void _next() {
    final kind = _currentStep;
    if (kind == _StepKind.eventDetails &&
        !(_step0Key.currentState?.validate() ?? true)) return;
    // Build the ordered player list + tee defaults when leaving Players so the
    // groups/tees step has them.  Cup flows have no Players step.
    if (kind == _StepKind.players) _initGroups();
    if (_step < _stepFlow.length - 1) setState(() => _step++);
    // Note: the post-creation step is index == length; _next() never reaches it.
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
    else Navigator.of(context).pop();
  }

  /// Rewrite the championship entry in [_tournamentActiveGames] from the chosen
  /// type & format.  Cup carries Stroke Play underneath (per-player detail);
  /// solo maps its format to a championship game.  The low_net secondary game
  /// is a cup-design add-on, so it is cleared when leaving the cup type.
  void _applyTypeFormat() {
    _tournamentActiveGames.removeAll({
      GameIds.teamCup,
      GameIds.teamPlay,
      GameIds.championshipStrokePlay,
      GameIds.championshipStableford,
    });
    switch (_eventType) {
      case _EventType.cup:
        _tournamentActiveGames.addAll({
          GameIds.teamCup,
          GameIds.championshipStrokePlay,
        });
        break;
      case _EventType.solo:
        _tournamentActiveGames
          ..remove('low_net')
          ..add(_soloFormat == 'stableford'
              ? GameIds.championshipStableford
              : GameIds.championshipStrokePlay);
        break;
      case _EventType.quad:
      case _EventType.pair:
        // Team Play is a SHAPE marker, like team_cup — the team layer sits on
        // top of the round rather than being a per-round game. The backend
        // reads it in Tournament.is_team_play and, importantly, excludes it
        // from is_individual_play.
        //
        // **Fours and pairs are the SAME marker and the same step flow.** The
        // size is a control, not a fourth shape: a separate two-golfer wizard
        // would duplicate seven screens to change two.
        _tournamentActiveGames.add(GameIds.teamPlay);
        _tpTeamSize = _eventType == _EventType.pair ? 2 : 4;
        // A format legal at the other size has to go — there is no two-golfer
        // shamble and no four-golfer Chapman, and the server refuses the pair.
        if (!(kFormatsBySize[_tpTeamSize] ?? const []).contains(_tpFormat)) {
          _tpFormat = 'scramble';
        }
        _applyTpFormatRules();
        // One round is STATED, not chosen. Nothing downstream has a round
        // dimension, so the wizard never offers more.
        _numRounds = 1;
        _additionalRounds = [];
        break;
    }
    if (!_handicapModeTouched) _handicapMode = _defaultHandicapForFormat();
  }

  /// `[24, 10, 6, 0]` → `[{place: 1, amount: 24}, …]`, dropping unpaid places.
  static List<Map<String, dynamic>> _payoutList(int count, List<int> amounts) {
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < count && i < amounts.length; i++) {
      if (amounts[i] > 0) {
        out.add({'place': i + 1, 'amount': amounts[i].toDouble()});
      }
    }
    return out;
  }

  static bool _listEq(List<int> a, List<int> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);

  /// The standard handicap mode for the chosen type.  Cup formats are
  /// foursome-based match play (Triple Cup, Singles, Fourball) and play off the
  /// low index (SO Low); individual/field play defaults to Net.
  String _defaultHandicapForFormat() =>
      _eventType == _EventType.cup ? 'strokes_off' : 'net';

  /// Short human summary of the chosen type + format, used in step subtitles.
  String _typeSummary() {
    switch (_eventType) {
      case _EventType.cup:
        const names = {
          'mixed': 'Mixed cup',
          'triple': 'Triple Cup',
        };
        return 'Cup play · ${names[_cupFormat] ?? 'Cup'}';
      case _EventType.solo:
        return _soloFormat == 'stableford'
            ? 'Individual · Stableford'
            : 'Individual · Stroke play';
      case _EventType.pair:
        return 'Pairs Play · ${kTeamFormatNames[_tpFormat] ?? 'Scramble'}';
      case _EventType.quad:
        return 'Foursome Play · ${kTeamFormatNames[_tpFormat] ?? 'Scramble'}';
    }
  }

  /// Append a round.  Dates create rounds — the new round is a day after the
  /// last and inherits the event course (a per-round override can change it).
  void _addRound() {
    if (_numRounds >= 6) return;
    setState(() {
      _numRounds += 1;
      final baseDate =
          _additionalRounds.isEmpty ? _date : _additionalRounds.last.date;
      _additionalRounds.add(_RoundDraft(
        courseId: _selectedCourseId,
        date    : baseDate.add(const Duration(days: 1)),
      ));
      _clampRoundsToCount();
    });
  }

  /// Remove round (2..N) at [additionalIndex] into [_additionalRounds].  Round 1
  /// is the event itself and cannot be removed.
  void _removeRound(int additionalIndex) {
    setState(() {
      _additionalRounds.removeAt(additionalIndex);
      _numRounds = _additionalRounds.length + 1;
      _clampRoundsToCount();
    });
  }

  /// "Best 3 of 4" cannot survive the tournament shrinking to two rounds.
  /// Dropping back to "every round counts" is the honest answer — it is also
  /// the only one the Scoring step would offer at that size.
  void _clampRoundsToCount() {
    final n = _roundsToCount;
    if (n != null && (_numRounds <= 2 || n >= _numRounds)) {
      _roundsToCount = null;
    }
  }

  /// Labels for the type step's "what's left after this step" panel — read off
  /// the real remaining flow (everything after the type step) so the panel and
  /// the honest header count can never disagree.
  List<({String label, String sub, bool perRound})> _remainingStepPlan() {
    return [
      for (final k in _stepFlow)
        if (k != _StepKind.typeFormat)
          switch (k) {
            _StepKind.eventDetails =>
              (label: 'Event details', sub: 'Name, course and rounds', perRound: false),
            _StepKind.handicap =>
              (label: 'Handicap', sub: 'How strokes are given', perRound: false),
            _StepKind.scoring =>
              (label: 'Scoring', sub: 'Method, handicap and rounds counted', perRound: false),
            _StepKind.stablefordPoints =>
              (label: 'Points table', sub: 'The Stableford scale', perRound: false),
            _StepKind.payouts =>
              (label: 'Payouts', sub: 'The 36-hole money', perRound: false),
            _StepKind.cupDesign =>
              (label: 'Cup design', sub: 'Teams and colours', perRound: false),
            _StepKind.cupGamePlan =>
              (label: 'Games by round', sub: 'Format and points', perRound: true),
            _StepKind.sideGame =>
              (label: 'Side game', sub: 'Field-wide — Irish Rumble, Pink Ball', perRound: false),
            _StepKind.players =>
              (label: 'Players', sub: 'Add the field', perRound: false),
            _StepKind.groups =>
              (label: 'Groups & tees', sub: 'Assign groups and tees', perRound: true),
            _StepKind.games =>
              (label: 'Side games', sub: 'The four you set, each with its fee', perRound: false),
            _StepKind.teamFormat =>
              (label: _tpTeamSize == 2 ? 'Pairs format' : 'Team format',
               sub: _tpTeamSize == 2
                   ? 'How the pair scores'
                   : 'Scramble or shamble',
               perRound: false),
            _StepKind.teamDrives =>
              (label: 'Drives', sub: 'Whose tee shots have to be used', perRound: false),
            _StepKind.teamHandicap =>
              (label: 'Handicap', sub: 'The allowance the format prescribes', perRound: false),
            _StepKind.teamPayout =>
              (label: 'Entry & payout', sub: 'Fee, places and split', perRound: false),
            _StepKind.review =>
              (label: 'Review', sub: 'Save & create', perRound: false),
            _StepKind.typeFormat =>
              (label: '', sub: '', perRound: false), // filtered above
          },
    ];
  }

  /// Build/update the ordered player list and per-player tee defaults when
  /// advancing from Step 2 → Step 3.  Preserves existing order and tee
  /// choices for players that are still selected.
  void _initGroups() {
    final newIds = _selectedIds.toList();
    // Keep existing order for players that stayed selected
    final kept  = _orderedPlayerIds.where((id) => newIds.contains(id)).toList();
    final added = newIds.where((id) => !kept.contains(id)).toList();
    _orderedPlayerIds = [...kept, ...added];
    // Assign default tees for newly-added players
    for (final id in added) {
      final player = _allPlayers.firstWhere((p) => p.id == id);
      _playerTees[id] = _defaultTeeForPlayer(player);
    }
    // Remove tees for players that were deselected
    _playerTees.removeWhere((id, _) => !newIds.contains(id));
  }

  /// Pick the best default tee for a player based on sex + sort priority.
  TeeInfo? _defaultTeeForPlayer(PlayerProfile player) {
    if (_courseTees.isEmpty) return null;
    final sorted = List.of(_courseTees)
        ..sort((a, b) => a.sortPriority.compareTo(b.sortPriority));
    // 1. Sex match
    final sexMatch = sorted.where((t) => t.sex == player.sex);
    if (sexMatch.isNotEmpty) return sexMatch.first;
    // 2. Unisex fallback
    final unisex = sorted.where((t) => t.sex == null);
    if (unisex.isNotEmpty) return unisex.first;
    // 3. Any tee
    return sorted.first;
  }

  // ---- create ----

  Future<void> _createRound() async {
    setState(() { _creating = true; _createError = null; });
    try {
      if (_isCupTournament) {
        await _createCupTournament();
      } else {
        await _createCasualOrStandardRound();
      }
    } catch (e) {
      if (mounted) {
        setState(() { _createError = friendlyError(e); _creating = false; });
      }
    }
  }

  // ── Cup path ─────────────────────────────────────────────────────────────
  // Creates the tournament skeleton (all rounds as stubs) + TeamTournament
  // with placeholder team names.  No foursomes or players are set up here —
  // those happen later via "Assign Teams" and "Set Up Round N" on the
  // tournament card.

  /// Mixed cup: turn a round's drawn counts into the persistable
  /// (games, point_values, cup_group_counts).  Only games the engine can score
  /// persist; counts become foursome-equivalent units so the backend's
  /// total_possible (Σ units × pts × multiplier) lands on the drawn total.
  (List<String>, Map<String, double>, Map<String, int>) _mixedRoundPayload(int r) {
    const mul = {
      'nassau': 3, 'quota_nassau': 3, 'singles_nassau': 6,
      'singles_18': 2, 'irish_rumble': 1,
    };
    final counts = _roundCupCounts[r] ?? const {};
    final prices = _roundCupPoints[r] ?? const {};
    final games = <String>[];
    final pts   = <String, double>{};
    final grp   = <String, int>{};
    for (final g in _kMixedGames) {
      final c = counts[g.$1] ?? 0;
      if (c <= 0 || !_mixedScoreable(g)) continue;
      final m = mul[g.$1];
      if (m == null) continue;
      final units = (c * _mixedSeg(g) / m).round();
      if (units <= 0) continue;
      games.add(g.$1);
      pts[g.$1] = prices[g.$1] ?? 1.0;
      grp[g.$1] = units;
    }
    return (games, pts, grp);
  }

  Future<void> _createCupTournament() async {
    final client  = context.read<AuthProvider>().client;
    final dateStr = DateFormat('yyyy-MM-dd').format(_date);

    // 1. Create tournament
    final t = await client.createTournament(
      name       : _nameCtrl.text.trim(),
      startDate  : dateStr,
      activeGames: _tournamentActiveGames.toList(),
      totalRounds: _numRounds,
    );
    final tournamentId = t.id;
    if (!mounted) return;

    // 2. Create Round 1 as a stub (no foursomes; will be set up in Phase 3).
    //    Save unique game types and per-game point values.  Group counts are
    //    NOT set here — they derive from the draft's side size, so total_possible
    //    stays unknown until then rather than being guessed.
    final bool mixed = _cupFormat == 'mixed';
    List<String>        round1Games;
    Map<String, double> round1Points;
    Map<String, int>    round1Counts;
    if (mixed) {
      (round1Games, round1Points, round1Counts) = _mixedRoundPayload(0);
    } else {
      round1Games  = List<String>.from(_roundCupGames[0] ?? []);
      round1Points = Map<String, double>.from(_roundCupPoints[0] ?? {});
      for (final g in round1Games) {
        round1Points.putIfAbsent(g, () => 1.0);
      }
      round1Counts = const {}; // derived from the draft's side size, not entered
    }
    // Field-wide side game plays every round (no cup points / group count).
    if (_tournamentSideGame != 'none') round1Games.add(_tournamentSideGame);
    final round1 = await client.createRound(
      tournamentId    : tournamentId,
      courseId        : _selectedCourseId!,
      date            : dateStr,
      activeGames     : round1Games,
      gamePointValues : round1Points,
      cupGroupCounts  : round1Counts,
      roundNumber     : 1,
      handicapMode    : _handicapMode,
      netPercent      : _netPercent,
      netMaxDoubleBogey: false, // struck — cup is match play, no total to cap
    );
    if (!mounted) return;

    // 3. Create stub rounds for rounds 2..N
    for (int i = 0; i < _additionalRounds.length; i++) {
      final draft        = _additionalRounds[i];
      final draftDate    = DateFormat('yyyy-MM-dd').format(draft.date);
      List<String>        roundGames;
      Map<String, double> roundPoints;
      Map<String, int>    roundCounts;
      if (mixed) {
        (roundGames, roundPoints, roundCounts) = _mixedRoundPayload(i + 1);
      } else {
        roundGames  = List<String>.from(_roundCupGames[i + 1] ?? []);
        roundPoints = Map<String, double>.from(_roundCupPoints[i + 1] ?? {});
        for (final g in roundGames) {
          roundPoints.putIfAbsent(g, () => 1.0);
        }
        roundCounts = const {};
      }
      if (_tournamentSideGame != 'none') roundGames.add(_tournamentSideGame);
      await client.createRound(
        tournamentId    : tournamentId,
        courseId        : draft.courseId ?? _selectedCourseId!, // inherit event course
        date            : draftDate,
        activeGames     : roundGames,
        gamePointValues : roundPoints,
        cupGroupCounts  : roundCounts,
        roundNumber     : i + 2,
        handicapMode    : _handicapMode,
        netPercent      : _netPercent,
        netMaxDoubleBogey: false, // struck — cup is match play, no total to cap
      );
      if (!mounted) return;
    }

    // 4. Create TeamTournament with the names, badges and colours captured on
    //    the Teams step, so the draft never has to rename.  Player assignments
    //    still come later from the draft.
    _resizeCupTeamColours(_cupTeamCount);
    final teams = List.generate(_cupTeamCount, (i) => <String, dynamic>{
      'team_number': i + 1,
      'name'       : _effectiveTeamName(i),
      'colour'     : _cupTeamColours[i],
      'short_code' : _effectiveTeamBadge(i),
    });
    await client.postTeamTournamentSetup(
      tournamentId,
      cupName        : _nameCtrl.text.trim(),   // one name: the tournament name
      playersPerTeam : 1,          // placeholder; real value set in Phase 2
      teams          : teams,
    );
    if (!mounted) return;

    // 5. Navigate to post-creation confirmation.
    setState(() {
      _createdRound        = round1;
      _createdTournamentId = tournamentId;
      _step                = _totalSteps;   // past the flow → post-creation
      _creating            = false;
    });
  }

  // ── Non-cup path ─────────────────────────────────────────────────────────
  // Full wizard flow: creates tournament + Round 1 with foursomes + any
  // side-game auto-config (same logic as before).

  Future<void> _createCasualOrStandardRound() async {
    final client  = context.read<AuthProvider>().client;
    final dateStr = DateFormat('yyyy-MM-dd').format(_date);
    final games   = _activeGames.toList();

    // 1. Resolve or create tournament
    int? tournamentId;
    if (_createNewTournament) {
      final t = await client.createTournament(
        name       : _nameCtrl.text.trim(),
        startDate  : dateStr,
        activeGames: _tournamentActiveGames.toList(),
        totalRounds: _numRounds,
        // Individual-play scoring is set ONCE here; every round and every
        // board reads it back rather than each carrying its own copy.
        scoringMethod: _soloFormat == 'stableford' ? 'stableford' : 'stroke',
        handicapMode : _handicapMode == 'gross' ? 'gross' : 'net',
        netPercent   : _netPercent,
        roundsToCount: _roundsToCount,
        miniSinglesCarvePct:
            _activeGames.contains(GameIds.matchPlay) ? _miniCarvePct : 0,
      );
      tournamentId = t.id;
    } else {
      tournamentId = _existingTournament?.id;
    }

    // 1b. Auto-apply Stroke Play Championship config if entered in Step 4.
    if (tournamentId != null &&
        _tournamentActiveGames.contains(GameIds.championshipStrokePlay) &&
        (_lowNetEntryFee > 0 || _lowNetPayouts.any((p) => p > 0))) {
      final payoutList = <Map<String, dynamic>>[];
      for (int i = 0; i < _lowNetNumPayouts; i++) {
        if (_lowNetPayouts[i] > 0) {
          payoutList.add({'place': i + 1, 'amount': _lowNetPayouts[i].toDouble()});
        }
      }
      await client.postTournamentLowNetSetup(
        tournamentId,
        LowNetChampionshipSetup(
          handicapMode: _handicapMode,
          netPercent  : _netPercent,
          entryFee    : _lowNetEntryFee.toDouble(),
          payouts     : payoutList,
        ),
      );
    }

    // 1c. Stableford Championship config — reuses the same buy-in state. Posts
    // the stakes + tournament handicap with the standard points table; the TD
    // can customise the table later via "Configure Stableford".
    if (tournamentId != null &&
        _tournamentActiveGames.contains(GameIds.championshipStableford) &&
        (_lowNetEntryFee > 0 || _lowNetPayouts.any((p) => p > 0))) {
      final payoutList = <Map<String, dynamic>>[];
      for (int i = 0; i < _lowNetNumPayouts; i++) {
        if (_lowNetPayouts[i] > 0) {
          payoutList.add({'place': i + 1, 'amount': _lowNetPayouts[i].toDouble()});
        }
      }
      await client.postTournamentStablefordSetup(
        tournamentId,
        handicapMode: _handicapMode == 'gross' ? 'gross' : 'net',
        netPercent  : _netPercent,
        entryFee    : _lowNetEntryFee.toDouble(),
        payouts     : payoutList,
        // The table the TD set on the points step — never a hardcoded
        // standard scale. A club's Sunday game and its member-guest use
        // different ones.
        pointsTable : {
          'albatross': _stablefordPoints[0],
          'eagle'    : _stablefordPoints[1],
          'birdie'   : _stablefordPoints[2],
          'par'      : _stablefordPoints[3],
          'bogey'    : _stablefordPoints[4],
          'double'   : _stablefordPoints[5],
        },
      );
    }
    if (!mounted) return;

    // 1d. Mini Singles Bracket — optional, at the TD's discretion. Nothing
    // downstream may assume it: no carve-out is taken and no day-2 foursome
    // is reserved unless this posts.
    if (tournamentId != null && _activeGames.contains(GameIds.matchPlay)) {
      await client.postMiniSinglesSetup(
        tournamentId,
        // Day-1 entry and payouts are set per group on the bracket screen;
        // this posts the tournament-level half so the carve-out and the
        // empty-seat rule exist from the moment the bracket is switched on.
        day1EntryFee : 0,
        day1Payouts  : const [],
        day2Payouts  : const [],
        emptySeatRule: _miniEmptySeatRule,
        carvePct     : _miniCarvePct,
      );
    }
    if (!mounted) return;

    // 2. Create stub rounds for rounds 2..N
    if (_createNewTournament) {
      for (int i = 0; i < _additionalRounds.length; i++) {
        final draft     = _additionalRounds[i];
        final draftDate = DateFormat('yyyy-MM-dd').format(draft.date);
        await client.createRound(
          tournamentId: tournamentId,
          courseId    : draft.courseId ?? _selectedCourseId!, // inherit event course
          date        : draftDate,
          activeGames : games,
          roundNumber : i + 2,
          handicapMode: _handicapMode,
          netPercent  : _netPercent,
          netMaxDoubleBogey: _netMaxDoubleBogey,
        );
      }
    }

    // 3. Create Round 1 with foursomes
    final existing = _existingTournament?.rounds.length ?? 0;
    final round = await client.createRound(
      tournamentId: tournamentId,
      courseId    : _selectedCourseId!,
      date        : dateStr,
      activeGames : games,
      roundNumber : _createNewTournament ? 1 : existing + 1,
      handicapMode: _handicapMode,
      netPercent  : _netPercent,
      netMaxDoubleBogey: _netMaxDoubleBogey,
    );

    // Compute per-player group_number when the TD overrode the
    // auto-balance.  The backend's setup endpoint takes the explicit-
    // groups path when ANY player carries a `group_number`, slicing
    // exactly per the sizes we send.  Without an override, omit the
    // field and let the backend auto-balance (legacy behaviour).
    final List<int>? overrideSizes = _groupSizesOverride;
    final playersList = <Map<String, int>>[];
    var groupIdx        = 0;
    var placedInGroup   = 0;

    // Foursome Play needs no assignment of its own — the Groups & Tees step
    // already put every golfer in a group, and the group IS the team. This
    // just reads that back so the group numbers reach the backend even when
    // the TD accepted the auto-balance.
    final Map<int, int> teamPlayGroupOf = {};
    if (_isTeamPlay) {
      final rosters = _tpRosters;
      for (var i = 0; i < rosters.length; i++) {
        for (final id in rosters[i]) {
          teamPlayGroupOf[id] = i + 1;
        }
      }
    }

    for (final id in _orderedPlayerIds) {
      final tee = _playerTees[id];
      if (tee == null) throw Exception('Player $id has no tee selected.');
      final entry = <String, int>{'player_id': id, 'tee_id': tee.id};
      if (teamPlayGroupOf.containsKey(id)) {
        entry['group_number'] = teamPlayGroupOf[id]!;
      } else if (overrideSizes != null) {
        // Advance to the next group when the current one is full.
        while (groupIdx < overrideSizes.length &&
               placedInGroup >= overrideSizes[groupIdx]) {
          groupIdx += 1;
          placedInGroup = 0;
        }
        entry['group_number'] = groupIdx + 1;
        placedInGroup += 1;
      }
      playersList.add(entry);
    }

    final fullRound = await client.setupRound(
      round.id,
      players       : playersList,
      randomise     : false,
      autoSetupGames: true,
    );
    if (!mounted) return;

    // Team Play — the config, then the names. It posts AFTER setup because
    // sync_teams needs the foursomes to exist: it provisions the phantom for
    // any team that came out at three and works every team's allowance.
    if (_isTeamPlay && tournamentId != null) {
      await client.postTeamPlaySetup(
        tournamentId,
        teamSize      : _tpTeamSize,
        teamFormat    : _tpFormat,
        ballCountMode : _tpBallMode,
        ballCountFixed: _tpBallFixed,
        ballCounts    : {
          for (final e in _tpPerHoleCounts.entries) '${e.key}': e.value,
        },
        driveRule     : _tpDriveRule,
        drivesRequired: _tpDrivesReq,
        drivePenalty  : _tpDrivePenalty,
        handicapMode  : _tpHandicapMode,
        allowanceOverridePct  : _tpOverridePct,
        clearAllowanceOverride: _tpOverridePct == null,
        entryFee      : _tpEntryFee.toDouble(),
        placesPaid    : _tpPlacesPaid,
        splitPcts     : _tpSplit.take(_tpPlacesPaid).toList(),
      );
      // No names posted here. Teams arrive as Group 1…Group N and name
      // themselves from the round hub — the TD inventing six names for golfers
      // who have not turned up yet is work nobody asked for.
    }
    if (!mounted) return;

    // Auto-apply match play config entered in Step 4.
    bool matchPlayAutoConfigured = false;
    if (_tournamentActiveGames.contains(GameIds.singlesNassau)) {
      const labels = ['1st', '2nd', '3rd', '4th'];
      final payoutConfig = <String, double>{};
      for (int i = 0; i < _matchPlayNumPayouts; i++) {
        if (_matchPlayPayouts[i] > 0) {
          payoutConfig[labels[i]] = _matchPlayPayouts[i].toDouble();
        }
      }
      if (_matchPlayEntryFee > 0 || payoutConfig.isNotEmpty) {
        for (final fs in fullRound.foursomes) {
          await client.postMatchPlaySetup(
            fs.id,
            entryFee:     _matchPlayEntryFee.toDouble(),
            payoutConfig: payoutConfig,
          );
        }
        matchPlayAutoConfigured = true;
      }
    }
    if (!mounted) return;

    // The day bet lives on the FINAL round, so it can only be posted once the
    // rounds exist. Fee and places are the TD's; the pool and the paid places
    // resize themselves at play time as eligibility resolves.
    if (_numRounds > 1 &&
        _activeGames.contains('day_bet') &&
        _dayBetEntryFee > 0 &&
        tournamentId != null) {
      try {
        final t = await client.getTournament(tournamentId);
        final rounds = [...t.rounds]
          ..sort((a, b) => a.roundNumber.compareTo(b.roundNumber));
        if (rounds.isNotEmpty) {
          await client.postDayBetSetup(
            rounds.last.id,
            entryFee: _dayBetEntryFee.toDouble(),
            payouts : _payoutList(_dayBetNumPayouts, _dayBetPayouts),
          );
        }
      } catch (_) {
        // A day bet that could not be priced is not worth failing the whole
        // tournament for — the TD can set it from the round's own screen, and
        // the post-create checklist will say it is not set.
      }
    }
    if (!mounted) return;

    final needsConfig =
        _activeGames.contains(GameIds.irishRumble) ||
        _activeGames.contains(GameIds.strokePlay)  ||
        _activeGames.contains(GameIds.pinkBall)    ||
        // Match Play needs per-foursome bracket setup (or Three-Person
        // Match setup for 3-player groups) before scoring can start.
        _activeGames.contains(GameIds.matchPlay)   ||
        (_tournamentActiveGames.contains(GameIds.singlesNassau) && !matchPlayAutoConfigured);
    if (needsConfig) {
      setState(() {
        _createdRound             = fullRound;
        _createdTournamentId      = tournamentId;
        _step                     = _totalSteps;   // past the flow → post-creation
        _creating                 = false;
        _matchPlayStep6Configured = matchPlayAutoConfigured;
      });
    } else {
      Navigator.of(context).pop(true);
    }
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _back(); },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          // "New Tournament", not "New Round". A round is a thing INSIDE the
          // tournament, created for each date — and this flow creates both.
          // The old header said Round while step 2 named an event with two of
          // them and the last step read "Create Round".
          title: Text(_isPostCreate
              ? 'Tournament Created'
              : (_isCupTournament
                  ? 'New Cup Tournament  (${_step + 1} of $_totalSteps)'
                  : 'New Tournament  (${_step + 1} of $_totalSteps)')),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              // Cap at 1.0 on the post-creation step so bar stays full
              value: (_isPostCreate ? _totalSteps : _step + 1) / _totalSteps,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: _dataLoading
              ? const Center(child: CircularProgressIndicator())
              : _dataError != null
                  ? ErrorView(message: _dataError!, onRetry: _loadReferenceData)
                  : _stepBody(),
        ),
        bottomNavigationBar: _dataLoading || _dataError != null
            ? null
            : _BottomBar(
                step            : _step,
                totalSteps      : _totalSteps,
                canAdvance      : _canAdvance(),
                creating        : _creating,
                isCupTournament : _isCupTournament,
                onBack          : _back,
                onNext          : _next,
                onCreate        : _createRound,
                onDone          : () => Navigator.of(context).pop(true),
              ),
      ),
    );
  }

  Widget _stepBody() {
    // Post-creation confirmation is terminal — shown once the round exists, at
    // an index past the flow.  Not a member of _stepFlow.
    if (_isPostCreate) {
      return _Step6GameSetup(
        round               : _createdRound!,
        tournamentId        : _createdTournamentId,
        tournamentName      : _createNewTournament
            ? _nameCtrl.text.trim()
            : (_existingTournament?.name ?? ''),
        activeGames         : _activeGames,
        isCupTournament     : _tournamentActiveGames.contains(GameIds.teamCup),
        matchPlayConfigured : _matchPlayStep6Configured,
      );
    }

    switch (_currentStep) {
      case _StepKind.typeFormat:
        return _Step1TypeFormat(
          eventType  : _eventType,
          cupFormat  : _cupFormat,
          soloFormat : _soloFormat,
          plan       : _remainingStepPlan(),
          onPickType : (t) => setState(() {
            _eventType = t;
            _applyTypeFormat();
          }),
          onPickCupFormat : (f) => setState(() {
            _cupFormat = f;
            if (!_handicapModeTouched) {
              _handicapMode = _defaultHandicapForFormat();
            }
          }),
          onPickSoloFormat: (f) => setState(() {
            _soloFormat = f;
            _applyTypeFormat();
          }),
        );
      case _StepKind.cupDesign:
        _resizeCupTeamColours(_cupTeamCount);
        return _StepTeams(
          teamCount   : _cupTeamCount,
          teamColours : _cupTeamColours,
          nameCtrls   : _teamNameCtrls,
          badgeCtrls  : _teamBadgeCtrls,
          badgeOwned  : _teamBadgeOwned,
          deriveBadge : _deriveBadge,
          onTeamCountChanged: (n) => setState(() {
            _cupTeamCount = n;
            _resizeCupTeamColours(n);
          }),
          onTeamColourChanged: (idx, colour) => setState(() {
            if (idx >= 0 && idx < _cupTeamColours.length) {
              _cupTeamColours[idx] = colour;
            }
          }),
        );
      case _StepKind.cupGamePlan:
        if (_cupFormat == 'mixed') {
          return _MixedGamesByRound(
            numRounds        : _numRounds,
            roundCounts      : _roundCupCounts,
            roundPoints      : _roundCupPoints,
            sideSize         : _cupSideSize,
            selectedCourseId : _selectedCourseId,
            additionalRounds : _additionalRounds,
            courses          : _courses,
            date             : _date,
            onCount          : (r, game, count) => setState(() {
              final m = _roundCupCounts.putIfAbsent(r, () => {});
              if (count <= 0) { m.remove(game); } else { m[game] = count; }
              // active_games = the games with a count this round
              _roundCupGames[r] = m.keys.toList();
              _roundCupPoints.putIfAbsent(r, () => {}).putIfAbsent(game, () => 1.0);
            }),
            onPrice          : (r, game, pts) => setState(() =>
                _roundCupPoints.putIfAbsent(r, () => {})[game] = pts),
            onSideSize       : (n) => setState(() => _cupSideSize = n.clamp(2, 64)),
          );
        }
        return _Step3CupRoundGames(
          numRounds           : _numRounds,
          roundCupGames       : _roundCupGames,
          roundCupPoints      : _roundCupPoints,
          selectedCourseId    : _selectedCourseId,
          additionalRounds    : _additionalRounds,
          courses             : _courses,
          date                : _date,
          onChanged           : (roundIdx, games) =>
              setState(() {
                _roundCupGames[roundIdx] = games;
                // Triple Cup foursomes spend 6 holes in alt-shot — the
                // individual-net scoring that drives championship Low
                // Net doesn't apply on those holes.  Auto-drop the
                // Low Net championship whenever any round uses Triple
                // Cup so we don't surface a half-meaningful aggregate.
                final anyTC = _roundCupGames.values
                    .any((g) => g.contains('triple_cup'));
                if (anyTC) {
                  _tournamentActiveGames.remove(GameIds.championshipStrokePlay);
                }
              }),
          onPointsChanged     : (roundIdx, points) =>
              setState(() => _roundCupPoints[roundIdx] = points),
        );
      case _StepKind.teamFormat:
        return TeamFormatStep(
          teamSize      : _tpTeamSize,
          format        : _tpFormat,
          ballCountMode : _tpBallMode,
          ballCountFixed: _tpBallFixed,
          perHoleCounts : _tpPerHoleCounts,
          parByHole     : _tpParByHole(),
          // The pair's OWN figure on every option, before it is chosen. The
          // same two golfers get 4 in a scramble and 12 in an alternate shot,
          // so a TD picking Chapman because it sounds fun should see what it
          // does to their field.
          samplePair    : _tpSamplePair,
          // Nothing is locked before the round exists — the lock is stamped by
          // the first score, which cannot have happened in the wizard.
          locked        : false,
          onFormat : (f) => setState(() {
            _tpFormat = f;
            _applyTpFormatRules();
          }),
          onMode   : (m) => setState(() => _tpBallMode = m),
          onFixed  : (n) => setState(() => _tpBallFixed = n),
          onPerHole: (hole, count) =>
              setState(() => _tpPerHoleCounts[hole] = count),
        );
      case _StepKind.teamDrives:
        return TeamDriveStep(
          teamSize      : _tpTeamSize,
          format        : _tpFormat,
          rulesAllowed  : _tpDriveRulesAllowed,
          rule          : _tpDriveRule,
          drivesRequired: _tpDrivesReq,
          penalty       : _tpDrivePenalty,
          hasShortTeam  : _tpHasShortTeam,
          onRule           : (r) => setState(() {
            _tpDriveRule = r;
            // A window can only be asked for as many drives as it has holes to
            // give, shared between the golfers — two each per nine for a foursome,
            // four for a pair. Carrying a per-eighteen figure across to per
            // nine would otherwise ask for more drives than the window holds.
            final cap = _tpMaxDrivesPerGolfer;
            if (_tpDrivesReq > cap) _tpDrivesReq = cap;
          }),
          onDrivesRequired: (n) => setState(() => _tpDrivesReq = n),
          onPenalty       : (p) => setState(() => _tpDrivePenalty = p),
        );
      case _StepKind.teamHandicap:
        return TeamHandicapStep(
          teamSize     : _tpTeamSize,
          format       : _tpFormat,
          handicapMode : _tpHandicapMode,
          overridePct  : _tpOverridePct,
          avgBallCount : _tpAvgBallCount,
          teeName      : _tpTeeName,
          // Blocking, not advice: a golfer with no partner is a broken
          // tournament, and the button says which golfer it is waiting on.
          problems     : _tpPairsProblems,
          threeBallAvailable: _tpFormat == 'best_ball',
          teams        : [
            for (var i = 0; i < _tpTeams.length; i++)
              TeamHandicapPreview(
                name   : _tpTeamLabel(i),
                members: [
                  for (final id in _tpTeams[i])
                    if (_tpGolfer(id) != null) _tpGolfer(id)!,
                ],
              ),
          ],
          onHandicapMode: (m) => setState(() => _tpHandicapMode = m),
          onOverridePct : (p) => setState(() => _tpOverridePct = p),
        );
      case _StepKind.teamPayout:
        return TeamPayoutStep(
          entryFee    : _tpEntryFee,
          placesPaid  : _tpPlacesPaid,
          splitPcts   : _tpSplit,
          golfers     : _orderedPlayerIds.length,
          teamCount   : _tpTeams.length,
          hasShortTeam: _tpHasShortTeam,
          onFee   : (v) => setState(() => _tpEntryFee = v),
          onPlaces: (n) => setState(() {
            _tpPlacesPaid = n;
            // Resize the split to the new place count, keeping what was set.
            final next = List<int>.filled(n, 0);
            for (var i = 0; i < n && i < _tpSplit.length; i++) {
              next[i] = _tpSplit[i];
            }
            _tpSplit = next;
          }),
          onSplit : (s) => setState(() => _tpSplit = s),
        );
      case _StepKind.sideGame:
        return _StepSideGame(
          value: _tournamentSideGame,
          onChanged: (v) => setState(() => _tournamentSideGame = v),
        );
      case _StepKind.eventDetails:
        return _StepEventDetails(
          createNew          : _createNewTournament,
          tournaments        : _tournaments,
          existingTournament : _existingTournament,
          nameCtrl           : _nameCtrl,
          formKey            : _step0Key,
          courses            : _courses,
          selectedCourseId   : _selectedCourseId,
          date               : _date,
          additionalRounds   : _additionalRounds,
          typeSummary        : _typeSummary(),
          remainingSteps     : _stepFlow.length - 2, // minus type + this step
          onToggleNew        : (v) => setState(() {
            _createNewTournament = v;
            _existingTournament  = null;
          }),
          onPickTournament : (t) => setState(() => _existingTournament = t),
          onPickCourse     : (course) => _selectWizardCourse(course),
          onPickDate       : (d) => setState(() => _date = d),
          onPickAdditionalCourse: (idx, course) =>
              _selectWizardCourse(course, additionalIndex: idx),
          onPickAdditionalDate: (idx, d) => setState(() {
            _additionalRounds[idx].date = d;
          }),
          onAddRound   : _addRound,
          onRemoveRound: _removeRound,
        );
      case _StepKind.handicap:
        return _StepHandicap(
          handicapMode      : _handicapMode,
          netPercent        : _netPercent,
          netMaxDoubleBogey : _netMaxDoubleBogey,
          onChangeHandicap  : (mode, pct) => setState(() {
            _handicapMode = mode;
            _netPercent   = pct;
            _handicapModeTouched = true; // stop the format default overriding
          }),
          onChangeNetMaxDoubleBogey: (v) =>
              setState(() => _netMaxDoubleBogey = v),
          isStablefordChampionship:
              _tournamentActiveGames.contains(GameIds.championshipStableford),
          isMatchPlay: _isCupTournament,
        );
      case _StepKind.players:
        return _Step2Players(
          players    : _allPlayers,
          selectedIds: _selectedIds,
          search     : _search,
          onToggle   : (id) => setState(() {
            _selectedIds.contains(id)
                ? _selectedIds.remove(id)
                : _selectedIds.add(id);
            // Player count changed — any TD-set group override is now
            // stale; drop it so Step 3 reverts to the fresh auto-balance.
            _groupSizesOverride = null;
          }),
          onSearch   : (s) => setState(() => _search = s),
          onSelectAll: () => setState(() {
            _selectedIds.addAll(_allPlayers.map((p) => p.id));
            _groupSizesOverride = null;
          }),
          onClearAll : () => setState(() {
            _selectedIds.clear();
            _groupSizesOverride = null;
          }),
          onAddByPhone: _addHalvedGolfer,
          onAddGolfer:  _addGolfer,
        );
      case _StepKind.groups:
        return _Step3GroupsAndTees(
          // A pairs field is twos: a trailing one has to be representable (a
          // 13-golfer field is otherwise unsaveable), and a three is only
          // legal in best ball, which is the one format that can count a third
          // ball.
          // A pairs field groups in fours — two pairs to a tee time — with a
          // twosome when the pair count is odd and a ONE when the field is.
          minGroupSize: _isTeamPlay && _tpTeamSize == 2 ? 1 : 2,
          maxGroupSize: 4,
          groupNoun   : 'Group',
          orderedPlayers: _orderedPlayers,
          playerTees    : _playerTees,
          courseTees    : _courseTees,
          groupSizes    : _effectiveGroupSizes,
          onReorder     : (oldIdx, newIdx) => setState(() {
            if (newIdx > oldIdx) newIdx--;
            final id = _orderedPlayerIds.removeAt(oldIdx);
            _orderedPlayerIds.insert(newIdx, id);
          }),
          onPickTee     : (playerId, tee) =>
              setState(() => _playerTees[playerId] = tee),
          onChangeGroupSizes: (sizes) => setState(() {
            // null = revert to auto-balance.
            _groupSizesOverride = sizes;
          }),
        );
      case _StepKind.scoring:
        return _StepScoring(
          soloFormat   : _soloFormat,
          handicapMode : _handicapMode,
          netPercent   : _netPercent,
          numRounds    : _numRounds,
          roundsToCount: _roundsToCount,
          // One tap back to step 1, which owns the method.
          onChangeMethod: () => setState(() {
            final i = _stepFlow.indexOf(_StepKind.typeFormat);
            if (i >= 0) _step = i;
          }),
          onChangeHandicap: (mode, pct) => setState(() {
            _handicapMode = mode;
            _netPercent   = pct;
            _handicapModeTouched = true;
          }),
          onChangeRoundsToCount: (n) => setState(() => _roundsToCount = n),
        );
      case _StepKind.stablefordPoints:
        return _StepStablefordPoints(
          tournamentName: _createNewTournament
              ? _nameCtrl.text.trim()
              : (_existingTournament?.name ?? ''),
          numRounds : _numRounds,
          presets   : _kStablefordPresets,
          preset    : _stablefordPreset,
          points    : _stablefordPoints,
          onPickPreset: (name) => setState(() {
            _stablefordPreset = name;
            final table = _kStablefordPresets[name];
            if (table != null) _stablefordPoints = List<int>.from(table);
          }),
          onEditPoint: (i, v) => setState(() {
            final next = List<int>.from(_stablefordPoints);
            next[i] = v;
            _stablefordPoints = next;
            // Editing any value flips the chip to Custom, so the state is
            // always readable rather than three chips with none marked.
            _stablefordPreset = _kStablefordPresets.entries
                .any((e) => _listEq(e.value, next))
                ? _kStablefordPresets.entries
                    .firstWhere((e) => _listEq(e.value, next)).key
                : 'Custom';
          }),
        );
      case _StepKind.payouts:
        return _StepPayouts(
          isStableford: _tournamentActiveGames
              .contains(GameIds.championshipStableford),
          numPlayers  : _selectedIds.length,
          entryFee    : _lowNetEntryFee,
          numPayouts  : _lowNetNumPayouts,
          payouts     : _lowNetPayouts,
          carvePct    : _miniCarvePct,
          miniSinglesOn: _activeGames.contains(GameIds.matchPlay),
          onChanged   : (fee, nPays, pays) => setState(() {
            _lowNetEntryFee   = fee;
            _lowNetNumPayouts = nPays;
            _lowNetPayouts    = pays;
          }),
        );
      // Individual play only — the cup flow prices its games on the
      // per-round plan and never reaches this step.
      case _StepKind.games:
        return _StepSideGames(
          activeGames: _activeGames,
          numPlayers : _selectedIds.length,
          numRounds  : _numRounds,
          // The day bet disqualifies whoever takes championship money, so its
          // eligible field depends on how many places the championship pays.
          championshipPlaces: _lowNetPayouts
              .take(_lowNetNumPayouts)
              .where((a) => a > 0)
              .length,
          onToggle   : (g, on) => setState(() {
            on ? _activeGames.add(g) : _activeGames.remove(g);
          }),
          miniCarvePct     : _miniCarvePct,
          miniEmptySeatRule: _miniEmptySeatRule,
          onMiniCarvePct     : (v) => setState(() => _miniCarvePct = v),
          onMiniEmptySeatRule: (v) =>
              setState(() => _miniEmptySeatRule = v),
          dayBetFee       : _dayBetEntryFee,
          dayBetNumPayouts: _dayBetNumPayouts,
          dayBetPayouts   : _dayBetPayouts,
          onDayBetFee     : (v) => setState(() => _dayBetEntryFee = v),
          onDayBetPayouts : (n, p) => setState(() {
            _dayBetNumPayouts = n;
            _dayBetPayouts    = p;
          }),
        );

      case _StepKind.review:
        if (_isCupTournament) {
          return _StepCupReview(
            cupName       : _nameCtrl.text.trim(),
            handicapMode  : _handicapMode,
            netPercent    : _netPercent,
            teams         : _cupReviewTeams(),
            rounds        : _cupReviewRounds(),
            createError   : _createError,
          );
        }
        return _Step5Review(
          // Null unless this is a Team Play event — the review's fill-to-four
          // rule is right for every other shape.
          teamPlaySize         : _isTeamPlay ? _tpTeamSize : null,
          createNew            : _createNewTournament,
          tournamentName       : _createNewTournament
              ? _nameCtrl.text.trim()
              : (_existingTournament?.name ?? '—'),
          numRounds            : _numRounds,
          tournamentActiveGames: _tournamentActiveGames.toList(),
          course               : _selectedCourse,
          date                 : _date,
          activeGames          : _activeGames.toList(),
          additionalRounds     : _additionalRounds,
          courses              : _courses,
          orderedPlayers       : _orderedPlayers,
          playerTees           : _playerTees,
          groupSizes           : _effectiveGroupSizes,
          // Each game names its own price at review — entry was taken at
          // signup, so by this point every game already has one.
          // Only the day bet has a price by now — the rest are set on their
          // own screens straight after Create, so review says so rather than
          // showing a misleading "No entry".
          sideGameFees         : {'day_bet': _dayBetEntryFee},
          championshipFee      : _lowNetEntryFee,
          carvePct             : _activeGames.contains(GameIds.matchPlay)
              ? _miniCarvePct : 0,
          createError          : _createError,
        );
    }
  }

  /// Team summaries for the cup review: name, badge and colour per team.
  List<({String name, String badge, String colour})> _cupReviewTeams() => [
        for (int i = 0; i < _cupTeamCount; i++)
          (
            name  : _effectiveTeamName(i),
            badge : _effectiveTeamBadge(i),
            colour: i < _cupTeamColours.length ? _cupTeamColours[i] : 'Red',
          ),
      ];

  /// Round summaries for the cup review: label, course, date and cup game(s).
  List<({String label, String course, DateTime date, String game})>
      _cupReviewRounds() {
    final courseMap = {for (final c in _courses) c.id: c};
    final labels = {
      // Mixed-cup titles as a base so a mixed-only game (Chapman, scramble…)
      // never shows as a raw slug; the catalog then overrides shared ids.
      for (final g in _kMixedGames) g.$1: g.$2,
      for (final g in kGameCatalog) g.id: g.displayName,
      for (final (v, l) in kChampionshipGames) v: l,
    };
    String gameFor(int roundIdx) {
      final games = (_roundCupGames[roundIdx] ?? [])
          .where((g) => g != _tournamentSideGame)
          .map((g) => labels[g] ?? g)
          .toList();
      return games.isEmpty ? 'Not set' : games.join(' · ');
    }
    return [
      (
        label : 'R1',
        course: _selectedCourse?.name ?? 'Not set',
        date  : _date,
        game  : gameFor(0),
      ),
      for (int i = 0; i < _additionalRounds.length; i++)
        (
          label : 'R${i + 2}',
          course: courseMap[_additionalRounds[i].courseId ?? _selectedCourseId]
                      ?.name ??
                  'Not set',
          date  : _additionalRounds[i].date,
          game  : gameFor(i + 1),
        ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Bottom nav bar
// ---------------------------------------------------------------------------

class _BottomBar extends StatelessWidget {
  final int step;
  final int totalSteps;
  final bool canAdvance;
  final bool creating;
  final bool isCupTournament;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onCreate;
  final VoidCallback onDone;

  const _BottomBar({
    required this.step,
    required this.totalSteps,
    required this.canAdvance,
    required this.creating,
    required this.isCupTournament,
    required this.onBack,
    required this.onNext,
    required this.onCreate,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    // Post-creation step — show Done only
    if (step >= totalSteps) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            const Spacer(),
            FilledButton.icon(
              onPressed: onDone,
              icon: const Icon(Icons.check),
              label: const Text('Done'),
            ),
          ]),
        ),
      );
    }

    final isLast = step == totalSteps - 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          OutlinedButton(onPressed: onBack, child: const Text('Back')),
          const Spacer(),
          if (isLast)
            FilledButton.icon(
              onPressed: (canAdvance && !creating) ? onCreate : null,
              icon: creating
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Colors.white))
                  : Icon(isCupTournament ? Icons.arrow_forward : Icons.flag),
              label: Text(isCupTournament
                  ? 'Save & draft teams'
                  : 'Create Tournament'),
            )
          else
            FilledButton(
              onPressed: canAdvance ? onNext : null,
              child: const Text('Next'),
            ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Step 0 — Tournament
// ===========================================================================

/// Wizard step layout: a pinned title/subtitle header that never scrolls up
/// under the app bar / progress bar (matters on short screens like the iPhone
/// 13 mini) above a scrollable body. For steps whose body is a simple Column.
Widget _pinnedStep(
  BuildContext context, {
  required String title,
  String? subtitle,
  GlobalKey<FormState>? formKey,
  required List<Widget> children,
}) {
  final theme = Theme.of(context);
  Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: children);
  if (formKey != null) body = Form(key: formKey, child: body);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.headlineSmall),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.grey)),
            ],
          ],
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: body,
        ),
      ),
    ],
  );
}

// ===========================================================================
// Step — Type & format ("What kind of event?")
// ===========================================================================

class _Step1TypeFormat extends StatelessWidget {
  final _EventType eventType;
  final String     cupFormat;
  final String     soloFormat;
  final List<({String label, String sub, bool perRound})> plan;
  final ValueChanged<_EventType> onPickType;
  final ValueChanged<String>     onPickCupFormat;
  final ValueChanged<String>     onPickSoloFormat;

  const _Step1TypeFormat({
    required this.eventType,
    required this.cupFormat,
    required this.soloFormat,
    required this.plan,
    required this.onPickType,
    required this.onPickCupFormat,
    required this.onPickSoloFormat,
  });

  // (value, title, subtitle, exclusive)
  // Mixed cup is the default — a day of several games, each foursome plays one.
  // Triple Cup is the exclusive preset that spends all 18 holes on its own four
  // segments, so it can't run alongside anything (Singles / Fourball are no
  // longer tournament-wide formats — they're games in a Mixed cup's day).
  static const _cupFormats = <(String, String, String, bool)>[
    ('mixed', 'Mixed cup',
        '1 to several games a day — Irish Rumble, Nassau pairs, Chapman, Singles. '
        'Each foursome plays one, with points set per match.', false),
    ('triple', 'Triple Cup',
        'A preset day: Fourball, Foursomes and two Singles per group — four points a group.', true),
  ];
  static const _soloFormats = <(String, String, String, bool)>[
    ('stroke', 'Stroke play', 'Gross or net against the field.', false),
    ('stableford', 'Stableford', 'Points per hole against par.', false),
  ];

  static const _cardBorder = Color(0xFFD3DED6);
  static const _deepPine   = Color(0xFF0B1F1A);
  static const _brightMint = Color(0xFF3BD89A);
  static const _unitBg     = Color(0xFFE4F2EA);
  static const _warnBg     = Color(0xFFFDF3E7);
  static const _warnFg     = Color(0xFF8A5216);

  bool get _isTriple => eventType == _EventType.cup && cupFormat == 'triple';

  @override
  Widget build(BuildContext context) {
    return _pinnedStep(
      context,
      title: 'What kind of event?',
      subtitle:
          'This decides the rest of the setup, so it is the first thing we ask.',
      children: [
        _sectionLabel(context, 'Who is competing'),
        _typeCard(context, _EventType.cup, 'Team — cup play',
            'Two to four drafted sides playing match segments for points.', 'Side'),
        _typeCard(context, _EventType.solo, 'Individual',
            'Every golfer for themselves, against the field.', 'Golfer'),
        _typeCard(context, _EventType.pair, 'Pairs Play',
            'Two-golfer teams against the field. Scramble, best ball, alternate '
            'shot, Scotch or Chapman.', 'Pair'),
        _typeCard(context, _EventType.quad, 'Foursome Play',
            'Small teams of four, all against each other on one leaderboard.',
            'Team'),
        const SizedBox(height: 20),
        _sectionLabel(context, _formatLabel()),
        ..._formatCards(context),
        const SizedBox(height: 16),
        _consequenceStrip(context),
        const SizedBox(height: 18),
        _planPanel(context),
      ],
    );
  }

  String _formatLabel() {
    switch (eventType) {
      case _EventType.cup:  return 'Cup format';
      case _EventType.solo: return 'Scoring';
      case _EventType.pair: return 'How the pair scores';
      case _EventType.quad: return 'How a team scores';
    }
  }

  List<Widget> _formatCards(BuildContext context) {
    if (eventType == _EventType.cup) {
      return _cupFormats
          .map((f) => _formatCard(
              context, f.$1, f.$2, f.$3, f.$4, cupFormat, onPickCupFormat))
          .toList();
    }
    if (eventType == _EventType.solo) {
      return _soloFormats
          .map((f) => _formatCard(
              context, f.$1, f.$2, f.$3, f.$4, soloFormat, onPickSoloFormat))
          .toList();
    }
    if (eventType == _EventType.quad || eventType == _EventType.pair) {
      // Team play asks the format two steps on, not here. The formats need
      // different entry screens and different handicap maths, so the question
      // comes after the tees — a percentage of course handicap needs a tee to
      // be a percentage OF.
      final what = eventType == _EventType.pair
          ? 'Scramble, best ball, alternate shot, Scotch or Chapman'
          : 'Scramble or shamble';
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '$what — asked after the course and tees, because the allowance '
            'is a percentage of course handicap.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Coming soon.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    ];
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              fontSize: 11)),
    );
  }

  Widget _radio(BuildContext context, bool selected) {
    final pine = Theme.of(context).colorScheme.primary;
    return Container(
      width: 18,
      height: 18,
      margin: const EdgeInsets.only(top: 1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
            color: selected ? pine : const Color(0xFFC3CFC6), width: 2),
      ),
      child: selected
          ? Center(
              child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: pine)))
          : null,
    );
  }

  Widget _pill(BuildContext context, String text, {bool muted = false}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: muted ? theme.colorScheme.surfaceContainerHighest : _unitBg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              color: muted ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              fontSize: 9.5)),
    );
  }

  Widget _typeCard(BuildContext context, _EventType t, String title, String sub,
      String unit, {bool enabled = true}) {
    final theme = Theme.of(context);
    final pine = theme.colorScheme.primary;
    final selected = enabled && eventType == t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: InkWell(
          onTap: enabled ? () => onPickType(t) : null,
          borderRadius: BorderRadius.circular(13),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected ? pine.withOpacity(0.06) : Colors.white,
              border: Border.all(
                  color: selected ? pine : _cardBorder, width: 1.5),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _radio(context, selected),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(sub,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ])),
              const SizedBox(width: 8),
              _pill(context, enabled ? unit : 'Soon', muted: !enabled),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _formatCard(BuildContext context, String value, String title,
      String sub, bool exclusive, String current, ValueChanged<String> onPick) {
    final theme = Theme.of(context);
    final pine = theme.colorScheme.primary;
    final selected = current == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => onPick(value),
        borderRadius: BorderRadius.circular(13),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? pine.withOpacity(0.06) : Colors.white,
            border:
                Border.all(color: selected ? pine : _cardBorder, width: 1.5),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _radio(context, selected),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ])),
            if (exclusive) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                    color: _warnBg, borderRadius: BorderRadius.circular(5)),
                child: const Text('EXCLUSIVE',
                    style: TextStyle(
                        color: _warnFg,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        fontSize: 9.5)),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _consequenceStrip(BuildContext context) {
    final theme = Theme.of(context);
    final isCup = eventType == _EventType.cup;
    // A Mixed cup can't say up front how scores come in — it depends on the game
    // each foursome plays, decided at round setup.
    final scoresIn = _isTriple
        ? 'Per golfer in Fourball, per pair in Foursomes'
        : isCup
            ? 'Depends on the game each foursome plays — set at round setup'
            : 'Per golfer';
    final lb = switch (eventType) {
      _EventType.cup  => 'Side against side',
      _EventType.solo => 'Field, gross or net',
      _EventType.pair => 'Pairs against the field',
      _EventType.quad => 'Groups against the field',
    };
    final bets = _isTriple
        ? 'Available — the Fourball segment has individual gross'
        : isCup
            ? 'Only in games that keep individual gross — Nassau pairs and '
              'Singles, not Irish Rumble, scramble or Chapman'
            : 'Available — individual gross is on the card';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _cardBorder),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(children: [
        _stripRow(context, 'Scores in', scoresIn),
        _stripRow(context, 'Leaderboard', lb),
        // Which games the TD gets to set. Naming them here is what stops the
        // side-game step being a surprise, and it is where "Mini Singles
        // Bracket" is first said — the name every later surface reads back.
        if (eventType == _EventType.solo)
          _stripRow(context, 'Side games',
              'Pink Ball · Irish Rumble · Mini Singles Bracket'),
        _stripRow(context, 'Group bets', bets, valueColor: theme.colorScheme.primary),
      ]),
    );
  }

  Widget _stripRow(BuildContext context, String label, String value,
      {Color? valueColor}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 92,
            child: Text(label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    fontSize: 10))),
        const SizedBox(width: 8),
        Expanded(
            child: Text(value,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600, color: valueColor))),
      ]),
    );
  }

  Widget _planPanel(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 15),
      decoration: BoxDecoration(
          color: _deepPine, borderRadius: BorderRadius.circular(15)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text("WHAT'S LEFT AFTER THIS STEP",
              style: TextStyle(
                  color: Color(0xFF7FA694),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  fontSize: 10.5)),
          const Spacer(),
          Text('${plan.length} steps',
              style: const TextStyle(
                  color: _brightMint, fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
        const SizedBox(height: 11),
        for (int i = 0; i < plan.length; i++) _planRow(context, i + 1, plan[i]),
        const SizedBox(height: 11),
        const Text(
            'Rounds are set on the next screen; the steps marked “per round” '
            'repeat with them.',
            style: TextStyle(
                color: Color(0xFF9EBCAD), fontSize: 11, height: 1.4)),
      ]),
    );
  }

  Widget _planRow(
      BuildContext context, int n, ({String label, String sub, bool perRound}) s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6)),
            child: Text('$n',
                style: const TextStyle(
                    color: Color(0xFFDDEBE2),
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5))),
        const SizedBox(width: 9),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.label,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          const SizedBox(height: 1),
          Text(s.sub,
              style: const TextStyle(
                  color: Color(0xFF9EBCAD), fontSize: 11.5, height: 1.35)),
        ])),
        if (s.perRound) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
                color: _brightMint, borderRadius: BorderRadius.circular(4)),
            child: const Text('PER ROUND',
                style: TextStyle(
                    color: Color(0xFF08301F),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    fontSize: 9)),
          ),
        ],
      ]),
    );
  }
}

class _StepEventDetails extends StatelessWidget {
  final bool                 createNew;
  final List<Tournament>     tournaments;
  final Tournament?          existingTournament;
  final TextEditingController nameCtrl;
  final GlobalKey<FormState> formKey;
  final List<CourseInfo>     courses;
  final int?                 selectedCourseId;
  final DateTime             date;
  final List<_RoundDraft>    additionalRounds;
  final String               typeSummary;
  final int                  remainingSteps;
  final ValueChanged<bool>        onToggleNew;
  final ValueChanged<Tournament?> onPickTournament;
  final ValueChanged<CourseInfo>  onPickCourse;
  final ValueChanged<DateTime>    onPickDate;
  final void Function(int idx, CourseInfo course) onPickAdditionalCourse;
  final void Function(int idx, DateTime date)     onPickAdditionalDate;
  final VoidCallback         onAddRound;
  final void Function(int idx) onRemoveRound;

  const _StepEventDetails({
    required this.createNew,
    required this.tournaments,
    required this.existingTournament,
    required this.nameCtrl,
    required this.formKey,
    required this.courses,
    required this.selectedCourseId,
    required this.date,
    required this.additionalRounds,
    required this.typeSummary,
    required this.remainingSteps,
    required this.onToggleNew,
    required this.onPickTournament,
    required this.onPickCourse,
    required this.onPickDate,
    required this.onPickAdditionalCourse,
    required this.onPickAdditionalDate,
    required this.onAddRound,
    required this.onRemoveRound,
  });

  int get _numRounds => additionalRounds.length + 1;

  static const _cardBorder = Color(0xFFD3DED6);
  static const _deepPine   = Color(0xFF0B1F1A);

  String _courseName(int? id) =>
      courses.where((c) => c.id == id).firstOrNull?.name ?? '';

  /// A round's resolved course: its own if overridden, else the event course.
  String _resolvedCourse(int? roundCourseId) {
    final name = _courseName(roundCourseId ?? selectedCourseId);
    return name.isEmpty ? 'Not set' : name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _pinnedStep(
      context,
      title: 'Event details',
      subtitle: '$typeSummary. Name the event and set its rounds.',
      formKey: formKey,
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: true,  label: Text('New'),      icon: Icon(Icons.add)),
            ButtonSegment(value: false, label: Text('Existing'), icon: Icon(Icons.list)),
          ],
          selected: {createNew},
          onSelectionChanged: (s) => onToggleNew(s.first),
        ),
        const SizedBox(height: 20),

        if (createNew) ...[
          GolfTextField(
            controller: nameCtrl,
            label: 'Name',
            prefixIcon: Icons.emoji_events,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Name the event' : null,
          ),
          const SizedBox(height: 8),

          _label(context, 'Course'),
          const SizedBox(height: 6),
          CourseSearchField(
            selected: courses.where((c) => c.id == selectedCourseId).firstOrNull,
            onSelected: onPickCourse,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Inherited by every round below — a round that moves can set its own.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 18),

          _label(context, 'Rounds  ·  $_numRounds'),
          const SizedBox(height: 8),
          // Round 1 — the event itself; course is the event course above.
          _roundCard(
            context,
            number: 1,
            date: date,
            courseLabel: _resolvedCourse(null),
            onPickDate: onPickDate,
            courseField: null,
          ),
          // Rounds 2..N — each with a date and an optional course override.
          for (int i = 0; i < additionalRounds.length; i++)
            _roundCard(
              context,
              number: i + 2,
              date: additionalRounds[i].date,
              courseLabel: _resolvedCourse(additionalRounds[i].courseId),
              onPickDate: (d) => onPickAdditionalDate(i, d),
              onRemove: () => onRemoveRound(i),
              courseField: CourseSearchField(
                selected: courses
                    .where((c) =>
                        c.id == (additionalRounds[i].courseId ?? selectedCourseId))
                    .firstOrNull,
                onSelected: (c) => onPickAdditionalCourse(i, c),
              ),
            ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: _numRounds >= 6 ? null : onAddRound,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a round'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              side: BorderSide(
                  color: _numRounds >= 6 ? _cardBorder : theme.colorScheme.primary),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13)),
            ),
          ),
          const SizedBox(height: 18),
          _derivedPanel(context),
        ] else ...[
          if (tournaments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No existing tournaments. Create a new one instead.',
                  style: TextStyle(color: Colors.grey)),
            )
          else ...[
            DropdownButtonFormField<Tournament>(
              value: existingTournament,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Select tournament',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.emoji_events),
              ),
              items: tournaments.map((t) => DropdownMenuItem(
                value: t, child: Text(t.name),
              )).toList(),
              onChanged: onPickTournament,
              validator: (v) => v == null ? 'Select a tournament' : null,
            ),
            const SizedBox(height: 16),
            _label(context, 'Course'),
            const SizedBox(height: 6),
            CourseSearchField(
              selected:
                  courses.where((c) => c.id == selectedCourseId).firstOrNull,
              onSelected: onPickCourse,
            ),
            const SizedBox(height: 16),
            _dateButton(context, date, onPickDate, full: true),
          ],
        ],
      ],
    );
  }

  Widget _label(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            fontSize: 11));
  }

  Widget _dateButton(BuildContext context, DateTime d, ValueChanged<DateTime> onPicked,
      {bool full = false}) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: d,
          firstDate: DateTime(2020),
          lastDate: DateTime(2030),
        );
        if (picked != null) onPicked(picked);
      },
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F8F4),
          border: Border.all(color: const Color(0xFFE2EAE3)),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('DATE',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  fontSize: 9.5)),
          const SizedBox(height: 2),
          Text(DateFormat(full ? 'MMMM d, yyyy' : 'EEE MMM d').format(d),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _roundCard(BuildContext context,
      {required int number,
      required DateTime date,
      required String courseLabel,
      required ValueChanged<DateTime> onPickDate,
      VoidCallback? onRemove,
      Widget? courseField}) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: const Color(0xFFE4F2EA),
                borderRadius: BorderRadius.circular(7)),
            child: Text('$number',
                style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5)),
          ),
          const SizedBox(width: 9),
          Text('Round $number',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (onRemove != null)
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 18, color: Color(0xFF93A29A)),
              ),
            ),
        ]),
        const SizedBox(height: 9),
        _dateButton(context, date, onPickDate),
        const SizedBox(height: 8),
        if (courseField != null)
          courseField
        else
          Text('Course · $courseLabel',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _derivedPanel(BuildContext context) {
    final n = _numRounds;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 104,
                child: Text(label,
                    style: const TextStyle(
                        color: Color(0xFF9EBCAD), fontSize: 11.5))),
            Expanded(
                child: Text(value,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5))),
          ]),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 14),
      decoration: BoxDecoration(
          color: _deepPine, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('WHAT THIS SETS UP',
            style: TextStyle(
                color: Color(0xFF7FA694),
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                fontSize: 10.5)),
        const SizedBox(height: 8),
        row('Rounds', '$n'),
        row('Format setups', n == 1 ? '1 — one per round' : '$n — one per round'),
        row('Group builds', n == 1 ? '1 — one per round' : '$n — one per round'),
        row('Steps left', '$remainingSteps'),
      ]),
    );
  }
}

// ===========================================================================
// Step — Handicap (mode + net double-bogey cap)
// ===========================================================================

class _StepHandicap extends StatelessWidget {
  final String            handicapMode;
  final int               netPercent;
  final bool              netMaxDoubleBogey;
  final void Function(String mode, int pct) onChangeHandicap;
  final ValueChanged<bool> onChangeNetMaxDoubleBogey;
  /// Stableford uses its own points table (and its 'double+' bucket is the
  /// floor) — so Strokes-Off and the net double-bogey cap don't apply.
  final bool isStablefordChampionship;
  /// Cup formats are match play (a hole is won, lost or halved), so the net
  /// double-bogey cap has no stroke total to protect — it is struck with its
  /// reason rather than offered as a live toggle.
  final bool isMatchPlay;

  const _StepHandicap({
    required this.handicapMode,
    required this.netPercent,
    required this.netMaxDoubleBogey,
    required this.onChangeHandicap,
    required this.onChangeNetMaxDoubleBogey,
    this.isStablefordChampionship = false,
    this.isMatchPlay = false,
  });

  @override
  Widget build(BuildContext context) {
    return _pinnedStep(
      context,
      title: 'Handicap',
      subtitle: isMatchPlay
          ? 'How strokes are given across the cup. Applies to every round.'
          : 'How strokes are given. Applies to every round.',
      children: [
        HandicapModeSelector(
          mode:             handicapMode,
          netPercent:       netPercent,
          allowStrokesOff:  !isStablefordChampionship,
          onModeChanged:    (m) => onChangeHandicap(m, netPercent),
          onPercentChanged: (p) => onChangeHandicap(handicapMode, p),
          soNote: 'The lowest-handicap player in each foursome plays '
              'to 0.  Other players get strokes proportional to '
              '(their HCP − foursome low HCP), scaled by Net %.',
        ),
        if (isMatchPlay) ...[
          const SizedBox(height: 16),
          _struckCapCard(context),
        ] else if (!isStablefordChampionship) ...[
          const SizedBox(height: 16),
          // Net double-bogey cap — round-level rule, applied to every round in
          // this tournament at creation time. Stableford's points table already
          // floors scores, so it's hidden there.
          NetDoubleBogeyCard(
            handicapMode: handicapMode, netPercent: netPercent,
            value: netMaxDoubleBogey,
            onChanged: onChangeNetMaxDoubleBogey,
          ),
        ],
      ],
    );
  }

  /// The struck net double-bogey cap — shown, not hidden, so a control that
  /// vanished doesn't read as a missing feature.
  Widget _struckCapCard(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 13, 13, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(
            color: const Color(0xFFC9D8CD),
            width: 1.5,
            style: BorderStyle.solid),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text('Net double-bogey cap',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(5)),
            child: Text('NOT SHOWN',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: muted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    fontSize: 9.5)),
          ),
        ]),
        const SizedBox(height: 7),
        Text(
          'The cap protects a stroke total from one disaster hole. In match '
          'play a hole is won, lost or halved, so a nine costs one hole and no '
          'more — there is nothing for the cap to do. It appears for stroke '
          'play and Stableford.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.45),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Scoring — individual play
// ===========================================================================

/// One step for both methods, set ONCE for the tournament: every round and
/// every board reads from it.
///
/// Three things separate this from the Cup's Handicap step:
///
///  * **The max is a rule, not a setting.** The shipped build had a Net
///    Double-Bogey Cap toggle, default on — one setting wearing a format's
///    clothes, and the field cannot tell from a leaderboard which way it was
///    set. It is always on, stated with a worked ceiling so a golfer who
///    picks up knows exactly what lands on their card.
///  * **No strokes off.** SO Low is a Cup mechanism: it exists so a match
///    plays off the low golfer, and against a field there is no low golfer to
///    play off. It must not render on this type.
///  * **Rounds that count**, asked only above two rounds.
class _StepScoring extends StatelessWidget {
  final String  soloFormat;          // stroke | stableford
  final String  handicapMode;        // net | gross
  final int     netPercent;
  final int     numRounds;
  final int?    roundsToCount;
  /// Jump back to the step that OWNS the method, rather than duplicating its
  /// control here.
  final VoidCallback onChangeMethod;
  final void Function(String mode, int pct) onChangeHandicap;
  final ValueChanged<int?>   onChangeRoundsToCount;

  const _StepScoring({
    required this.soloFormat,
    required this.handicapMode,
    required this.netPercent,
    required this.numRounds,
    required this.roundsToCount,
    required this.onChangeMethod,
    required this.onChangeHandicap,
    required this.onChangeRoundsToCount,
  });

  bool get _isStableford => soloFormat == 'stableford';

  @override
  Widget build(BuildContext context) {
    return _pinnedStep(
      context,
      title: 'How is it scored?',
      subtitle: 'Set once for the tournament. Every round and every board '
          'reads from this.',
      children: [
        _methodRecap(context),
        const SizedBox(height: 16),
        if (_isStableford) _stablefordNote(context) else _capRule(context),
        const SizedBox(height: 16),
        _handicapBlock(context),
        // Only asked above two rounds — a one or two-round event counts
        // everything and there is no interesting answer to give.
        if (numRounds > 2) ...[
          const SizedBox(height: 16),
          _roundsThatCount(context),
        ],
        const SizedBox(height: 16),
        _flightsDeferred(context),
      ],
    );
  }

  // ── Method — a read-back, not a second question ───────────────────────
  /// The method was already picked on step 1, where it decides the step list.
  /// Asking again here with a live radio group reads as being asked twice, so
  /// this states the answer and offers one tap back to the step that owns it.
  Widget _methodRecap(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Method',
      trailing: TextButton(
        onPressed: onChangeMethod,
        child: const Text('Change'),
      ),
      child: Row(children: [
        Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _isStableford
                ? 'Stableford — points per hole against par.'
                : 'Stroke play — gross and net against the field.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }

  // ── The cap, stated as a rule with a worked ceiling ───────────────────
  Widget _capRule(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SectionCard(
      title: 'Net double bogey max',
      trailing: Chip(
        label: const Text('Always on', style: TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Every hole is capped at par + 2 + the strokes you get there. '
          'Nobody wrecks a net total on one hole, and nobody has to remember '
          'to pick up.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.45),
        ),
        const SizedBox(height: 10),
        for (final (situation, ceiling) in const [
          ('Par 4 · gets 1 stroke', 'net double is 7'),
          ('Par 3 · no stroke',     'net double is 5'),
          ('Par 5 · gets 2 strokes','net double is 9'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(situation,
                  style: theme.textTheme.bodySmall)),
              Text(ceiling,
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary)),
            ]),
          ),
        const SizedBox(height: 8),
        Text(
          'It protects a net total, not a hole result — group bets and skins '
          'still read the real gross. The gross board ignores the cap; the net '
          'board applies it.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.45),
        ),
      ]),
    );
  }

  Widget _stablefordNote(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SectionCard(
      title: 'Points, high to low',
      child: Text(
        'Points are figured off net score per hole, so the handicap answer '
        'below still applies. A hole that scores nothing needs no ceiling — '
        'the net double bogey max is not used under Stableford. The max keeps '
        'a blow-up hole at a ceiling; Stableford stops scoring it at all.',
        style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.45),
      ),
    );
  }

  // ── Handicap — net or gross, and an allowance ─────────────────────────
  Widget _handicapBlock(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Handicap',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HandicapModeSelector(
          mode:            handicapMode,
          netPercent:      netPercent,
          // Strokes off the low index needs a single opponent to anchor to.
          // Against a field there is no low golfer, so it is not offered — it
          // survives on the Mini Singles Bracket alone.
          allowStrokesOff: false,
          onModeChanged:   (m) => onChangeHandicap(m, netPercent),
          onPercentChanged:(p) => onChangeHandicap(handicapMode, p),
        ),
        const SizedBox(height: 8),
        Text(
          'Applies to the whole field. Strokes off the low index is Cup-only '
          'and is not offered here.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }

  // ── Rounds that count ─────────────────────────────────────────────────
  Widget _roundsThatCount(BuildContext context) {
    final theme = Theme.of(context);
    final options = <int?>[null, for (int n = numRounds - 1; n >= 2; n--) n];
    return SectionCard(
      title: 'Rounds that count',
      trailing: Text(
        roundsToCount == null
            ? 'All $numRounds'
            : 'Best $roundsToCount of $numRounds',
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary,
                       fontWeight: FontWeight.w700),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, children: [
          for (final n in options)
            ChoiceChip(
              selected: roundsToCount == n,
              onSelected: (_) => onChangeRoundsToCount(n),
              label: Text(n == null ? 'All $numRounds' : 'Best $n'),
            ),
        ]),
        const SizedBox(height: 10),
        Text(
          "A golfer's worst round is dropped, so somebody who sits one out on "
          'a 36-hole day stays in the championship. The dropped round is '
          'struck through on the board, not hidden, and it moves as scores '
          'land. A round still in progress never displaces a finished one.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, height: 1.45),
        ),
      ]),
    );
  }

  // ── Flights — drawn, not hidden ───────────────────────────────────────
  /// Nothing is disabled without saying why. Flights are a real intention and
  /// a real absence, so the row states both rather than vanishing.
  Widget _flightsDeferred(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SectionCard(
      title: 'Flights',
      trailing: Chip(
        label: const Text('NOT YET', style: TextStyle(fontSize: 9.5)),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
      child: Text(
        'One board for everyone. Splitting the field into flights would give '
        'each its own board and its own payout — it changes what the '
        'leaderboard IS, so it is not something to switch on halfway. Not '
        'built yet, and nothing else on this step depends on it.',
        style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.45),
      ),
    );
  }
}

// ===========================================================================
// Payouts — the championship pot, on its own
// ===========================================================================

/// Split out of the combined games+money step. Money was being collected in
/// two places, one round late: the championship fee here and side games ticked
/// here but priced afterwards, on a checklist that only appeared once the round
/// existed. Entry is a flat fee per game taken at signup, so each fee now sits
/// beside the game that charges it — and this step is left with one pot.
///
/// Splitting it also fixes the clipped section header: the fee fields are never
/// on screen without the pot they belong to.
class _StepPayouts extends StatefulWidget {
  final bool      isStableford;
  final int       numPlayers;
  final int       entryFee;
  final int       numPayouts;
  final List<int> payouts;
  /// Carve-out currently set for Mini Singles day 2. Zero when the bracket is
  /// off — nothing here may assume it exists.
  final int       carvePct;
  final bool      miniSinglesOn;
  final void Function(int fee, int numPayouts, List<int> payouts) onChanged;

  const _StepPayouts({
    required this.isStableford,
    required this.numPlayers,
    required this.entryFee,
    required this.numPayouts,
    required this.payouts,
    required this.carvePct,
    required this.miniSinglesOn,
    required this.onChanged,
  });

  @override
  State<_StepPayouts> createState() => _StepPayoutsState();
}

class _StepPayoutsState extends State<_StepPayouts> {
  late final TextEditingController _feeCtrl;
  late int _numPayouts;
  late final List<TextEditingController> _payoutCtrls;

  @override
  void initState() {
    super.initState();
    _feeCtrl = TextEditingController(
        text: widget.entryFee == 0 ? '' : '${widget.entryFee}');
    _numPayouts = widget.numPayouts;
    _payoutCtrls = List.generate(4, (i) {
      final v = i < widget.payouts.length ? widget.payouts[i] : 0;
      return TextEditingController(text: v == 0 ? '' : '$v');
    });
    _feeCtrl.addListener(_notify);
    for (final c in _payoutCtrls) { c.addListener(_notify); }
  }

  @override
  void dispose() {
    _feeCtrl.dispose();
    for (final c in _payoutCtrls) { c.dispose(); }
    super.dispose();
  }

  int get _fee  => int.tryParse(_feeCtrl.text.trim()) ?? 0;
  int get _pool => _fee * widget.numPlayers;

  /// What the championship places actually share. The Mini Singles day-2 pot
  /// is a percentage off the TOP of this pool rather than a separate entry, so
  /// the places have to balance against what is LEFT.
  int get _carved => widget.miniSinglesOn
      ? (_pool * widget.carvePct / 100).round()
      : 0;
  int get _available => _pool - _carved;

  void _notify() {
    widget.onChanged(_fee, _numPayouts,
        _payoutCtrls.map((c) => int.tryParse(c.text.trim()) ?? 0).toList());
  }

  void _suggest() {
    if (_available <= 0) return;
    final suggested = suggestPayouts(_available, _numPayouts);
    for (int i = 0; i < 4; i++) {
      _payoutCtrls[i].text = suggested[i] == 0 ? '' : '${suggested[i]}';
    }
    setState(() {});
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = widget.isStableford
        ? 'Stableford Championship'
        : 'Championship';

    return _pinnedStep(
      context,
      title: 'Payouts',
      subtitle: 'The 36-hole money. Side games are priced on the next step.',
      children: [
        SectionCard(
          title: label,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GolfTextField(
              controller: _feeCtrl,
              label: 'Entry per golfer (\$)',
              hint: '0',
              prefixText: '\$ ',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: false),
            ),
            const SizedBox(height: 8),
            // The pool line names its SCOPE and its COUNT. Two money cards in
            // a row look identical otherwise, and a captain should not have to
            // count players to know which pot they are filling.
            Text(
              pooLine(_fee, widget.numPlayers, field: true),
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            if (widget.miniSinglesOn && widget.carvePct > 0) ...[
              const SizedBox(height: 10),
              _carveOutLines(context),
            ],
          ]),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Paid places',
          child: PayoutConfigField(
            pool       : _available,
            numPayouts : _numPayouts,
            payoutCtrls: _payoutCtrls,
            onNumPayoutsChanged: (n) {
              setState(() => _numPayouts = n);
              _notify();
            },
            onPayoutChanged: () => setState(_notify),
            onSuggest      : _suggest,
          ),
        ),
        if (!widget.miniSinglesOn) ...[
          const SizedBox(height: 12),
          Text(
            'If you switch on the Mini Singles Bracket on the next step, its '
            'day-2 pot comes off the top of this pool and these places '
            'rebalance against what is left.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),
        ],
      ],
    );
  }

  Widget _carveOutLines(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      for (final (label, amount, strong) in [
        ('${widget.carvePct}% to the champions\' foursome', _carved, false),
        ('Left for the championship places', _available, true),
      ])
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
            Text('\$$amount',
                style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                    color: strong ? theme.colorScheme.primary : null)),
          ]),
        ),
    ]);
  }
}

/// ``$10 × 8 in the field = $80`` vs ``$10 × 4 in this foursome = $40``.
///
/// The trap these screens set is two identical money cards over completely
/// different pots, so the scope and the count belong in the sentence.
String pooLine(int fee, int count, {required bool field}) =>
    '\$$fee × $count ${field ? "in the field" : "in this foursome"} '
    '= \$${fee * count}';

// ===========================================================================
// Side games — the four the TD sets, each with its entry fee
// ===========================================================================

/// **These are the tournament-scope games, and the only ones the TD sets.**
/// Foursome side bets — skins, Nassau, rabbit, survivor, sixes — belong to the
/// foursome, are set up exactly as in a casual round, and read the
/// tournament's score entry rather than opening their own. They never appear
/// here and never appear in settlement.
///
/// Entry is a flat fee per game taken at signup, so the fee sits beside the
/// chip that turns the game on. Then post-creation has nothing left to
/// collect, the field's entries are known before round one, and no golfer is
/// asked for money after they have teed off.
class _StepSideGames extends StatelessWidget {
  final Set<String> activeGames;
  final int         numPlayers;
  final int         numRounds;
  /// Championship places paid — the golfers the day bet will disqualify.
  final int         championshipPlaces;
  final void Function(String game, bool on) onToggle;

  // Mini Singles — the two settings no game screen can know: how much of the
  // CHAMPIONSHIP pool funds day 2, and what happens to an unfillable seat.
  // Its day-1 entry and payouts belong to the bracket's own setup screen.
  final int       miniCarvePct;
  final String    miniEmptySeatRule;
  final ValueChanged<int>    onMiniCarvePct;
  final ValueChanged<String> onMiniEmptySeatRule;

  // The day bet is the ONE game with no setup screen of its own, so its money
  // is set here or nowhere.
  final int               dayBetFee;
  final int               dayBetNumPayouts;
  final List<int>         dayBetPayouts;
  final ValueChanged<int> onDayBetFee;
  final void Function(int numPayouts, List<int> payouts) onDayBetPayouts;

  const _StepSideGames({
    required this.activeGames,
    required this.numPlayers,
    required this.numRounds,
    required this.championshipPlaces,
    required this.onToggle,
    required this.miniCarvePct,
    required this.miniEmptySeatRule,
    required this.onMiniCarvePct,
    required this.onMiniEmptySeatRule,
    required this.dayBetFee,
    required this.dayBetNumPayouts,
    required this.dayBetPayouts,
    required this.onDayBetFee,
    required this.onDayBetPayouts,
  });

  /// How many golfers actually fund the day bet.
  ///
  /// Two groups are out, for two different reasons, and NEITHER pays in:
  /// the Mini Singles day-2 finalists (playing a match, not posting a card —
  /// an absence rather than an exclusion) and the championship money winners
  /// (disqualified by winning). Sixteen − four − two = ten.
  ///
  /// An estimate, because eligibility is not knowable until the championship
  /// closes; the board recomputes it from the real standings.
  int get dayBetEligible {
    var n = numPlayers;
    if (activeGames.contains(GameIds.matchPlay)) n -= 4;
    n -= championshipPlaces;
    return n < 0 ? 0 : n;
  }

  String get dayBetPoolNote {
    final parts = <String>[];
    if (activeGames.contains(GameIds.matchPlay)) {
      parts.add('4 Mini Singles finalists');
    }
    if (championshipPlaces > 0) {
      parts.add('$championshipPlaces championship money '
          '${championshipPlaces == 1 ? "winner" : "winners"}');
    }
    if (parts.isEmpty) return '';
    return 'Estimated: $numPlayers less ${parts.join(" and ")}. None of them '
        'pay in, and the pot firms up when the championship closes.';
  }

  /// 9–16 golfers, three or four groups. Four is the ceiling: eight or fewer
  /// gives a final with no semis (not a bracket), and above sixteen there are
  /// five group winners, who cannot play a knockout in one round.
  ({bool fits, int groups, String reason}) get _bracketField {
    if (numPlayers < 9) {
      return (fits: false, groups: 0,
          reason: 'Mini Singles needs at least 9 golfers. Eight or fewer '
              'gives a final with no semis, which is not a bracket.');
    }
    if (numPlayers > 16) {
      return (fits: false, groups: 0,
          reason: 'Mini Singles tops out at 16. Above that you get five group '
              'winners, and five cannot play a knockout in one round — it '
              'needs a third day.');
    }
    return (fits: true, groups: numPlayers >= 13 ? 4 : 3, reason: '');
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final field  = _bracketField;

    return _pinnedStep(
      context,
      title: 'Side games',
      subtitle: 'The games you set for the whole field. Entry is taken at '
          'signup, so each one is priced here.',
      children: [
        // Irish Rumble and Pink Ball each own a setup screen that asks for
        // their rules AND their money — and the payout table there needs the
        // pool, so the entry has to live beside it. Asking again here just
        // collected a number and threw it away.
        _GameToggleCard(
          on      : activeGames.contains(GameIds.irishRumble),
          title   : 'Irish Rumble',
          blurb   : "Every group's best nets are added up and ranked against "
                    'the whole field. Re-drawn every round.',
          moneyNote: 'Entry and payouts are set on the Irish Rumble screen, '
                     'right after you create the tournament.',
          onToggle: (v) => onToggle(GameIds.irishRumble, v),
        ),
        const SizedBox(height: 12),
        _GameToggleCard(
          on      : activeGames.contains(GameIds.pinkBall),
          title   : 'Pink Ball',
          blurb   : 'One ball per group, no replacements — the last group '
                    'still holding it wins.',
          moneyNote: 'Entry, payouts and what you call it are set on the '
                     'Pink Ball screen — Red Ball, Devil Ball, whatever the '
                     'group calls it.',
          onToggle: (v) => onToggle(GameIds.pinkBall, v),
        ),
        const SizedBox(height: 12),

        // ── Mini Singles ────────────────────────────────────────────────
        _GameToggleCard(
          on      : activeGames.contains(GameIds.matchPlay),
          title   : 'Mini Singles Bracket',
          blurb   : numRounds > 1
              ? 'A bracket in every group on day 1. The winners meet on day 2 '
                'as one foursome for the title; everyone else plays a normal '
                'stroke-play round.'
              : 'A bracket in every group. Needs a second day for the '
                'champions to meet, so on a one-round event it runs day 1 '
                'only.',
          moneyNote: "Day 1's entry and payouts are set per group on the "
                     'bracket screen. The two things below are the '
                     "tournament's to decide.",
          disabledReason: field.fits ? null : field.reason,
          onToggle: (v) => onToggle(GameIds.matchPlay, v),
          extra   : activeGames.contains(GameIds.matchPlay) && field.fits
              ? _miniExtras(context, field.groups)
              : null,
        ),

        // ── Day bet ─────────────────────────────────────────────────────
        // Multi-day only. On a one-round event it is absent, and the footnote
        // says so rather than showing a struck row for something that will
        // never apply to this tournament.
        const SizedBox(height: 12),
        if (numRounds > 1)
          _GameFeeCard(
            on      : activeGames.contains('day_bet'),
            title   : 'Day bet · final round',
            blurb   : "The last day's 18-hole stroke play side bet — it pays a "
                      'great single round from somebody out of contention.',
            fee     : dayBetFee,
            // The whole field does NOT play this. The Mini Singles finalists
            // are playing a match rather than posting a card, and the
            // championship money winners are disqualified by winning — and
            // neither group pays in. Pricing it at the full field overstates
            // the pot by a third.
            numPlayers: dayBetEligible,
            payee   : 'golfers',
            poolNote: dayBetPoolNote,
            onToggle: (v) => onToggle('day_bet', v),
            onFee   : onDayBetFee,
            extra   : activeGames.contains('day_bet')
                ? _DayBetPayouts(
                    pool      : dayBetFee * dayBetEligible,
                    numPayouts: dayBetNumPayouts,
                    payouts   : dayBetPayouts,
                    onChanged : onDayBetPayouts,
                  )
                : null,
          )
        else
          Text(
            'The day bet appears on events with more than one round — it pays '
            'a great single round from somebody already out of the 36-hole '
            'money, so a one-round event has nothing for it to sit beside.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),

        const SizedBox(height: 20),
        _foursomeScopeNote(context),
      ],
    );
  }

  Widget _miniExtras(BuildContext context, int groups) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 12),
      Text('$numPlayers golfers, $groups groups — fits.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),

      // Day 2 is funded by a carve-out, not an entry.
      Text('Day 2 — the championship carve-out',
          style: theme.textTheme.labelMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        'A percentage off the top of the championship pool. There is no day-2 '
        "entry, which is why 4th has nothing to refund — they are still in the "
        'main tournament, and losing a semi on Sunday costs them nothing they '
        'was otherwise going to win.',
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant, height: 1.45),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Text('Carve-out', style: theme.textTheme.bodyMedium),
        const Spacer(),
        IconButton(
          onPressed: miniCarvePct <= 0
              ? null
              : () => onMiniCarvePct(miniCarvePct - 5),
          icon: const Icon(Icons.remove_circle_outline),
          visualDensity: VisualDensity.compact,
        ),
        Text('$miniCarvePct%',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        IconButton(
          onPressed: miniCarvePct >= 50
              ? null
              : () => onMiniCarvePct(miniCarvePct + 5),
          icon: const Icon(Icons.add_circle_outline),
          visualDensity: VisualDensity.compact,
        ),
      ]),

      const SizedBox(height: 8),
      // One rule for a short field AND a withdrawal, answered once here rather
      // than being asked on Sunday morning.
      Text('If a seat cannot be filled',
          style: theme.textTheme.labelMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(
        'Three groups, or a winner who withdraws — same problem, same answer, '
        'settled now.',
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant),
      ),
      for (final (value, label, blurb) in const [
        ('promote', 'Promote the best runner-up',
         'The lowest net of the beaten finalists fills the fourth seat — and '
         'still has to win two matches to take it.'),
        ('points', 'Points, then a match',
         'All three play points over the front; the two leaders play the back '
         'nine as a match.'),
        ('short', 'Play it short-handed',
         'Nobody is promoted. No byes — a seat nobody earned is not handed out '
         'as a free pass to the final.'),
      ])
        RadioListTile<String>(
          value: value,
          groupValue: miniEmptySeatRule,
          onChanged: (v) { if (v != null) onMiniEmptySeatRule(v); },
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label, style: theme.textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.w600)),
          subtitle: Text(blurb, style: theme.textTheme.bodySmall),
        ),

      const SizedBox(height: 4),
      Text(
        'Handicap: strokes off low. A match has two players and a low golfer to '
        'anchor to — the reverse of the field games, which inherit full net. '
        'Change it on the Mini Singles setup screen.',
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant, height: 1.45),
      ),
    ]);
  }

  Widget _foursomeScopeNote(BuildContext context) {
    return InlineMessage(
      kind: InlineMessageKind.info,
      text: 'Skins, Nassau, rabbit, survivor and sixes are the foursome\'s to '
          'set, exactly as in a casual round. They read this tournament\'s '
          'score entry, and they settle inside the group — you never collect '
          'for them.',
    );
  }
}

/// A side game that owns its own setup screen: a switch, what the game is, and
/// where its money gets set.
///
/// The money is NOT here. Each of these games has a setup screen that asks for
/// its payout table, and a payout table needs the pool — so the entry has to
/// sit beside it or the two drift apart. Asking on both screens collected the
/// number twice and used one of them.
class _GameToggleCard extends StatelessWidget {
  final bool   on;
  final String title;
  final String blurb;
  final String moneyNote;
  final String? disabledReason;
  final Widget? extra;
  final ValueChanged<bool> onToggle;

  const _GameToggleCard({
    required this.on,
    required this.title,
    required this.blurb,
    required this.moneyNote,
    required this.onToggle,
    this.disabledReason,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final muted   = theme.colorScheme.onSurfaceVariant;
    final blocked = disabledReason != null;

    return SectionCard(
      title: title,
      trailing: Switch(
        value: on && !blocked,
        // Nothing is disabled without saying why — the reason prints below
        // rather than being left to a grey control.
        onChanged: blocked ? null : onToggle,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(blurb,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: muted, height: 1.45)),
        if (blocked) ...[
          const SizedBox(height: 8),
          InlineMessage(kind: InlineMessageKind.warn, text: disabledReason!),
        ],
        if (on && !blocked) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.payments_outlined, size: 14, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(moneyNote,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: muted, height: 1.4)),
            ),
          ]),
          if (extra != null) extra!,
        ],
      ]),
    );
  }
}

/// The day bet's payout table, using the same construct as every other pot.
///
/// The pool it balances against is an ESTIMATE — the eligible field is not
/// knowable until the championship closes — so a table that balances here is
/// the TD's intent, and the board resizes the places as eligibility resolves.
class _DayBetPayouts extends StatefulWidget {
  final int       pool;
  final int       numPayouts;
  final List<int> payouts;
  final void Function(int numPayouts, List<int> payouts) onChanged;

  const _DayBetPayouts({
    required this.pool,
    required this.numPayouts,
    required this.payouts,
    required this.onChanged,
  });

  @override
  State<_DayBetPayouts> createState() => _DayBetPayoutsState();
}

class _DayBetPayoutsState extends State<_DayBetPayouts> {
  late int _n;
  late final List<TextEditingController> _ctrls;

  @override
  void initState() {
    super.initState();
    _n = widget.numPayouts;
    _ctrls = List.generate(4, (i) {
      final v = i < widget.payouts.length ? widget.payouts[i] : 0;
      return TextEditingController(text: v == 0 ? '' : '$v');
    });
    for (final c in _ctrls) { c.addListener(_notify); }
  }

  @override
  void dispose() {
    for (final c in _ctrls) { c.dispose(); }
    super.dispose();
  }

  void _notify() => widget.onChanged(
      _n, _ctrls.map((c) => int.tryParse(c.text.trim()) ?? 0).toList());

  void _suggest() {
    if (widget.pool <= 0) return;
    final amts = suggestPayouts(widget.pool, _n);
    for (int i = 0; i < 4; i++) {
      _ctrls[i].text = amts[i] == 0 ? '' : '${amts[i]}';
    }
    setState(() {});
    _notify();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: PayoutConfigField(
          pool       : widget.pool,
          numPayouts : _n,
          payoutCtrls: _ctrls,
          // Ten eligible pays three places; a smaller field drops to two, then
          // one — three places on a small field would pay most of the golfers who
          // entered, which is not what this bet is for.
          maxPayouts : 3,
          onNumPayoutsChanged: (n) { setState(() => _n = n); _notify(); },
          onPayoutChanged    : () => setState(_notify),
          onSuggest          : _suggest,
        ),
      );
}

/// A side game with NO setup screen of its own — the day bet — so its money is
/// set here or nowhere.
///
/// Stateful for one reason: the fee field owns a controller. Rebuilding one in
/// `build` would reset the cursor on every keystroke the parent rebuilds for.
class _GameFeeCard extends StatefulWidget {
  final bool   on;
  final String title;
  final String blurb;
  final int    fee;
  final int    numPlayers;
  final String payee;
  /// Extra sentence under the pool line — used where the count is an
  /// ESTIMATE rather than the whole field.
  final String poolNote;
  final Widget? extra;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int>  onFee;

  const _GameFeeCard({
    required this.on,
    required this.title,
    required this.blurb,
    required this.fee,
    required this.numPlayers,
    required this.payee,
    required this.onToggle,
    required this.onFee,
    this.poolNote = '',
    this.extra,
  });

  @override
  State<_GameFeeCard> createState() => _GameFeeCardState();
}

class _GameFeeCardState extends State<_GameFeeCard> {
  late final TextEditingController _feeCtrl;

  @override
  void initState() {
    super.initState();
    _feeCtrl = TextEditingController(
        text: widget.fee == 0 ? '' : '${widget.fee}');
  }

  @override
  void dispose() {
    _feeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final muted    = theme.colorScheme.onSurfaceVariant;

    return SectionCard(
      title: widget.title,
      trailing: Switch(value: widget.on, onChanged: widget.onToggle),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.blurb,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: muted, height: 1.45)),
        if (widget.on) ...[
          const SizedBox(height: 12),
          GolfTextField(
            controller: _feeCtrl,
            label: 'Entry per golfer (\$)',
            hint: '0',
            prefixText: '\$ ',
            keyboardType:
                const TextInputType.numberWithOptions(decimal: false),
            onChanged: (v) => widget.onFee(int.tryParse(v.trim()) ?? 0),
          ),
          const SizedBox(height: 6),
          Text(
            '${pooLine(widget.fee, widget.numPlayers, field: true)} '
            '· pays ${widget.payee}',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          if (widget.poolNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(widget.poolNote,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: muted, height: 1.4)),
          ],
          if (widget.extra != null) widget.extra!,
        ],
      ]),
    );
  }
}

// ===========================================================================
// Stableford points — the casual question, asked once for the tournament
// ===========================================================================

/// Casual rounds already ask this on their own setup screen, so the tournament
/// asks the SAME question with the same table rather than inventing a second
/// one. Three things change in tournament context:
///
///  * a scope line says what the table governs — this tournament, every round;
///  * how the money settles is NOT asked here (per point makes the pot
///    unknowable until the last card lands, and a tournament advertises
///    1st/2nd/3rd at signup — so paid places, set on Payouts);
///  * the active preset is marked, and editing any value flips it to Custom.
///
/// No floor and no validation of the table: the TD sets the points as they see
/// fit. Negatives, a 10 for an albatross, zero for par are all valid. The
/// screen reports what the table implies and gets out of the way.
class _StepStablefordPoints extends StatelessWidget {
  static const _labels = ['ALB', 'EAG', 'BIR', 'PAR', 'BOG', 'DBL+'];

  final String              tournamentName;
  final int                 numRounds;
  final Map<String, List<int>> presets;
  final String              preset;
  final List<int>           points;
  final ValueChanged<String> onPickPreset;
  final void Function(int index, int value) onEditPoint;

  const _StepStablefordPoints({
    required this.tournamentName,
    required this.numRounds,
    required this.presets,
    required this.preset,
    required this.points,
    required this.onPickPreset,
    required this.onEditPoint,
  });

  bool get _canScoreBelowZero => points.any((p) => p < 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _pinnedStep(
      context,
      title: 'Points table',
      subtitle: 'Points awarded per hole by score vs par. Negatives allowed.',
      children: [
        // The scope chip: casual sets one round, and a multi-round event
        // cannot have two scales.
        Align(
          alignment: Alignment.centerLeft,
          child: Chip(
            avatar: const Icon(Icons.emoji_events_outlined, size: 15),
            label: Text(
              'Applies to ${tournamentName.isEmpty ? "this tournament" : tournamentName}'
              ' — ${numRounds == 1 ? "the round" : "all $numRounds rounds"}',
              style: const TextStyle(fontSize: 11),
            ),
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(height: 14),

        SectionCard(
          title: 'Scale',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final name in presets.keys)
                ChoiceChip(
                  selected: preset == name,
                  onSelected: (_) => onPickPreset(name),
                  label: Text(name),
                ),
              // Live builds showed three chips with none marked. Editing any
              // value lands here, so the state is always readable.
              ChoiceChip(
                selected: preset == 'Custom',
                onSelected: (_) => onPickPreset('Custom'),
                label: const Text('Custom'),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              for (int i = 0; i < 6; i++) ...[
                Expanded(child: _PointsCell(
                  label: _labels[i],
                  value: points[i],
                  onChanged: (v) => onEditPoint(i, v),
                )),
                if (i < 5) const SizedBox(width: 6),
              ],
            ]),
          ]),
        ),

        if (_canScoreBelowZero) ...[
          const SizedBox(height: 14),
          InlineMessage(
            kind: InlineMessageKind.warn,
            text: 'This table can score below zero, so the net double-bogey '
                'max now matters — a hole is capped at par + 2 plus strokes '
                'before its points are read. On a standard table a double or '
                'worse already scores nothing, so the cap changes nothing.',
          ),
        ],

        const SizedBox(height: 14),
        SectionCard(
          title: 'How the money settles',
          child: Text(
            'Paid places, set on the Payouts step. Per point is a casual '
            'game — a tournament prize has to be knowable at signup, and a '
            'per-point price means nobody can state it until the field '
            'finishes.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// One editable bucket in the points table. Steps rather than a keyboard —
/// the values are small and the whole table has to stay on one line.
class _PointsCell extends StatelessWidget {
  final String label;
  final int    value;
  final ValueChanged<int> onChanged;

  const _PointsCell({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      Text(label,
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 9.5)),
      const SizedBox(height: 4),
      Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(children: [
          InkWell(
            onTap: () => onChanged(value + 1),
            child: const SizedBox(
                height: 22, width: double.infinity,
                child: Icon(Icons.keyboard_arrow_up, size: 16)),
          ),
          Text('$value',
              style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          InkWell(
            onTap: () => onChanged(value - 1),
            child: const SizedBox(
                height: 22, width: double.infinity,
                child: Icon(Icons.keyboard_arrow_down, size: 16)),
          ),
        ]),
      ),
    ]);
  }
}

// ===========================================================================
// Step 2 — Player Selection
// ===========================================================================

class _Step2Players extends StatelessWidget {
  final List<PlayerProfile> players;
  final Set<int>            selectedIds;
  final String              search;
  final ValueChanged<int>   onToggle;
  final ValueChanged<String> onSearch;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;
  final VoidCallback onAddByPhone;
  final VoidCallback onAddGolfer;

  const _Step2Players({
    required this.players,
    required this.selectedIds,
    required this.search,
    required this.onToggle,
    required this.onSearch,
    required this.onSelectAll,
    required this.onClearAll,
    required this.onAddByPhone,
    required this.onAddGolfer,
  });

  @override
  Widget build(BuildContext context) {
    final filtered = search.isEmpty
        ? players
        : players
            .where((p) => p.name.toLowerCase().contains(search.toLowerCase()))
            .toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Select Players',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '${selectedIds.length} selected  •  '
            '${groupSizes(selectedIds.length).length} group(s)  •  '
            'Assign tees in the next step',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Colors.grey),
          ),
        ]),
      ),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: GolfTextField(
              hint: 'Search players…',
              prefixIcon: Icons.search,
              // Give the keyboard a working "done" — otherwise it can't be
              // closed from the keyboard and covers the bottom action button.
              textInputAction: TextInputAction.search,
              onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
              onChanged: onSearch,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onSelectAll, child: const Text('All')),
          TextButton(onPressed: onClearAll,  child: const Text('None')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Wrap(children: [
          TextButton.icon(
            onPressed: onAddGolfer,
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
            label: const Text('Add Golfer'),
          ),
          TextButton.icon(
            onPressed: onAddByPhone,
            icon: const Icon(Icons.phone_iphone, size: 18),
            label: const Text('Halved Golfer search'),
          ),
        ]),
      ),
      const SizedBox(height: 4),

      Expanded(
        child: filtered.isEmpty
            ? const Center(child: Text('No players found.'))
            : ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final p   = filtered[i];
                  final sel = selectedIds.contains(p.id);
                  return CheckboxListTile(
                    value    : sel,
                    onChanged: (_) => onToggle(p.id),
                    title    : Text(p.name),
                    subtitle : Text('Index ${p.handicapIndex}'),
                    secondary: CircleAvatar(
                      backgroundColor: sel
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Text(
                        p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          color: sel ? Colors.white : null,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),

      if (selectedIds.length < 2)
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.errorContainer,
          padding: const EdgeInsets.all(8),
          child: Text(
            'Select at least 2 players to continue.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer),
          ),
        ),
    ]);
  }
}

// ===========================================================================
// Step 3 — Group arrangement + per-player tee
// ===========================================================================

class _Step3GroupsAndTees extends StatelessWidget {
  /// Players in drag order — sizes (below) slice them into groups.
  final List<PlayerProfile>     orderedPlayers;
  /// A pairs round groups in twos, with a trailing one when the field is odd
  /// (blocked later, and named there) and a three only in best ball.
  final int    minGroupSize;
  final int    maxGroupSize;
  final String groupNoun;
  final Map<int, TeeInfo?>      playerTees;
  final List<TeeInfo>           courseTees;
  /// Group sizes the wizard is currently using (auto-balance or TD
  /// override).  Sum equals orderedPlayers.length; each entry in {2,3,4}.
  final List<int>               groupSizes;
  final void Function(int, int) onReorder;
  final void Function(int playerId, TeeInfo tee) onPickTee;
  /// Apply a TD-supplied group-size override.  null reverts to the
  /// auto-balance.  Wizard handles validation before calling.
  final void Function(List<int>? sizes) onChangeGroupSizes;

  const _Step3GroupsAndTees({
    this.minGroupSize = 2,
    this.maxGroupSize = 4,
    this.groupNoun    = 'Group',
    required this.orderedPlayers,
    required this.playerTees,
    required this.courseTees,
    required this.groupSizes,
    required this.onReorder,
    required this.onPickTee,
    required this.onChangeGroupSizes,
  });

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final sizes       = groupSizes;
    final groupCount  = sizes.length;
    // The default this screen is comparing against — twos for a pairs field,
    // the fours auto-balance otherwise. Comparing a pairs override against the
    // fours default marked every pairs field as "overridden".
    final autoBalance = minGroupSize == 1
        ? gr.pairPlayGroupSizes(orderedPlayers.length)
        : gr.groupSizes(orderedPlayers.length);
    bool _sameAsAuto() {
      if (sizes.length != autoBalance.length) return false;
      for (var i = 0; i < sizes.length; i++) {
        if (sizes[i] != autoBalance[i]) return false;
      }
      return true;
    }
    final isOverridden = !_sameAsAuto();

    return _pinnedStep(
      context,
      title: 'Groups & Tees',
      subtitle: 'Drag  ≡  to reorder. Tap "Edit sizes" to override the '
          'default group breakdown. Set tees below — all at once, or per '
          'golfer.',
      children: [
          const SizedBox(height: 8),
          // The SAME tee UI as casual round setup and Edit Tee Boxes:
          // golfers grouped by sex, a prominent "Set all" per group, per-player
          // overrides, and a loud warning chip until every golfer has one.
          // The wizard used to hand-roll a bare dropdown per row, which is why
          // assigning sixteen tees here was worse than doing it in the hub.
          TeeAssignmentList(
            players:   orderedPlayers,
            tees:      courseTees,
            picks:     {
              for (final p in orderedPlayers)
                if (playerTees[p.id] != null) p.id: playerTees[p.id]!.id,
            },
            onChanged: (pid, teeId) {
              final tee = courseTees.where((t) => t.id == teeId).firstOrNull;
              if (tee != null) onPickTee(pid, tee);
            },
            subtitle: (p) => 'Index ${p.handicapIndex}',
          ),
          const SizedBox(height: 8),
          // Group legend chips + Edit Sizes affordance
          Row(children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: List.generate(groupCount, (i) {
                  final color = _groupColors[i % _groupColors.length];
                  return Chip(
                    label: Text(
                      'Group ${i + 1} · ${sizes[i]}',
                      style: TextStyle(
                          color: color, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    backgroundColor: color.withOpacity(0.1),
                    side: BorderSide(color: color.withOpacity(0.4)),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  );
                }),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.tune, size: 16),
              label: Text(isOverridden ? 'Edit sizes *' : 'Edit sizes'),
              onPressed: () async {
                final result = await showDialog<List<int>?>(
                  context: context,
                  builder: (_) => _GroupSizeEditor(
                    initialSizes: List<int>.from(sizes),
                    totalPlayers: orderedPlayers.length,
                    autoBalance: autoBalance,
                    minSize: minGroupSize,
                    maxSize: maxGroupSize,
                    noun   : groupNoun,
                  ),
                );
                if (result == null) return;   // dialog dismissed
                // Empty list sentinel = "revert to auto-balance".
                onChangeGroupSizes(result.isEmpty ? null : result);
              },
            ),
          ]),
          const SizedBox(height: 12),

          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outline),
            ),
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              // 68 px per row
              height: orderedPlayers.length * 68.0,
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: onReorder,
                proxyDecorator: (child, _, animation) => Material(
                  elevation: 4,
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                  child: child,
                ),
                children: orderedPlayers.asMap().entries.map((entry) {
                  final idx      = entry.key;
                  final player   = entry.value;
                  final groupNum = groupOf(idx, sizes);
                  final color    =
                      _groupColors[(groupNum - 1) % _groupColors.length];
                  final tee      = playerTees[player.id];

                  // First player in a group gets a stronger top border
                  final isGroupStart = isGroupBoundary(idx, sizes);

                  return Container(
                    key: ValueKey(player.id),
                    height: 68,
                    decoration: BoxDecoration(
                      color: idx.isEven
                          ? theme.colorScheme.surface
                          : theme.colorScheme.surfaceContainerLowest,
                      border: Border(
                        top: BorderSide(
                          color: isGroupStart
                              ? theme.colorScheme.outline
                              : theme.colorScheme.outlineVariant,
                          width: isGroupStart ? 2.0 : 0.5,
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        // ── Drag handle ──
                        ReorderableDragStartListener(
                          index: idx,
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            child: Icon(Icons.drag_handle,
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),

                        // ── Player name + tee dropdown ──
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                player.name,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              // Tees are set in the list above, not per drag
                              // row — the row's job here is group order. Its
                              // tee just READS back so the grouping and the
                              // assignment can be checked against each other.
                              //
                              // The COURSE HANDICAP rides along because it is
                              // what the TD is actually grouping on, and it is
                              // the number the next steps spend: a Foursome
                              // Play allowance is a percentage of it, and the
                              // tee is the reason two golfers off the same
                              // index get different figures. Reading the tee
                              // name and doing the slope arithmetic in your
                              // head is not a thing anybody does.
                              Text(
                                tee == null
                                    ? 'No tee yet'
                                    : '${tee.teeName} · CH '
                                      '${courseHandicapFor(player, tee)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: tee == null
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),

                        // ── Group badge ──
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: color.withOpacity(0.4)),
                          ),
                          child: Text(
                            'G $groupNum',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: color, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          const SizedBox(height: 12),
          Text(
            minGroupSize == 1
                // A pairs field. There is no phantom partner to pad with — it
                // would be an imaginary partner taking half the shots in an
                // alternate shot — so an odd field is a problem to fix, and
                // the Handicap step names the golfer standing there.
                ? 'Two pairs go off together — one tee time, one scorer, one '
                  'card. The first two golfers in a group are one pair and the '
                  'next two are the other. A golfer left without a partner is '
                  'named on the Handicap step, and Next waits on it.'
                : 'Groups with fewer than 4 players will have a phantom added '
                  'automatically so all scoring works correctly.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
    );
  }
}

// ===========================================================================
// Step 2 (Cup) — Cup Design
// ===========================================================================

class _StepTeams extends StatefulWidget {
  final int                   teamCount;
  final List<String>          teamColours;
  final List<TextEditingController> nameCtrls;
  final List<TextEditingController> badgeCtrls;
  final List<bool>            badgeOwned;
  final String Function(String) deriveBadge;
  final ValueChanged<int>     onTeamCountChanged;
  final void Function(int teamIdx, String colour) onTeamColourChanged;

  const _StepTeams({
    required this.teamCount,
    required this.teamColours,
    required this.nameCtrls,
    required this.badgeCtrls,
    required this.badgeOwned,
    required this.deriveBadge,
    required this.onTeamCountChanged,
    required this.onTeamColourChanged,
  });

  @override
  State<_StepTeams> createState() => _StepTeamsState();
}

class _StepTeamsState extends State<_StepTeams> {
  static const _cardBorder = Color(0xFFD3DED6);
  static const _ink        = Color(0xFF0B1F1A);
  static const _muted      = Color(0xFF9AA8A0);

  @override
  void initState() {
    super.initState();
    _syncBadges();
  }

  @override
  void didUpdateWidget(_StepTeams old) {
    super.didUpdateWidget(old);
    if (old.teamCount != widget.teamCount) _syncBadges();
  }

  /// Keep each not-yet-owned badge field showing the derived letter, so the
  /// field mirrors the chip on arrival and after a team-count change.
  void _syncBadges() {
    for (int i = 0; i < widget.teamCount; i++) {
      if (widget.badgeOwned[i]) continue;
      final d = widget.deriveBadge(
          widget.nameCtrls[i].text.isEmpty ? 'Team ${i + 1}' : widget.nameCtrls[i].text);
      if (widget.badgeCtrls[i].text != d) widget.badgeCtrls[i].text = d;
    }
  }

  String _badgeFor(int i) {
    final b = widget.badgeCtrls[i].text.trim();
    if (b.isNotEmpty) return b.toUpperCase();
    return widget.deriveBadge(
        widget.nameCtrls[i].text.isEmpty ? 'Team ${i + 1}' : widget.nameCtrls[i].text);
  }

  Color _colourFor(int i) {
    final name = i < widget.teamColours.length ? widget.teamColours[i] : 'Red';
    return _kCupColourChoices
        .firstWhere((e) => e.$1.toLowerCase() == name.toLowerCase(),
            orElse: () => _kCupColourChoices.first)
        .$2;
  }

  bool _colourLocked(int teamIdx, String colourName) {
    for (int j = 0; j < widget.teamCount; j++) {
      if (j == teamIdx) continue;
      if (j < widget.teamColours.length &&
          widget.teamColours[j].toLowerCase() == colourName.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  String? _duplicateBadge() {
    final seen = <String>{};
    for (int i = 0; i < widget.teamCount; i++) {
      final b = _badgeFor(i);
      if (b.isEmpty) continue;
      if (!seen.add(b)) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dup = _duplicateBadge();
    return _pinnedStep(
      context,
      title: 'Teams',
      subtitle: 'How many sides, what they are called, and which colour each '
          'one wears. Players are assigned in the draft.',
      children: [
        _label(context, 'Number of teams'),
        const SizedBox(height: 8),
        Row(children: [2, 3, 4].map((n) {
          final on = widget.teamCount == n;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: n < 4 ? 8 : 0),
              child: InkWell(
                onTap: () => widget.onTeamCountChanged(n),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? theme.colorScheme.primary : Colors.white,
                    border: Border.all(
                        color: on ? theme.colorScheme.primary : _cardBorder,
                        width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('$n teams',
                      style: TextStyle(
                          color: on ? Colors.white : theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          );
        }).toList()),
        const SizedBox(height: 20),
        _label(context, 'Teams'),
        const SizedBox(height: 8),
        for (int i = 0; i < widget.teamCount; i++) _teamCard(context, i),
        if (dup != null) ...[
          const SizedBox(height: 2),
          _dupWarning(context, dup),
        ],
        const SizedBox(height: 10),
        Text(
          'Names up to 16 characters — enough to fit the leaderboard on the '
          'smallest phone. The badge is one or two characters and follows the '
          'name unless you set it yourself.',
          style: theme.textTheme.bodySmall?.copyWith(color: _muted),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            fontSize: 11));
  }

  Widget _teamCard(BuildContext context, int i) {
    final theme = Theme.of(context);
    final colour = _colourFor(i);
    final name = widget.nameCtrls[i].text.trim();
    final nameLen = widget.nameCtrls[i].text.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 13),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _cardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            constraints: const BoxConstraints(minWidth: 24),
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: colour, borderRadius: BorderRadius.circular(8)),
            child: Text(_badgeFor(i),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
          ),
          const SizedBox(width: 9),
          Text(name.isEmpty ? 'Team ${i + 1}' : name,
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: name.isEmpty ? _muted : theme.colorScheme.onSurface)),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: widget.nameCtrls[i],
              maxLength: 16,
              textCapitalization: TextCapitalization.words,
              onChanged: (v) => setState(() {
                if (!widget.badgeOwned[i]) {
                  widget.badgeCtrls[i].text =
                      widget.deriveBadge(v.isEmpty ? 'Team ${i + 1}' : v);
                }
              }),
              decoration: InputDecoration(
                hintText: 'Team ${i + 1}',
                counterText: nameLen >= 12 ? '$nameLen/16' : '',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 9),
          SizedBox(
            width: 66,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: widget.badgeCtrls[i],
                maxLength: 2,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                onChanged: (v) => setState(() {
                  widget.badgeOwned[i] = v.trim().isNotEmpty;
                  final up = v.toUpperCase();
                  if (up != v) {
                    widget.badgeCtrls[i].value = TextEditingValue(
                      text: up,
                      selection: TextSelection.collapsed(offset: up.length),
                    );
                  }
                }),
                decoration: const InputDecoration(
                  counterText: '',
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              Text('BADGE',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      fontSize: 9.5)),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        _swatches(context, i),
      ]),
    );
  }

  Widget _swatches(BuildContext context, int i) {
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: _kCupColourChoices.map((e) {
        final (cname, ccolor) = e;
        final selected = i < widget.teamColours.length &&
            widget.teamColours[i].toLowerCase() == cname.toLowerCase();
        final locked = _colourLocked(i, cname);
        return GestureDetector(
          onTap: locked ? null : () => widget.onTeamColourChanged(i, cname),
          child: Opacity(
            opacity: locked ? 0.3 : 1,
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                    color: selected ? _ink : Colors.transparent, width: 2),
              ),
              child: Stack(alignment: Alignment.center, children: [
                Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                        color: ccolor, borderRadius: BorderRadius.circular(8))),
                if (selected) const Icon(Icons.check, size: 15, color: Colors.white),
                if (locked)
                  Transform.rotate(
                      angle: -0.785,
                      child: Container(width: 30, height: 2, color: _ink)),
              ]),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _dupWarning(BuildContext context, String letter) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
          color: const Color(0xFFFDF3E7), borderRadius: BorderRadius.circular(11)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFB9791C)),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(TextSpan(
            style: const TextStyle(
                color: Color(0xFF8A5216), fontSize: 12.5, height: 1.4),
            children: [
              const TextSpan(text: 'Two teams use the badge '),
              TextSpan(text: letter, style: const TextStyle(fontWeight: FontWeight.w700)),
              const TextSpan(
                  text: '. Colour still tells them apart, but a different '
                      'letter reads faster on the scorecard.'),
            ],
          )),
        ),
      ]),
    );
  }
}

// Available team colours for cup tournaments — the shared canonical palette
// (`kCupTeamColours`), so the swatch a captain picks here is the exact colour
// the draft board and round-groups render for that side.
const _kCupColourChoices = kCupTeamColours;

// ===========================================================================
// Step (Cup) — Tournament side game (field-wide only)
// ===========================================================================

class _StepSideGame extends StatelessWidget {
  final String value; // none | irish_rumble | pink_ball
  final ValueChanged<String> onChanged;

  const _StepSideGame({required this.value, required this.onChanged});

  static const _cardBorder = Color(0xFFD3DED6);
  static const _unitBg     = Color(0xFFE4F2EA);

  // (value, title, subtitle, fieldTag)
  static const _opts = <(String, String, String, bool)>[
    ('none', 'None', 'The cup stands on its own. Most do.', false),
    ('irish_rumble', 'Irish Rumble',
        'One, two, then three balls counted across the round. Needs its own hole setup.',
        true),
    ('pink_ball', 'Pink Ball',
        'One marked ball rotates through the group and must survive the round. '
        'Call it something else on its setup screen — Red Ball, Devil Ball — '
        'and that name is used everywhere after.',
        true),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _pinnedStep(
      context,
      title: 'Tournament side game',
      subtitle: 'A game every group plays, scored across the whole field.',
      children: [
        _label(context, 'Played by the whole field'),
        const SizedBox(height: 8),
        for (final o in _opts) _optCard(context, o.$1, o.$2, o.$3, o.$4),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F8F4),
            border: Border.all(color: const Color(0xFFDDE7DF)),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Looking for Skins, Nassau or rabbit?',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
              'Those are settled inside a foursome, not across the field, so '
              'they are set on each group when you build them. They read the '
              'gross scores this tournament already collects, and an exclusive '
              'format does not block them.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.45),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            fontSize: 11));
  }

  Widget _optCard(
      BuildContext context, String v, String title, String sub, bool fieldTag) {
    final theme = Theme.of(context);
    final pine = theme.colorScheme.primary;
    final selected = value == v;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => onChanged(v),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? pine.withOpacity(0.06) : Colors.white,
            border: Border.all(color: selected ? pine : _cardBorder, width: 1.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: selected ? pine : const Color(0xFFC0CFC5), width: 2),
              ),
              child: selected
                  ? Center(
                      child: Container(
                          width: 8,
                          height: 8,
                          decoration:
                              BoxDecoration(shape: BoxShape.circle, color: pine)))
                  : null,
            ),
            const SizedBox(width: 11),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ])),
            if (fieldTag) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                    color: _unitBg, borderRadius: BorderRadius.circular(5)),
                child: Text('FIELD',
                    style: TextStyle(
                        color: pine,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        fontSize: 9.5)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

// ===========================================================================
// Step 3 (Cup, MIXED) — Games & points by round
// ===========================================================================
//
// A mixed cup runs several point-bearing games in a day; each foursome plays
// one.  You set HOW MANY of each game runs (the count is the pick — >0 means
// it's in the day), then what each match is worth, and the totals follow.
//
// NOTE (scaffold ahead of scoring): the one-ball formats (Chapman, two-golfer
// scramble, scramble) are drawn and priced but the app can't score them yet —
// `scoreable:false`.  Singles are counted in twosomes as drawn; the engine
// prices per foursome (two singles each), so an ODD twosome can't fully persist
// until the backend gains an odd-twosome shape.  Totals shown here are the
// drawn/intended values; persisted `cup_group_counts` are foursome-equivalent.

// (id, title, descriptor, family, perSideCost, segments, isOneMatch, scoreable)
// family: 'foursome' (2 a side inside the group) | 'twosome' (1 a side) |
//         'match' (one blue-four vs one red-four, on/off)
const _kMixedGames = <(String, String, String, String, int, int, bool, bool)>[
  ('nassau',           'Nassau pairs',      '2 v 2 inside a foursome — one match each',
      'foursome', 2, 3, false, true),
  ('two_man_chapman',  'Two-golfer Chapman',   '2 v 2 inside a foursome — one ball a pair',
      'foursome', 2, 1, false, false),
  ('foursomes',        'Foursomes',         'Alternate shot — 2 v 2, one ball a pair',
      'foursome', 2, 1, false, false),
  ('singles_18',       'Singles',           '1 v 1 — counted in twosomes',
      'twosome', 1, 1, false, true),
  ('singles_nassau',   'Singles Nassau',    '1 v 1 — front, back and overall',
      'twosome', 1, 3, false, true),
  ('irish_rumble',     'Irish Rumble',      'One match only — a blue foursome against a red foursome',
      'match', 4, 1, true, true),
  ('scramble',         'Scramble',          'One match only — four a side, one ball',
      'match', 4, 1, true, false),
];

typedef _MixedGame = (String, String, String, String, int, int, bool, bool);

int _mixedSeg(_MixedGame g)      => g.$6;
int _mixedPerSide(_MixedGame g)  => g.$5;
bool _mixedOneMatch(_MixedGame g)=> g.$7;
bool _mixedScoreable(_MixedGame g)=> g.$8;

/// Points a game contributes = matches × price × segments.  For a one-match
/// game the count is 0/1.
double _mixedPoints(_MixedGame g, int count, double price) =>
    count * price * _mixedSeg(g);

/// Golfers committed on one side by a game's count.
int _mixedCommitted(_MixedGame g, int count) => count * _mixedPerSide(g);

String _fmtPts(double v) =>
    v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

class _MixedGamesByRound extends StatelessWidget {
  final int                            numRounds;
  final Map<int, Map<String, int>>     roundCounts;
  final Map<int, Map<String, double>>  roundPoints;
  final int                            sideSize;
  final int?                           selectedCourseId;
  final List<_RoundDraft>              additionalRounds;
  final List<CourseInfo>               courses;
  final DateTime                       date;
  final void Function(int roundIdx, String game, int count) onCount;
  final void Function(int roundIdx, String game, double pts) onPrice;
  final ValueChanged<int>              onSideSize;

  const _MixedGamesByRound({
    required this.numRounds,
    required this.roundCounts,
    required this.roundPoints,
    required this.sideSize,
    required this.selectedCourseId,
    required this.additionalRounds,
    required this.courses,
    required this.date,
    required this.onCount,
    required this.onPrice,
    required this.onSideSize,
  });

  String _courseName(int? id) => id == null
      ? '—'
      : courses.firstWhere((c) => c.id == id,
              orElse: () => CourseInfo(id: id, name: '—')).name;

  double _roundTotal(int r) {
    final counts = roundCounts[r] ?? const {};
    final pts    = roundPoints[r] ?? const {};
    double t = 0;
    for (final g in _kMixedGames) {
      final c = counts[g.$1] ?? 0;
      if (c > 0) t += _mixedPoints(g, c, pts[g.$1] ?? 1.0);
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    double cupTotal = 0;
    for (int r = 0; r < numRounds; r++) cupTotal += _roundTotal(r);
    final toWin = cupTotal <= 0 ? 0.0 : (cupTotal / 2).floorToDouble() + 1;

    return _pinnedStep(
      context,
      title: 'Games & points by round',
      subtitle: 'Set how many of each game a day runs, then what each match is '
          'worth. Totals follow.',
      children: [
        for (int r = 0; r < numRounds; r++) ...[
          _MixedRoundCard(
            roundNumber : r + 1,
            courseName  : r == 0
                ? _courseName(selectedCourseId)
                : _courseName(additionalRounds[r - 1].courseId),
            date        : r == 0 ? date : additionalRounds[r - 1].date,
            counts      : roundCounts[r] ?? const {},
            points      : roundPoints[r] ?? const {},
            sideSize    : sideSize,
            roundTotal  : _roundTotal(r),
            onCount     : (g, c) => onCount(r, g, c),
            onPrice     : (g, p) => onPrice(r, g, p),
            onSideSize  : onSideSize,
          ),
          const SizedBox(height: 16),
        ],
        // ── Cup total panel ──────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1F1A),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (int r = 0; r < numRounds; r++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  Expanded(
                    child: Text('Round ${r + 1}',
                        style: const TextStyle(color: Color(0xFF9DB0A3), fontSize: 13)),
                  ),
                  Text('${_fmtPts(_roundTotal(r))} pts',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                ]),
              ),
            const Divider(color: Color(0xFF26332B), height: 18),
            Row(children: [
              const Expanded(
                child: Text('Points to play',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              Text(_fmtPts(cupTotal),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Expanded(
                child: Text('To win the cup',
                    style: TextStyle(color: Color(0xFF7FC98A), fontWeight: FontWeight.w700)),
              ),
              Text(_fmtPts(toWin),
                  style: const TextStyle(
                      color: Color(0xFF7FC98A), fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
          ]),
        ),
        const SizedBox(height: 4),
        Text(
          'Chapman, two-golfer scramble and scramble are drawn but not scored yet; '
          'their points are indicative.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _MixedRoundCard extends StatefulWidget {
  final int                   roundNumber;
  final String                courseName;
  final DateTime              date;
  final Map<String, int>      counts;
  final Map<String, double>   points;
  final int                   sideSize;
  final double                roundTotal;
  final void Function(String game, int count)  onCount;
  final void Function(String game, double pts) onPrice;
  final ValueChanged<int>     onSideSize;

  const _MixedRoundCard({
    required this.roundNumber,
    required this.courseName,
    required this.date,
    required this.counts,
    required this.points,
    required this.sideSize,
    required this.roundTotal,
    required this.onCount,
    required this.onPrice,
    required this.onSideSize,
  });

  @override
  State<_MixedRoundCard> createState() => _MixedRoundCardState();
}

class _MixedRoundCardState extends State<_MixedRoundCard> {
  int get _committed {
    int c = 0;
    for (final g in _kMixedGames) {
      c += _mixedCommitted(g, widget.counts[g.$1] ?? 0);
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final committed = _committed;
    final over = committed > widget.sideSize;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text('R${widget.roundNumber}',
                  style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.courseName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${DateFormat('EEE, MMM d').format(widget.date)} · '
                    '2 sides of ${widget.sideSize}',
                    style: theme.textTheme.bodySmall),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          // Game rows
          for (final g in _kMixedGames) _gameRow(theme, g),
          const Divider(height: 22),
          // Roster meter
          Row(children: [
            Expanded(
              child: Text('Committed per side',
                  style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
            _sideSizeStepper(theme),
            const SizedBox(width: 10),
            Text('$committed of ${widget.sideSize}',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: over ? theme.colorScheme.error : theme.colorScheme.primary)),
          ]),
          const SizedBox(height: 4),
          Text(
            committed == 0
                ? 'Pick games to fill the day.'
                : over
                    ? '${committed - widget.sideSize} over a side of ${widget.sideSize}.'
                    : committed == widget.sideSize
                        ? 'Every golfer on both sides has a match.'
                        : '${widget.sideSize - committed} per side without a match yet.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: over
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Text('${_fmtPts(widget.roundTotal)} pts this round',
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }

  Widget _gameRow(ThemeData theme, _MixedGame g) {
    final count = widget.counts[g.$1] ?? 0;
    final price = widget.points[g.$1] ?? 1.0;
    final active = count > 0;
    final seg = _mixedSeg(g);
    final unitNoun = switch (g.$4) {
      'foursome' => count == 1 ? 'foursome' : 'foursomes',
      'twosome'  => count == 1 ? 'twosome' : 'twosomes',
      _          => 'match',
    };
    final pts = _mixedPoints(g, count, price);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(g.$2,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: active
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant)),
                ),
                if (!_mixedScoreable(g)) ...[
                  const SizedBox(width: 6),
                  _tag(theme, 'SOON'),
                ],
              ]),
              Text(g.$3,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: 8),
          // Count control — On/Off for a one-match game, stepper otherwise.
          if (_mixedOneMatch(g))
            Switch(
              value: active,
              onChanged: (v) => widget.onCount(g.$1, v ? 1 : 0),
            )
          else
            _stepper(
              value: count,
              onDown: count > 0 ? () => widget.onCount(g.$1, count - 1) : null,
              onUp: () => widget.onCount(g.$1, count + 1),
            ),
        ]),
        if (active) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Text(
                _mixedOneMatch(g)
                    ? '${_mixedPerSide(g)} per side'
                    : '$count $unitNoun'
                        '${seg > 1 ? ' × $seg segments' : ''} · '
                        '${_mixedCommitted(g, count)} per side',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            _priceStepper(theme, g, price, seg),
            const SizedBox(width: 10),
            SizedBox(
              width: 44,
              child: Text('${_fmtPts(pts)} pt${pts == 1 ? '' : 's'}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _priceStepper(ThemeData theme, _MixedGame g, double price, int seg) {
    final unit = seg > 1 ? 'seg' : 'match';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _roundIconBtn(Icons.remove,
          price > 1 ? () => widget.onPrice(g.$1, price - 1) : null),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text('${_fmtPts(price)} / $unit',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
      ),
      _roundIconBtn(Icons.add, () => widget.onPrice(g.$1, price + 1)),
    ]);
  }

  Widget _sideSizeStepper(ThemeData theme) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _roundIconBtn(Icons.remove,
              widget.sideSize > 2 ? () => widget.onSideSize(widget.sideSize - 2) : null),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('${widget.sideSize}/side',
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
          _roundIconBtn(Icons.add, () => widget.onSideSize(widget.sideSize + 2)),
        ],
      );

  Widget _stepper({required int value, VoidCallback? onDown, VoidCallback? onUp}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        _roundIconBtn(Icons.remove, onDown),
        SizedBox(
          width: 24,
          child: Text('$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ),
        _roundIconBtn(Icons.add, onUp),
      ]);

  Widget _roundIconBtn(IconData icon, VoidCallback? onTap) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 30, height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: onTap == null
                  ? theme.colorScheme.outlineVariant
                  : theme.colorScheme.primary),
        ),
        child: Icon(icon,
            size: 16,
            color: onTap == null
                ? theme.colorScheme.outlineVariant
                : theme.colorScheme.primary),
      ),
    );
  }

  Widget _tag(ThemeData theme, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(text,
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                fontSize: 9)),
      );
}

// ===========================================================================
// Step 3 (Cup) — Per-round game plan
// ===========================================================================

const _kCupGameChoices = [
  ('nassau',          'Four Ball (Nassau)'),
  ('quota_nassau',    'Four Ball Quota (Nassau)'),
  ('irish_rumble',    'Irish Rumble'),
  ('singles_nassau',  'Singles Nassau (F9/B9/All)'),
  ('singles_18',      '18-Hole Singles'),
  // One Day Ryder Cup: every foursome plays Triple Cup (fourball +
  // alt-shot foursomes + 2 singles).  When picked here, the per-round
  // cup setup wizard auto-locks every foursome to triple_cup so the
  // admin doesn't have to repeat the pick.
  ('triple_cup',      'One-Day Triple Cup'),
];

class _Step3CupRoundGames extends StatelessWidget {
  final int                                   numRounds;
  final Map<int, List<String>>                roundCupGames;
  final Map<int, Map<String, double>>         roundCupPoints;
  final int?                                  selectedCourseId;
  final List<_RoundDraft>                     additionalRounds;
  final List<CourseInfo>                      courses;
  final DateTime                              date;
  final void Function(int roundIdx, List<String> games)           onChanged;
  final void Function(int roundIdx, Map<String, double> points)   onPointsChanged;

  const _Step3CupRoundGames({
    super.key,
    required this.numRounds,
    required this.roundCupGames,
    required this.roundCupPoints,
    required this.selectedCourseId,
    required this.additionalRounds,
    required this.courses,
    required this.date,
    required this.onChanged,
    required this.onPointsChanged,
  });

  String _courseName(int? courseId) {
    if (courseId == null) return '—';
    return courses.firstWhere((c) => c.id == courseId,
            orElse: () => CourseInfo(id: courseId, name: '—'))
        .name;
  }

  @override
  Widget build(BuildContext context) {
    return _pinnedStep(
      context,
      title: 'Games by Round',
      subtitle: 'For each round, add one entry per foursome. '
          'The order defines which group plays which format.',
      children: [
        for (int r = 0; r < numRounds; r++) ...[
          _RoundGameSlots(
            roundIndex        : r,
            roundNumber       : r + 1,
            courseName        : r == 0
                ? _courseName(selectedCourseId)
                : _courseName(additionalRounds[r - 1].courseId),
            date              : r == 0 ? date : additionalRounds[r - 1].date,
            currentGames      : roundCupGames[r] ?? [],
            currentPoints     : roundCupPoints[r] ?? {},
            onChanged         : (games) => onChanged(r, games),
            onPointsChanged   : (pts) => onPointsChanged(r, pts),
          ),
          if (r < numRounds - 1) const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _RoundGameSlots extends StatefulWidget {
  final int                     roundIndex;
  final int                     roundNumber;
  final String                  courseName;
  final DateTime                date;
  final List<String>            currentGames;
  final Map<String, double>     currentPoints;
  final void Function(List<String>)           onChanged;
  final void Function(Map<String, double>)    onPointsChanged;

  const _RoundGameSlots({
    required this.roundIndex,
    required this.roundNumber,
    required this.courseName,
    required this.date,
    required this.currentGames,
    required this.currentPoints,
    required this.onChanged,
    required this.onPointsChanged,
  });

  @override
  State<_RoundGameSlots> createState() => _RoundGameSlotsState();
}

class _RoundGameSlotsState extends State<_RoundGameSlots> {
  final Map<String, TextEditingController> _ptCtrl = {};

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void didUpdateWidget(_RoundGameSlots old) {
    super.didUpdateWidget(old);
    _syncControllers();
  }

  void _syncControllers() {
    // currentGames is already a unique list — one entry per game type
    final unique = widget.currentGames.toSet();
    // Add controllers for new game types
    for (final g in unique) {
      if (!_ptCtrl.containsKey(g)) {
        final initial = widget.currentPoints[g] ?? 1.0;
        final ctrl = TextEditingController(
          text: initial % 1 == 0 ? initial.toInt().toString() : initial.toString(),
        );
        ctrl.addListener(() {
          final pts = double.tryParse(ctrl.text.trim()) ?? 1.0;
          final updated = Map<String, double>.from(widget.currentPoints);
          updated[g] = pts;
          widget.onPointsChanged(updated);
        });
        _ptCtrl[g] = ctrl;
      }
    }
    // Remove controllers for game types no longer in the list
    _ptCtrl.removeWhere((g, ctrl) {
      if (!unique.contains(g)) {
        ctrl.dispose();
        return true;
      }
      return false;
    });
  }

  @override
  void dispose() {
    for (final c in _ptCtrl.values) c.dispose();
    super.dispose();
  }

  String _label(String id) =>
      _kCupGameChoices.firstWhere((g) => g.$1 == id,
              orElse: () => (id, id))
          .$2;

  void _addGame(BuildContext context) {
    // Only show game types not already in the list
    final existing = widget.currentGames.toSet();
    final choices  = _kCupGameChoices.where((g) => !existing.contains(g.$1)).toList();
    if (choices.isEmpty) return;
    showModalBottomSheet<String>(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Add a game format',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ...choices.map((g) => ListTile(
            title: Text(g.$2),
            onTap: () => Navigator.of(context).pop(g.$1),
          )),
        ],
      ),
    ).then((picked) {
      if (picked == null) return;
      // Triple Cup is exclusive — it owns the entire foursome (4
      // matches × 18 holes).  Replace any other formats on this
      // round rather than stacking them.
      if (picked == 'triple_cup') {
        widget.onChanged(const ['triple_cup']);
        widget.onPointsChanged(const {'triple_cup': 1.0});
        return;
      }
      widget.onChanged([...widget.currentGames, picked]);
    });
  }

  /// Swap the format on this row for a different one, preserving its points.
  /// Triple Cup is exclusive, so choosing it clears any others.
  void _changeGame(BuildContext context, String gameId) {
    showModalBottomSheet<String>(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Change format',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ..._kCupGameChoices.map((g) => ListTile(
            title: Text(g.$2),
            trailing: g.$1 == gameId
                ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                : null,
            onTap: () => Navigator.of(context).pop(g.$1),
          )),
        ],
      ),
    ).then((picked) {
      if (picked == null || picked == gameId) return;
      if (picked == 'triple_cup') {
        widget.onChanged(const ['triple_cup']);
        widget.onPointsChanged(const {'triple_cup': 1.0});
        return;
      }
      final games = widget.currentGames
          .map((x) => x == gameId ? picked : x)
          .toList();
      final pts = Map<String, double>.from(widget.currentPoints);
      final oldPt = pts.remove(gameId) ?? 1.0;
      pts[picked] = oldPt;
      widget.onChanged(games);
      widget.onPointsChanged(pts);
    });
  }

  /// Segments a format plays per group — the multiplier from points-per-segment
  /// to points-per-group.  Triple Cup is Fourball + Foursomes + two Singles.
  int _segments(String gameId) => gameId == 'triple_cup' ? 4 : 1;

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final gameList    = widget.currentGames; // unique game types

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text('R${widget.roundNumber}',
                  style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(widget.courseName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(DateFormat('EEE, MMM d').format(widget.date),
                    style: theme.textTheme.bodySmall),
              ]),
            ),
          ]),

          const SizedBox(height: 12),

          if (gameList.isEmpty)
            Text('No games added yet.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic))
          else ...[
            // Column headers — no group count here; it's derived from the
            // draft's side size, not entered.
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Expanded(child: Text('Format',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                SizedBox(width: 82, child: Text('Per segment',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
              ]),
            ),
            const Divider(height: 1),
            const SizedBox(height: 4),

            // One row per game type — format (with a Change link) + points,
            // and, for multi-segment formats, the per-group arithmetic.
            ...gameList.map((g) {
              final segs = _segments(g);
              final pts  = widget.currentPoints[g] ?? 1.0;
              String n(double v) => v % 1 == 0 ? v.toInt().toString() : '$v';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(children: [
                    Expanded(
                      child: Row(children: [
                        Flexible(
                          child: Text(_label(g),
                              style: theme.textTheme.bodyMedium,
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 10),
                        InkWell(
                          onTap: () => _changeGame(context, g),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Text('Change',
                                style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 8),

                    // Points per segment field
                    SizedBox(
                      width: 82,
                      child: TextField(
                        controller: _ptCtrl[g],
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => FocusScope.of(context).unfocus(),
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          suffixText: 'pt',
                          border    : OutlineInputBorder(),
                          isDense   : true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                        ),
                      ),
                    ),
                  ]),
                  if (segs > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        '${n(pts)} pt × $segs segments = ${n(pts * segs)} pts/group',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                ]),
              );
            }),
          ],

          if (gameList.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFFDF3E7),
                border: Border.all(color: const Color(0xFFF0DCBE)),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.schedule, size: 16, color: Color(0xFFB9791C)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Groups aren\'t set here. Side size is set in the draft, '
                    'and the group count — and the totals — follow from it.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF8A5216), height: 1.4),
                  ),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 6),
          if (gameList.contains('triple_cup'))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Triple Cup is exclusive — no other games on this round.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic),
              ),
            )
          else
            TextButton.icon(
              onPressed: gameList.length < _kCupGameChoices.length
                  ? () => _addGame(context)
                  : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add a game'),
            ),
        ]),
      ),
    );
  }
}


// ===========================================================================
// Step 3 — Group-size editor dialog
// ===========================================================================
//
// Lets the TD override the auto-balance with any valid breakdown:
//   • Each group in {2, 3, 4}
//   • Sum equals total player count
//   • At least one group
//
// Returns:
//   • List<int> of sizes when the user taps Apply with a valid layout
//   • Empty list when the user taps "Reset to default" (signals revert)
//   • null when the dialog is dismissed (no change)

class _GroupSizeEditor extends StatefulWidget {
  final List<int> initialSizes;
  final List<int> autoBalance;
  final int       totalPlayers;
  /// A foursome round groups in 2s to 4s. **A pairs round groups in twos** —
  /// with a trailing ONE when the field is odd, which has to be representable
  /// here or a 13-golfer field cannot be saved at all, and a THREE only when
  /// the format is best ball (the one way out that counts a third ball).
  final int       minSize;
  final int       maxSize;
  final String    noun;

  const _GroupSizeEditor({
    required this.initialSizes,
    required this.autoBalance,
    required this.totalPlayers,
    this.minSize = 2,
    this.maxSize = 4,
    this.noun    = 'Group',
  });

  @override
  State<_GroupSizeEditor> createState() => _GroupSizeEditorState();
}

class _GroupSizeEditorState extends State<_GroupSizeEditor> {
  late List<int> _sizes;

  @override
  void initState() {
    super.initState();
    _sizes = List<int>.from(widget.initialSizes);
  }

  int  get _total     => _sizes.fold(0, (s, x) => s + x);
  int  get _remaining => widget.totalPlayers - _total;
  bool get _isValid   => _total == widget.totalPlayers &&
                         _sizes.every(
                             (s) => s >= widget.minSize && s <= widget.maxSize) &&
                         _sizes.isNotEmpty;

  void _inc(int idx) {
    if (_sizes[idx] >= widget.maxSize) return;
    setState(() => _sizes[idx] = _sizes[idx] + 1);
  }
  void _dec(int idx) {
    if (_sizes[idx] <= widget.minSize) return;
    setState(() => _sizes[idx] = _sizes[idx] - 1);
  }
  void _remove(int idx) {
    if (_sizes.length <= 1) return;
    setState(() => _sizes.removeAt(idx));
  }
  void _addGroup() {
    // Default a new group to the biggest size that fits, floored at the
    // minimum — a pairs field adds twos, a foursome field adds fours.
    final spaceLeft = widget.totalPlayers - _total;
    final initial   = spaceLeft >= widget.maxSize
        ? widget.maxSize
        : (spaceLeft >= widget.minSize ? spaceLeft : widget.maxSize);
    setState(() => _sizes.add(initial));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      // `scrollable: true` wraps the dialog body in a SingleChildScrollView
      // so a long group list (many players → many rows) scrolls inside the
      // dialog rather than overflowing the screen.  Combined with the
      // bounded-width SizedBox below, this also avoids the
      // "RenderShrinkWrappingViewport does not support returning intrinsic
      // dimensions" crash a bare ListView produces inside AlertDialog's
      // IntrinsicWidth wrapper.
      scrollable: true,
      title: Text('Edit ${widget.noun} Sizes'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each ${widget.noun.toLowerCase()} must have '
              '${[for (var n = widget.minSize; n <= widget.maxSize; n++) '$n']
                  .join(', ')} '
              'player${widget.maxSize == 1 ? '' : 's'}. Total must '
              'equal ${widget.totalPlayers}.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              'Auto-balance: ${widget.autoBalance.join(" + ")} '
              '= ${widget.totalPlayers}',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 12),
            // Group rows with steppers — built inline so the row height
            // grows with the group count rather than reserving a fixed
            // ListView height (which left a 280-px hole when only two
            // groups were configured and pushed the footer off-screen).
            for (int i = 0; i < _sizes.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              Row(children: [
                SizedBox(
                  width: 72,
                  child: Text('${widget.noun} ${i + 1}',
                      style: TextStyle(
                          color: _groupColors[i % _groupColors.length],
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  onPressed: _sizes[i] > 2 ? () => _dec(i) : null,
                ),
                SizedBox(
                  width: 28,
                  child: Center(
                    child: Text('${_sizes[i]}',
                        style: theme.textTheme.titleMedium),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  onPressed: _sizes[i] < 4 ? () => _inc(i) : null,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove group',
                  onPressed: _sizes.length > 1 ? () => _remove(i) : null,
                ),
              ]),
            ],
            const SizedBox(height: 8),
            Row(children: [
              TextButton.icon(
                icon : const Icon(Icons.add, size: 18),
                label: const Text('Add group'),
                onPressed: _addGroup,
              ),
              const Spacer(),
              Text(
                'Total: $_total / ${widget.totalPlayers}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _isValid
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ]),
            if (!_isValid && _remaining != 0) ...[
              const SizedBox(height: 4),
              Text(
                _remaining > 0
                    ? '$_remaining more player${_remaining == 1 ? "" : "s"} '
                      'to place — add a group or +1 to an existing one.'
                    : '${(-_remaining)} too many — -1 from a group or '
                      'remove one.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(<int>[]),
          child: const Text('Reset to default'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isValid
              ? () => Navigator.of(context).pop(_sizes)
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Step 5 — Review
// ===========================================================================

// ===========================================================================
// Step (Cup) — Review & save
// ===========================================================================

class _StepCupReview extends StatelessWidget {
  final String cupName;
  final String handicapMode;
  final int    netPercent;
  final List<({String name, String badge, String colour})> teams;
  final List<({String label, String course, DateTime date, String game})> rounds;
  final String? createError;

  const _StepCupReview({
    required this.cupName,
    required this.handicapMode,
    required this.netPercent,
    required this.teams,
    required this.rounds,
    this.createError,
  });

  static const _cardBorder  = Color(0xFFD3DED6);
  static const _warnBg      = Color(0xFFFDF3E7);
  static const _warnBorder  = Color(0xFFF0DCBE);
  static const _warnFg      = Color(0xFF8A5216);
  static const _pineChipBg  = Color(0xFFE4F2EA);
  static const _brightMint  = Color(0xFF3BD89A);

  Color _teamColour(String name) => _kCupColourChoices
      .firstWhere((e) => e.$1.toLowerCase() == name.toLowerCase(),
          orElse: () => _kCupColourChoices.first)
      .$2;

  String get _handicapShort {
    switch (handicapMode) {
      case 'gross':       return 'Gross';
      case 'strokes_off': return 'Strokes off low';
      default:            return netPercent < 100 ? 'Net $netPercent%' : 'Net';
    }
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return _pinnedStep(
      context,
      title: 'Review',
      subtitle: 'Check the cup over, then save it. The draft and one group '
          'build per round come next.',
      children: [
        // ── Cup card ──
        _card(children: [
          Text(cupName.isEmpty ? 'Untitled cup' : cupName,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('Team (Cup) Play · ${_handicapShort.toLowerCase()}',
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 12),
          Row(children: [
            for (int i = 0; i < teams.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _teamPill(context, teams[i])),
            ],
          ]),
        ]),
        // ── Rounds ──
        _sectionCard(context, 'Rounds', [
          for (int i = 0; i < rounds.length; i++)
            _roundRow(context, rounds[i], i > 0),
        ]),
        // ── Players todo (warns, doesn't block) ──
        _todoRow(context),
        // ── Scoring ──
        _sectionCard(context, 'Scoring', [
          _kv(context, 'Handicap', _handicapShort,
              sub: handicapMode == 'strokes_off'
                  ? 'Every golfer plays off the lowest index in the group'
                  : null,
              first: true),
        ]),
        // ── What happens after saving ──
        _sectionCard(context, 'What happens after saving', [
          _nextRow(context, 1, 'Draft the teams',
              'Add players to each side, then lock the draft.', first: true),
          _nextRow(context, 2, 'Build the groups',
              'One screen per group — golfers, tees and tee time. Repeats for each round.'),
          _nextRow(context, 3, 'Start Round 1',
              'Scoring opens once a group has its four.'),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Container(
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration:
                const BoxDecoration(color: _brightMint, shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 11, color: Color(0xFF08301F)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Everything here stays editable until Round 1 starts.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
        ]),
        if (createError != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(createError!,
                      style: TextStyle(
                          color: theme.colorScheme.onErrorContainer))),
            ]),
          ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _card({required List<Widget> children}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 11),
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _cardBorder),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _sectionCard(BuildContext context, String heading, List<Widget> rows) {
    final theme = Theme.of(context);
    return _card(children: [
      Text(heading.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              fontSize: 11)),
      const SizedBox(height: 8),
      ...rows,
    ]);
  }

  Widget _teamPill(BuildContext context, ({String name, String badge, String colour}) t) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
          color: const Color(0xFFF6F9F6), borderRadius: BorderRadius.circular(11)),
      child: Row(children: [
        Container(
          constraints: const BoxConstraints(minWidth: 22),
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: _teamColour(t.colour), borderRadius: BorderRadius.circular(7)),
          child: Text(t.badge,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11.5)),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text(t.colour,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11.5)),
          ]),
        ),
      ]),
    );
  }

  Widget _roundRow(BuildContext context,
      ({String label, String course, DateTime date, String game}) r, bool border) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: border
          ? const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFF1F5F1))))
          : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: _pineChipBg, borderRadius: BorderRadius.circular(9)),
          child: Text(r.label,
              style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.course,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(DateFormat('EEEE, MMMM d, yyyy').format(r.date),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            // Games wrap on their own line — a mixed cup can list several, which
            // a fixed right-side pill can't hold (it starved the course column
            // and overflowed).
            Text(r.game,
                style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  Widget _todoRow(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: _warnBg,
        border: Border.all(color: _warnBorder),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFB9791C)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('No players added yet',
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600, color: _warnFg)),
            const SizedBox(height: 1),
            Text('You can save now and draft later, or add players before Round 1.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: const Color(0xFF9A6B24), height: 1.4)),
          ]),
        ),
      ]),
    );
  }

  Widget _kv(BuildContext context, String k, String v, {String? sub, bool first = false}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: first
          ? null
          : const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFF1F5F1)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 96,
            child: Text(k,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(v,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            if (sub != null)
              Text(sub,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }

  Widget _nextRow(BuildContext context, int n, String title, String sub, {bool first = false}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: first
          ? null
          : const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFF1F5F1)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration:
              const BoxDecoration(color: _pineChipBg, shape: BoxShape.circle),
          child: Text('$n',
              style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(sub,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

class _Step5Review extends StatelessWidget {
  final bool               createNew;
  final String             tournamentName;
  final int                numRounds;
  final List<String>       tournamentActiveGames;
  final CourseInfo?        course;
  final DateTime           date;
  final List<String>       activeGames;
  final List<_RoundDraft>  additionalRounds;
  final List<CourseInfo>   courses;
  /// All players in drag/group order.
  final List<PlayerProfile> orderedPlayers;
  final Map<int, TeeInfo?> playerTees;
  final String?            createError;
  /// Group sizes the TD selected (may be the auto-balance or an
  /// override).  Passed in from the wizard parent so the Review step
  /// shows the same shape the TD actually saw + accepted in Step 3.
  final List<int>          groupSizes;
  /// Entry fee per side game, keyed by game id — so each game names its own
  /// price at review rather than being a bare chip. Entry is taken at signup,
  /// so by this point every game already has one.
  final Map<String, int>   sideGameFees;
  /// Championship entry per golfer, and the carve-out taken off the top.
  final int                championshipFee;
  final int                carvePct;
  /// Team Play only: how many golfers make a complete team. **A pair of two is
  /// complete** — it fields no phantom, because in fours the phantom is a
  /// handicap device for a team that still hits four balls and here it would
  /// be an imaginary partner taking half the shots. Null for every other shape,
  /// where the old fill-to-four rule stands.
  final int?               teamPlaySize;

  const _Step5Review({
    required this.createNew,
    required this.tournamentName,
    required this.numRounds,
    required this.tournamentActiveGames,
    required this.course,
    required this.date,
    required this.activeGames,
    required this.additionalRounds,
    required this.courses,
    required this.orderedPlayers,
    required this.playerTees,
    required this.groupSizes,
    this.sideGameFees   = const {},
    this.championshipFee = 0,
    this.carvePct        = 0,
    this.teamPlaySize,
    this.createError,
  });

  /// The name this game goes by everywhere — tab, review row, payout row and
  /// chat line. "Mini Singles Bracket", never "Match Play Foursome".
  static String _sideGameLabel(String id) => switch (id) {
        'irish_rumble' => 'Irish Rumble',
        'pink_ball'    => 'Pink Ball',
        'match_play'   => 'Mini Singles Bracket',
        'day_bet'      => 'Day bet · final round',
        _              => id,
      };

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final sizes       = groupSizes;
    final groupCount  = sizes.length;
    final gameLabels  = {
      for (final g in kGameCatalog) g.id: g.displayName,
      for (final (v, l) in kChampionshipGames) v: l,
    };
    final courseMap   = {for (final c in courses) c.id: c};

    return _pinnedStep(
      context,
      title: 'Review',
      subtitle: 'Tap "Create Tournament" to set up all foursomes and games.',
      children: [

        _ReviewCard(children: [
          _ReviewRow(Icons.emoji_events, 'Tournament',
              '${createNew ? "New — " : ""}$tournamentName'),
          if (createNew && numRounds > 1)
            _ReviewRow(Icons.repeat, 'Rounds', '$numRounds rounds'),
          _ReviewRow(Icons.golf_course,    'Round 1 Course',
              course?.name ?? '—'),
          _ReviewRow(Icons.calendar_today, 'Round 1 Date',
              DateFormat('MMMM d, yyyy').format(date)),
          for (int i = 0; i < additionalRounds.length; i++) ...[
            _ReviewRow(Icons.golf_course,
                'Round ${i + 2} Course',
                courseMap[additionalRounds[i].courseId]?.name ?? '—'),
            _ReviewRow(Icons.calendar_today,
                'Round ${i + 2} Date',
                DateFormat('MMMM d, yyyy').format(additionalRounds[i].date)),
          ],
          _ReviewRow(Icons.people,         'Players',
              '${orderedPlayers.length} players → $groupCount group(s)'),
          if (championshipFee > 0)
            _ReviewRow(
              Icons.emoji_events_outlined,
              'Championship',
              pooLine(championshipFee, orderedPlayers.length, field: true) +
                  (carvePct > 0
                      ? ' · $carvePct% carved for day 2'
                      : ''),
            ),
        ]),

        if (tournamentActiveGames.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Tournament Games',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 4,
            children: tournamentActiveGames
                .map((g) => GameChip(label: gameLabels[g] ?? g))
                .toList(),
          ),
        ],

        if (activeGames.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Side games',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          // ONE name per game, and each shows its fee. The shipped review
          // listed "Stroke Play Championship" under Tournament Games and
          // "Stroke Play" under Active Games — both true, and nothing
          // distinguished them.
          _ReviewCard(children: [
            for (final g in activeGames)
              _ReviewRow(
                Icons.sports_golf,
                _sideGameLabel(g),
                // The day bet is priced here; the rest are priced on their own
                // setup screens straight after Create, so say that rather than
                // reading "No entry" as though the game were free.
                (sideGameFees[g] ?? 0) > 0
                    ? '\$${sideGameFees[g]} entry'
                    : (sideGameFees.containsKey(g)
                        ? 'No entry'
                        : 'Entry set on its setup screen'),
              ),
          ]),
        ],

        // ── Foursome arrangement ──
        const SizedBox(height: 16),
        Text('Foursomes',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        ...List.generate(groupCount, (g) {
          final groupPlayers = orderedPlayers
              .asMap()
              .entries
              .where((e) => groupOf(e.key, sizes) == g + 1)
              .map((e) => e.value)
              .toList();
          final color = _groupColors[g % _groupColors.length];
          // A group is short only against the size its shape actually fills.
          // A pairs event fills to TWO, so a complete pair was being labelled
          // "+ 1 phantom" for being two golfers — which is the whole team.
          final needsPhantom = gr.groupNeedsPhantom(
              groupPlayers.length, teamPlaySize: teamPlaySize);

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                        color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text('Group ${g + 1}',
                        style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.bold, color: color)),
                    if (needsPhantom) ...[
                      const SizedBox(width: 8),
                      Text('+ 1 phantom',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ]),
                  const SizedBox(height: 6),
                  ...groupPlayers.map((p) {
                    final tee = playerTees[p.id];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        const Icon(Icons.person_outline, size: 15),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(p.name,
                              style: theme.textTheme.bodyMedium),
                        ),
                        if (tee != null)
                          Text(tee.teeName,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color:
                                      theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(width: 8),
                        Text('Index ${p.handicapIndex}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color:
                                    theme.colorScheme.onSurfaceVariant)),
                      ]),
                    );
                  }),
                ],
              ),
            ),
          );
        }),

        if (createError != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(createError!,
                    style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ]),
          ),
        ],

        const SizedBox(height: 80),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared review widgets
// ---------------------------------------------------------------------------

class _ReviewCard extends StatelessWidget {
  final List<Widget> children;
  const _ReviewCard({required this.children});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
}

class _ReviewRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  const _ReviewRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // NOT a ListTile: `trailing` takes width priority, so a long value
    // squeezed the title until it wrapped one character per line
    // ("Championship" running vertically down the card). A Row lets the label
    // keep the width it needs and the value wrap into the space that is left.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: Colors.grey),
        const SizedBox(width: 16),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Step 6 — Game Setup (shown after round is created)
// ===========================================================================

class _Step6GameSetup extends StatefulWidget {
  final Round       round;
  final int?        tournamentId;
  final String      tournamentName;
  final Set<String> activeGames;
  /// True when this tournament has Cup Play (team_cup) selected.
  final bool        isCupTournament;
  /// True when match play entry fee / payouts were entered in Step 4 and
  /// auto-applied to all groups — no per-group setup needed.
  final bool        matchPlayConfigured;

  const _Step6GameSetup({
    required this.round,
    this.tournamentId,
    this.tournamentName      = '',
    required this.activeGames,
    this.isCupTournament     = false,
    this.matchPlayConfigured = false,
  });

  @override
  State<_Step6GameSetup> createState() => _Step6GameSetupState();
}

class _Step6GameSetupState extends State<_Step6GameSetup> {
  /// Game IDs whose setup screen returned a save signal this session.  The
  /// _SetupButton flips from an empty circle to a filled flag once an ID
  /// lands in here so the user can see which configs they've already
  /// touched without re-tapping each card.
  final Set<String> _savedConfigs = <String>{};

  /// Foursome IDs whose Match Play / Three-Person Match setup returned a
  /// save signal this session.  Same idea as [_savedConfigs] but indexed
  /// by foursome (Match Play config is per-group, not per-game).
  final Set<int> _savedFoursomes = <int>{};

  @override
  void initState() {
    super.initState();
    // Push the just-created round into the shared RoundProvider so
    // downstream setup screens that read from it (notably Three-Person
    // Match, which derives its 3-player roster from
    // RoundProvider.round.foursomes) see real data instead of an empty
    // list.  Without this the 3-some setup screen showed "needs exactly
    // 3 players" even when the foursome was correctly built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rp = context.read<RoundProvider>();
      if (rp.round?.id != widget.round.id) {
        rp.loadRound(widget.round.id);
      }
    });
  }

  /// Push [page] and, if the user saved (the setup screen pops with `true`),
  /// mark [gameId] as configured so the icon updates.
  Future<void> _openSetup(String gameId, Widget page) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => page),
    );
    if (!mounted) return;
    if (result == true) {
      setState(() => _savedConfigs.add(gameId));
    }
  }

  /// Per-foursome variant of [_openSetup] for Match Play / Three-Person
  /// Match.  Pushes the right route based on foursome size.
  ///
  /// Note: both setup screens use `pushReplacementNamed` to jump straight
  /// to score entry after save (a casual-round convenience), so an
  /// await-for-pop signal never resolves here.  Instead we re-fetch the
  /// round when the user navigates back and inspect the foursome's
  /// `configuredGames` list to decide whether to flip the icon.
  Future<void> _openMatchPlaySetup(Foursome fs, List<Foursome> allFs) async {
    final isThreesome = fs.realPlayers.length == 3;
    final allIds  = allFs.map((f) => f.id).toList();
    final peerIds = allFs
        .where((f) =>
            f.id != fs.id && f.realPlayers.length == fs.realPlayers.length)
        .map((f) => f.id)
        .toList();
    // Ensure the RoundProvider has *this* round loaded before pushing.
    // The setup screen reads its roster from RoundProvider.round; without
    // this await the screen could mount before the post-frame load in
    // initState completes, see an empty foursome list, and leave the
    // Start Match button disabled with a "needs exactly 3 players"
    // warning even when the group is correctly built.
    final rp = context.read<RoundProvider>();
    if (rp.round?.id != widget.round.id) {
      await rp.loadRound(widget.round.id);
      if (!mounted) return;
    }
    // Note: pushNamed without a generic type because the wizard's
    // route generator builds MaterialPageRoute<dynamic>; declaring
    // <bool> here trips a runtime type cast.  We don't read the
    // result anyway — configuredGames is re-read from the round after
    // navigation.
    await Navigator.of(context).pushNamed(
      isThreesome ? '/three-person-match-setup' : '/match-play-setup',
      arguments: isThreesome
          ? fs.id
          : {
              'foursomeId'     : fs.id,
              'allMatchPlayIds': allIds,
              'peerIds'        : peerIds,
            },
    );
    if (!mounted) return;
    // Reload the round so configuredGames reflects whatever the user
    // saved (or didn't).  If the foursome now has match_play or
    // three_person_match in configured_games, flip the icon.
    await rp.loadRound(widget.round.id);
    if (!mounted) return;
    final refreshed = rp.round?.foursomes
        .where((f) => f.id == fs.id)
        .firstOrNull;
    final isConfigured = refreshed != null &&
        (refreshed.configuredGames.contains('match_play') ||
         refreshed.configuredGames.contains('three_person_match'));
    if (isConfigured) {
      setState(() => _savedFoursomes.add(fs.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final round          = widget.round;
    final activeGames    = widget.activeGames;
    final tournamentId   = widget.tournamentId;
    final tournamentName = widget.tournamentName;
    final isCupTournament     = widget.isCupTournament;
    final matchPlayConfigured = widget.matchPlayConfigured;
    final roundId        = round.id;
    final hasIrishRumble = activeGames.contains(GameIds.irishRumble);
    final hasStrokePlay  = activeGames.contains(GameIds.strokePlay);
    final hasPinkBall    = activeGames.contains(GameIds.pinkBall);
    // hasMatchPlay covers both the cup-style singles game and the new
    // single-pick match-play tournament game.  When match_play is the
    // active slug, each foursome's "Set Up" button below routes to
    // /three-person-match-setup for 3-player groups and /match-play-setup
    // for 4-player groups.
    final hasMatchPlay   = activeGames.contains(GameIds.singlesNassau) ||
                           activeGames.contains(GameIds.matchPlay);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tournament created',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          // A confirmation, not a to-do list. Every game already carries its
          // entry fee — that was collected on the side-game step, at signup —
          // so nothing here is waiting on money. What is left is rules: the
          // ball's name, how many balls count, the bracket's seeds.
          Text(
            isCupTournament
                ? 'Draft your teams before the first round.'
                : 'Every game already has its entry fee. What is left is the '
                  'rules — the ball\'s name, how many balls count, the seeds.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),

          // ── Cup Play setup ─────────────────────────────────────────────────
          if (isCupTournament && tournamentId != null) ...[
            _SetupButton(
              icon : Icons.emoji_events_outlined,
              label: 'Set Up Cup Teams & Draft',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RyderCupDraftScreen(
                  tournamentId  : tournamentId!,
                  tournamentName: tournamentName,
                ),
              )),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Create your teams and draft players before the tournament begins.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (hasIrishRumble) ...[
            _SetupButton(
              icon : Icons.flag_circle_outlined,
              label: 'Irish Rumble',
              configured: _savedConfigs.contains(GameIds.irishRumble),
              stateLabel: _savedConfigs.contains(GameIds.irishRumble)
                  ? 'Set' : 'Rules not set',
              onTap: () => _openSetup(
                GameIds.irishRumble,
                IrishRumbleSetupScreen(roundId: roundId),
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (hasStrokePlay) ...[
            _SetupButton(
              icon : Icons.leaderboard_outlined,
              label: 'Stroke Play',
              configured: _savedConfigs.contains(GameIds.strokePlay),
              stateLabel: _savedConfigs.contains(GameIds.strokePlay)
                  ? 'Set' : 'Not set',
              onTap: () => _openSetup(
                GameIds.strokePlay,
                LowNetSetupScreen(roundId: roundId),
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (hasPinkBall) ...[
            _SetupButton(
              icon : Icons.circle_outlined,
              label: 'Pink Ball',
              stateLabel: _savedConfigs.contains(GameIds.pinkBall)
                  ? 'Named' : 'Needs a name',
              configured: _savedConfigs.contains(GameIds.pinkBall),
              onTap: () => _openSetup(
                GameIds.pinkBall,
                PinkBallSetupScreen(roundId: roundId),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Match Play: auto-configured or needs per-group setup
          if (hasMatchPlay) ...[
            Text('Mini Singles Brackets',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            if (matchPlayConfigured) ...[
              // Entry fee + payouts were applied to all groups in Step 4.
              Row(children: [
                Icon(Icons.check_circle_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text('All brackets configured',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.primary)),
              ]),
              const SizedBox(height: 4),
              Text(
                'Seedings can still be adjusted from the round screen.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ] else ...[
              Text(
                'Set entry fee and payouts for each group:',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              for (final fs in round.foursomes) ...[
                _SetupButton(
                  icon : Icons.sports_golf,
                  label: 'Set Up ${fs.label}',
                  // Empty circle before this group's bracket / 3-some
                  // config is saved, filled flag after.  Per-foursome
                  // state since Match Play config is per-group.
                  configured: _savedFoursomes.contains(fs.id),
                  onTap: () =>
                      _openMatchPlaySetup(fs, round.foursomes),
                ),
                const SizedBox(height: 8),
              ],        // closes for [...]
            ],          // closes else [...]
          ],            // closes if (hasMatchPlay) [...]

          const SizedBox(height: 8),
          Text(
            'You can also adjust these settings later from the round screen.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SetupButton extends StatelessWidget {
  /// Icon shown when [configured] is null (the side-rail icon, e.g. for
  /// Cup Teams or Stroke Play that don't yet have configured-state plumbed
  /// through).  When [configured] is non-null, an empty-circle /
  /// filled-flag icon takes precedence so the user can see at a glance
  /// whether each game has been set up.
  final IconData icon;
  final String   label;
  final VoidCallback onTap;

  /// null → use [icon] (legacy behavior).
  /// false → not configured yet.
  /// true  → this game's setup has been saved.
  final bool? configured;

  /// What this row's state IS, in words — "Set · \$10" or "Not set".
  ///
  /// The shipped build drew an empty radio circle here. The circles were
  /// progress, not selection, but they read as a pick list and Done was
  /// enabled either way. Words cannot be misread as a choice.
  final String? stateLabel;

  const _SetupButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.configured,
    this.stateLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final scheme = theme.colorScheme;
    final done   = configured == true;
    return Card(
      child: ListTile(
        leading: Icon(
          configured == null ? icon : (done ? Icons.check_circle : icon),
          color: done ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (stateLabel != null)
            Text(stateLabel!,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: done ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: done ? FontWeight.w700 : FontWeight.w500)),
          const Icon(Icons.chevron_right),
        ]),
        onTap: onTap,
      ),
    );
  }
}
