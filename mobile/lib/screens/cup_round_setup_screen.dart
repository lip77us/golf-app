/// cup_round_setup_screen.dart
///
/// Phase 3 of the Cup tournament lifecycle.
/// Entry: push with (roundId, tournamentId, roundNumber, courseName).
/// The screen builds foursomes one at a time, enforcing team composition
/// rules, and finishes by calling setupRound + postRyderCupRoundSetup +
/// setTeeTimes on the backend.
///
/// Composition rules
/// -----------------
///   Irish Rumble  → 4 players, ALL from the same team
///   Four Ball    → 4 players (2+2), or 3 players (1+2 / 2+1) — solo side gets a phantom
///   Four Ball Quota→ 4 players (2+2), or 3 players (1+2 / 2+1) — solo side gets a phantom
///   Singles       → 2 OR 4 players, split evenly (1+1 or 2+2)
///
/// For a 4-player Singles group the user additionally pairs each Team-A
/// player with a Team-B player so the scoreboard knows who plays whom.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../utils/cup_colors.dart';
import '../utils/grouping.dart';
import '../widgets/error_view.dart';
import '../widgets/irish_rumble_variant.dart';
import '../widgets/tee_assignment.dart' show TeePicker;

// ---------------------------------------------------------------------------
// Game choices (same IDs as the Django backend)
// ---------------------------------------------------------------------------

const _kCupGames = [
  ('nassau',          'Four Ball (Nassau)',        Icons.people),
  ('quota_nassau',    'Four Ball Quota (Nassau)',  Icons.calculate),
  ('irish_rumble',    'Irish Rumble',             Icons.flag),
  ('singles_nassau',  'Singles Nassau (F9/B9/All)', Icons.person),
  ('singles_18',      '18-Hole Singles',          Icons.sports_golf),
];

String _gameLabel(String id) {
  // triple_cup is armed via the round-format toggle, not the per-group game
  // picker, so it isn't in _kCupGames — map it explicitly rather than letting
  // the fallback render the raw slug.
  if (id == 'triple_cup') return 'Triple Cup';
  return _kCupGames
      .firstWhere((g) => g.$1 == id, orElse: () => (id, id, Icons.sports_golf))
      .$2;
}

/// Minutes between consecutive groups' tee times.  A course property in the
/// full design (set once, remembered) — a constant for now; the group builder
/// proposes previous-group + this interval so the TD rarely touches it.
const int _kTeeInterval = 10;

/// "HH:MM" (24h) → a friendly "9:10 AM".  Falls back to the raw string if it
/// can't be parsed.
String _friendlyTeeTime(String hhmm) {
  final t = _parseTeeTime(hhmm);
  if (t == null) return hhmm;
  final h12 = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  final ampm = t.period == DayPeriod.am ? 'AM' : 'PM';
  return '$h12:${t.minute.toString().padLeft(2, '0')} $ampm';
}

/// Adds [deltaMin] to an "HH:MM" string, clamped to the same day, returning
/// "HH:MM".  Used by the tee-time ±5 steppers.
String _shiftTeeTime(String hhmm, int deltaMin) {
  final t = _parseTeeTime(hhmm) ?? const TimeOfDay(hour: 8, minute: 0);
  var mins = (t.hour * 60 + t.minute + deltaMin);
  mins = mins.clamp(0, 23 * 60 + 59);
  return _formatTeeTime(TimeOfDay(hour: mins ~/ 60, minute: mins % 60));
}

/// Formats a [TimeOfDay] as a zero-padded "HH:MM" string — the only format
/// accepted by the backend's `TimeField` serializer.
String _formatTeeTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';

/// Parses an "HH:MM" or "HH:MM:SS" string back into a [TimeOfDay].  Returns
/// null on any malformed input so the caller can fall back to a sensible
/// default when opening the time picker.
TimeOfDay? _parseTeeTime(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  final parts = s.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return TimeOfDay(hour: h, minute: m);
}

/// Opens the platform time picker and returns the result formatted as
/// "HH:MM", or null if the user cancelled.  Centralised so every entry
/// point produces the same backend-friendly string.
Future<String?> _pickTeeTime(BuildContext context, String? initial) async {
  final result = await showTimePicker(
    context: context,
    initialTime: _parseTeeTime(initial) ?? const TimeOfDay(hour: 8, minute: 0),
  );
  return result == null ? null : _formatTeeTime(result);
}

// ---------------------------------------------------------------------------
// Data holder for one completed foursome draft
// ---------------------------------------------------------------------------

class _FoursomeDraft {
  final String           gameType;
  final List<int>        playerIds;   // in submission order (group1 first, etc.)
  final Map<int, int>    playerTees;  // playerId → teeId
  final String?          teeTime;     // 'HH:MM' or null
  final double           pointValue;  // cup points per segment win (overrides round-level)
  // For 4-player Singles: pairs of (team-A playerId, team-B playerId)
  final List<(int, int)> singlesMatchups;

  const _FoursomeDraft({
    required this.gameType,
    required this.playerIds,
    required this.playerTees,
    this.teeTime,
    this.pointValue = 1.0,
    this.singlesMatchups = const [],
  });
}

// ---------------------------------------------------------------------------
// Main screen
// ---------------------------------------------------------------------------

class CupRoundSetupScreen extends StatefulWidget {
  final int          roundId;
  final int          tournamentId;
  final int          roundNumber;
  final int          courseId;
  final String       courseName;
  /// Game types configured in the wizard for this round (may be empty for
  /// tournaments created before this field was saved).  When non-empty the
  /// game-picker is filtered to only these options; when exactly one game is
  /// in the list it is auto-selected and the picker step is skipped entirely.
  final List<String> availableGames;
  /// Cup point values per game type, set at wizard time.
  /// e.g. {'nassau': 1.0, 'singles': 2.0}
  /// Applied automatically when committing each foursome — no per-foursome
  /// text field is shown when this is non-empty.
  final Map<String, double> gamePointValues;
  /// Mixed-cup per-game plan (foursome-equivalent units) — how many of each
  /// game the wizard sized this round for.  Drives the worklist header ("what's
  /// left to build").  Empty for Triple Cup / legacy rounds.
  final Map<String, int> cupGroupCounts;

  const CupRoundSetupScreen({
    super.key,
    required this.roundId,
    required this.tournamentId,
    required this.roundNumber,
    required this.courseId,
    required this.courseName,
    this.availableGames  = const [],
    this.gamePointValues = const {},
    this.cupGroupCounts  = const {},
  });

  @override
  State<CupRoundSetupScreen> createState() => _CupRoundSetupScreenState();
}

// The group builder collapses the old players → tees → teeTime steps into one
// `group` card (golfers with index + inline tees + a tee-time stepper).
enum _BuildStep { gameType, group, matchups, review }

class _CupRoundSetupScreenState extends State<CupRoundSetupScreen> {
  // ── Loaded data ────────────────────────────────────────────────────────────
  TeamTournamentSummary? _cup;
  List<TeeInfo>          _courseTees = [];
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;

  // ── Build state ────────────────────────────────────────────────────────────
  _BuildStep _buildStep = _BuildStep.gameType;

  /// Round-level preset.  'custom' lets the admin pick a game type per
  /// foursome (legacy behaviour).  'triple_cup' locks every foursome
  /// to the Triple Cup format ("One Day Ryder Cup") — the wizard
  /// skips the per-foursome game-type picker and the backend
  /// auto-fills game_type='triple_cup' from the round_format field.
  /// Locked once the first foursome is committed so we can't end up
  /// with mixed formats in the payload.
  String _roundFormat = 'custom';

  // Current-foursome draft
  String?        _gameType;
  final Set<int> _selectedIds = {};
  int?           _irishRumbleTeamIdx; // which team (0 or 1) for Irish Rumble

