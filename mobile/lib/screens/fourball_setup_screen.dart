/// screens/fourball_setup_screen.dart
/// -----------------------------------
/// Setup for the Fourball casual game — a single 18-hole 2v2 best-ball match.
/// Pick the two fixed teams of two, the handicap mode, and the match bet.
/// Exactly four players. If a game is already started, jumps straight to
/// score entry.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/stake_field.dart';
import '../widgets/team_splitter_4.dart';

class FourballSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const FourballSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<FourballSetupScreen> createState() => _FourballSetupScreenState();
}

class _FourballSetupScreenState extends State<FourballSetupScreen> {
  // Casual default → Strokes-Off Low (the most-asked-for course setting); an
  // existing game overwrites this from its persisted mode on load.
  String _mode       = 'strokes_off';
  int    _netPercent = 100;
  final  _betCtrl    = TextEditingController();
  bool   _stakeOk    = false;

  /// `best_ball` (Fourball), `scramble` or `alternate_shot` — read off the
  /// round's games, so the three share this screen and the route.
  String _format = 'best_ball';
  bool get _oneBall => _format != 'best_ball';
  bool get _isAlt   => _format == 'alternate_shot';
  String get _title => _isAlt
      ? 'Alternate Shot'
      : _format == 'scramble' ? 'Two-man Scramble' : 'Fourball';

  /// A flat allowance for every golfer in place of the pairs table. Null =
  /// the table (35% low + 15% high for a scramble, 50% of combined for
  /// alternate shot).
  int? _allowancePct;
  /// Alternate shot: who tees off the first hole played, per side.
  int? _firstTee1;
  int? _firstTee2;
  /// Scramble match: `none` | `per_nine` | `per_eighteen`, and how many
  /// drives each golfer owes per window.
  String _driveRule = 'none';
  int    _drivesEach = 1;

