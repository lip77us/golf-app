/// screens/pink_ball_screen.dart
///
/// Score-entry screen for tournament rounds that include the Pink Ball game.
///
/// Layout:
///   • AppBar: "Pink Ball — Group N"  |  scorecard icon
///   • Carrier banner: "Hole N — [PlayerName] carries the [Pink] Ball"
///   • Player score rows (one per real player)
///   • Ball-lost toggle: "Lost the Pink Ball on this hole"
///   • Bottom nav: ← Prev  |  Next →
///
/// Scores are submitted via RoundProvider.submitHole() which persists offline
/// and syncs automatically (same path as all other entry screens).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';


class PinkBallScreen extends StatefulWidget {
  final int foursomeId;
  const PinkBallScreen({super.key, required this.foursomeId});

  @override
  State<PinkBallScreen> createState() => _PinkBallScreenState();
}

class _PinkBallScreenState extends State<PinkBallScreen> {
  int  _holeIndex = 0;          // 0-based; displayed as hole _holeIndex+1
  bool _ballLost  = false;
  bool _saving    = false;

  String _ballColor = 'Pink';
  List<int> _order  = [];       // 18 player PKs (carrier per hole)
  bool _configLoaded = false;

  // Ball-lost tracking: null = ball still in play.
  int? _ballLostOnHole;

  // Irish Rumble co-game info (null if not active).
  List<Map<String, dynamic>> _irishSegments = [];
  bool _irishRumbleActive = false;

  // Match Play co-game info (null if not active).
  bool _matchPlayActive = false;

  // Three-Person Match Phase 2 — true for 3-player groups in a tournament.
  bool _threePersonMatchActive = false;

  // Per-player gross score edits for the current hole.
  // Null = not yet entered this session (uses stored value from scorecard).
  final Map<int, int?> _pendingScores = {};

  // Match play refresh — sync-drain watcher + 3-second polling timer.
  SyncService?  _syncRef;
  VoidCallback? _syncWatcher;
  bool          _wasPending = false;
  Timer?        _matchPlayTimer;
  Timer?        _tpmTimer;