  // Irish Rumble is a ROUND-level game (one IrishRumbleConfig per round), so the
  // balls variant is chosen once and applies to every IR match in the round.
  // 'classic' | 'arizona_shuffle' | 'shuffle' | 'custom'.
  String    _irVariant     = 'classic';
  List<int> _irCustomBalls = List.filled(18, 2);
  // Per-player tee selection for the current foursome draft: playerId → teeId
  final Map<int, int> _playerTees = {};
  final _teeTimeCtrl   = TextEditingController();
  // For 4-player singles matchup builder:
  // _matchupA[i] = team-A player paired with _matchupB[i]
  final List<int?> _matchupA = [];
  final List<int?> _matchupB = [];

  // Completed foursomes
  final List<_FoursomeDraft> _foursomes = [];

  // ── Submission state ───────────────────────────────────────────────────────
  bool    _submitting   = false;
  String? _submitError;

  // ── Derived helpers ────────────────────────────────────────────────────────

  ApiClient get _client => context.read<AuthProvider>().client;

  List<CupTeam> get _teams => _cup?.teams ?? [];

  /// The drafted roster size (all sides' players).
  int get _rosterSize =>
      _cup == null ? 0 : _cup!.teams.expand((t) => t.players).length;

  /// Per-hole pars (18) from the first course tee, for the Irish Rumble
  /// par-based / custom variant preview.  Falls back to all-par-4 if the tee
  /// carries no hole data.
  List<int> get _holePars {
    if (_courseTees.isEmpty) return List.filled(18, 4);
    final holes = [..._courseTees.first.holes]
      ..sort((a, b) => ((a['number'] as num?) ?? 0)
          .compareTo((b['number'] as num?) ?? 0));
    if (holes.length < 18) return List.filled(18, 4);
    return [for (final h in holes.take(18)) (h['par'] as num?)?.toInt() ?? 4];
  }

  /// Group count DERIVED from the roster — never entered.  Same helper the
  /// casual path uses: groups = ceil(roster / 4).  This is the target the
  /// builder works toward, so the count can't disagree with the draft.
  int get _expectedGroupCount =>
      _rosterSize == 0 ? 0 : groupSizes(_rosterSize).length;

  /// Players already assigned to a completed foursome.
  Set<int> get _assignedIds =>
      _foursomes.expand((f) => f.playerIds).toSet();

  /// True when at least one foursome is ready to go.
  /// Unassigned players (sitting out due to uneven singles etc.) are allowed.
  bool get _allPlayersAssigned =>
      _cup != null && _foursomes.isNotEmpty;

  /// Players not placed in any group for this round (sitting out).
  List<CupPlayer> get _sittingOut {
    if (_cup == null) return [];
    return _cup!.teams
        .expand((t) => t.players)
        .where((p) => !_assignedIds.contains(p.id))
        .toList();
  }

  /// Players selected for current foursome, partitioned by team index.
  List<int> _selectedForTeam(int teamIdx) => _selectedIds
      .where((id) => _teamIndexOf(id) == teamIdx)
      .toList();

  int _teamIndexOf(int playerId) {
    for (int i = 0; i < _teams.length; i++) {
      if (_teams[i].players.any((p) => p.id == playerId)) return i;
    }
    return -1;
  }

  String _playerName(int id) {
    for (final t in _teams) {
      final p = t.players.where((p) => p.id == id).firstOrNull;
      if (p != null) return p.name;
    }
    return 'Player $id';
  }

  /// A player's tee-designation sex ('M'/'W'), used to filter the tee list so
  /// each golfer only sees their own set (not both men's and women's tees).
  String _playerSex(int id) {
    for (final t in _teams) {
      final p = t.players.where((p) => p.id == id).firstOrNull;
      if (p != null) return p.sex;
    }
    return 'M';
  }

  // ── Game filtering ─────────────────────────────────────────────────────────

  /// Foursome drafts committed per game so far.
  Map<String, int> _builtPerGame() {
    final m = <String, int>{};
    for (final f in _foursomes) {
      m[f.gameType] = (m[f.gameType] ?? 0) + 1;
    }
    return m;
  }

  /// Games in the round's plan that still need a group (built < target).
  /// Empty for a round with no mixed plan (Triple Cup / legacy).
  Set<String> _remainingGames() {
    final counts = widget.cupGroupCounts;
    if (counts.isEmpty) return {};
    final built = _builtPerGame();
    return {
      for (final e in counts.entries)
        if (e.value > 0 && (built[e.key] ?? 0) < e.value) e.key,
    };
  }

  /// Games to show in the picker, filtered to the round's game plan.
  /// Falls back to the full list if no plan was saved (older tournaments).
  /// For a MIXED cup (cup_group_counts set) the picker is a worklist — only
  /// games that still have a group to build; when the plan is complete the
  /// list is empty (and the review step hides "Add another group").
  List<(String, String, IconData)> get _filteredGames {
    final avail = widget.availableGames;
    final base = avail.isEmpty
        ? _kCupGames
        : _kCupGames.where((g) => avail.contains(g.$1)).toList();
    if (widget.cupGroupCounts.isEmpty) return base;
    final remaining = _remainingGames();
    return base.where((g) => remaining.contains(g.$1)).toList();
  }

  // ── Validation for current builder step ────────────────────────────────────

  bool get _canProceed {
    switch (_buildStep) {
      case _BuildStep.gameType:
        return _gameType != null;
      case _BuildStep.group:
        // Legal composition AND every selected golfer has a tee (tee time is
        // always defaulted, so it never gates).
        return _playersValid &&
               _selectedIds.every((id) => _playerTees.containsKey(id));
      case _BuildStep.matchups:
        return _matchupA.every((v) => v != null) &&
               _matchupB.every((v) => v != null);
      case _BuildStep.review:
        return _allPlayersAssigned;
    }
  }

  /// Max golfers per side for the current game.  Both sides cap at 2 for every
  /// two-sided cup format (2 v 2, or a legal 1 v 2 / 1 v 1 under it); once a
  /// side hits it, its remaining golfers dim to "Team full".  Irish Rumble is
  /// one team of 4 and handled by its own team selector, so it has no per-side
  /// cap here.
  int get _teamCap => _gameType == 'irish_rumble' ? 4 : 2;

  bool get _playersValid {
    final n = _selectedIds.length;
    switch (_gameType) {
      case 'irish_rumble':
        // exactly 4 players, all from one team
        if (n != 4) return false;
        final teamIdx = _irishRumbleTeamIdx;
        if (teamIdx == null) return false;
        return _selectedIds.every((id) => _teamIndexOf(id) == teamIdx);
      case 'singles_nassau':
      case 'singles_18':
        // 2 players (1+1), 3 players (1+2 or 2+1), or 4 players (2+2)
        if (n != 2 && n != 3 && n != 4) return false;
        final a = _selectedForTeam(0).length;
        final b = _selectedForTeam(1).length;
        if (n == 2) return a == 1 && b == 1;
        if (n == 3) return (a == 1 && b == 2) || (a == 2 && b == 1);
        return a == 2 && b == 2;
      default:
        // nassau / quota_nassau / triple_cup:
        //   4 players (2+2) — full group, all formats
        //   3 players (1+2 or 2+1) — solo side gets a phantom partner (cup-only)
        //   2 players (1+1) — triple_cup falls back to an 18-hole
        //     Nassau (F9 + B9 + Overall, 4 cup pts).  Nassau / Quota
        //     also accept 1+1 for casual heads-up matches.
        if (n != 4 && n != 3 && n != 2) return false;
        final a = _selectedForTeam(0).length;
        final b = _selectedForTeam(1).length;
        if (n == 4) return a == 2 && b == 2;
        if (n == 3) return (a == 1 && b == 2) || (a == 2 && b == 1);
        return a == 1 && b == 1;   // 2-player: 1 vs 1
    }
  }

