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
  handicap,     // Handicap mode (+ net double-bogey cap)
  cupDesign,    // Cup: team count + colours
  cupGamePlan,  // Cup: per-round game plan
  sideGame,     // Cup: field-wide side game (struck when format is exclusive)
  players,      // Non-cup: player selection
  groups,       // Non-cup: group assignment + tees
  games,        // Non-cup: side games + buy-ins
  review,       // Review → create
}

/// Who is competing — the "scoring unit" the whole flow derives from.  Cup and
/// solo are wired; pair/quad are drawn but staged (no pair/quad scoring engine
/// yet), so the picker shows them disabled.
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
    return const [
      _StepKind.typeFormat,
      _StepKind.eventDetails,
      _StepKind.handicap,
      _StepKind.players,
      _StepKind.groups,
      _StepKind.games,
      _StepKind.review,
    ];
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
  // Who is competing + the format that sets the scoring unit.  Defaults to a
  // cup on Triple Cup, matching the type-first design.  Selecting a type/format
  // rewrites the championship entry in _tournamentActiveGames (see
  // _applyTypeFormat).  The cup format is informational for now — per-round
  // "Games by round" remains the source of truth; solo format is functional
  // (it chooses the championship game).
  _EventType _eventType  = _EventType.cup;
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
  final Set<String> _tournamentActiveGames = {
    GameIds.teamCup,
    GameIds.championshipStrokePlay,
  };

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
  String            _handicapMode   = 'strokes_off';
  bool              _handicapModeTouched = false;
  int               _netPercent     = 100;
  bool              _netMaxDoubleBogey = true;

  // ---- Step 4: Side-game selection + buy-in config ----
  final Set<String> _activeGames = {}; // no defaults — user picks

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
      case _EventType.pair:
      case _EventType.quad:
        // Not wired yet — the picker keeps these disabled.
        break;
    }
    if (!_handicapModeTouched) _handicapMode = _defaultHandicapForFormat();
  }

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
        return 'Two-man team';
      case _EventType.quad:
        return 'Four-man team';
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
    });
  }

  /// Remove round (2..N) at [additionalIndex] into [_additionalRounds].  Round 1
  /// is the event itself and cannot be removed.
  void _removeRound(int additionalIndex) {
    setState(() {
      _additionalRounds.removeAt(additionalIndex);
      _numRounds = _additionalRounds.length + 1;
    });
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
              (label: 'Side games', sub: 'Field games and buy-ins', perRound: false),
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
        pointsTable : const {
          'albatross': 5, 'eagle': 4, 'birdie': 3,
          'par': 2, 'bogey': 1, 'double': 0,
        },
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
    for (final id in _orderedPlayerIds) {
      final tee = _playerTees[id];
      if (tee == null) throw Exception('Player $id has no tee selected.');
      final entry = <String, int>{'player_id': id, 'tee_id': tee.id};
      if (overrideSizes != null) {
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
          title: Text(_isPostCreate
              ? (_isCupTournament ? 'Tournament Created' : 'Game Setup')
              : (_isCupTournament
                  ? 'New Cup Tournament  (${_step + 1} of $_totalSteps)'
                  : 'New Round  (${_step + 1} of $_totalSteps)')),
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
      case _StepKind.games:
        return _Step4Games(
          activeGames               : _activeGames,
          groupSizeList             : _effectiveGroupSizes,
          onToggleGame              : (g, on) => setState(() {
            on ? _activeGames.add(g) : _activeGames.remove(g);
          }),
          hasTournamentLowNet       : _tournamentActiveGames.contains(GameIds.championshipStrokePlay),
          hasTournamentStableford   : _tournamentActiveGames.contains(GameIds.championshipStableford),
          numPlayers                : _selectedIds.length,
          initialLowNetFee          : _lowNetEntryFee,
          initialLowNetNumPayouts   : _lowNetNumPayouts,
          initialLowNetPayouts      : _lowNetPayouts,
          onLowNetConfigChanged     : (fee, nPays, pays) => setState(() {
            _lowNetEntryFee    = fee;
            _lowNetNumPayouts  = nPays;
            _lowNetPayouts     = pays;
          }),
          hasTournamentMatchPlay    : _tournamentActiveGames.contains(GameIds.singlesNassau),
          initialMatchPlayFee       : _matchPlayEntryFee,
          initialMatchPlayNumPayouts: _matchPlayNumPayouts,
          initialMatchPlayPayouts   : _matchPlayPayouts,
          onMatchPlayConfigChanged  : (fee, nPays, pays) => setState(() {
            _matchPlayEntryFee    = fee;
            _matchPlayNumPayouts  = nPays;
            _matchPlayPayouts     = pays;
          }),
          hasAnyTournamentGame      : _tournamentActiveGames.isNotEmpty,
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
              label: Text(isCupTournament ? 'Save & draft teams' : 'Create Round'),
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
            'Every golfer for himself, against the field.', 'Golfer'),
        _typeCard(context, _EventType.pair, 'Two-man team',
            'Pairs against the field. Chapman, alternate shot, best ball.', 'Pair',
            enabled: false),
        _typeCard(context, _EventType.quad, 'Four-man team',
            'The whole group against the field. Scramble, shamble, bramble.', 'Group',
            enabled: false),
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
      case _EventType.pair: return 'Two-man format';
      case _EventType.quad: return 'Four-man format';
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
    final autoBalance = gr.groupSizes(orderedPlayers.length);
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
          'default group breakdown. Pick each player\'s tee on the right.',
      children: [
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

                  // Only show tees that match this player's sex, plus unisex.
                  final playerTeeOptions = courseTees
                      .where((t) => t.sex == player.sex || t.sex == null)
                      .toList();

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
                              DropdownButton<TeeInfo>(
                                value: (tee != null &&
                                        playerTeeOptions.contains(tee))
                                    ? tee
                                    : null,
                                isDense: true,
                                underline: const SizedBox.shrink(),
                                hint: Text('Pick tee',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant)),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface),
                                items: playerTeeOptions
                                    .map((t) => DropdownMenuItem(
                                          value: t,
                                          child: Text(t.teeName),
                                        ))
                                    .toList(),
                                onChanged: (t) {
                                  if (t != null) onPickTee(player.id, t);
                                },
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
            'Groups with fewer than 4 players will have a phantom added '
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
        'One marked ball rotates through the group and must survive the round.',
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
// NOTE (scaffold ahead of scoring): the one-ball formats (Chapman, two-man
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
  ('two_man_chapman',  'Two-man Chapman',   '2 v 2 inside a foursome — one ball a pair',
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
          'Chapman, two-man scramble and scramble are drawn but not scored yet; '
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
  const _GroupSizeEditor({
    required this.initialSizes,
    required this.autoBalance,
    required this.totalPlayers,
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
                         _sizes.every((s) => s >= 2 && s <= 4) &&
                         _sizes.isNotEmpty;

  void _inc(int idx) {
    if (_sizes[idx] >= 4) return;
    setState(() => _sizes[idx] = _sizes[idx] + 1);
  }
  void _dec(int idx) {
    if (_sizes[idx] <= 2) return;
    setState(() => _sizes[idx] = _sizes[idx] - 1);
  }
  void _remove(int idx) {
    if (_sizes.length <= 1) return;
    setState(() => _sizes.removeAt(idx));
  }
  void _addGroup() {
    // Default new group to 4 when possible; otherwise whatever fits
    // up to 4 (and at least 2, else don't add).
    final spaceLeft = widget.totalPlayers - _total;
    final initial   = spaceLeft >= 4 ? 4 : (spaceLeft >= 2 ? spaceLeft : 4);
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
      title: const Text('Edit Group Sizes'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each group must have 2, 3, or 4 players. Total must '
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
                  child: Text('Group ${i + 1}',
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
// Step 4 — Game Selection
// ===========================================================================

class _Step4Games extends StatefulWidget {
  final Set<String>   activeGames;
  final List<int>     groupSizeList;
  final void Function(String game, bool on) onToggleGame;
  /// When true, the Stroke Play Championship buy-in section is shown first.
  final bool          hasTournamentLowNet;
  /// Stableford Championship selected — reuses the same buy-in UI/state, but
  /// the header reads "Stableford" and it's posted to the Stableford config.
  final bool          hasTournamentStableford;
  /// Total number of selected players — pool multiplier for the championship.
  final int           numPlayers;
  // Stroke Play Championship buy-in
  final int           initialLowNetFee;
  final int           initialLowNetNumPayouts;
  final List<int>     initialLowNetPayouts;
  final void Function(int fee, int numPayouts, List<int> payouts)
      onLowNetConfigChanged;
  /// When true, the Match Play buy-in section is shown at the top of this step.
  final bool          hasTournamentMatchPlay;
  // Match Play buy-in — collected here and applied to all groups on creation.
  final int           initialMatchPlayFee;
  final int           initialMatchPlayNumPayouts;
  final List<int>     initialMatchPlayPayouts;
  final void Function(int fee, int numPayouts, List<int> payouts)
      onMatchPlayConfigChanged;
  /// True when ANY championship game (stroke play, stableford, singles
  /// nassau, …) was picked back at step 0.  When false AND no side
  /// games are selected, this step shows a warning explaining that the
  /// tournament needs at least one game to proceed.
  final bool          hasAnyTournamentGame;

  const _Step4Games({
    required this.activeGames,
    required this.groupSizeList,
    required this.onToggleGame,
    this.hasTournamentLowNet        = false,
    this.hasTournamentStableford    = false,
    this.numPlayers                 = 0,
    this.initialLowNetFee           = 0,
    this.initialLowNetNumPayouts    = 3,
    this.initialLowNetPayouts       = const [0, 0, 0, 0],
    required this.onLowNetConfigChanged,
    this.hasTournamentMatchPlay     = false,
    this.initialMatchPlayFee        = 0,
    this.initialMatchPlayNumPayouts = 3,
    this.initialMatchPlayPayouts    = const [0, 0, 0, 0],
    required this.onMatchPlayConfigChanged,
    this.hasAnyTournamentGame       = false,
  });

  @override
  State<_Step4Games> createState() => _Step4GamesState();
}

class _Step4GamesState extends State<_Step4Games> {
  // ── Low Net (Stroke Play Championship) controllers ──
  late final TextEditingController _lowNetFeeCtrl;
  int _lowNetNumPayouts = 3;
  late final List<TextEditingController> _lowNetPayoutCtrls;

  // ── Match Play controllers ──
  late final TextEditingController _feeCtrl;
  int _numPayouts = 3;
  late final List<TextEditingController> _payoutCtrls;

  @override
  void initState() {
    super.initState();

    // Low Net
    _lowNetFeeCtrl = TextEditingController(
        text: widget.initialLowNetFee == 0 ? '' : '${widget.initialLowNetFee}');
    _lowNetNumPayouts = widget.initialLowNetNumPayouts;
    _lowNetPayoutCtrls = List.generate(4, (i) {
      final v = i < widget.initialLowNetPayouts.length
          ? widget.initialLowNetPayouts[i]
          : 0;
      return TextEditingController(text: v == 0 ? '' : '$v');
    });
    _lowNetFeeCtrl.addListener(_notifyLowNet);
    for (final c in _lowNetPayoutCtrls) c.addListener(_notifyLowNet);

    // Match Play
    _feeCtrl    = TextEditingController(
        text: widget.initialMatchPlayFee == 0 ? '' : '${widget.initialMatchPlayFee}');
    _numPayouts = widget.initialMatchPlayNumPayouts;
    _payoutCtrls = List.generate(4, (i) {
      final v = i < widget.initialMatchPlayPayouts.length
          ? widget.initialMatchPlayPayouts[i]
          : 0;
      return TextEditingController(text: v == 0 ? '' : '$v');
    });
    _feeCtrl.addListener(_notify);
    for (final c in _payoutCtrls) c.addListener(_notify);
  }

  @override
  void dispose() {
    _lowNetFeeCtrl.dispose();
    for (final c in _lowNetPayoutCtrls) c.dispose();
    _feeCtrl.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  void _notifyLowNet() {
    final fee     = int.tryParse(_lowNetFeeCtrl.text.trim()) ?? 0;
    final payouts = _lowNetPayoutCtrls
        .map((c) => int.tryParse(c.text.trim()) ?? 0)
        .toList();
    widget.onLowNetConfigChanged(fee, _lowNetNumPayouts, payouts);
  }

  void _suggestLowNetPayouts() {
    final fee  = int.tryParse(_lowNetFeeCtrl.text.trim()) ?? 0;
    final pool = fee * widget.numPlayers;
    if (pool <= 0) return;
    final suggested = suggestPayouts(pool, _lowNetNumPayouts);
    for (int i = 0; i < 4; i++) {
      _lowNetPayoutCtrls[i].text = suggested[i] == 0 ? '' : '${suggested[i]}';
    }
    setState(() {});
    _notifyLowNet();
  }

  void _notify() {
    final fee     = int.tryParse(_feeCtrl.text.trim()) ?? 0;
    final payouts = _payoutCtrls
        .map((c) => int.tryParse(c.text.trim()) ?? 0)
        .toList();
    widget.onMatchPlayConfigChanged(fee, _numPayouts, payouts);
  }

  void _suggestPayoutsWizard() {
    final fee    = int.tryParse(_feeCtrl.text.trim()) ?? 0;
    final nFours = widget.groupSizeList.where((s) => s == 4).length;
    final pool   = fee * (nFours > 0 ? 4 : 3);
    if (pool <= 0) return;
    final suggested = suggestPayouts(pool, _numPayouts);
    for (int i = 0; i < 4; i++) {
      _payoutCtrls[i].text = suggested[i] == 0 ? '' : '${suggested[i]}';
    }
    setState(() {});
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final nFours     = widget.groupSizeList.where((s) => s == 4).length;
    final nThrees    = widget.groupSizeList.where((s) => s == 3).length;
    final groupCount = widget.groupSizeList.length;

    final parts = <String>[];
    if (nFours  > 0) parts.add('$nFours foursome${nFours  == 1 ? '' : 's'}');
    if (nThrees > 0) parts.add('$nThrees threesome${nThrees == 1 ? '' : 's'}');
    final groupSummary =
        '$groupCount group${groupCount == 1 ? '' : 's'}: ${parts.join(', ')}';

    final fee           = int.tryParse(_feeCtrl.text.trim()) ?? 0;
    // Pool for balance / auto-suggest: prefer foursome pool, fall back to threesome.
    final poolForSuggest = fee * (nFours > 0 ? 4 : 3);

    final lowNetFee      = int.tryParse(_lowNetFeeCtrl.text.trim()) ?? 0;
    final lowNetPool     = lowNetFee * widget.numPlayers;

    // Single source of truth for "no game configured anywhere".  Both
    // championships (step 0) and side games (this step) count.  The
    // wizard footer disables Next/Create under the same condition.
    final hasAnyGame = widget.hasAnyTournamentGame ||
        widget.activeGames.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        if (!hasAnyGame) ...[
          const InlineMessage(
            kind: InlineMessageKind.warn,
            text: 'Pick at least one side game below, or go back to '
                'step 1 and pick a championship game (Stroke Play '
                'or Cup Play).  A tournament needs at '
                'least one game.',
          ),
          const SizedBox(height: 16),
        ],

        // ── Championship Buy-In (Stroke Play or Stableford) ────────────────────
        if (widget.hasTournamentLowNet || widget.hasTournamentStableford) ...[
          Text(widget.hasTournamentStableford
                  ? 'Stableford Championship'
                  : 'Stroke Play Championship',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Entry fee and payouts applied to the tournament. '
            'Leave blank to configure later.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),

          // Entry fee
          GolfTextField(
            controller: _lowNetFeeCtrl,
            label: 'Entry fee per player (\$)',
            prefixIcon: Icons.attach_money,
            keyboardType: TextInputType.number,
          ),
          if (lowNetFee > 0 && widget.numPlayers > 0) ...[
            const SizedBox(height: 6),
            Text(
              'Total pool: \$${lowNetFee * widget.numPlayers} '
              '(${widget.numPlayers} players × \$$lowNetFee)',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),

          PayoutConfigField(
            pool:                lowNetPool,
            numPayouts:          _lowNetNumPayouts,
            payoutCtrls:         _lowNetPayoutCtrls,
            onNumPayoutsChanged: (n) {
              setState(() => _lowNetNumPayouts = n);
              _notifyLowNet();
            },
            onPayoutChanged: _notifyLowNet,
            onSuggest:       _suggestLowNetPayouts,
          ),

          const Divider(height: 28),
        ],

        // ── Match Play Buy-In (shown first when tournament includes match play) ──
        if (widget.hasTournamentMatchPlay) ...[
          Text('Mini Singles Buy-In',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Entry fee and payouts applied to all groups on creation. '
            'Leave blank to configure each group individually after creation.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),

          // Entry fee
          GolfTextField(
            controller: _feeCtrl,
            label: 'Entry fee per player (\$)',
            prefixIcon: Icons.attach_money,
            keyboardType: TextInputType.number,
          ),
          if (fee > 0) ...[
            const SizedBox(height: 6),
            if (nFours > 0)
              Text(
                'Foursomes pool: \$${fee * 4} per group',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            if (nThrees > 0)
              Text(
                'Threesomes pool: \$${fee * 3} per group',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
          const SizedBox(height: 16),

          // Shared payout config widget
          PayoutConfigField(
            pool:                poolForSuggest,
            numPayouts:          _numPayouts,
            payoutCtrls:         _payoutCtrls,
            onNumPayoutsChanged: (n) { setState(() => _numPayouts = n); _notify(); },
            onPayoutChanged:     _notify,
            onSuggest:           _suggestPayoutsWizard,
          ),

          const Divider(height: 28),
        ],

        // ── Side Games ────────────────────────────────────────────────────────
        Text('Side Games', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Optional — pick side games to run alongside the main tournament.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          groupSummary,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),

        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final meta in tournamentRoundGames)
              GameSelectableChip(
                gameId:     meta.id,
                selected:   widget.activeGames.contains(meta.id),
                onSelected: (v) => widget.onToggleGame(meta.id, v),
              ),
          ],
        ),

        const SizedBox(height: 16),
      ]),
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
    this.createError,
  });

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
      subtitle: 'Tap "Create Round" to set up all foursomes and games.',
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
          Text('Active Games',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 4,
            children: activeGames
                .map((g) => GameChip(label: gameLabels[g] ?? g))
                .toList(),
          ),
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
          final needsPhantom = groupPlayers.length < 4;

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
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: Icon(icon, size: 20, color: Colors.grey),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: Text(value,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Colors.grey)),
      );
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
          Text('Round created!',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Configure your games below before players start entering scores.',
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
              label: 'Configure Irish Rumble',
              configured: _savedConfigs.contains(GameIds.irishRumble),
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
              label: 'Configure Stroke Play',
              configured: _savedConfigs.contains(GameIds.strokePlay),
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
              label: 'Configure Pink Ball',
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
  /// false → show an empty circle (this game hasn't been configured yet).
  /// true  → show a filled flag (this game's setup has been saved).
  final bool? configured;

  const _SetupButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.configured,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final IconData leading;
    final Color    leadingColor;
    if (configured == null) {
      leading      = icon;
      leadingColor = scheme.primary;
    } else if (configured!) {
      leading      = Icons.flag_circle;
      leadingColor = scheme.primary;
    } else {
      leading      = Icons.circle_outlined;
      leadingColor = scheme.onSurfaceVariant;
    }
    return Card(
      child: ListTile(
        leading: Icon(leading, color: leadingColor),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
