/// screens/multi_skins_setup_screen.dart
/// -------------------------------------
/// Setup screen for Multi-Foursome Skins — a round-level skins pool that
/// crosses every participating foursome.
///
/// Setup knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + Net % allowance
///   • Bet unit — each participating player chips in this amount
///   • Roster — pick which players (across every foursome in the round)
///     are paying into the pool.  Defaults to all real players checked.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../utils/skins_cards.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/inline_message.dart';
import '../widgets/skin_validation_card.dart';

class MultiSkinsSetupScreen extends StatefulWidget {
  final int roundId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to the game screen), and
  /// returns to the /round launch page on save instead of jumping to the game.
  final bool returnToHub;

  const MultiSkinsSetupScreen({
    super.key,
    required this.roundId,
    this.returnToHub = false,
  });

  @override
  State<MultiSkinsSetupScreen> createState() => _MultiSkinsSetupScreenState();
}

class _MultiSkinsSetupScreenState extends State<MultiSkinsSetupScreen> {
  // Multi-Group Skins defaults to Net — Strokes-Off Low doesn't translate
  // across foursomes since there's no single "best golfer" in a multi-
  // group pool.  Per-foursome games default to SO Low instead.
  String _mode       = 'net';
  int    _netPercent = 100;
  // Validation (services/skin_rules.py) — the same two rules round skins has.
  String _skinMinimum = 'none';
  bool   _birdieSteal = false;

  final TextEditingController _betCtrl = TextEditingController();
  bool _betCtrlInitialized = false;
  /// Explicit opt-in to a no-money game (lets Start proceed at $0 entry).
  bool _noStakes = false;

  /// player_id → checked
  final Map<int, bool> _participants = {};

  /// Narrows the roster. A 60-player tournament field is a scroll, and the
  /// TD is looking for named golfers rather than reading the list.
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// True on a tournament round, which changes three things about this
  /// screen — see [_isTournamentRound].
  bool _isTournament = false;

  /// Connected (on-app) golfers NOT in this round — they ante into the pool but
  /// play in their own round, which the host links to this pool from its hub
  /// (docs/multi-skins-cross-round.md). Only Halved members can be matched
  /// across rounds, so login-less golfers are intentionally excluded.
  List<PlayerProfile> _externalGolfers = [];

  /// Player ids that are on Halved — the only golfers eligible for the pool
  /// (roster is Halved-only; login-less golfers can't be matched cross-round).
  Set<int> _onAppIds = {};

  bool    _loading  = true;
  bool    _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool    _editing  = false;
  Object? _error;

  MultiSkinsSummary? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// **A tournament pool is a different question from a casual one**, and
  /// three things follow from it:
  ///
  /// 1. *Nobody is ticked by default.* A casual pool is the round's whole
  ///    point, so everybody is in; a tournament pool is SPARSE — twenty of
  ///    sixty — and defaulting to all would mean unticking forty.
  /// 2. *Every seated golfer is eligible.* The "needs somebody on Halved on
  ///    his card" rule is about a CASUAL multi-group round, where each card
  ///    needs its own scorer. A tournament group already has one, which is
  ///    Paul's own distinction: *when skins is attached to groups that
  ///    already exist the group already has a scorer and the question does
  ///    not arise.* The server has always agreed — `valid_participant_ids`
  ///    admits host-round members, login-less included.
  /// 3. *No golfer from outside the round.* That section exists for a pool
  ///    whose other participants play in their own rounds and link in by
  ///    watch link. A tournament round holds the whole field, so an outsider
  ///    would ante into a pool he has no card in — and the server refuses
  ///    him.
  bool get _isTournamentRound => _isTournament;

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      _summary = await client.getMultiSkinsSummary(widget.roundId);
      if (!mounted) return;

      // A configured game reports its players even before any hole is scored
      // (status 'pending' is sent both when no game exists AND when one exists
      // but is unscored — a non-empty players list is the "already set up"
      // tell).
      final configured =
          _summary!.status == 'in_progress' || _summary!.players.isNotEmpty;

      // Which golfers are on Halved — the pool is Halved-only, so only they are
      // eligible. Fetch first so the roster defaults + gating below can use it.
      // Best-effort: a failed fetch leaves _onAppIds empty (nothing eligible),
      // and hides the external section.
      _isTournament =
          context.read<RoundProvider>().round?.tournamentId != null;
      final memberIds = _allMemberships.map((m) => m.player.id).toSet();
      try {
        final all = await client.getPlayers();
        if (mounted) {
          _onAppIds = all.where((p) => p.isOnApp).map((p) => p.id).toSet();
          _externalGolfers = all
              .where((p) => p.isOnApp && !memberIds.contains(p.id))
              .toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        }
      } catch (_) { /* roster fetch is best-effort */ }