  bool get _needsMatchupStep =>
      (_gameType == 'singles_nassau' || _gameType == 'singles_18') &&
      (_selectedIds.length == 4 || _selectedIds.length == 3);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _teeTimeCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _client.getTeamTournament(widget.tournamentId),
        _client.getTees(),
      ]);
      final cup  = results[0] as TeamTournamentSummary;
      final tees = (results[1] as List<TeeInfo>)
          .where((t) => t.course.id == widget.courseId)
          .toList()
        ..sort((a, b) => a.sortPriority.compareTo(b.sortPriority));

      // Guard: if no team has any players, the draft hasn't been done yet.
      final hasPlayers = cup.teams.any((t) => t.players.isNotEmpty);
      if (!hasPlayers && mounted) {
        setState(() {
          _error = 'No players have been assigned to teams yet.\n\n'
                   'Go back and use "Cup Draft & Teams" on the tournament '
                   'card to assign players before setting up a round.';
          _networkError = false;
        });
        return;
      }

      if (mounted) {
        setState(() {
          _cup        = cup;
          _courseTees = tees;
          // Auto-select game type if only one option for this round, jumping
          // straight to the group card with its tee time proposed.
          if (widget.availableGames.length == 1) {
            _gameType         = widget.availableGames.first;
            _teeTimeCtrl.text = _defaultTeeTimeForNewGroup();
            _buildStep        = _BuildStep.group;
          }
          // Auto-arm the Triple Cup preset when the tournament wizard
          // already chose it as the round's only game.  Same effect as
          // ticking "One Day Ryder Cup" on the format toggle — every
          // foursome auto-locks to triple_cup and the format toggle
          // hides the per-foursome game picker.
          if (widget.availableGames.contains('triple_cup')) {
            _roundFormat = 'triple_cup';
            _gameType    = 'triple_cup';
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _error        = friendlyError(e);
        _networkError = isNetworkError(e);
      });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  // ── Navigation within builder ──────────────────────────────────────────────

  void _nextStep() {
    switch (_buildStep) {
      case _BuildStep.gameType:
        setState(() {
          _selectedIds.clear();
          _playerTees.clear();
          _irishRumbleTeamIdx = null;
          _teeTimeCtrl.text   = _defaultTeeTimeForNewGroup();
          _buildStep          = _BuildStep.group;
        });
      case _BuildStep.group:
        // Players + tees + tee time are all set on this one card.  Singles
        // groups of 3/4 still need the matchup step; everyone else commits.
        if (_needsMatchupStep) {
          _initMatchups();
          setState(() => _buildStep = _BuildStep.matchups);
        } else {
          _commitFoursome();
        }
      case _BuildStep.matchups:
        _commitFoursome();
      case _BuildStep.review:
        break;
    }
  }

  void _prevStep() {
    switch (_buildStep) {
      case _BuildStep.gameType:
        if (_foursomes.isEmpty) {
          Navigator.of(context).pop();
        } else {
          setState(() => _buildStep = _BuildStep.review);
        }
      case _BuildStep.group:
        // If the game was auto-selected (only 1 option), don't go back to
        // the (skipped) game picker — pop the screen instead.
        if (widget.availableGames.length == 1 && _foursomes.isEmpty) {
          Navigator.of(context).pop();
        } else if (widget.availableGames.length == 1) {
          setState(() => _buildStep = _BuildStep.review);
        } else {
          setState(() => _buildStep = _BuildStep.gameType);
        }
      case _BuildStep.matchups:
        setState(() => _buildStep = _BuildStep.group);
      case _BuildStep.review:
        // Back on the review step exits the setup flow.  (Adding another group
        // is the explicit "Add group" button — NOT a back action.  Wiring it to
        // _startNewFoursome() here made Back bounce group→review→group forever
        // with no way to pop the screen.)
        Navigator.of(context).pop();
    }
  }

  /// Proposed tee time for the next group: one interval after the previous
  /// group (the answer in almost every case), or 8:00 AM for the first group.
  String _defaultTeeTimeForNewGroup() {
    final prev = _foursomes.isNotEmpty ? _foursomes.last.teeTime : null;
    if (prev == null) return '08:00';
    return _shiftTeeTime(prev, _kTeeInterval);
  }

  /// Sex-matched default tee for a golfer: their lowest-priority tee (men's for
  /// men, women's for women), or the first course tee if none match.
  int _defaultTeeFor(int id) {
    final sex = _playerSex(id);
    final tees = _courseTees
        .where((t) => t.sex == null || t.sex == sex)
        .toList()
      ..sort((a, b) => a.sortPriority.compareTo(b.sortPriority));
    return (tees.isNotEmpty ? tees.first : _courseTees.first).id;
  }

  /// Add or remove a golfer from the group being built.  Adding prefills their
  /// tee; a side already at [_teamCap] is a no-op (its rows are dimmed anyway).
  void _toggleGroupPlayer(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        _playerTees.remove(id);
        return;
      }
      // Guard the per-side cap for two-sided formats (Irish Rumble uses its
      // own single-team selector, so skip the cap there).
      if (_gameType != 'irish_rumble') {
        final side = _teamIndexOf(id);
        final onSide = _selectedIds.where((s) => _teamIndexOf(s) == side).length;
        if (onSide >= _teamCap) return;
      }
      _selectedIds.add(id);
      if (_courseTees.isNotEmpty) _playerTees[id] = _defaultTeeFor(id);
    });
  }

  /// "Set all tees": apply one tee to every selected golfer it's legal for
  /// (unisex, or matching that golfer's sex).
  void _setAllTees(int teeId) {
    final tee = _courseTees.where((t) => t.id == teeId).firstOrNull;
    if (tee == null) return;
    setState(() {
      for (final id in _selectedIds) {
        if (tee.sex == null || tee.sex == _playerSex(id)) {
          _playerTees[id] = teeId;
        }
      }
    });
  }

  void _initMatchups() {
    final teamA = _selectedForTeam(0);
    final teamB = _selectedForTeam(1);
    _matchupA.clear();
    _matchupB.clear();

    if (teamA.length == 1 && teamB.length == 2) {
      // A1 plays both B1 and B2
      _matchupA.add(teamA[0]);
      _matchupA.add(teamA[0]);
      _matchupB.add(teamB[0]);
      _matchupB.add(teamB[1]);
    } else if (teamA.length == 2 && teamB.length == 1) {
      // A1 and A2 both play B1
      _matchupA.add(teamA[0]);
      _matchupA.add(teamA[1]);
      _matchupB.add(teamB[0]);
      _matchupB.add(teamB[0]);
    } else {
      // Even teams (1+1 or 2+2)
      for (int i = 0; i < teamA.length; i++) {
        _matchupA.add(teamA[i]);
        _matchupB.add(teamB.length > i ? teamB[i] : null);
      }
    }
  }

  void _commitFoursome() {
    final teeTime = _teeTimeCtrl.text.trim().isEmpty
        ? null
        : _teeTimeCtrl.text.trim();

    List<(int, int)> matchups = [];
    if (_needsMatchupStep || _buildStep == _BuildStep.matchups) {
      matchups = List.generate(
        _matchupA.length,
        (i) => (_matchupA[i]!, _matchupB[i]!),
      );
    }

    // Order: for Irish Rumble all same team; for others interleave A/B
    List<int> ordered;
    if (_gameType == 'irish_rumble') {
      ordered = _selectedIds.toList();
    } else if ((_gameType == 'singles_nassau' || _gameType == 'singles_18') && matchups.isNotEmpty) {
      // Interleave matchup pairs, deduplicating so a player who appears in
      // two matches (uneven teams) is only in the foursome once.
      final seen = <int>{};
      ordered = matchups
          .expand((m) => [m.$1, m.$2])
          .where((id) => seen.add(id))
          .toList();
    } else {
      // Interleave team A and B players
      final a = _selectedForTeam(0);
      final b = _selectedForTeam(1);
      ordered = [];
      for (int i = 0; i < a.length || i < b.length; i++) {
        if (i < a.length) ordered.add(a[i]);
        if (i < b.length) ordered.add(b[i]);
      }
    }

    // Use wizard-configured point value for this game type, falling back to 1.0
    final pointValue = widget.gamePointValues[_gameType!] ?? 1.0;

    setState(() {
      _foursomes.add(_FoursomeDraft(
        gameType       : _gameType!,
        playerIds      : ordered,
        playerTees     : Map.from(_playerTees),
        teeTime        : teeTime,
        pointValue     : pointValue,
        singlesMatchups: matchups,
      ));
      _buildStep = _BuildStep.review;
    });
  }

  void _startNewFoursome() {
    setState(() {
      // If only one game available, keep it auto-selected and go to players
      final autoGame = widget.availableGames.length == 1
          ? widget.availableGames.first
          : null;
      _gameType           = autoGame;
      _selectedIds.clear();
      _playerTees.clear();
      _irishRumbleTeamIdx = null;
      _teeTimeCtrl.text   = _defaultTeeTimeForNewGroup();
      _matchupA.clear();
      _matchupB.clear();
      _buildStep = autoGame != null ? _BuildStep.group : _BuildStep.gameType;
    });
  }

  void _removeFoursome(int idx) {
    setState(() => _foursomes.removeAt(idx));
    if (_foursomes.isEmpty) _startNewFoursome();
  }

  /// "Assign" from the round-groups review: open the builder on a new group
  /// with this unassigned golfer already seated (and their side/tee set).
  void _assignGolfer(int id) {
    final autoGame = widget.availableGames.length == 1
        ? widget.availableGames.first
        : _gameType;
    setState(() {
      _gameType = autoGame;
      _selectedIds
        ..clear()
        ..add(id);
      _playerTees.clear();
      if (_courseTees.isNotEmpty) _playerTees[id] = _defaultTeeFor(id);
      _irishRumbleTeamIdx =
          autoGame == 'irish_rumble' ? _teamIndexOf(id) : null;
      _teeTimeCtrl.text = _defaultTeeTimeForNewGroup();
      _matchupA.clear();
      _matchupB.clear();
      // With a game known we can go straight to the group card; otherwise the
      // multi-game round still needs its per-group format pick first.
      _buildStep = autoGame != null ? _BuildStep.group : _BuildStep.gameType;
    });
  }

  Future<void> _editFoursomeTeeTime(int idx) async {
    final draft  = _foursomes[idx];
    final picked = await _pickTeeTime(context, draft.teeTime);
    if (picked == null) return;     // user cancelled — leave value as-is
    setState(() {
      _foursomes[idx] = _FoursomeDraft(
        gameType        : draft.gameType,
        playerIds       : draft.playerIds,
        playerTees      : draft.playerTees,
        teeTime         : picked,
        pointValue      : draft.pointValue,
        singlesMatchups : draft.singlesMatchups,
      );
    });
  }

  void _clearFoursomeTeeTime(int idx) {
    final draft = _foursomes[idx];
    setState(() {
      _foursomes[idx] = _FoursomeDraft(
        gameType        : draft.gameType,
        playerIds       : draft.playerIds,
        playerTees      : draft.playerTees,
        teeTime         : null,
        pointValue      : draft.pointValue,
        singlesMatchups : draft.singlesMatchups,
      );
    });
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    setState(() { _submitting = true; _submitError = null; });
    try {
      // Group numbers follow tee time: submit foursomes in tee-time order so the
      // backend (which numbers by submission order) gives Group 1 to the
      // earliest tee time.  Nulls (no time set) sort last.
      final sorted = [..._foursomes]
        ..sort((a, b) => (a.teeTime ?? '~').compareTo(b.teeTime ?? '~'));

      // Build flat ordered player list for setupRound.
      // Players from each foursome appear in order; backend groups first-N
      // into group 1, next-N into group 2, etc. (randomise=false).
      // Singles groups may have 2 real players → backend adds 2 phantoms.
      final flatPlayers = <Map<String, int>>[];
      for (final f in sorted) {
        for (final pid in f.playerIds) {
          final entry = <String, int>{'player_id': pid};
          final teeId = f.playerTees[pid];
          if (teeId != null) entry['tee_id'] = teeId;
          flatPlayers.add(entry);
        }
      }

      // 1. Call setupRound — creates foursomes and marks round in_progress.
      final fullRound = await _client.setupRound(
        widget.roundId,
        players        : flatPlayers,
        randomise      : false,
        autoSetupGames : false,
      );

      // 2. Match our draft foursomes to the created foursomes by index.
      //    The backend preserves submission order, so index aligns.
      final teams = _cup!.teams;
      final team1Id = teams.isNotEmpty ? teams[0].teamId : null;
      final team2Id = teams.length > 1  ? teams[1].teamId : null;

      final foursomesPayload = <Map<String, dynamic>>[];
      for (int i = 0; i < sorted.length && i < fullRound.foursomes.length; i++) {
        final draft = sorted[i];
        final fs    = fullRound.foursomes[i];
        foursomesPayload.add({
          'foursome_id' : fs.id,
          'game_type'   : draft.gameType,
          'point_value' : draft.pointValue,
          if (team1Id != null) 'team1_id': team1Id,
          if (team2Id != null) 'team2_id': team2Id,
          if (draft.singlesMatchups.isNotEmpty)
            'singles_matchups': draft.singlesMatchups
                .map((m) => {'player1_id': m.$1, 'player2_id': m.$2})
                .toList(),
        });
      }

      final hasIrishRumble =
          _foursomes.any((f) => f.gameType == 'irish_rumble');
      await _client.postRyderCupRoundSetup(
        widget.roundId,
        nassauPointValue : 1.0,
        pointMultiplier  : 1.0,
        roundFormat      : _roundFormat,
        foursomes        : foursomesPayload,
        irishRumbleVariant: hasIrishRumble ? _irVariant : null,
        irishRumbleCustomBalls:
            hasIrishRumble && _irVariant == 'custom' ? _irCustomBalls : null,
      );

      // 3. Set tee times where provided.
      final teeEntries = <Map<String, dynamic>>[];
      for (int i = 0; i < sorted.length && i < fullRound.foursomes.length; i++) {
        final t = sorted[i].teeTime;
        if (t != null) {
          teeEntries.add({
            'group_number': fullRound.foursomes[i].groupNumber,
            'tee_time'    : t,
          });
        }
      }
      if (teeEntries.isNotEmpty) {
        await _client.setTeeTimes(widget.roundId, teeEntries);
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() {
        _submitError = friendlyError(e);
        _submitting  = false;
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _prevStep),
        title: Text('Round ${widget.roundNumber} · ${widget.courseName}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: _buildStep == _BuildStep.review
                ? 1.0
                : (_BuildStep.values.indexOf(_buildStep) + 1) /
                  (_BuildStep.values.length),
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: _error!, isNetwork: _networkError, onRetry: _load)
              : _buildBody(),
      bottomNavigationBar: (_loading || _error != null)
          ? null
          : _buildBottomBar(),
    );
  }

  /// Mixed-cup worklist header: what the wizard sized this round for vs. what's
  /// been built so far, per game.  Null for Triple Cup / rounds with no plan.
  Widget? _worklistStrip() {
    final counts = widget.cupGroupCounts;
    if (counts.isEmpty || _roundFormat == 'triple_cup') return null;
    final entries = counts.entries.where((e) => e.value > 0).toList();
    if (entries.isEmpty) return null;
    // built per game = committed foursome drafts assigned that game (each
    // foursome is one foursome-equivalent unit, matching the count basis).
    final built = <String, int>{};
    for (final f in _foursomes) {
      built[f.gameType] = (built[f.gameType] ?? 0) + 1;
    }
    final allDone = entries.every((e) => (built[e.key] ?? 0) >= e.value);
    return Container(
      width: double.infinity,
      color: const Color(0xFF0B1F1A),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(allDone ? 'All matches built' : 'Round plan — left to build',
            style: const TextStyle(
                color: Color(0xFF9DB0A3),
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in entries)
            _WorklistChip(
              label: _gameLabel(e.key),
              built: built[e.key] ?? 0,
              target: e.value,
            ),
        ]),
      ]),
    );
  }

  Widget _buildBody() {
    switch (_buildStep) {
      case _BuildStep.gameType:
        // "Round Format" preset row above the per-foursome game
        // picker.  Picking "One Day Ryder Cup" locks the wizard to
        // triple_cup for every foursome.  Locked once a foursome is
        // committed so we can't produce a mixed-format payload.
        final worklist = _worklistStrip();
        // A mixed cup already chose its formats in the wizard (captured as a
        // plan in cupGroupCounts), so don't re-offer the Round Format preset —
        // showing "Triple Cup" here would let it silently override the plan.
        // The toggle is only for a legacy round with no pre-chosen plan.
        final hasMixedPlan = widget.cupGroupCounts.isNotEmpty;
        return Column(children: [
          if (worklist != null) worklist,
          if (!hasMixedPlan)
            _RoundFormatToggle(
              value: _roundFormat,
              locked: _foursomes.isNotEmpty,
              onChanged: (v) => setState(() {
                _roundFormat = v;
                if (v == 'triple_cup') {
                  _gameType = 'triple_cup';
                } else if (_gameType == 'triple_cup') {
                  _gameType = null;
                }
              }),
            ),
          if (!hasMixedPlan && _roundFormat == 'triple_cup')
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _TripleCupFormatNote(),
            )
          else
            Expanded(child: _GameTypePicker(
              selected        : _gameType,
              games           : _filteredGames,
              onPick          : (g) => setState(() => _gameType = g),
              foursomeNumber  : _foursomes.length + 1,
              gamePointValues : widget.gamePointValues,
            )),
        ]);
      case _BuildStep.group:     return _GroupBuilder(
        foursomeNumber     : _foursomes.length + 1,
        gameType           : _gameType!,
        teams              : _teams,
        irVariant          : _irVariant,
        irCustomBalls      : _irCustomBalls,
        holePars           : _holePars,
        onIrVariantChanged : (v) => setState(() => _irVariant = v),
        onIrCustomBall     : (idx, val) =>
            setState(() => _irCustomBalls[idx] = val),
        selectedIds        : _selectedIds,
        assignedIds        : _assignedIds,
        irishRumbleTeamIdx : _irishRumbleTeamIdx,
        teamCap            : _teamCap,
        playerTees         : _playerTees,
        courseTees         : _courseTees,
        playerName         : _playerName,
        playerSex          : _playerSex,
        teamIndexOf        : _teamIndexOf,
        selectedForTeam    : _selectedForTeam,
        teeTime            : _teeTimeCtrl.text,
        prevGroupTeeTime   : _foursomes.isNotEmpty ? _foursomes.last.teeTime : null,
        onToggle           : _toggleGroupPlayer,
        onPickIrishTeam    : (idx) => setState(() {
          _irishRumbleTeamIdx = idx;
          // Remove any selected players not on this team
          _selectedIds.removeWhere((id) => _teamIndexOf(id) != idx);
        }),
        onPickTee          : (pid, teeId) =>
            setState(() => _playerTees[pid] = teeId),
        onSetAllTees       : _setAllTees,
        onTeeTimeShift     : (delta) => setState(() =>
            _teeTimeCtrl.text = _shiftTeeTime(_teeTimeCtrl.text, delta)),
        onTeeTimePick      : () async {
          final picked = await _pickTeeTime(context, _teeTimeCtrl.text);
          if (picked != null) {
            setState(() => _teeTimeCtrl.text = picked);
          }
        },
      );
      case _BuildStep.matchups:  return _MatchupBuilder(
        matchupA     : _matchupA,
        matchupB     : _matchupB,
        teamAPlayers : _selectedForTeam(0),
        teamBPlayers : _selectedForTeam(1),
        teamAName    : _teams.isNotEmpty ? _teams[0].name : 'Team A',
        teamBName    : _teams.length > 1 ? _teams[1].name : 'Team B',
        playerName   : _playerName,
        onSwapB      : (matchIdx, playerId) =>
            setState(() => _matchupB[matchIdx] = playerId),
        onSwapA      : (matchIdx, playerId) =>
            setState(() => _matchupA[matchIdx] = playerId),
      );
      case _BuildStep.review:    return _ReviewPage(
        foursomes      : _foursomes,
        teams          : _teams,
        courseTees     : _courseTees,
        playerName     : _playerName,
        onRemove       : _removeFoursome,
        onEditTeeTime  : _editFoursomeTeeTime,
        onClearTeeTime : _clearFoursomeTeeTime,
        onAddAnother   : _startNewFoursome,
        // Mixed cup: once every planned group is built there's nothing left to
        // add, so the review offers only "Start Round".
        canAddAnother  :
            widget.cupGroupCounts.isEmpty || _remainingGames().isNotEmpty,
        onAssign       : _assignGolfer,
        submitError    : _submitError,
        sittingOut     : _sittingOut,
        expectedGroups : _expectedGroupCount,
        rosterSize     : _rosterSize,
      );
    }
  }

  Widget _buildBottomBar() {
    final isReview = _buildStep == _BuildStep.review;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          OutlinedButton(
            onPressed: _prevStep,
            child: const Text('Back'),
          ),
          const Spacer(),
          if (isReview)
            FilledButton.icon(
              onPressed: (_allPlayersAssigned && !_submitting) ? _submit : null,
              icon: _submitting
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Colors.white))
                  : const Icon(Icons.flag),
              label: const Text('Start Round'),
            )
          else
            FilledButton(
              onPressed: _canProceed ? _nextStep : null,
              // The group card is the last step before commit unless a 3/4-player
              // singles group still needs its matchups.
              child: Text(
                (_buildStep == _BuildStep.group && !_needsMatchupStep)
                    ? 'Add Group'
                    : 'Next',
              ),
            ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Step A — Game Type Picker
// ===========================================================================

class _GameTypePicker extends StatelessWidget {
  final String?              selected;
  final List<(String, String, IconData)> games;
  final ValueChanged<String> onPick;
  final int                  foursomeNumber;
  /// Point value for each game type (from wizard config). Shown read-only
  /// so the organiser can confirm what was set at creation time.
  final Map<String, double>  gamePointValues;

  const _GameTypePicker({
    required this.selected,
    required this.games,
    required this.onPick,
    required this.foursomeNumber,
    this.gamePointValues = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Group $foursomeNumber — Game Format',
            style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('What game will this group play?',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
        const SizedBox(height: 24),
        ...games.map((g) {
          final isSelected = selected == g.$1;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              onTap: () => onPick(g.$1),
              borderRadius: BorderRadius.circular(12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(children: [
                  Icon(g.$3,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 16),
                  Expanded(child: Text(g.$2,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : null))),
                  if (isSelected)
                    Icon(Icons.check_circle,
                        color: theme.colorScheme.primary),
                ]),
              ),
            ),
          );
        }),

        // ── Cup Points reminder (read-only, set at wizard time) ──────────
        if (gamePointValues.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          Text('Points per win (from tournament setup)',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: gamePointValues.entries.map((e) {
              final label = _kCupGames
                  .firstWhere((g) => g.$1 == e.key,
                      orElse: () => (e.key, e.key, Icons.sports_golf))
                  .$2;
              final pts = e.value % 1 == 0
                  ? e.value.toInt().toString()
                  : e.value.toString();
              return Chip(
                label: Text('$label · ${pts}pt',
                    style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}
// ===========================================================================
// Step B — Group Builder (players + inline tees + tee time, one card)
// ===========================================================================
// Collapses the shipped players → tees → teeTime flow into a single card,
// repeated once per group.  Golfers carry their index, tees sit next to each
// golfer (with "Set all"), and the tee time is proposed as previous-group +
// interval with ±5 steppers rather than a clock dial.
// ===========================================================================

class _GroupBuilder extends StatelessWidget {
  final int                foursomeNumber;
  final String             gameType;
  final List<CupTeam>      teams;
  final Set<int>           selectedIds;
  final Set<int>           assignedIds;
  final int?               irishRumbleTeamIdx;
  final int                teamCap;
  final Map<int, int>      playerTees;      // playerId → teeId
  final List<TeeInfo>      courseTees;
  final String Function(int) playerName;
  final String Function(int) playerSex;
  final int    Function(int) teamIndexOf;
  final List<int> Function(int) selectedForTeam;
  final String             teeTime;         // 'HH:MM'
  final String?            prevGroupTeeTime;
  final ValueChanged<int>  onToggle;
  final ValueChanged<int>  onPickIrishTeam;
  final void Function(int pid, int teeId) onPickTee;
  final ValueChanged<int>  onSetAllTees;
  final ValueChanged<int>  onTeeTimeShift;
  final VoidCallback        onTeeTimePick;
  // Irish Rumble balls variant (round-level; only used when gameType is
  // irish_rumble).
  final String             irVariant;
  final List<int>          irCustomBalls;
  final List<int>          holePars;
  final ValueChanged<String> onIrVariantChanged;
  final void Function(int holeIdx, int value) onIrCustomBall;

  const _GroupBuilder({
    required this.foursomeNumber,
    required this.gameType,
    required this.teams,
    required this.irVariant,
    required this.irCustomBalls,
    required this.holePars,
    required this.onIrVariantChanged,
    required this.onIrCustomBall,
    required this.selectedIds,
    required this.assignedIds,
    required this.irishRumbleTeamIdx,
    required this.teamCap,
    required this.playerTees,
    required this.courseTees,
    required this.playerName,
    required this.playerSex,
    required this.teamIndexOf,
    required this.selectedForTeam,
    required this.teeTime,
    required this.prevGroupTeeTime,
    required this.onToggle,
    required this.onPickIrishTeam,
    required this.onPickTee,
    required this.onSetAllTees,
    required this.onTeeTimeShift,
    required this.onTeeTimePick,
  });

  String get _rule {
    switch (gameType) {
      case 'irish_rumble':
        return 'Pick 4 golfers from the same team.';
      case 'singles_nassau':
      case 'singles_18':
        return 'Pick 1–2 per team. Uneven (1 vs 2) — the solo golfer plays two matches.';
      case 'triple_cup':
        return 'Pick 2 per team (4 total), 1 vs 2 (phantom fills the solo '
               'side), or 1 vs 1 (plays an 18-hole Nassau — F9 / B9 / Overall).';
      default:
        return 'Pick 2 per team (4 total), or 1 vs 2 — the solo side gets a phantom partner.';
    }
  }

  CupPlayer? _find(int id) {
    for (final t in teams) {
      final p = t.players.where((p) => p.id == id).firstOrNull;
      if (p != null) return p;
    }
    return null;
  }

  List<TeeInfo> _teesFor(int id) {
    final sex = playerSex(id);
    return courseTees.where((t) => t.sex == null || t.sex == sex).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final selected = selectedIds.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text('Group $foursomeNumber', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 2),
        Text('${_gameLabel(gameType)} · $_rule',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),

        // ── Irish Rumble balls variant (round-level — applies to every IR
        //     match in this round) ────────────────────────────────────────────
        if (gameType == 'irish_rumble') ...[
          IrishRumbleVariantPicker(
            variant: irVariant,
            onChanged: onIrVariantChanged,
          ),
          const SizedBox(height: 12),
          IrishRumbleSegmentPreview(
            variant: irVariant,
            holePars: holePars,
            customBalls: irCustomBalls,
          ),
          if (irVariant == 'custom') ...[
            const SizedBox(height: 12),
            IrishRumbleCustomBallsEditor(
              holePars: holePars,
              customBalls: irCustomBalls,
              onChanged: onIrCustomBall,
            ),
          ],
          const SizedBox(height: 20),
        ],

        // ── Tee time (proposed = previous group + interval) ──────────────────
        _teeTimeCard(theme),
        const SizedBox(height: 20),

        // ── Golfers (with index + inline tees) ───────────────────────────────
        Row(children: [
          Text('Golfers', style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.bold)),
          const Spacer(),
          if (selected.isNotEmpty && courseTees.isNotEmpty)
            PopupMenuButton<int>(
              onSelected: onSetAllTees,
              itemBuilder: (_) => courseTees
                  .map((t) => PopupMenuItem<int>(
                        value: t.id,
                        child: Text('${t.teeName} · par ${t.par}'),
                      ))
                  .toList(),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.done_all, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Text('Set all tees',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.primary)),
              ]),
            ),
        ]),
        const SizedBox(height: 8),
        if (selected.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Pick golfers below to build the group.',
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant)),
          )
        else
          ...selected.map((id) => _selectedGolferCard(theme, id)),

        const SizedBox(height: 20),

        // ── Pool: who's not yet in this group ────────────────────────────────
        if (gameType == 'irish_rumble') _irishTeamChips(theme),
        ..._pool(theme),

        const SizedBox(height: 16),
        _countFooter(theme),
      ],
    );
  }

  Widget _teeTimeCard(ThemeData theme) {
    final caption = prevGroupTeeTime != null
        ? '$_kTeeInterval min after Group ${foursomeNumber - 1} '
          '(${_friendlyTeeTime(prevGroupTeeTime!)})'
        : 'First group of the round';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.schedule, size: 18,
              color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('Tee time', style: theme.textTheme.titleSmall),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton(
            onPressed: () => onTeeTimeShift(-5),
            child: const Text('−5 min'),
          ),
          Expanded(
            child: Center(
              child: InkWell(
                onTap: onTeeTimePick,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 4),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_friendlyTeeTime(teeTime),
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
                      Icon(Icons.edit, size: 16,
                          color: theme.colorScheme.onSurfaceVariant),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          OutlinedButton(
            onPressed: () => onTeeTimeShift(5),
            child: const Text('+5 min'),
          ),
        ]),
        const SizedBox(height: 6),
        Text('$caption · tap the time to set it',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _selectedGolferCard(ThemeData theme, int id) {
    final p    = _find(id);
    final tees = _teesFor(id);
    final selectedTeeId =
        tees.any((t) => t.id == playerTees[id]) ? playerTees[id] : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(playerName(id), style: theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
                if (p != null && p.handicapIndex.isNotEmpty)
                  Text('Index ${p.handicapIndex}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Remove from group',
              onPressed: () => onToggle(id),
            ),
          ]),
          const SizedBox(height: 4),
          if (courseTees.isEmpty)
            Text('No tees for this course',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error))
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TeePicker(
                tees: tees,
                value: selectedTeeId,
                onChanged: (t) => onPickTee(id, t),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _irishTeamChips(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(children: [
      Text('Team: ', style: theme.textTheme.titleSmall),
      const SizedBox(width: 8),
      ...teams.asMap().entries.map((e) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(e.value.name),
          selected: irishRumbleTeamIdx == e.key,
          onSelected: (_) => onPickIrishTeam(e.key),
        ),
      )),
    ]),
  );

  List<Widget> _pool(ThemeData theme) {
    return teams.asMap().entries.map((entry) {
      final teamIdx = entry.key;
      final team    = entry.value;

      // Irish Rumble: only show the chosen team.
      if (gameType == 'irish_rumble' &&
          irishRumbleTeamIdx != null &&
          irishRumbleTeamIdx != teamIdx) {
        return const SizedBox.shrink();
      }

      final available = team.players
          .where((p) => !assignedIds.contains(p.id) &&
                        !selectedIds.contains(p.id))
          .toList();
      if (available.isEmpty) return const SizedBox.shrink();

      final sideFull = gameType != 'irish_rumble' &&
          selectedForTeam(teamIdx).length >= teamCap;

      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
          child: Text(team.name, style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
        ),
        ...available.map((p) {
          final dim = sideFull;
          return Opacity(
            opacity: dim ? 0.45 : 1,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              enabled: !dim,
              leading: Icon(
                dim ? Icons.block : Icons.add_circle_outline,
                color: dim
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
              ),
              title: Text(p.name),
              subtitle: p.handicapIndex.isEmpty
                  ? null
                  : Text('Index ${p.handicapIndex}'),
              trailing: dim
                  ? Text('Team full', style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                  : null,
              onTap: dim ? null : () => onToggle(p.id),
            ),
          );
        }),
      ]);
    }).toList();
  }

  Widget _countFooter(ThemeData theme) {
    return Row(children: [
      Text('Selected: ${selectedIds.length}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const Spacer(),
      if (gameType != 'irish_rumble')
        ...teams.asMap().entries.map((e) {
          final cnt = selectedForTeam(e.key).length;
          return Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text('${e.value.name}: $cnt',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          );
        }),
    ]);
  }
}