  @override
  void initState() {
    super.initState();

    // Polling timer: refreshes match play every 3 s while the screen is open.
    // Started immediately so it doesn't depend on postFrameCallback completing.
    _matchPlayTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !_matchPlayActive) return;
      context.read<RoundProvider>().loadMatchPlay(widget.foursomeId);
    });

    // Polling timer for Three-Person Match Phase 2 (3-player groups).
    _tpmTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_threePersonMatchActive) return;
      context.read<RoundProvider>().loadThreePersonMatch(widget.foursomeId);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initScreen();
    });
  }

  @override
  void dispose() {
    _syncRef?.removeListener(_syncWatcher!);
    _matchPlayTimer?.cancel();
    _tpmTimer?.cancel();
    super.dispose();
  }

  Future<void> _initScreen() async {
    final rp = context.read<RoundProvider>();
    if (rp.scorecard == null) {
      await rp.loadScorecard(widget.foursomeId);
    }
    // Jump to first unplayed hole
    final sc = rp.scorecard;
    if (sc != null) {
      final firstEmpty = sc.holes.indexWhere(
          (h) => h.scores.any((s) => s.grossScore == null));
      if (firstEmpty >= 0) {
        setState(() => _holeIndex = firstEmpty);
      }
    }
    // Load match play data if that game is also active — but NOT for
    // 3-player foursomes that play Three-Person Match (5-3-1) instead of
    // a bracket.  Those have three_person_match in configuredGames and must
    // never show the match play card.
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    final isThreePersonMatch =
        fs?.configuredGames.contains('three_person_match') == true;
    final games = {...?rp.round?.activeGames};
    final fsGames = fs?.activeGames ?? [];
    if (!isThreePersonMatch &&
        (games.contains('match_play') || fsGames.contains('match_play'))) {
      setState(() => _matchPlayActive = true);
      rp.loadMatchPlay(widget.foursomeId);
    }
    // Three-Person Match — load phase 2 data for back-9 display.
    if (isThreePersonMatch) {
      setState(() => _threePersonMatchActive = true);
      rp.loadThreePersonMatch(widget.foursomeId);
    }
    // Initialise phantom rotation config if this foursome has a phantom player.
    if (fs?.hasPhantom == true) {
      rp.initPhantom(widget.foursomeId);
    }

    // Register sync-drain watcher so match play reloads the moment each
    // submitted score lands on the server (pending→idle transition).
    final sync = context.read<SyncService>();
    _syncRef    = sync;
    _wasPending = sync.hasPending;
    _syncWatcher = () {
      if (!mounted) return;
      final nowPending = sync.hasPending;
      if (_wasPending && !nowPending) {
        if (_matchPlayActive) {
          context.read<RoundProvider>().loadMatchPlay(widget.foursomeId);
        }
        if (_threePersonMatchActive) {
          context.read<RoundProvider>().loadThreePersonMatch(widget.foursomeId);
        }
      }
      _wasPending = nowPending;
    };
    sync.addListener(_syncWatcher!);

    // Load pink ball config (ball colour + order)
    await _loadConfig();
  }

  Future<void> _loadConfig() async {
    final rp      = context.read<RoundProvider>();
    final roundId = rp.round?.id;
    if (roundId == null) return;
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getPinkBallSetup(roundId);
      final foursomeData = (data['foursomes'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (f) => (f['foursome_id'] as int?) == widget.foursomeId,
            orElse: () => <String, dynamic>{},
          );
      final rawOrder = foursomeData['order'] as List? ?? [];
      final order   = rawOrder.isEmpty
          ? <int>[]
          : List<int>.from(rawOrder.map((v) => v as int));
      final elim = foursomeData['eliminated_on_hole'];
      final ballLostOnHole = elim is int ? elim : null;

      // Load Irish Rumble segment config if that game is also active.
      List<Map<String, dynamic>> irishSegs = [];
      bool irishActive = false;
      if (rp.round?.activeGames.contains('irish_rumble') == true) {
        try {
          final irishData = await client.getIrishRumbleConfig(roundId);
          irishSegs = (irishData['segments'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          irishActive = irishSegs.isNotEmpty;
        } catch (_) {}
      }

      setState(() {
        _ballColor         = data['ball_color'] as String? ?? 'Pink';
        _order             = order;
        _configLoaded      = true;
        _ballLostOnHole    = ballLostOnHole;
        _irishSegments     = irishSegs;
        _irishRumbleActive = irishActive;
        // If the ball is already lost, reflect it on whatever hole we start on.
        if (_ballLostOnHole != null) {
          _ballLost = _ballLostOnHole == _holeNumber;
        }
      });
    } catch (_) {
      final fs = rp.round?.foursomes
          .firstWhere((f) => f.id == widget.foursomeId,
              orElse: () => rp.round!.foursomes.first);
      setState(() {
        _order        = fs?.pinkBallOrder ?? [];
        _configLoaded = true;
      });
    }
    // Force the player to confirm the ball rotation before scoring starts.
    // Count how many consecutive leading holes have complete scores — if none
    // have been played yet we always open the order sheet (non-dismissible),
    // even when the backend already returned a default order.  This mirrors
    // the Sixes "set teams before Match 4" gate.
    if (mounted) {
      final sc = context.read<RoundProvider>().scorecard;
      final fs = context.read<RoundProvider>().round?.foursomes.firstWhere(
            (f) => f.id == widget.foursomeId,
            orElse: () => context.read<RoundProvider>().round!.foursomes.first);
      final mems = fs?.memberships
              .where((m) => !m.player.isPhantom)
              .toList() ??
          <Membership>[];
      int holesScored = 0;
      if (sc != null && mems.isNotEmpty) {
        for (final hole in sc.holes) {
          final allScored = mems.every((m) => hole.scores
              .any((s) => s.playerId == m.player.id && s.grossScore != null));
          if (allScored) {
            holesScored++;
          } else {
            break;
          }
        }
      }
      if (holesScored == 0) {
        await _promptSetOrder();
      }
    }
  }

  /// Show a bottom sheet letting the foursome drag-to-reorder their players
  /// for the ball rotation.  Generates a round-robin 18-hole order on confirm.
  Future<void> _promptSetOrder() async {
    final rp = context.read<RoundProvider>();
    final foursome = rp.round?.foursomes.firstWhere(
        (f) => f.id == widget.foursomeId,
        orElse: () => rp.round!.foursomes.first);
    final members = foursome?.memberships
            .where((m) => !m.player.isPhantom)
            .toList() ??
        [];
    if (members.isEmpty) return;

    // Count how many leading holes have complete scores so we can lock
    // those positions in the rotation (once hole 1 is scored, position 1
    // is fixed; once hole 2 is scored, position 2 is fixed; etc.).
    int holesScored = 0;
    final sc = rp.scorecard;
    if (sc != null) {
      for (final hole in sc.holes) {
        final allScored = members.every((m) => hole.scores
            .any((s) => s.playerId == m.player.id && s.grossScore != null));
        if (allScored) {
          holesScored++;
        } else {
          break; // only count consecutive complete holes from hole 1
        }
      }
    }
    // With N players, after N-1 holes the 4th position is inferred → lock all.
    final lockedCount = holesScored >= members.length - 1
        ? members.length
        : holesScored;

    // Build the initial member order from the stored _order, if set.
    late final List<Membership> orderedMembers;
    if (_order.isNotEmpty) {
      // Re-order members to match the already-confirmed rotation.
      final seen = <int>{};
      final sorted = <Membership>[];
      for (final pid in _order) {
        if (!seen.contains(pid)) {
          seen.add(pid);
          final m = members.firstWhere((m) => m.player.id == pid,
              orElse: () => members.first);
          sorted.add(m);
        }
      }
      // Append any members not in _order (shouldn't happen, but safety net).
      for (final m in members) {
        if (!seen.contains(m.player.id)) sorted.add(m);
      }
      orderedMembers = sorted;
    } else {
      orderedMembers = List.of(members);
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: lockedCount >= members.length, // locked → dismissible
      enableDrag: false,
      isScrollControlled: true,
      builder: (ctx) => _OrderSetupSheet(
        ballColor:   _ballColor,
        members:     orderedMembers,
        lockedCount: lockedCount,
        onConfirm: (List<int> playerOrder) async {
          // Round-robin over 18 holes
          final fullOrder = List.generate(
              18, (i) => playerOrder[i % playerOrder.length]);
          try {
            final client = context.read<AuthProvider>().client;
            await client.postPinkBallOrder(
                widget.foursomeId, order: fullOrder);
            setState(() => _order = fullOrder);
          } catch (_) {
            // Non-fatal — the order stays empty; they can retry
          }
        },
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  int get _holeNumber => _holeIndex + 1;

  /// Returns balls_to_count for the current hole from the Irish Rumble segments,
  /// or null if Irish Rumble is not active or no segment covers this hole.
  int? get _irishBallsToCount {
    if (!_irishRumbleActive) return null;
    for (final seg in _irishSegments) {
      final start = seg['start_hole'] as int? ?? 1;
      final end   = seg['end_hole']   as int? ?? 18;
      if (_holeNumber >= start && _holeNumber <= end) {
        return seg['balls_to_count'] as int?;
      }
    }
    return null;
  }

  /// Player PK who carries the ball on the current hole.
  int? get _carrierId {
    if (_order.isEmpty) return null;
    return _order[_holeIndex % _order.length];
  }

  ScorecardHole? _currentHole(Scorecard sc) {
    if (_holeIndex >= sc.holes.length) return null;
    return sc.holes[_holeIndex];
  }

  /// Gross score to SHOW for a player on the current hole:
  /// 1. Session-pending edit (_pendingScores)
  /// 2. Stored gross from scorecard
  int? _displayScore(int playerId, ScorecardHole hole) {
    if (_pendingScores.containsKey(playerId)) return _pendingScores[playerId];
    return hole.scores
        .where((s) => s.playerId == playerId)
        .firstOrNull
        ?.grossScore;
  }

  bool _holeIsComplete(ScorecardHole hole, List<Membership> realMembers) {
    for (final m in realMembers) {
      final score = _displayScore(m.player.id, hole);
      if (score == null) return false;
    }
    return true;
  }

  // ── Edit existing score via modal ─────────────────────────────────────────

  Future<void> _editScore(Membership m, int par, int strokes) async {
    final current = _pendingScores[m.player.id]
        ?? context.read<RoundProvider>().scorecard
            ?.holeData(_holeNumber)
            ?.scoreFor(m.player.id)
            ?.grossScore;

    final score = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _EditScoreSheet(
        playerName: m.player.name,
        par:        par,
        holeNumber: _holeNumber,
        strokes:    strokes,
        current:    current,
      ),
    );
    if (!mounted || score == null) return;
    setState(() {
      if (score == -1) {
        _pendingScores.remove(m.player.id);
      } else {
        _pendingScores[m.player.id] = score;
      }
    });
  }

  // ── Score submission ──────────────────────────────────────────────────────

  Future<void> _save({bool advance = true}) async {
    final rp = context.read<RoundProvider>();
    final sc = rp.scorecard;
    if (sc == null) return;

    final hole        = _currentHole(sc);
    final realMembers = rp.round?.foursomes
        .firstWhere((f) => f.id == widget.foursomeId,
            orElse: () => rp.round!.foursomes.first)
        .memberships
        .where((m) => !m.player.isPhantom)
        .toList() ?? [];

    // Build score list from pending edits + existing stored scores
    final scoreList = <Map<String, int>>[];
    for (final m in realMembers) {
      final gross = _pendingScores.containsKey(m.player.id)
          ? _pendingScores[m.player.id]
          : hole?.scores
              .where((s) => s.playerId == m.player.id)
              .firstOrNull
              ?.grossScore;
      if (gross != null) {
        scoreList.add({'player_id': m.player.id, 'gross_score': gross});
      }
    }

    if (scoreList.isEmpty) return;

    setState(() => _saving = true);
    final ok = await rp.submitHole(
      foursomeId:   widget.foursomeId,
      holeNumber:   _holeNumber,
      scores:       scoreList,
      pinkBallLost: _ballLost,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      // Update ball-lost tracking based on what was just submitted.
      if (_ballLost) {
        _ballLostOnHole = _holeNumber;
      } else if (_ballLostOnHole == _holeNumber) {
        _ballLostOnHole = null;   // user corrected — ball not lost after all
      }
      // Reload match play / three-person match once the score has reached the server.
      if (_matchPlayActive || _threePersonMatchActive) {
        context.read<SyncService>().waitUntilIdle().then((_) {
          if (!mounted) return;
          if (_matchPlayActive) {
            context.read<RoundProvider>().loadMatchPlay(widget.foursomeId);
          }
          if (_threePersonMatchActive) {
            context.read<RoundProvider>().loadThreePersonMatch(widget.foursomeId);
          }
        });
      }
    }
    if (ok && advance && _holeIndex < 17) {
      setState(() {
        _holeIndex++;
        _ballLost = _ballLostOnHole == (_holeIndex + 1); // restore for new hole
        _pendingScores.clear();
      });
    } else if (ok && advance && _holeIndex == 17) {
      // Finished hole 18
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All 18 holes saved!')),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp    = context.watch<RoundProvider>();
    final sc    = rp.scorecard;
    final round = rp.round;

    if (rp.loadingScorecard || sc == null || !_configLoaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pink Ball')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final foursome = round?.foursomes.firstWhere(
        (f) => f.id == widget.foursomeId,
        orElse: () => round!.foursomes.first);
    final realMembers = foursome?.memberships
            .where((m) => !m.player.isPhantom)
            .toList() ??
        [];
    final phantomMember = foursome?.memberships
        .where((m) => m.player.isPhantom)
        .firstOrNull;

    final hole = _currentHole(sc);
    final par  = hole?.par ?? 4;

    // carrier name
    final cid          = _carrierId;
    final carrierMem   = cid == null
        ? null
        : realMembers.firstWhere((m) => m.player.id == cid,
            orElse: () => realMembers.first);
    final carrierName  = carrierMem?.player.name ?? '—';

    final complete = hole != null && _holeIsComplete(hole, realMembers);
    final groupNum = foursome?.groupNumber ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('Group $groupNum'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Leaderboard',
            onPressed: round == null
                ? null
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: round.id),
          ),
          IconButton(
            icon: const Icon(Icons.format_list_numbered),
            tooltip: 'Set ball rotation',
            onPressed: _promptSetOrder,
          ),
          IconButton(
            icon: const Icon(Icons.table_chart_outlined),
            tooltip: 'View scorecard',
            onPressed: () {
              context.read<RoundProvider>().loadScorecard(widget.foursomeId);
              Navigator.of(context).pushNamed('/scorecard', arguments: {
                'foursomeId': widget.foursomeId,
                'readOnly': true,
              });
            },
          ),
        ],
      ),
      body: Column(children: [
        // ── Hole chip strip ───────────────────────────────────────────────
        _HoleChipStrip(
          holeIndex:    _holeIndex,
          scorecard:    sc,
          realMembers:  realMembers,
          onTap:        (i) => setState(() {
            _holeIndex = i;
            _ballLost  = _ballLostOnHole == (i + 1);
            _pendingScores.clear();
          }),
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              // ── Carrier banner ────────────────────────────────────────
              _CarrierBanner(
                holeNumber:       _holeNumber,
                par:              par,
                yards:            hole?.yards,
                si:               hole?.strokeIndex,
                carrierName:      carrierName,
                ballColor:        _ballColor,
                irishRumbleBalls: _irishBallsToCount,
                ballAlreadyLost:  _ballLostOnHole != null && _holeNumber > _ballLostOnHole!,
              ),
              const SizedBox(height: 12),

              // ── Lost ball toggle ──────────────────────────────────────
              _BallLostCard(
                ballColor:    _ballColor,
                lost:         _ballLost,
                lockedOnHole: (_ballLostOnHole != null && _holeNumber > _ballLostOnHole!)
                    ? _ballLostOnHole
                    : null,
                onChanged:    (v) => setState(() => _ballLost = v),
              ),
              const SizedBox(height: 12),

              // ── Player score rows + hot-player inline picker ─────────
              Card(
                elevation: 0,
                clipBehavior: Clip.hardEdge,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                      color: Theme.of(context).colorScheme.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...() {
                  // Compute hot spot once — first player without a score.
                  int hotSpotIdx = -1;
                  for (int i = 0; i < realMembers.length; i++) {
                    final pid = realMembers[i].player.id;
                    final s = _pendingScores[pid] ??
                        hole?.scores
                            .where((s) => s.playerId == pid)
                            .firstOrNull
                            ?.grossScore;
                    if (s == null) { hotSpotIdx = i; break; }
                  }
                  return realMembers.asMap().entries.expand<Widget>((entry) {
                final idx       = entry.key;
                final m         = entry.value;
                final isCarrier = m.player.id == cid;
                final holeEntry = hole?.scores
                    .where((s) => s.playerId == m.player.id)
                    .firstOrNull;
                final stored    = holeEntry?.grossScore;
                final strokes   = holeEntry?.handicapStrokes ?? 0;
                final pending   = _pendingScores[m.player.id];
                final displayed = pending ?? stored;
                final isHot     = idx == hotSpotIdx;

                return [
                  _PlayerScoreRow(
                    position:        idx + 1,
                    member:          m,
                    isCarrier:       isCarrier,
                    isHot:           isHot,
                    ballColor:       _ballColor,
                    ballAlreadyLost: _ballLostOnHole != null && _holeNumber > _ballLostOnHole!,
                    par:             par,
                    grossScore:      displayed,
                    handicapStrokes: strokes,
                    onEditTap: displayed != null
                        ? () => _editScore(m, par, strokes)
                        : null,
                  ),
                  if (isHot && displayed == null)
                    _ScorePicker(
                      par:             par,
                      strokes:         strokes,
                      currentScore:    null,
                      onScoreSelected: (score) {
                        setState(
                            () => _pendingScores[m.player.id] = score);
                      },
                    ),
                ];
                  }).toList();
                }(),

                // Phantom player row — read-only, at the bottom of the card.
                // Shown whenever this foursome has a phantom player.
                if (phantomMember != null && hole != null)
                  _PinkBallPhantomRow(
                    phantom:     phantomMember,
                    holeNumber:  _holeNumber,
                    hole:        hole,
                    phantomInit: rp.phantomInitFor(widget.foursomeId),
                    realMembers: realMembers,
                  ),
                  ],
                ),
              ),

              // ── Match Play status (when match play is also active) ───────
              if (_matchPlayActive) ...[
                const SizedBox(height: 12),
                _PinkBallMatchPlayCard(
                  foursomeId: widget.foursomeId,
                ),
              ],

              // ── Three-Person Match Phase 2 (back-9 match play) ──────────
              if (_threePersonMatchActive && _holeNumber >= 10) ...[
                const SizedBox(height: 12),
                _ThreePersonMatchPhase2Card(
                  foursomeId: widget.foursomeId,
                ),
              ],

            ],
          ),
        ),
      ]),

      // ── Bottom navigation ──────────────────────────────────────────────────
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            OutlinedButton.icon(
              onPressed: _holeIndex == 0
                  ? null
                  : () => setState(() {
                        final newIdx = _holeIndex - 1;
                        _holeIndex = newIdx;
                        _ballLost  = _ballLostOnHole == (newIdx + 1);
                        _pendingScores.clear();
                      }),
              icon: const Icon(Icons.chevron_left),
              label: Text('Hole $_holeIndex'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: (!complete || _saving)
                  ? null
                  : () => _save(advance: true),
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Icon(_holeIndex == 17
                      ? Icons.check
                      : Icons.chevron_right),
              label: Text(_saving
                  ? 'Saving…'
                  : _holeIndex == 17
                      ? 'Finish'
                      : 'Hole ${_holeNumber + 1}'),
              iconAlignment: IconAlignment.end,
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hole chip strip
// ---------------------------------------------------------------------------

class _HoleChipStrip extends StatelessWidget {
  final int              holeIndex;
  final Scorecard        scorecard;
  final List<Membership> realMembers;
  final void Function(int) onTap;

  const _HoleChipStrip({
    required this.holeIndex,
    required this.scorecard,
    required this.realMembers,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: scorecard.holes.length,
        itemBuilder: (_, i) {
          final h        = scorecard.holes[i];
          final complete = h.scores.every((s) => s.grossScore != null);
          final isCurrent = i == holeIndex;
          return GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isCurrent
                    ? theme.colorScheme.primary
                    : complete
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Center(
                child: Text(
                  '${h.holeNumber}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: isCurrent
                        ? theme.colorScheme.onPrimary
                        : complete
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carrier banner
// ---------------------------------------------------------------------------

class _CarrierBanner extends StatelessWidget {
  final int     holeNumber;
  final int     par;
  final int?    yards;
  final int?    si;
  final String  carrierName;
  final String  ballColor;
  /// Number of scores that count for Irish Rumble on this hole, or null if
  /// Irish Rumble is not an active game.
  final int?    irishRumbleBalls;
  /// True when the ball was lost on a previous hole — hides carrier info.
  final bool    ballAlreadyLost;

  const _CarrierBanner({
    required this.holeNumber,
    required this.par,
    this.yards,
    this.si,
    required this.carrierName,
    required this.ballColor,
    this.irishRumbleBalls,
    this.ballAlreadyLost = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Hole $holeNumber',
                style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer)),
            const Spacer(),
            _InfoChip('Par $par'),
            if (yards != null) ...[
              const SizedBox(width: 6),
              _InfoChip('${yards}y'),
            ],
            if (si != null) ...[
              const SizedBox(width: 6),
              _InfoChip('SI $si'),
            ],
          ]),
          const SizedBox(height: 10),
          if (!ballAlreadyLost) ...[
            Row(children: [
              Icon(Icons.sports_golf,
                  size: 18,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer),
                    children: [
                      TextSpan(
                        text: carrierName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      TextSpan(text: ' plays the $ballColor Ball'),
                    ],
                  ),
                ),
              ),
            ]),
          ],
          if (irishRumbleBalls != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.filter_none,
                  size: 16,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '$irishRumbleBalls ${irishRumbleBalls == 1 ? 'ball counts' : 'balls count'} '
                'for Irish Rumble',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  const _InfoChip(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer)),
    );
  }
}

// ---------------------------------------------------------------------------
// Player score row
// ---------------------------------------------------------------------------

class _PlayerScoreRow extends StatelessWidget {
  final int                position;   // 1-based display position
  final Membership         member;
  final bool               isCarrier;
  final bool               isHot;      // active entry player
  final String             ballColor;
  final int                par;
  final int?               grossScore;
  final int                handicapStrokes;
  final VoidCallback?      onEditTap;  // tap scored box to edit
  /// When true the Red Ball badge is suppressed (ball already lost).
  final bool               ballAlreadyLost;

  const _PlayerScoreRow({
    required this.position,
    required this.member,
    required this.isCarrier,
    required this.isHot,
    required this.ballColor,
    required this.par,
    required this.grossScore,
    required this.handicapStrokes,
    this.onEditTap,
    this.ballAlreadyLost = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final player = member.player;

    // Score box coloring: net result when scored, hot highlight when active+empty.
    final Color? boxBg;
    final Border boxBorder;
    if (grossScore != null) {
      final diff = (grossScore! - handicapStrokes) - par;
      final Color c = diff < 0
          ? Colors.green.shade200
          : diff == 0
              ? Colors.grey.shade200
              : Colors.red.shade200;
      boxBg    = c;
      boxBorder = Border.all(color: c);
    } else if (isHot) {
      boxBg    = theme.colorScheme.primaryContainer.withOpacity(0.4);
      boxBorder = Border.all(color: theme.colorScheme.primary, width: 2);
    } else {
      boxBg    = null;
      boxBorder = Border.all(color: theme.colorScheme.outline);
    }

    return Container(
      decoration: BoxDecoration(
        // Carrier gets a distinctive tinted band; hot player gets the standard blue tint.
        color: isCarrier
            ? theme.colorScheme.secondaryContainer.withOpacity(0.25)
            : isHot
                ? theme.colorScheme.primaryContainer.withOpacity(0.08)
                : null,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
          // Accent left border for ball carrier
          left: isCarrier
              ? BorderSide(color: theme.colorScheme.secondary, width: 3)
              : BorderSide.none,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Position + name + HCP chip + optional carrier badge
        Expanded(
          child: Row(children: [
            Text('$position)  ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary)),
            Flexible(
              child: Text(
                player.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isHot ? theme.colorScheme.primary : null,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer
                    .withOpacity(0.6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: theme.colorScheme.outlineVariant),
              ),
              child: Text(
                'Hcp ${member.playingHandicap}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            if (isCarrier && !ballAlreadyLost) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$ballColor Ball',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSecondary,
                  ),
                ),
              ),
            ],
          ]),
        ),

        // Score box
        GestureDetector(
          onTap: grossScore != null ? onEditTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 36,
            decoration: BoxDecoration(
              color: boxBg,
              border: boxBorder,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: grossScore != null
                ? Text(
                    '$grossScore',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  )
                : null,
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Horizontal score picker — scrollable 1–12, opens with par-2 as first visible
// ---------------------------------------------------------------------------

class _ScorePicker extends StatefulWidget {
  final int    par;
  final int    strokes;
  final int?   currentScore;
  final void Function(int) onScoreSelected;

  const _ScorePicker({
    required this.par,
    required this.strokes,
    required this.currentScore,
    required this.onScoreSelected,
  });

  @override
  State<_ScorePicker> createState() => _ScorePickerState();
}

class _ScorePickerState extends State<_ScorePicker> {
  static const _itemWidth  = 50.0;
  static const _itemMargin = 4.0;
  static const _itemTotal  = _itemWidth + _itemMargin * 2;

  late final ScrollController _ctrl;

  @override
  void initState() {
    super.initState();
    final firstIdx = (widget.par + widget.strokes - 3).clamp(0, 9);
    _ctrl = ScrollController(initialScrollOffset: firstIdx * _itemTotal);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scores = List.generate(12, (i) => i + 1);
    return SizedBox(
      height: 48,
      child: ListView.builder(
        controller:      _ctrl,
        scrollDirection: Axis.horizontal,
        padding:         EdgeInsets.zero,
        itemCount:       scores.length,
        itemBuilder: (_, i) {
          final s = scores[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
            child: NetScoreButton(
              score:    s,
              par:      widget.par,
              strokes:  widget.strokes,
              selected: s == widget.currentScore,
              width:    _itemWidth,
              height:   44,
              onTap:    () => widget.onScoreSelected(s),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ScoreChip extends StatelessWidget {
  final int gross;
  final int par;
  final int strokes;
  const _ScoreChip({required this.gross, required this.par,
      required this.strokes});

  @override
  Widget build(BuildContext context) {
    final net  = gross - strokes;
    final diff = net - par;
    Color bg;
    if (diff < 0) bg = Colors.green.shade200;
    else if (diff > 0) bg = Colors.red.shade200;
    else bg = Colors.grey.shade200;
    return CircleAvatar(
      radius: 16,
      backgroundColor: bg,
      child: Text('$gross',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
              color: Colors.black87)),
    );
  }
}

// ---------------------------------------------------------------------------
// Order setup bottom sheet  (shown once per foursome before scoring starts)
// ---------------------------------------------------------------------------

class _OrderSetupSheet extends StatefulWidget {
  final String           ballColor;
  final List<Membership> members;
  /// Number of leading positions that are already fixed by played holes.
  /// 0 = all positions freely reorderable.
  final int              lockedCount;
  final Future<void> Function(List<int>) onConfirm;

  const _OrderSetupSheet({
    required this.ballColor,
    required this.members,
    required this.lockedCount,
    required this.onConfirm,
  });

  @override
  State<_OrderSetupSheet> createState() => _OrderSetupSheetState();
}

class _OrderSetupSheetState extends State<_OrderSetupSheet> {
  late final List<Membership> _ordered;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ordered = List.of(widget.members);
  }

  bool get _allLocked => widget.lockedCount >= _ordered.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: MediaQuery.of(context).viewInsets,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ball Rotation',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    _allLocked
                        ? 'The rotation is locked — at least 3 holes have been scored.'
                        : widget.lockedCount > 0
                            ? 'The first ${widget.lockedCount} position${widget.lockedCount > 1 ? 's are' : ' is'} locked by scored holes. '
                              'Drag the remaining players to set their order.'
                            : 'Drag to set the order your group will carry the '
                              '${widget.ballColor} Ball. The rotation repeats across all 18 holes.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),

            // Reorderable player list.
            // Uses ReorderableListView.builder with buildDefaultDragHandles: false
            // so that ReorderableDragStartListener gives precise drag control.
            // Locked rows get a lock icon instead of a drag handle.
            SizedBox(
              height: _ordered.length * 76.0,
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _ordered.length,
                onReorder: (oldIndex, newIndex) {
                  // Prevent dragging a locked row or dropping into a locked slot.
                  if (oldIndex < widget.lockedCount) return;
                  final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
                  if (target < widget.lockedCount) return;
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final item = _ordered.removeAt(oldIndex);
                    _ordered.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, idx) {
                  final m        = _ordered[idx];
                  final isLocked = idx < widget.lockedCount;
                  return Card(
                    key: ValueKey(m.player.id),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _posColor(idx),
                        radius: 16,
                        child: Text(
                          '${idx + 1}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                        ),
                      ),
                      title: Text(m.player.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('HCP ${m.playingHandicap}',
                          style: theme.textTheme.bodySmall),
                      trailing: isLocked
                          ? Icon(Icons.lock_outline,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withOpacity(0.45))
                          : ReorderableDragStartListener(
                              index: idx,
                              child: const Icon(Icons.drag_handle),
                            ),
                    ),
                  );
                },
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: _allLocked
                    ? OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      )
                    : FilledButton(
                        onPressed: _saving
                            ? null
                            : () async {
                                setState(() => _saving = true);
                                final playerOrder =
                                    _ordered.map((m) => m.player.id).toList();
                                await widget.onConfirm(playerOrder);
                                if (context.mounted) Navigator.of(context).pop();
                              },
                        child: _saving
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('Confirm Rotation'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _posColor(int index) {
    const colors = [Colors.blue, Colors.orange, Colors.green, Colors.purple];
    return colors[index % colors.length];
  }
}

// ---------------------------------------------------------------------------
// Ball-lost toggle card
// ---------------------------------------------------------------------------

class _BallLostCard extends StatelessWidget {
  final String  ballColor;
  final bool    lost;
  final void Function(bool) onChanged;
  /// Non-null when the ball was already lost on a previous hole (< current).
  /// Shows a locked / informational state instead of an interactive toggle.
  final int?    lockedOnHole;

  const _BallLostCard({
    required this.ballColor,
    required this.lost,
    required this.onChanged,
    this.lockedOnHole,
  });

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final locked = lockedOnHole != null;

    if (locked) {
      // The ball was already lost on a previous hole — this hole is locked out.
      return Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Icon(Icons.lock_outline,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$ballColor Ball lost on hole $lockedOnHole',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ]),
        ),
      );
    }

    return Card(
      color: lost ? theme.colorScheme.errorContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!lost),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Icon(
              lost ? Icons.cancel : Icons.circle_outlined,
              color: lost
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Lost the $ballColor Ball on this hole',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: lost
                      ? theme.colorScheme.onErrorContainer
                      : null,
                ),
              ),
            ),
            Switch(
              value: lost,
              onChanged: onChanged,
              activeColor: theme.colorScheme.error,
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit-score modal — tap a scored player's box to correct a score
// ---------------------------------------------------------------------------

class _EditScoreSheet extends StatefulWidget {
  final String playerName;
  final int    par;
  final int    holeNumber;
  final int    strokes;
  final int?   current;

  const _EditScoreSheet({
    required this.playerName,
    required this.par,
    required this.holeNumber,
    required this.strokes,
    this.current,
  });

  @override
  State<_EditScoreSheet> createState() => _EditScoreSheetState();
}

class _EditScoreSheetState extends State<_EditScoreSheet> {
  static const _itemWidth  = 50.0;
  static const _itemMargin = 4.0;
  static const _itemTotal  = _itemWidth + _itemMargin * 2;

  late final ScrollController _ctrl;

  @override
  void initState() {
    super.initState();
    final firstIdx = (widget.par + widget.strokes - 3).clamp(0, 9);
    _ctrl = ScrollController(initialScrollOffset: firstIdx * _itemTotal);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final netPar = widget.par + widget.strokes;
    final scores = List.generate(12, (i) => i + 1);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            widget.playerName,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          Text(
            widget.strokes > 0
                ? 'Hole ${widget.holeNumber}  •  Par ${widget.par}  •  Net par $netPar'
                : 'Hole ${widget.holeNumber}  •  Par ${widget.par}',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: ListView.builder(
              controller:      _ctrl,
              scrollDirection: Axis.horizontal,
              padding:         EdgeInsets.zero,
              itemCount:       scores.length,
              itemBuilder: (_, i) {
                final s = scores[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: _itemMargin),
                  child: NetScoreButton(
                    score:    s,
                    par:      widget.par,
                    strokes:  widget.strokes,
                    selected: s == widget.current,
                    width:    _itemWidth,
                    height:   52,
                    onTap:    () => Navigator.of(context).pop(s),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          if (widget.current != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(-1),
              child: const Text('Clear score'),
            ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Match Play status card — shown when match play is also active alongside
// Pink Ball.  Reads from RoundProvider, tappable to open the bracket view.
// ---------------------------------------------------------------------------

class _PinkBallMatchPlayCard extends StatelessWidget {
  final int foursomeId;
  const _PinkBallMatchPlayCard({required this.foursomeId});

  List<Map<String, dynamic>> _matchesForRound(
      Map<String, dynamic> data, int round) =>
      (data['matches'] as List? ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .where((m) => (m['round'] as int) == round)
          .toList();

  String _matchSummary(Map<String, dynamic> match) {
    final status     = match['status'] as String;
    final result     = match['result'] as String?;
    final holes      = (match['holes'] as List? ?? []);
    final p1         = match['player1'] as String;
    final winnerName = match['winner_name'] as String?;
    final finishedOn = match['finished_hole'] as int?;
    final tieBreak   = match['tie_break'] as String?;
    final round      = match['round'] as int;
    final playersTbd = match['players_tbd'] as bool? ?? false;

    if (playersTbd && status == 'pending') return 'Awaiting semi results';
    if (status == 'pending' && holes.isEmpty) return 'Waiting for scores';

    if (status == 'complete') {
      if (result == 'halved') return 'Halved';
      if (winnerName == null) return 'Complete';
      if (tieBreak == 'sudden_death') return '$winnerName wins (SD)';
      if (tieBreak == 'last_hole_won') return '$winnerName wins (last hole)';
      if (finishedOn != null) {
        final scheduledEnd = round == 1 ? 9 : 18;
        final remaining    = scheduledEnd - finishedOn;
        final h = holes.cast<Map>().firstWhere(
              (h) => h['hole'] == finishedOn,
              orElse: () => <dynamic, dynamic>{});
        final margin = ((h['margin'] as int?) ?? 0).abs();
        if (remaining > 0) return '$winnerName ${margin}&$remaining';
      }
      return '$winnerName wins';
    }

    // in_progress
    if (holes.isEmpty) return 'In progress';
    final last   = holes.last as Map;
    final margin = last['margin'] as int? ?? 0;
    final hole   = last['hole'] as int? ?? 0;
    if (margin == 0) return 'All Square thru $hole';
    final leader = margin > 0 ? p1 : match['player2'] as String;
    return '$leader ${margin.abs()}UP thru $hole';
  }

  @override
  Widget build(BuildContext context) {
    final rp    = context.watch<RoundProvider>();
    final data  = rp.matchPlayData;
    final theme = Theme.of(context);

    if (rp.loadingMatchPlay && data == null) {
      return const Center(
          child: Padding(
            padding: EdgeInsets.all(8),
            child: CircularProgressIndicator(strokeWidth: 2),
          ));
    }
    if (data == null) return const SizedBox.shrink();

    final status = data['status'] as String? ?? 'pending';
    final winner = data['winner'] as String?;
    final r1     = _matchesForRound(data, 1);
    final r2     = _matchesForRound(data, 2);

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context)
            .pushNamed('/match-play-setup', arguments: foursomeId),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.sports_tennis,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('Match Play',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                _MPStatusChip(status: status, winner: winner),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant),
              ]),

              if (r1.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Semis (F9)',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                for (final m in r1)
                  _MPMatchRow(
                      match: m, summary: _matchSummary(m), theme: theme),
              ],

              if (r2.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Final & 3rd (B9)',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                for (final m in r2)
                  _MPMatchRow(
                      match: m, summary: _matchSummary(m), theme: theme),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MPStatusChip extends StatelessWidget {
  final String  status;
  final String? winner;
  const _MPStatusChip({required this.status, this.winner});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color bg;
    String label;
    if (status == 'complete') {
      bg    = theme.colorScheme.primaryContainer;
      label = winner != null ? '$winner wins' : 'Final';
    } else if (status == 'in_progress') {
      bg    = theme.colorScheme.tertiaryContainer;
      label = 'In progress';
    } else {
      bg    = theme.colorScheme.surfaceContainerHighest;
      label = 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label,
          style: theme.textTheme.labelSmall
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

// ---------------------------------------------------------------------------
// Phantom player row — read-only informational row for the ghost player.
// Shows gross score (copied from source player) and attribution.
// Mirrors _PhantomPlayerRow in score_entry_screen.dart but reads from the
// pink-ball scorecard data model instead of the sixes/points-531 model.
// ---------------------------------------------------------------------------

class _PinkBallPhantomRow extends StatelessWidget {
  final Membership        phantom;
  final int               holeNumber;
  final ScorecardHole     hole;
  final PhantomInitResult? phantomInit;
  final List<Membership>  realMembers;

  const _PinkBallPhantomRow({
    required this.phantom,
    required this.holeNumber,
    required this.hole,
    required this.phantomInit,
    required this.realMembers,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ghost = theme.colorScheme.onSurface.withOpacity(0.38);

    // Phantom's stored score for this hole (pre-created at round setup).
    final phantomEntry = hole.scoreFor(phantom.player.id);
    final gross        = phantomEntry?.grossScore;
    final net          = phantomEntry?.netScore;

    // Which real player is the source for this hole?
    final sourcePid  = phantomInit?.sourceByHole[holeNumber];
    final sourceName = sourcePid != null
        ? realMembers
            .where((m) => m.player.id == sourcePid)
            .firstOrNull
            ?.player
            .displayShort
        : null;

    final String subtitle;
    if (sourceName != null) {
      subtitle = 'Copies $sourceName this hole';
    } else if (phantomInit != null) {
      subtitle = 'Phantom player';
    } else {
      subtitle = 'Phantom (initialising…)';
    }

    final int? playingHcp = phantomInit?.playingHandicap;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Icon(Icons.person_outline, size: 18, color: ghost),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      phantom.player.displayShort,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: ghost,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(color: ghost),
                    ),
                  ],
                ),
              ),
              // Computed handicap chip — always shown once phantomInit is loaded.
              if (playingHcp != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: ghost.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ghost.withOpacity(0.25)),
                  ),
                  child: Text(
                    'Hcp $playingHcp',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: ghost,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Net score chip (if available) + gross in the score box
        if (net != null && net != gross) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: ghost.withOpacity(0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Net $net',
              style: theme.textTheme.labelSmall?.copyWith(
                color: ghost, fontStyle: FontStyle.italic),
            ),
          ),
        ],
        Container(
          width: 40,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ghost.withOpacity(0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ghost.withOpacity(0.3)),
          ),
          child: gross != null
              ? Text(
                  '$gross',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: ghost,
                    fontStyle: FontStyle.italic,
                  ),
                )
              : Text('—',
                  style: theme.textTheme.bodySmall?.copyWith(color: ghost)),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Three-Person Match Phase 2 card — back-9 match play between top-2 players.
// Shown on holes 10-18 when the foursome is playing a Three-Person Match.
// ---------------------------------------------------------------------------

class _ThreePersonMatchPhase2Card extends StatelessWidget {
  final int foursomeId;
  const _ThreePersonMatchPhase2Card({required this.foursomeId});

  /// One-line status string for the back-9 match.
  static String _matchStatus(Map<String, dynamic> p2) {
    final p2Status   = p2['status']         as String? ?? 'pending';
    final leader     = p2['leader_name']    as String? ?? '?';
    final runnerUp   = p2['runner_up_name'] as String? ?? '?';
    final margin     = (p2['margin']        as num?)?.toInt() ?? 0;
    final lastHole   = (p2['last_hole']     as num?)?.toInt();
    final winnerName = p2['winner_name']    as String?;

    if (p2Status == 'pending') return 'Waiting for hole 10 scores';
    if (p2Status == 'complete') {
      if (winnerName == null) return 'All Square after 18';
      if (lastHole != null && lastHole < 18) {
        return '$winnerName wins ${margin.abs()}&${18 - lastHole}';
      }
      return '$winnerName wins ${margin.abs()}UP';
    }
    // in_progress
    if (lastHole == null || margin == 0) {
      return 'All Square${lastHole != null ? ' thru $lastHole' : ''}';
    }
    final aheadName = margin > 0 ? leader : runnerUp;
    return '$aheadName ${margin.abs()}UP thru $lastHole';
  }

  @override
  Widget build(BuildContext context) {
    final rp    = context.watch<RoundProvider>();
    final tpm   = rp.threePersonMatchSummary;
    final theme = Theme.of(context);

    if (tpm == null) return const SizedBox.shrink();
    final phase2 = tpm.phase2;
    if (phase2 == null) return const SizedBox.shrink();

    final p2Status   = phase2['status']         as String? ?? 'pending';
    final leader     = phase2['leader_name']    as String? ?? '?';
    final runnerUp   = phase2['runner_up_name'] as String? ?? '?';
    final winnerName = phase2['winner_name']    as String?;
    final status     = p2Status == 'complete' ? 'complete' : p2Status;

    final statusLine = _matchStatus(phase2);

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(children: [
              Icon(Icons.sports_tennis,
                  size: 16,
                  color: status == 'complete'
                      ? Colors.green.shade700
                      : theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text('Back 9 Match Play',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: status == 'complete'
                      ? Colors.green.shade100
                      : status == 'in_progress'
                          ? theme.colorScheme.tertiaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status == 'complete'
                      ? (winnerName != null ? '$winnerName wins' : 'Final')
                      : status == 'in_progress'
                          ? 'In progress'
                          : 'Pending',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: status == 'complete'
                        ? Colors.green.shade800
                        : null,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 8),

            // Matchup
            RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: leader,
                    style: const TextStyle(color: Colors.blue),
                  ),
                  TextSpan(
                    text: ' vs ',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.normal),
                  ),
                  TextSpan(
                    text: runnerUp,
                    style: TextStyle(color: Colors.orange.shade800),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),

            // Status line
            Text(
              statusLine,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: status == 'complete'
                    ? Colors.green.shade700
                    : status == 'in_progress'
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MPMatchRow extends StatelessWidget {
  final Map<String, dynamic> match;
  final String               summary;
  final ThemeData            theme;
  const _MPMatchRow(
      {required this.match, required this.summary, required this.theme});

  @override
  Widget build(BuildContext context) {
    final p1    = match['player1'] as String? ?? '?';
    final p2    = match['player2'] as String? ?? '?';
    final label = match['label']   as String? ?? 'Match';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text('$p1 vs $p2',
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 8),
        Text(summary,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