      // Pre-populate roster from an existing game, or default to all
      // ELIGIBLE round players.
      //
      // **A login-less golfer is eligible when somebody on his card is on
      // Halved.** This screen used to refuse him outright, which is how a
      // guest seated in the TD's own foursome — his score being kept on that
      // card like everyone else's — was left out of the pool and off its
      // leaderboard while appearing on the round's Stroke Play tab. The
      // engine never required it: `valid_participant_ids` admits host-round
      // members "(login-less OK)".
      final existingIds = _summary!.players.map((p) => p.playerId).toSet();
      final mates = _cardMates;
      // Default: everybody on a casual round, NOBODY on a tournament one.
      // See `_isTournamentRound` — sparse is the point there, and ticking
      // sixty so the TD can untick forty is the wrong way round.
      final defaultOn = !_isTournament;
      for (final m in _allMemberships) {
        final eligible = _canJoin(m.player.id, mates);
        _participants[m.player.id] = eligible &&
            (existingIds.isEmpty ? defaultOn
                                 : existingIds.contains(m.player.id));
      }
      for (final g in _externalGolfers) {
        _participants[g.id] = existingIds.contains(g.id);
      }

      setState(() {
        if (configured) _editing = true;
        _mode       = _summary!.handicapMode;
        _netPercent = _summary!.netPercent;
        _skinMinimum = _summary!.skinMinimum;
        _birdieSteal = _summary!.birdieSteal;
        if (!_betCtrlInitialized) {
          // Default to $10 (the common "everyone throw in a ten" amount).
          // Existing game: use whatever the user previously saved.
          final v = _summary!.betUnit > 0 ? _summary!.betUnit : 10.0;
          // Drop trailing .00 so the placeholder reads "10" not "10.00".
          _betCtrl.text = v == v.roundToDouble()
              ? v.toStringAsFixed(0)
              : v.toStringAsFixed(2);
          _betCtrlInitialized = true;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// player id → the OTHER golfers on his scorecard.
  ///
  /// A login-less golfer can be in the pool, but only if one of them is on
  /// Halved to enter his score — the rule `utils/skins_cards.canJoinPool`
  /// states, and the reason this screen needs the seating and not just the
  /// roster.
  Map<int, List<int>> get _cardMates {
    final rp = context.read<RoundProvider>();
    final out = <int, List<int>>{};
    for (final fs in rp.round?.foursomes ?? const <Foursome>[]) {
      final ids = [
        for (final m in fs.memberships)
          if (!m.player.isPhantom) m.player.id,
      ];
      for (final id in ids) {
        out[id] = [for (final o in ids) if (o != id) o];
      }
    }
    return out;
  }

  /// His group number, for the line that says who keeps his score.
  Map<int, int> get _groupOf {
    final rp = context.read<RoundProvider>();
    final out = <int, int>{};
    for (final fs in rp.round?.foursomes ?? const <Foursome>[]) {
      for (final m in fs.memberships) {
        if (!m.player.isPhantom) out[m.player.id] = fs.groupNumber;
      }
    }
    return out;
  }

  bool _canJoin(int playerId, Map<int, List<int>> mates) =>
      // In a tournament the groups already exist and already have a scorer,
      // so the card-mate rule has nothing to decide — point 2 of
      // `_isTournamentRound`.
      _isTournament ||
      canJoinPool(
        isOnApp: _onAppIds.contains(playerId),
        cardMatesOnApp:
            (mates[playerId] ?? const []).map(_onAppIds.contains),
      );

  /// The roster in the order a TD reads a draw — by group, then by name. A
  /// casual pool keeps card order, which is how its own screens list it.
  List<Membership> get _rosterInOrder {
    final out = [..._allMemberships];
    if (_isTournament) {
      final g = _groupOf;
      out.sort((a, b) {
        final ga = g[a.player.id] ?? 1 << 20;
        final gb = g[b.player.id] ?? 1 << 20;
        return ga != gb
            ? ga.compareTo(gb)
            : a.player.name.toLowerCase().compareTo(b.player.name.toLowerCase());
      });
    }
    return out;
  }

  bool _matchesQuery(String name) =>
      _query.isEmpty || name.toLowerCase().contains(_query);

  void _setAll(bool on) => setState(() {
        final mates = _cardMates;
        for (final m in _allMemberships) {
          _participants[m.player.id] = on && _canJoin(m.player.id, mates);
        }
        if (!on) {
          for (final g in _externalGolfers) {
            _participants[g.id] = false;
          }
        }
      });

  List<Membership> get _allMemberships {
    final rp = context.read<RoundProvider>();
    final out = <Membership>[];
    for (final fs in rp.round?.foursomes ?? const <Foursome>[]) {
      for (final m in fs.memberships) {
        if (!m.player.isPhantom) out.add(m);
      }
    }
    return out;
  }

  int get _participantCount => _participants.values.where((v) => v).length;

  double get _betUnit {
    final v = double.tryParse(_betCtrl.text.trim());
    return v == null || v < 0 ? 0.0 : v;
  }

  double get _pool => _participantCount * _betUnit;

  bool get _canStart =>
      _participantCount >= 2 && (_betUnit > 0 || _noStakes);

  Future<void> _start() async {
    if (!_canStart) return;
    setState(() { _starting = true; });
    try {
      final client = context.read<AuthProvider>().client;
      final ids = _participants.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toList();
      final rp = context.read<RoundProvider>();
      await client.postMultiSkinsSetup(
        widget.roundId,
        participantIds: ids,
        handicapMode  : _mode,
        netPercent    : _netPercent,
        betUnit       : _betUnit,
        skinMinimum   : _skinMinimum,
        birdieSteal   : _birdieSteal,
      );
      // Refresh round so multi_skins shows up in activeGames, and pre-load
      // the summary into the provider.
      await rp.loadRound(widget.roundId);
      await rp.loadMultiSkins(widget.roundId);
      if (!mounted) return;

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": return to the launch page
        // sitting below us.  The round was reloaded above so the hub reflects
        // the freshly-saved game; pop (rather than pushing a new /multi-skins)
        // to keep a single hub on the stack.
        await context.read<RoundProvider>().loadRound(widget.roundId);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacementNamed(
          '/multi-skins',
          arguments: widget.roundId,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to start: $e'),
        ));
        setState(() { _starting = false; });
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: const GolfAppBar(title: 'Multi-Group Skins Setup'),
        body: ErrorView(message: friendlyError(_error!), onRetry: _load),
      );
    }

    return Scaffold(
      appBar: GolfAppBar(
          title: _editing
              ? 'Edit Multi-Group Skins'
              : 'Multi-Group Skins Setup'),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                  _isTournamentRound
                      ? 'A skins pool across the groups, played by whoever '
                          'is in it. Lowest score on each hole wins 1 skin; '
                          'tied holes die (no carryover).'
                      : 'Round-level skins pool. Lowest score on each hole '
                          'wins 1 skin; tied holes die (no carryover).',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),

              // ── Handicap mode ────────────────────────────────────────────
              HandicapModeSelector(
                mode:             _mode,
                netPercent:       _netPercent,
                onModeChanged:    (m) => setState(() => _mode = m),
                onPercentChanged: (p) => setState(() => _netPercent = p),
              ),
              const Divider(height: 32),

              // ── Validation ───────────────────────────────────────────────
              SkinValidationCard(
                // The server's words for each rule, so this screen and the
            // board cannot describe one rule two ways.
            ruleCopy:    _summary?.skinRuleCopy ?? const [],
            minimum:     _skinMinimum,
                birdieSteal: _birdieSteal,
                onMinimumChanged: (v) => setState(() => _skinMinimum = v),
                onBirdieStealChanged: (v) => setState(() => _birdieSteal = v),
              ),
              const Divider(height: 32),

              // ── Bet unit ─────────────────────────────────────────────────
              Row(children: [
                const Expanded(
                    flex: 2, child: Text('Entry fee per player (\$)')),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _betCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(
                      prefixText: '\$ ', isDense: true,
                    ),
                    onChanged: (_) => setState(() {
                      if (_betUnit > 0 && _noStakes) _noStakes = false;
                    }),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Pool: \$${_pool.toStringAsFixed(2)} '
                '($_participantCount × \$${_betUnit.toStringAsFixed(2)})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Play for fun — no stakes'),
                value: _noStakes,
                onChanged: (v) => setState(() {
                  _noStakes = v ?? false;
                  if (_noStakes) _betCtrl.text = '0';
                }),
              ),
              const Divider(height: 32),

              // ── Roster (flat list) ───────────────────────────────────────
              // Flat, not grouped by card. The groups ARE arbitrary now
              // (4, 1, 1, 2 on a spread-out field), but this screen asks who
              // is anteing in, which is a question about golfers; who shares
              // a card is the Groups screen's. A guest's row names his card
              // because for him the two questions meet.
              Row(children: [
                Expanded(
                  child: Text(
                    _isTournamentRound
                        // The field size is the thing that makes it sparse,
                        // so both numbers are in the heading.
                        ? 'In the pool — $_participantCount of '
                            '${_allMemberships.length}'
                        : 'Participants',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                // Plain words, because "Select all" on a filtered list is
                // ambiguous and these act on the WHOLE field either way.
                TextButton(
                    onPressed: () => _setAll(true), child: const Text('All')),
                TextButton(
                    onPressed: () => _setAll(false), child: const Text('None')),
              ]),
              if (_isTournamentRound) ...[
                Text(
                  'Tick whoever is in. Their scores come off the cards their '
                  'groups are already keeping — there is nothing else to set '
                  'up and no re-grouping to do.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
              ],
              // A field this size is searched, not read.
              if (_allMemberships.length > 12)
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Find a golfer',
                    border: const OutlineInputBorder(),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() {
                              _searchCtrl.clear();
                              _query = '';
                            }),
                          ),
                  ),
                  onChanged: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                ),
              const SizedBox(height: 4),
              // Hoisted out of the rows: both of these walk every foursome,
              // and inside a 60-row builder that is 60 walks of the draw.
              ...(() {
                final mates   = _cardMates;
                final groupOf = _groupOf;
                final rows    = [
                  for (final m in _rosterInOrder)
                    if (_matchesQuery(m.player.name)) m,
                ];
                if (rows.isEmpty) {
                  return <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('Nobody in this round matches “$_query”.',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ];
                }
                int? lastGroup;
                final out = <Widget>[];
                for (final m in rows) {
                  final onApp   = _onAppIds.contains(m.player.id);
                  final canJoin = _canJoin(m.player.id, mates);
                  final group   = groupOf[m.player.id];
                  // Grouped by card in a tournament, because that is how a
                  // draw is read and how the TD knows who he is looking at.
                  // Suppressed while searching: a one-row band per match is
                  // noise, and the row's own line names the group.
                  if (_isTournamentRound && _query.isEmpty &&
                      group != lastGroup) {
                    lastGroup = group;
                    out.add(Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 2),
                      child: Text('Group ${group ?? '?'}',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                    ));
                  }
                  out.add(CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(m.player.name),
                    // A guest says WHO keeps his score, because that is the
                    // whole question about him — and when nobody does, it
                    // says that instead of "not on Halved", which sounds like
                    // a fact about him rather than something fixable. In a
                    // tournament nobody is in that state, so the line is the
                    // index and his group.
                    subtitle: Text(_isTournamentRound
                        ? 'Index ${m.player.handicapIndex} · Group '
                            '${group ?? '?'}'
                        : onApp
                            ? 'Index ${m.player.handicapIndex}'
                            : canJoin
                                ? 'Index ${m.player.handicapIndex} · scored '
                                    'on Group ${group ?? '?'}\'s card'
                                : 'Needs somebody on Halved on his card — '
                                    'see Groups'),
                    value: canJoin && (_participants[m.player.id] ?? false),
                    onChanged: canJoin
                        ? (v) => setState(() {
                              _participants[m.player.id] = v ?? false;
                            })
                        : null,
                  ));
                }
                return out;
              })(),
              // ── Other Halved golfers (each gets their own group of one) ────
              // Never in a tournament: the field is already here, and a
              // golfer from outside it would ante into a pool he has no card
              // in. The server refuses him by name.
              if (!_isTournamentRound && _externalGolfers.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 2),
                  child: Text('Add golfers',
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                Text(
                  'Each gets their own group and enters their own score. If '
                  'they\'re playing a foursome game (e.g. Sixes), link that '
                  'round to the pool from its hub instead.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final g in _externalGolfers)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(g.name),
                    subtitle: Text('Index ${g.handicapIndex}'),
                    value: _participants[g.id] ?? false,
                    onChanged: (v) => setState(() {
                      _participants[g.id] = v ?? false;
                    }),
                  ),
              ],
            ],
          ),
        ),

        // ── Persistent Start button (outside ListView so it stays above
        // the soft keyboard when the bet field is being edited). ─────────
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(children: [
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _canStart && !_starting ? _start : null,
                  child: _starting
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(_editing
                          ? 'Save Configuration'
                          : 'Start Multi-Group Skins',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              if (!_canStart)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InlineMessage(
                    kind: InlineMessageKind.warn,
                    text: _participantCount < 2
                        ? 'Pick at least 2 participants.'
                        : 'Enter an entry fee, or tick “Play for fun”.',
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