// ===========================================================================
// Step E — Singles Matchup Builder (4-player Singles only)
// ===========================================================================

class _MatchupBuilder extends StatelessWidget {
  final List<int?>       matchupA;
  final List<int?>       matchupB;
  final List<int>        teamAPlayers;
  final List<int>        teamBPlayers;
  final String           teamAName;
  final String           teamBName;
  final String Function(int) playerName;
  final void Function(int matchIdx, int playerId) onSwapB;
  final void Function(int matchIdx, int playerId)? onSwapA;

  const _MatchupBuilder({
    required this.matchupA,
    required this.matchupB,
    required this.teamAPlayers,
    required this.teamBPlayers,
    required this.teamAName,
    required this.teamBName,
    required this.playerName,
    required this.onSwapB,
    this.onSwapA,
  });

  // Is one side "solo" (same player ID in all matchup slots)?
  bool get _aIsSolo => teamAPlayers.length == 1;
  bool get _bIsSolo => teamBPlayers.length == 1;
  bool get _isUneven => _aIsSolo || _bIsSolo;
  String get _soloName => _aIsSolo
      ? playerName(teamAPlayers.first)
      : playerName(teamBPlayers.first);
  String get _soloTeamName => _aIsSolo ? teamAName : teamBName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Define Matchups', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          _isUneven
              ? 'Uneven group — $_soloName ($_soloTeamName) plays 2 matches.'
              : 'Pair each $teamAName player with a $teamBName player.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),

