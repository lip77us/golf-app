/// screens/onboarding_wizard.dart
/// ------------------------------
/// Guided first-round setup for brand-new accounts.  A linear stepper that
/// sequences the same building blocks the full casual picker uses — so a new
/// user (no course, no other golfers, unsure which game) can't miss a step:
///
///   0. Welcome      — what the app does.
///   1. Add a course — inline catalog search (CourseSearchField).
///   2. Add golfers  — you're in; add 1–3 more (PlayerFormScreen).  2–4 total.
///   3. Pick a game  — Skins featured for beginners (simple, fixed rules) with
///                     a "More games" expander; non-Skins games hand off to
///                     their own setup screen.
///
/// Round creation + route dispatch go through the shared [createCasualRound]
/// helper, so this flow can never drift from the full picker.  "Skip" is always
/// available; this is never a trap.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/create_casual_round.dart';
import '../utils/golfer_invite.dart';
import '../widgets/course_search_field.dart';
import '../widgets/error_view.dart';
import '../widgets/halved_mark.dart';
import '../widgets/stake_field.dart';
import 'player_form_screen.dart';

class OnboardingWizard extends StatefulWidget {
  const OnboardingWizard({super.key});

  @override
  State<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends State<OnboardingWizard> {
  static const int _lastStep = 3;

  int _step = 0;

  CourseInfo? _course;
  List<PlayerProfile> _players = [];
  final Set<int> _selected = {}; // selected player ids (you're auto-included)
  List<TeeInfo> _tees = [];

  String _game = GameIds.skins; // featured beginner game
  bool _showAllGames = false;

  final TextEditingController _betCtrl = TextEditingController();
  bool _stakeOk = false;

  bool _loadingRoster = true;
  bool _busy = false; // creating the round
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadRoster();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRoster() async {
    setState(() { _loadingRoster = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final authPlayer = context.read<AuthProvider>().player;
      final players = (await client.getPlayers())
          .where((p) => !p.isPhantom)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() {
        _players = players;
        // You're locked in as a participant from the start.
        if (authPlayer != null && players.any((p) => p.id == authPlayer.id)) {
          _selected.add(authPlayer.id);
        }
        _loadingRoster = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loadingRoster = false; });
    }
  }

  int? get _myId => context.read<AuthProvider>().player?.id;

  Future<void> _onCourseSelected(CourseInfo c) async {
    // A freshly cloned catalog course brings new tees — refresh so default
    // tee assignment can find them.
    try {
      final tees = await context.read<AuthProvider>().client.getTees();
      if (!mounted) return;
      setState(() { _course = c; _tees = tees; });
    } catch (_) {
      if (mounted) setState(() => _course = c);
    }
  }

  Future<void> _addGolfer() async {
    final created = await Navigator.of(context).push<PlayerProfile>(
      MaterialPageRoute(builder: (_) => const PlayerFormScreen()),
    );
    if (created == null || !mounted) return;
    setState(() {
      if (!_players.any((p) => p.id == created.id)) {
        _players = [..._players, created]
          ..sort((a, b) => a.name.compareTo(b.name));
      }
      if (_selected.length < 4) _selected.add(created.id);
    });
    await maybeOfferRoundSmsInvite(context, created, courseName: _course?.name);
  }

  void _togglePlayer(int id, bool on) {
    setState(() {
      if (on) {
        if (_selected.length >= 4) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('A casual round is one foursome — up to 4 golfers.'),
          ));
          return;
        }
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  /// Beginner-friendly games that fit the chosen group size (single foursome,
  /// so no across-group games), Skins first.
  List<GameMeta> _fittingGames() {
    final n = _selected.length;
    final list = casualGames
        // Side-game-only add-ons (Spots) aren't standalone games.
        .where((m) => !m.sideGameOnly && !m.acrossGroups && m.supportsSize(n))
        .toList();
    list.sort((a, b) {
      if (a.id == GameIds.skins) return -1;
      if (b.id == GameIds.skins) return 1;
      return a.displayName.compareTo(b.displayName);
    });
    return list;
  }

  /// Per-player default tees for the current selection, or null if the course
  /// has no matching tee for someone (an unseeded course — shouldn't happen).
  Map<int, int>? _buildTees() {
    final map = <int, int>{};
    for (final id in _selected) {
      final p = _players.firstWhere((p) => p.id == id);
      final tee = defaultTeeIdFor(_tees, _course!.id, p.sex);
      if (tee == null) return null;
      map[id] = tee;
    }
    return map;
  }

  void _teeError() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('That course has no tees set up. Pick another course.'),
    ));
  }

  /// Featured path: start Skins immediately with simple, fixed beginner rules —
  /// strokes off the low handicap, no carryover, no junk — then go score.
  Future<void> _startSimpleSkins() async {
    final tees = _buildTees();
    if (tees == null) { _teeError(); return; }
    setState(() { _busy = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final rp = context.read<RoundProvider>();
      final launch = await createCasualRound(
        client: client,
        roundProvider: rp,
        courseId: _course!.id,
        playerTees: tees,
        activeGames: {GameIds.skins},
        primaryGame: GameIds.skins,
      );
      final fsId = launch.firstFoursome!.id;

      final stake = double.tryParse(_betCtrl.text.trim()) ?? 0;
      if (rp.round != null && stake != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(stake);
      }
      await client.postSkinsSetup(
        fsId,
        handicapMode: 'strokes_off',
        netPercent: 100,
        carryover: false,
        allowJunk: false,
      );
      await rp.loadSkins(fsId);

      if (!mounted) return;
      // Wizard completed (a round was created) → retire the onboarding entry.
      context.read<SettingsProvider>().markOnboardingDone();
      Navigator.of(context)
          .pushReplacementNamed('/score-entry', arguments: fsId);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = e; });
    }
  }

  /// Any other game (or "Customize Skins rules"): create the round and hand off
  /// to that game's own setup screen via the shared dispatch.
  Future<void> _continueToSetup(String game) async {
    final tees = _buildTees();
    if (tees == null) { _teeError(); return; }
    setState(() { _busy = true; _error = null; });
    try {
      final launch = await createCasualRound(
        client: context.read<AuthProvider>().client,
        roundProvider: context.read<RoundProvider>(),
        courseId: _course!.id,
        playerTees: tees,
        activeGames: {game},
        primaryGame: game,
      );
      if (!mounted) return;
      // Wizard completed (a round was created) → retire the onboarding entry.
      context.read<SettingsProvider>().markOnboardingDone();
      // Land on the /round launch page; push the game's setup screen on top
      // (returnToHub mode) so saving setup pops back to the same hub.
      final nav = Navigator.of(context);
      nav.pushReplacementNamed('/round', arguments: launch.round.id);
      if (launch.route != null) {
        nav.pushNamed(launch.route!, arguments: launch.effectiveArgs);
      }
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = e; });
    }
  }

  /// Leave the wizard: pop if we were pushed onto a stack (drawer / empty-state
  /// re-entry), otherwise drop to the app's home.
  void _skip() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      nav.pushReplacementNamed('/tournaments');
    }
  }

  // ── Step navigation ──────────────────────────────────────────────────────

  bool get _canAdvance {
    switch (_step) {
      case 0:
        return true;
      case 1:
        return _course != null;
      case 2:
        return _selected.length >= 2 && _selected.length <= 4;
      default:
        return false;
    }
  }

  void _next() {
    if (_step == 2) {
      // Entering the game step: make sure the chosen game still fits the group.
      final fits = gameMeta(_game)?.supportsSize(_selected.length) ?? false;
      if (!fits) _game = GameIds.skins;
    }
    setState(() => _step = (_step + 1).clamp(0, _lastStep));
  }

  void _back() => setState(() => _step = (_step - 1).clamp(0, _lastStep));

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your first round'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _busy ? null : _skip,
            child: const Text('Skip'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _StepDots(step: _step, total: _lastStep + 1),
            Expanded(child: _buildBody()),
            _buildNav(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingRoster) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          switch (_step) {
            0 => _welcomeStep(),
            1 => _courseStep(),
            2 => _golfersStep(),
            _ => _gameStep(),
          },
          if (_error != null) ...[
            const SizedBox(height: 16),
            ErrorView(message: friendlyError(_error!)),
          ],
        ],
      ),
    );
  }

  // ── Step 0: Welcome ──
  Widget _welcomeStep() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Icon(Icons.sports_golf,
            size: 72, color: theme.colorScheme.primary),
        const SizedBox(height: 20),
        Text('Track your golf bets',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text(
          "Let's set up your first round. It takes three quick steps:\n"
          "pick a course, add the golfers you're playing with, and choose "
          'a game. We\'ll handle the scoring and the money.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _miniSteps(theme),
      ],
    );
  }

  Widget _miniSteps(ThemeData theme) {
    Widget row(IconData icon, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Text(label, style: theme.textTheme.bodyLarge),
          ]),
        );
    return Column(children: [
      row(Icons.golf_course, 'Find your course'),
      row(Icons.group_add_outlined, "Add who's playing"),
      row(Icons.casino_outlined, 'Pick a game and play'),
    ]);
  }

  // ── Step 1: Course ──
  Widget _courseStep() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Where are you playing?',
            style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Search by course or city. We\'ll pull in the tees and ratings.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        CourseSearchField(
          selected: _course,
          onSelected: _onCourseSelected,
        ),
      ],
    );
  }

  // ── Step 2: Golfers ──
  Widget _golfersStep() {
    final theme = Theme.of(context);
    final n = _selected.length;
    final tooMany = n > 4;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("Who's playing?", style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          n < 2
              ? 'Add at least one more golfer (2–4 total).'
              : tooMany
                  ? 'A casual round is one foursome — pick up to 4.'
                  : '$n golfers selected.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: (n < 2 || tooMany)
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addGolfer,
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
            label: const Text('Add a golfer'),
          ),
        ),
        const SizedBox(height: 4),
        for (final p in _players) _golferTile(p),
      ],
    );
  }

  Widget _golferTile(PlayerProfile p) {
    final theme = Theme.of(context);
    final selected = _selected.contains(p.id);
    final isMe = p.id == _myId;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: CheckboxListTile(
        value: selected,
        // You're always in; can't uncheck yourself.
        onChanged: isMe ? null : (v) => _togglePlayer(p.id, v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: Row(children: [
          Flexible(
            child: Text(p.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          if (p.isOnApp) ...[
            const SizedBox(width: 6),
            const HalvedMark(size: 16),
          ],
          if (isMe) ...[
            const SizedBox(width: 6),
            Chip(
              label: const Text('You', style: TextStyle(fontSize: 11)),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              backgroundColor: theme.colorScheme.secondaryContainer,
            ),
          ],
        ]),
        subtitle: Text('Index ${p.handicapIndex}',
            style: theme.textTheme.bodySmall),
      ),
    );
  }

  // ── Step 3: Game ──
  Widget _gameStep() {
    final theme = Theme.of(context);
    final games = _fittingGames();
    final others = games.where((m) => m.id != GameIds.skins).toList();
    final hasSkins = games.any((m) => m.id == GameIds.skins);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pick a game', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Skins is the easiest place to start. You can explore the rest any '
          'time.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (hasSkins)
              ChoiceChip(
                label: const Text('Skins · Recommended'),
                selected: _game == GameIds.skins,
                onSelected: (_) => setState(() => _game = GameIds.skins),
              ),
            if (_showAllGames)
              for (final m in others)
                ChoiceChip(
                  label: Text(m.displayName),
                  selected: _game == m.id,
                  onSelected: (_) => setState(() => _game = m.id),
                ),
          ],
        ),
        if (others.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _showAllGames = !_showAllGames),
              icon: Icon(_showAllGames
                  ? Icons.expand_less
                  : Icons.expand_more),
              label: Text(_showAllGames ? 'Fewer games' : 'More games'),
            ),
          ),
        const SizedBox(height: 8),
        if (_game == GameIds.skins) _simpleSkinsBody(theme) else _otherGameBody(theme),
      ],
    );
  }

  Widget _simpleSkinsBody(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.colorScheme.outline),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Simple Skins',
                    style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary)),
                const SizedBox(height: 8),
                Text(
                  'Each player chips in the stake. Low score on a hole wins a '
                  'skin; ties just move on. Strokes come off the low handicap, '
                  'and the pot is split by how many skins each golfer wins.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        StakeField(
          controller: _betCtrl,
          onChanged: (v) => setState(() => _stakeOk = v),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : () => _continueToSetup(GameIds.skins),
            child: const Text('Customize the rules instead'),
          ),
        ),
      ],
    );
  }

  Widget _otherGameBody(ThemeData theme) {
    final name = gameMeta(_game)?.displayName ?? _game;
    return Card(
      elevation: 0,
      color: theme.colorScheme.secondaryContainer.withOpacity(0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Icon(Icons.tune, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "Next we'll set up $name — handicaps and the stake.",
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ]),
      ),
    );
  }

  // ── Bottom navigation bar ──
  Widget _buildNav() {
    final isSkins = _game == GameIds.skins;
    final String primaryLabel;
    final VoidCallback? primaryAction;

    if (_step < _lastStep) {
      primaryLabel = _step == 0 ? 'Get started' : 'Next';
      primaryAction = _canAdvance ? _next : null;
    } else if (isSkins) {
      primaryLabel = 'Start Round';
      primaryAction = (_stakeOk && !_busy) ? _startSimpleSkins : null;
    } else {
      primaryLabel = 'Continue';
      primaryAction = _busy ? null : () => _continueToSetup(_game);
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(children: [
          if (_step > 0)
            OutlinedButton(
              onPressed: _busy ? null : _back,
              child: const Text('Back'),
            ),
          const Spacer(),
          FilledButton(
            onPressed: primaryAction,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(primaryLabel),
          ),
        ]),
      ),
    );
  }
}

/// Slim progress dots across the top of the wizard.
class _StepDots extends StatelessWidget {
  final int step;
  final int total;
  const _StepDots({required this.step, required this.total});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (int i = 0; i < total; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: i == step ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i <= step
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