  List<Membership> _ordered = const [];   // [0,1] = team 1, [2,3] = team 2
  bool    _loading  = true;
  bool    _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool    _editing  = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    super.dispose();
  }

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId).firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final rp = context.read<RoundProvider>();
      final games = {
        ...?rp.round?.activeGames,
        ...?rp.round?.foursomes
            .where((f) => f.id == widget.foursomeId)
            .firstOrNull
            ?.activeGames,
      };
      _format = games.contains(GameIds.alternateShotMatch)
          ? 'alternate_shot'
          : games.contains(GameIds.scrambleMatch) ? 'scramble' : 'best_ball';
      // A pair match has no strokes-off-the-low-golfer: the allowance is the
      // PAIR's, and the difference between pairs is what is played off.
      if (_oneBall) _mode = 'net';
      // Only prefill a real, previously-set stake — a fresh round (bet 0)
      // starts empty so the stake gate forces a conscious stake / "Play for
      // fun" choice before Start enables.
      final bet = rp.round?.betUnit ?? 0;
      if (bet > 0) {
        _betCtrl.text = bet.toStringAsFixed(bet % 1 == 0 ? 0 : 2);
        _stakeOk = true;
      }

      try {
        final existing = await client.getFourballSummary(widget.foursomeId);
        // A configured game has both teams assigned (isStarted) — even at
        // status 'pending' before any hole is scored.
        final configured = existing.status == 'in_progress' ||
            existing.status == 'complete' ||
            existing.status == 'halved' ||
            existing.isStarted;
        // Normal flow: an already-set-up game jumps straight to score entry.
        // In edit mode (returnToHub) stay on the form so settings can change.
        if ((existing.status == 'in_progress' ||
                existing.status == 'complete' ||
                existing.status == 'halved') &&
            !widget.returnToHub) {
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed(
              '/score-entry', arguments: widget.foursomeId);
          return;
        }
        if (configured) _editing = true;
        _mode       = _oneBall && existing.handicapMode == 'strokes_off'
            ? 'net' : existing.handicapMode;
        _netPercent = existing.netPercent;
        _allowancePct = existing.allowancePct;
        _driveRule    = existing.driveRule;
        _drivesEach   = existing.drivesRequired;
        _firstTee1 = existing.firstTee[1];
        _firstTee2 = existing.firstTee[2];
        if (existing.betAmount > 0) {
          _betCtrl.text = existing.betAmount
              .toStringAsFixed(existing.betAmount % 1 == 0 ? 0 : 2);
        }
        // Restore teams if assigned.
        final members = _realMembers;
        final byId = {for (final m in members) m.player.id: m};
        if (existing.team1.playerIds.length == 2 &&
            existing.team2.playerIds.length == 2) {
          _ordered = [
            for (final id in existing.team1.playerIds) byId[id],
            for (final id in existing.team2.playerIds) byId[id],
          ].whereType<Membership>().toList();
        }
      } catch (_) {/* no existing game — default split below */}

      if (_ordered.length != 4) _ordered = List.of(_realMembers);
      setState(() { _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  bool get _rosterValid => _realMembers.length == 4 && _ordered.length == 4;

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      // **The stake is the MATCH's, not the round's.** This used to call
      // `updateRoundBetUnit`, which is the figure Honors, Nassau and the rest
      // read as their own stake — so setting a $20 fourball silently restaked
      // every side game on the round. `FourballGame.bet_amount` is the game's
      // own field and the only one its settlement reads; the round's unit is
      // left where the round set it.
      final parsed = double.tryParse(_betCtrl.text.trim()) ?? 0;

      await client.postFourballSetup(
        widget.foursomeId,
        team1PlayerIds: [_ordered[0].player.id, _ordered[1].player.id],
        team2PlayerIds: [_ordered[2].player.id, _ordered[3].player.id],
        handicapMode: _mode,
        netPercent: _netPercent,
        betAmount: parsed,
        ballFormat: _format,
        allowancePct: _oneBall ? _allowancePct : null,
        driveRule: _format == 'scramble' ? _driveRule : 'none',
        drivesRequired: _drivesEach,
        team1FirstTee: _isAlt ? (_firstTee1 ?? _ordered[0].player.id) : null,
        team2FirstTee: _isAlt ? (_firstTee2 ?? _ordered[2].player.id) : null,
      );

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": reload the round so the
        // launch page reflects the freshly-saved game, then pop back to it.
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
            '/score-entry', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_editing ? 'Edit $_title' : '$_title — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load)
              : Column(children: [
                  Expanded(child: _buildBody()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: (_rosterValid && _stakeOk && !_starting)
                              ? _start : null,
                          child: _starting
                              ? const SizedBox(
                                  height: 20, width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(_editing
                                  ? 'Save Configuration'
                                  : 'Start $_title'),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _buildBody() {
    if (_realMembers.length != 4) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(
          '$_title needs exactly four players (two teams of two).',
          textAlign: TextAlign.center)),
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Teams',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_isAlt
                ? 'Drag to set the two pairs — partners share a color. Each '
                  'pair plays one ball, hit in turn.'
                : _oneBall
                    ? 'Drag to set the two pairs — partners share a color. '
                      'Both hit, the pair plays the better ball, one score '
                      'a hole.'
                    : 'Drag to set the two teams — partners share a color. The '
                      'better of each team’s two balls counts on every hole.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TeamSplitter4(
              players: _ordered,
              onChanged: (o) => setState(() => _ordered = o),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        if (_oneBall) ..._pairOptions(theme)
        else HandicapModeSelector(
          mode: _mode,
          netPercent: _netPercent,
          onModeChanged: (m) => setState(() => _mode = m),
          onPercentChanged: (p) => setState(() => _netPercent = p),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'The Match',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('One 18-hole match decided by holes won, lost, or halved '
                '(up/down, dormie). The winning team collects the stake; a '
                'halved match is a push.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            StakeField(
              controller: _betCtrl,
              onChanged: (ok) => setState(() => _stakeOk = ok),
              label: 'Match stake (\$ per player)',
            ),
          ]),
        ),
      ],
    );
  }

  // ── The pair formats ──────────────────────────────────────────────────────
  //
  // The same options the Team Play pairs offer: the format's own allowance
  // table, one flat percentage in its place if the group has its own, and —
  // in alternate shot — who tees the first hole (the rota is fixed for the
  // round, like the pairs' rota is).

  String get _tableText => _isAlt
      ? '50% of the pair’s combined handicap'
      : '35% of the low handicap + 15% of the high';

  String _name(int i) => _ordered[i].player.shortName.isNotEmpty
      ? _ordered[i].player.shortName : _ordered[i].player.name;

  List<Widget> _pairOptions(ThemeData theme) {
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return [
      SectionCard(
        title: 'Handicap',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Each pair plays off $_tableText. The pair with the higher '
              'allowance gets the difference in strokes, spread by stroke '
              'index; the other plays to scratch.', style: muted),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'net', label: Text('Net')),
              ButtonSegment(value: 'gross', label: Text('Gross')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          if (_mode == 'net') ...[
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use one percentage for everyone'),
              subtitle: Text(
                  'Your group’s own number instead of the table.',
                  style: muted),
              value: _allowancePct != null,
              onChanged: (on) =>
                  setState(() => _allowancePct = on ? 50 : null),
            ),
            if (_allowancePct != null)
              Row(children: [
                Expanded(
                  child: Slider(
                    value: _allowancePct!.toDouble(),
                    min: 10, max: 100, divisions: 18,
                    label: '$_allowancePct%',
                    onChanged: (v) =>
                        setState(() => _allowancePct = v.round()),
                  ),
                ),
                SizedBox(width: 44, child: Text('$_allowancePct%')),
              ]),
          ],
        ]),
      ),
      if (_format == 'scramble') ...[
        const SizedBox(height: 12),
        _driveSection(theme, muted),
      ],
      if (_isAlt) ...[
        const SizedBox(height: 12),
        SectionCard(
          title: 'Who tees off the first hole',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Partners alternate tee shots from there, hole after hole. '
                'It is fixed for the round — a pair that loses track plays a '
                'hole out of order.', style: muted),
            const SizedBox(height: 10),
            for (final side in const [0, 2]) ...[
              Text(side == 0 ? 'Pair 1' : 'Pair 2',
                  style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                segments: [
                  for (final i in [side, side + 1])
                    ButtonSegment(
                        value: _ordered[i].player.id, label: Text(_name(i))),
                ],
                selected: {
                  (side == 0 ? _firstTee1 : _firstTee2) ??
                      _ordered[side].player.id
                },
                onSelectionChanged: (v) => setState(() {
                  if (side == 0) { _firstTee1 = v.first; }
                  else { _firstTee2 = v.first; }
                }),
              ),
              const SizedBox(height: 10),
            ],
          ]),
        ),
      ],
    ];
  }

  // Drive requirement — the same rule the Team Play pairs offer. Optional; it
  // adds one tap a hole (whose drive the pair took) and costs nothing if a
  // pair falls short: it is a record, and the match is decided on the score.
  Widget _driveSection(ThemeData theme, TextStyle? muted) {
    final perNine = _driveRule == 'per_nine';
    final window  = perNine ? 9 : 18;
    final owed    = _drivesEach * 2;
    final free    = (window - owed).clamp(0, 18);
    final maxEach = window ~/ 2;
    return SectionCard(
      title: 'Drive requirement',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Optional. Adds one tap per hole to say whose drive the pair '
            'took. Falling short costs nothing.', style: muted),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'none', label: Text('None')),
            ButtonSegment(value: 'per_nine', label: Text('Per nine')),
            ButtonSegment(value: 'per_eighteen', label: Text('Per 18')),
          ],
          selected: {_driveRule},
          onSelectionChanged: (v) => setState(() {
            _driveRule = v.first;
            final cap = (_driveRule == 'per_nine' ? 9 : 18) ~/ 2;
            if (_drivesEach > cap) _drivesEach = cap;
          }),
        ),
        if (_driveRule != 'none') ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Text(
                perNine ? 'Drives each, per nine' : 'Drives each, across 18',
                style: theme.textTheme.bodyMedium)),
            IconButton(
              key: const ValueKey('drives-minus'),
              onPressed: _drivesEach > 1
                  ? () => setState(() => _drivesEach--) : null,
              icon: const Icon(Icons.remove_circle_outline)),
            Text('$_drivesEach', key: const ValueKey('drives-each'),
                style: theme.textTheme.titleMedium),
            IconButton(
              key: const ValueKey('drives-plus'),
              onPressed: _drivesEach < maxEach
                  ? () => setState(() => _drivesEach++) : null,
              icon: const Icon(Icons.add_circle_outline)),
          ]),
          Text(free > 0
              ? 'Two golfers owe $owed of $window holes — $free '
                'hole${free == 1 ? '' : 's'} free either way.'
              : 'No slack at all — every hole has to go to a golfer who owes '
                'one.', style: muted),
          if (perNine)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('The front nine does not carry to the back.',
                  style: muted),
            ),
        ],
      ]),
    );
  }
}