        // Banner for uneven groups
        if (_isUneven) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$_soloName will use their single scorecard for both matches. '
                  'They can earn points in each match independently.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ]),
          ),
        ],

        const SizedBox(height: 24),

        ...List.generate(matchupA.length, (i) {
          final aId = matchupA[i];
          final bId = matchupB[i];

          Widget aWidget = _aIsSolo
              // Solo A player — fixed, show as text
              ? Text(aId != null ? playerName(aId) : '—',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600))
              // Multiple A players — dropdown (for 2v1 swap)
              : (onSwapA != null && teamAPlayers.length > 1)
                  ? DropdownButton<int>(
                      value: aId,
                      isExpanded: true,
                      hint: Text('Pick $teamAName player'),
                      items: teamAPlayers.map((id) => DropdownMenuItem(
                        value: id,
                        child: Text(playerName(id)),
                      )).toList(),
                      onChanged: (id) { if (id != null) onSwapA!(i, id); },
                    )
                  : Text(aId != null ? playerName(aId) : '—',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600));

          Widget bWidget = _bIsSolo
              // Solo B player — fixed, show as text
              ? Text(bId != null ? playerName(bId) : '—',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600))
              // Multiple B players — dropdown
              : DropdownButton<int>(
                  value: bId,
                  isExpanded: true,
                  hint: Text('Pick $teamBName player'),
                  items: teamBPlayers.map((id) => DropdownMenuItem(
                    value: id,
                    child: Text(playerName(id)),
                  )).toList(),
                  onChanged: (id) { if (id != null) onSwapB(i, id); },
                );

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isUneven)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('Match ${i + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold)),
                    ),
                  Row(children: [
                    Expanded(child: aWidget),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('vs',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    Expanded(child: bWidget),
                  ]),
                ],
              ),
            ),
          );
        }),
      ]),
    );
  }
}

// ===========================================================================
// Step F — Review page ("Groups for this round")
// ===========================================================================
// The hub of round setup: every group is added, checked, and reached from
// here.  Each row carries the three things that go wrong on the first tee —
// composition, tee time, and tees — and unassigned golfers are listed by name
// with an Assign link rather than reduced to a count.
// ===========================================================================

class _ReviewPage extends StatelessWidget {
  final List<_FoursomeDraft> foursomes;
  final List<CupTeam>        teams;
  final List<TeeInfo>        courseTees;
  final String Function(int) playerName;
  final void Function(int)   onRemove;
  final Future<void> Function(int) onEditTeeTime;
  final void Function(int)   onClearTeeTime;
  final VoidCallback         onAddAnother;
  /// False once a mixed cup's plan is fully built — hides "Add another group"
  /// so the TD can only finish (Start Round).  Always true for Triple/legacy.
  final bool                 canAddAnother;
  final ValueChanged<int>    onAssign;
  final String?              submitError;
  final List<CupPlayer>      sittingOut;
  /// Group count derived from the drafted roster (ceil(roster / 4)).
  final int                  expectedGroups;
  final int                  rosterSize;

  const _ReviewPage({
    required this.foursomes,
    required this.teams,
    required this.courseTees,
    required this.playerName,
    required this.onRemove,
    required this.onEditTeeTime,
    required this.onClearTeeTime,
    required this.onAddAnother,
    this.canAddAnother = true,
    required this.onAssign,
    this.submitError,
    this.sittingOut = const [],
    this.expectedGroups = 0,
    this.rosterSize = 0,
  });

  CupTeam? _teamOf(int playerId) {
    for (final t in teams) {
      if (t.players.any((p) => p.id == playerId)) return t;
    }
    return null;
  }

  int _teamIndexOf(int playerId) {
    for (int i = 0; i < teams.length; i++) {
      if (teams[i].players.any((p) => p.id == playerId)) return i;
    }
    return -1;
  }

  String _teeName(int teeId) => courseTees
      .where((t) => t.id == teeId)
      .map((t) => t.teeName)
      .firstOrNull ?? '—';

  /// "2 v 2", "1 v 2", "1 v 1"; Irish Rumble is one team → "4 · one team".
  String _composition(_FoursomeDraft d) {
    if (d.gameType == 'irish_rumble') return '${d.playerIds.length} · one team';
    final a = d.playerIds.where((id) => _teamIndexOf(id) == 0).length;
    final b = d.playerIds.where((id) => _teamIndexOf(id) == 1).length;
    return '$a v $b';
  }

  /// A tee summary that reads at a glance: "All White tees",
  /// "White · 1 on Gold", or "Tees not set".
  String _teeSummary(_FoursomeDraft d) {
    final names = <String>[];
    for (final id in d.playerIds) {
      final teeId = d.playerTees[id];
      if (teeId == null) return 'Tees not set';
      names.add(_teeName(teeId));
    }
    if (names.isEmpty) return 'Tees not set';
    final counts = <String, int>{};
    for (final n in names) {
      counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.length == 1) return 'All ${names.first} tees';
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final base = sorted.first.key;
    final rest = sorted.skip(1).map((e) => '${e.value} on ${e.key}').join(', ');
    return '$base · $rest';
  }

  Widget _badge(ThemeData theme, CupTeam? team) {
    final code = (team?.shortCode.isNotEmpty ?? false)
        ? team!.shortCode
        : (team?.name.isNotEmpty ?? false ? team!.name[0] : '?');
    // Badge colour is the side's own colour, so it reads the same here as on the
    // draft board and the wizard swatch.
    final bg = team != null
        ? cupTeamColor(team.colour)
        : theme.colorScheme.primaryContainer;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(code,
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.white)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final built     = foursomes.length;
    final remaining = expectedGroups - built;
    final assigned  = foursomes.fold<int>(0, (s, d) => s + d.playerIds.length);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Groups for this round',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Tap a group to remove it, or add more. '
             'Start the round when the groups are set.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 12),

        // Derived group-count tally + assigned/unassigned counts.
        if (expectedGroups > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: remaining <= 0
                  ? Colors.green.shade50
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: remaining <= 0
                      ? Colors.green.shade200
                      : theme.colorScheme.outlineVariant),
            ),
            child: Row(children: [
              Icon(remaining <= 0 ? Icons.check_circle : Icons.groups_outlined,
                  size: 18,
                  color: remaining <= 0
                      ? Colors.green.shade700
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  remaining <= 0
                      ? '$built of $expectedGroups groups · '
                          '$assigned assigned · all set'
                      : '$built of $expectedGroups groups · $assigned assigned · '
                          '${sittingOut.length} not in a group',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: remaining <= 0
                          ? Colors.green.shade800
                          : theme.colorScheme.onSurface),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 16),

        ...foursomes.asMap().entries.map((e) => _groupCard(theme, e.key, e.value)),

        const SizedBox(height: 8),
        if (canAddAnother)
          OutlinedButton.icon(
            onPressed: onAddAnother,
            icon: const Icon(Icons.add),
            label: Text('Add group ${foursomes.length + 1}'),
          )
        else
          Row(children: [
            Icon(Icons.check_circle,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('Every planned group is built.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.primary)),
          ]),

        if (sittingOut.isNotEmpty) _unassignedSection(theme),

        if (submitError != null) ...[
          const SizedBox(height: 16),
          Text(submitError!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Widget _groupCard(ThemeData theme, int i, _FoursomeDraft d) {
    // Players grouped by side, so a mixed group reads at a glance.
    final sides = <Widget>[];
    for (int t = 0; t < teams.length; t++) {
      final ids = d.playerIds.where((id) => _teamIndexOf(id) == t).toList();
      if (ids.isEmpty) continue;
      sides.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _badge(theme, teams[t]),
          const SizedBox(width: 8),
          Expanded(child: Text(ids.map(playerName).join(', '),
              style: theme.textTheme.bodyMedium)),
        ]),
      ));
    }
    // Fallback (e.g. a phantom-partnered id off both teams): plain name list.
    if (sides.isEmpty) {
      sides.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(d.playerIds.map(playerName).join(', '),
            style: theme.textTheme.bodyMedium),
      ));
    }

    final pts = d.pointValue % 1 == 0
        ? d.pointValue.toInt().toString()
        : d.pointValue.toString();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 15, child: Text('${i + 1}')),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_gameLabel(d.gameType),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(_composition(d),
                  style: theme.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Remove group',
              onPressed: () => onRemove(i),
            ),
          ]),
          ...sides,
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.golf_course, size: 14,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(_teeSummary(d),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            // Tee time — tap to edit; clear button when set.
            InkWell(
              onTap: () => onEditTeeTime(i),
              child: Row(children: [
                Icon(Icons.schedule, size: 14,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  d.teeTime != null
                      ? 'Tee ${_friendlyTeeTime(d.teeTime!)}'
                      : 'Set tee time',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: d.teeTime != null
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.primary,
                    decoration: d.teeTime != null
                        ? null
                        : TextDecoration.underline,
                  ),
                ),
              ]),
            ),
            if (d.teeTime != null) ...[
              const SizedBox(width: 4),
              InkWell(
                onTap: () => onClearTeeTime(i),
                child: Icon(Icons.close, size: 13,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const Spacer(),
            Text('$pts pt${d.pointValue == 1.0 ? '' : 's'} per win',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: d.pointValue != 1.0
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant)),
          ]),
        ]),
      ),
    );
  }

  Widget _unassignedSection(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.person_off_outlined, size: 16,
              color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('Not in a group (${sittingOut.length})',
              style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 4),
        Text('Assign them to a group, or leave them sitting out this round.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        ...sittingOut.map((p) {
          final team = _teamOf(p.id);
          final sub = [
            if (team != null) team.name,
            if (p.handicapIndex.isNotEmpty) 'index ${p.handicapIndex}',
          ].join(' · ');
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              _badge(theme, team),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: theme.textTheme.bodyMedium),
                  if (sub.isNotEmpty)
                    Text(sub, style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
              TextButton(
                onPressed: () => onAssign(p.id),
                child: const Text('Assign'),
              ),
            ]),
          );
        }),
      ]),
    );
  }
}

/// "Round Format" preset toggle shown above the per-foursome game
/// picker.  Two choices: Custom (admin picks a game type per
/// One pill in the mixed-cup worklist header: "<game>  built/target", tinted
/// green (with a check) once every unit of that game has a group.
class _WorklistChip extends StatelessWidget {
  final String label;
  final int    built, target;
  const _WorklistChip({
    required this.label, required this.built, required this.target,
  });

  @override
  Widget build(BuildContext context) {
    final done = built >= target;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: done ? const Color(0xFF1A2A20) : const Color(0xFF16221C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: done ? const Color(0xFF7FC98A) : const Color(0xFF26332B)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (done) ...[
          const Icon(Icons.check, size: 13, color: Color(0xFF7FC98A)),
          const SizedBox(width: 4),
        ],
        Text('$label  $built/$target',
            style: TextStyle(
                color: done ? const Color(0xFF7FC98A) : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// foursome, the historic behaviour) or One Day Ryder Cup (locks
/// every foursome to Triple Cup — fourball + foursomes + 2 singles).
/// Becomes read-only once any foursome has been committed so a
/// half-configured round can't mix formats.
class _RoundFormatToggle extends StatelessWidget {
  final String value;
  final bool   locked;
  final ValueChanged<String> onChanged;
  const _RoundFormatToggle({
    required this.value,
    required this.locked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Round format',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          if (locked)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Locked after the first foursome is committed.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            ChoiceChip(
              label: const Text('Custom'),
              selected: value == 'custom',
              onSelected: locked ? null : (_) => onChanged('custom'),
            ),
            ChoiceChip(
              label: const Text('One-Day Triple Cup'),
              selected: value == 'triple_cup',
              onSelected: locked ? null : (_) => onChanged('triple_cup'),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Inline note that replaces the per-foursome game picker when the
/// One Day Ryder Cup preset is active.  Clarifies that every
/// foursome will play Triple Cup automatically.
class _TripleCupFormatNote extends StatelessWidget {
  const _TripleCupFormatNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.primary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Every foursome plays Triple Cup',
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          Text(
            'One-Day Triple Cup locks every foursome to the same 4-match '
            'format:\n'
            '  •  Holes 1–6 — Fourball (best-ball match play)\n'
            '  •  Holes 7–12 — Foursomes (alt-shot)\n'
            '  •  Holes 13–18 — two simultaneous singles matches\n'
            'Each foursome contributes 4 cup points.  Skip ahead to '
            'pick players for each group.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
