/// screens/wolf_screen.dart
///
/// Play screen for the Wolf casual game.  Per hole it shows, top-to-bottom:
///   • Hole header (par / yards / SI) with a "set rotation" action.
///   • Wolf decision panel — who's the Wolf, the reverse-honors tee order
///     (worst on the previous hole tees first, Wolf last), and the Wolf's
///     choice: Take-as-partner on each non-Wolf row (4-player only), Lone
///     Wolf, or Blind Wolf.
///   • Score-entry rows (modeled on points_531_screen) ordered to match the
///     tee order, with an inline net-centred picker on the hot row.
///   • The hole's outcome once it's decided + scored.
///   • An 18-hole points grid.
///
/// The Wolf identity, tee order, decision, and results all come from the
/// server summary (services.wolf.wolf_summary), which is refreshed after
/// every score submission and decision.

import '../utils/effective_scores.dart';
import '../utils/handicap_rounding.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_colors.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../utils/match_handicap.dart';
import '../utils/play_order.dart';
import '../utils/round_complete.dart';
import '../utils/wolf_standing.dart';
import '../widgets/hole_header.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/icon_help_sheet.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/standing_ribbon.dart';
import '../widgets/spots_capture.dart';
import '../widgets/stroke_dots.dart';
import '../widgets/combo_tee_chip.dart';
import '../widgets/forty_balls_keypad.dart';
import '../widgets/wolf_entry.dart';
import '../widgets/reveal_on_mount.dart';

/// Team accent color for a player's role on a hole. Per the color standard the
/// Wolf side (Wolf + partner) is team 1 (blue); the opponents are team 2
/// (orange). Null = no team yet.
Color? _wolfTeamColor(String? role) {
  switch (role) {
    case 'wolf':
    case 'partner':
      return GameColors.team1;
    case 'opponent':
      return GameColors.team2;
  }
  return null;
}

/// A legend swatch for the by-hole card — the same fill and edge a winning
/// cell wears, so the key is the mark rather than a description of it.
// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class WolfScreen extends StatefulWidget {
  final int foursomeId;
  const WolfScreen({super.key, required this.foursomeId});

  @override
  State<WolfScreen> createState() => _WolfScreenState();
}

class _WolfScreenState extends State<WolfScreen> with SpotsCaptureMixin {
  /// Unsubmitted score edits: hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;
  bool _decisionBusy    = false;
  // Set when the user taps an already-scored player to correct a past hole, so
  // the inline picker re-opens for that row (a completed hole has no hot-spot).
  int? _editingPlayerId;
  bool _sheetOpen       = false;

  /// `Edit scores` is open: the keypad stays on the golfer just edited until
  /// Done, rather than dropping back to the tray after one score.
  bool _trayEditing = false;

  /// The hole we have asked the server for, so a missing card is fetched
  /// once rather than on every frame. Cleared the moment one arrives, which
  /// is what lets the fetch run AGAIN if that card is then dropped.
  int? _cardAsked;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rp = context.read<RoundProvider>();
      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      } else {
        rp.refreshPendingOverlay();
      }
      rp.loadWolf(widget.foursomeId);
      if (rp.round?.activeGames.contains('spots') ?? false) {
        rp.loadSpots(widget.foursomeId);
      }
    });
  }

  @override
  void dispose() {
    disposeSpots();
    super.dispose();
  }

  Future<void> _refresh() async {
    final rp = context.read<RoundProvider>();
    await rp.loadScorecard(widget.foursomeId);
    rp.loadWolf(widget.foursomeId);
    if (rp.round?.activeGames.contains('spots') ?? false) {
      rp.loadSpots(widget.foursomeId);
    }
  }

  // ── Player ordering ───────────────────────────────────────────────────────

  /// Real (non-phantom) members for this foursome.
  List<Membership> _realMembers(Round? round) {
    final fs = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  /// Members ordered to match the hole's tee order (reverse honors, Wolf
  /// last) when the summary has it; falls back to membership order.
  List<Membership> _orderedPlayers(Round? round, WolfHole? hole) {
    final members = _realMembers(round);
    if (hole == null || hole.teeOrder.isEmpty) return members;
    final byId = {for (final m in members) m.player.id: m};
    final out = <Membership>[];
    for (final slot in hole.teeOrder) {
      final m = byId[slot.playerId];
      if (m != null) out.add(m);
    }
    for (final m in members) {
      if (!out.contains(m)) out.add(m);
    }
    return out;
  }

  // ── Score helpers ─────────────────────────────────────────────────────────

  /// See `utils/effective_scores.dart` — the SYNC QUEUE is the third place a
  /// score lives, and every screen's own copy of this merge used to skip it.
  Map<int, int> _effectiveScores(Scorecard sc, int hole) => effectiveScores(
        sc,
        hole,
        queued: context.read<RoundProvider>().localPendingByHole,
        pending: _pending,
      );

  bool _anyScoreEntered(Scorecard sc, int hole) =>
      _effectiveScores(sc, hole).isNotEmpty;

  /// True once any score has been entered (saved or pending) — gates the
  /// app-bar Exit (✕) on a single-foursome casual round.
  bool get _hasAnyScore {
    if (_pending.isNotEmpty) return true;
    final rp = context.read<RoundProvider>();
    final sc = rp.scorecard;
    if (sc != null) {
      for (int h = 1; h <= 18; h++) {
        if (_effectiveScores(sc, h).isNotEmpty) return true;
      }
    }
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    return fs?.hasAnyScore ?? false;
  }

  int _hotSpotIdx(List<Membership> players, Map<int, int> scores) {
    for (int i = 0; i < players.length; i++) {
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  /// The Wolf's call cannot be changed from the chips.
  ///
  /// **A hole with its four scores AND a call is settled**, and the tray for
  /// it stays up until the group moves on — so this is the screen they are
  /// looking at on the next tee, with the old hole's chips one thumb away.
  /// `Edit scores` on the tray is what reopens it, the same deliberate step
  /// that reopens a score.
  ///
  /// Not locked while the hole has NO call: four scores with none is the
  /// state where the tray asks for it, and the chips answer too.
  bool _callLocked(WolfHoleCard card, List<Membership> players,
          Map<int, int> scores) =>
      !_trayEditing && _allScored(players, scores) && card.isDecided;

  bool _allScored(List<Membership> players, Map<int, int> scores) =>
      players.every((m) => scores.containsKey(m.player.id));

  void _selectScore(Membership player, int score, int hole) {
    setState(() {
      if (score == -1) {
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  /// Record a score and, if the user's Auto-advance setting is on, save +
  /// move to the next hole once the last player's score completes it.
  void _handleScore(BuildContext ctx, Membership m, int score,
      List<Membership> players) {
    final sc = context.read<RoundProvider>().scorecard;
    final hole = _selectedHole;
    final wasAllScored =
        sc != null && _allScored(players, _effectiveScores(sc, hole));
    _selectScore(m, score, hole);
    if (sc == null || score <= 0) return;
    if (wasAllScored) {
      // Editing an already-complete (past) hole: there's no save+advance step
      // for a correction, so persist it immediately — otherwise the change is
      // lost the moment the user navigates to another hole.
      //
      // **A session keeps its cursor.** Clearing it unconditionally leaves
      // `_trayEditing` true with no golfer being edited — a state neither
      // the tray nor the keypad draws, so the bottom bar falls through to
      // the bare pager (reported on Rabbit, 30 Oct 2026).
      if (!_trayEditing) setState(() => _editingPlayerId = null);
      _saveHole(ctx, hole, players);
      return;
    }
    // **A tray game saves and STAYS.** The tray IS the end of the hole —
    // what the call did to it, and where that leaves the round — and its
    // forward button is the advance. Auto-advance would carry the scorer
    // straight past it (reported on Rabbit, whose screen has this shape).
    // The keypad posts the hole itself, so nothing is left unsent.
    if (_card(context.read<RoundProvider>()) != null) return;
    if (!context.read<SettingsProvider>().autoAdvanceHole) return;
    if (!_allScored(players, _effectiveScores(sc, hole))) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedHole != hole) return;
      final rp = context.read<RoundProvider>();
      if (rp.submitting) return;
      _saveAndAdvance(ctx, players);   // on hole 18 this saves + stays
    });
  }

  /// Holes this group plays, in order (back-9 / 9-hole / shotgun aware).
  List<int> _playOrder(RoundProvider rp) =>
      roundPlayOrder(rp.round, rp.scorecard);

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = _realMembers(rp.round).map((m) => m.player.id).toSet();
    final order = _playOrder(rp);
    for (final h in order) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      final allScored = hd.scores
          .where((s) => realIds.contains(s.playerId))
          .every((s) => s.grossScore != null);
      if (!allScored && !rp.localPendingByHole.containsKey(h)) {
        setState(() { _selectedHole = h; });
        return;
      }
    }
    setState(() { _selectedHole = order.isEmpty ? 18 : order.last; });
  }

  void _advance() {
    final next = nextInOrder(
        _playOrder(context.read<RoundProvider>()), _selectedHole);
    if (next != null) {
      setState(() { _selectedHole = next; _editingPlayerId = null;
                    _trayEditing = false; });
    }
  }
  void _retreat() {
    final prev = prevInOrder(
        _playOrder(context.read<RoundProvider>()), _selectedHole);
    if (prev != null) {
      setState(() { _selectedHole = prev; _editingPlayerId = null;
                    _trayEditing = false; });
    }
  }

  // ── the hole card behind the keypad and the tray ────────────────────────

  WolfHoleCard? _card(RoundProvider rp) {
    final c = rp.wolfHole(_selectedHole);
    return (c != null && c.hole == _selectedHole) ? c : null;
  }

  /// **Make sure the hole on screen has a card**, because without one the
  /// keypad is not drawn at all.
  ///
  /// A save drops every other hole's card (they can be stale), and that
  /// races the fetch the forward button started: the next hole's card can
  /// arrive FIRST and then be thrown away by the response to a save posted
  /// before it, leaving a screen with no keypad. This closes the race from
  /// the other end — whenever the hole on screen has no card, one is asked
  /// for. (Reported on Rabbit, whose screen has the identical shape.)
  void _ensureCard(RoundProvider rp) {
    if (_card(rp) != null) { _cardAsked = null; return; }
    if (_cardAsked == _selectedHole) return;
    _cardAsked = _selectedHole;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<RoundProvider>()
          .loadWolfHole(widget.foursomeId, _selectedHole);
    });
  }

  /// Who the keypad is on: the golfer being edited, else the first without
  /// a score.
  Membership? _keypadMember(List<Membership> players, Map<int, int> scores) {
    if (_editingPlayerId != null) {
      for (final m in players) {
        if (m.player.id == _editingPlayerId) return m;
      }
    }
    final i = _hotSpotIdx(players, scores);
    return (i >= 0 && i < players.length) ? players[i] : null;
  }

  // ── Wolf decision ─────────────────────────────────────────────────────────

  /// Set (or clear) the Wolf's call for [hole], defaulting to the hole on
  /// screen.
  ///
  /// **The card comes back with it**, because setting a call is the other
  /// thing that settles a hole: the sides, the points and the standing all
  /// move, and a second request for them would make the group wait for
  /// figures the server has just computed.
  Future<void> _setDecision(String decision,
      {int? partnerId, int? hole}) async {
    if (_decisionBusy) return;
    setState(() => _decisionBusy = true);
    try {
      final client = context.read<AuthProvider>().client;
      final res = await client.postWolfDecision(
        widget.foursomeId,
        holeNumber: hole ?? _selectedHole,
        decision:   decision,
        partnerId:  partnerId,
      );
      if (!mounted) return;
      final rp = context.read<RoundProvider>();
      rp.setWolfSummary(res.summary);
      if (res.hole != null) rp.setWolfHole(res.hole!);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not save the Wolf decision: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      if (mounted) setState(() => _decisionBusy = false);
    }
  }

  /// Show the hole's tee order — reverse honors, the Wolf last — and who
  /// gets a stroke on it.
  ///
  /// **It no longer picks.** The call lives in the chips above the scores,
  /// where it can be set at any point in the hole; this sheet is what is
  /// left of the old overlay, and it is the only place the tee order is
  /// shown at all. Two controls for one decision is what the chips replace.
  Future<void> _openTeeOrderSheet(int hole) async {
    if (_sheetOpen) return;
    final rp = context.read<RoundProvider>();
    final summary = rp.wolfSummary;
    final sc = rp.scorecard;
    if (summary == null || sc == null) return;
    final holeInfo = summary.holeFor(hole);
    if (holeInfo == null) return;

    _sheetOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WolfDecisionSheet(
        hole:      holeInfo,
        summary:   summary,
        scorecard: sc,
        anyScored: _anyScoreEntered(sc, hole),
      ),
    );
    _sheetOpen = false;
  }

  Future<void> _promptRotation() async {
    final rp = context.read<RoundProvider>();
    final members = _realMembers(rp.round);
    if (members.isEmpty) return;
    final summary = rp.wolfSummary;
    // Seed from the current server order, then any missing members.
    final ids = members.map((m) => m.player.id).toList();
    final order = <int>[
      ...?summary?.wolfOrder.where(ids.contains),
    ];
    for (final id in ids) {
      if (!order.contains(id)) order.add(id);
    }
    // Positions whose hole has already been played are frozen — locking the
    // prefix up to the furthest played position so a past Wolf can't change.
    final locked = summary?.lockedPositions ?? const [];
    final lockedCount = locked.isEmpty
        ? 0
        : (locked.reduce((a, b) => a > b ? a : b) + 1).clamp(0, order.length);
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RotationSheet(
          order: order, members: members, lockedCount: lockedCount),
    );
    if (result == null || !mounted) return;
    try {
      final client = context.read<AuthProvider>().client;
      final updated = await client.postWolfOrder(
        widget.foursomeId, wolfOrder: result);
      if (!mounted) return;
      context.read<RoundProvider>().setWolfSummary(updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not update rotation: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  /// Persist whatever is pending for [hole] without changing the selected hole.
  /// Used by both the save+advance button and inline edits to past holes.
  Future<void> _saveHole(
      BuildContext ctx, int hole, List<Membership> players) async {
    final edits = _pending[hole];
    if (edits == null || edits.isEmpty) return;
    final scores = edits.entries
        .map((e) => {'player_id': e.key, 'gross_score': e.value})
        .toList();
    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
      foursomeId: widget.foursomeId,
      holeNumber: hole,
      scores:     scores,
    );
    if (!mounted) return;
    if (!ok) {
      _snack(ctx, rp.error ?? 'Failed to save hole.',
          () => _saveHole(ctx, hole, players));
      return;
    }
    setState(() { _pending.remove(hole); });
    rp.loadWolf(widget.foursomeId);
  }

  Future<void> _saveAndAdvance(
      BuildContext ctx, List<Membership> players) async {
    final hole = _selectedHole;
    if (_pending[hole]?.isNotEmpty ?? false) {
      await _saveHole(ctx, hole, players);
      if (!mounted || _pending.containsKey(hole)) return;   // save failed
    }
    _advance();
  }

  Future<void> _finishRound(BuildContext ctx, List<Membership> players) async {
    final rp      = context.read<RoundProvider>();
    // Soft gate: warn if finishing early (holes still unscored), consistent
    // with the other score screens.
    final sc = rp.scorecard;
    final unscored = <int>[];
    if (sc != null) {
      for (final h in _playOrder(rp)) {
        if (_effectiveScores(sc, h).isEmpty) unscored.add(h);
      }
    }
    if (!await confirmCompleteRound(ctx, unscoredHoles: unscored)) return;
    if (!mounted) return;
    final sync    = context.read<SyncService>();
    final roundId = rp.round?.id;

    final pendingForHole = _pending[_selectedHole];
    if (pendingForHole != null && pendingForHole.isNotEmpty) {
      final scores = pendingForHole.entries
          .map((e) => {'player_id': e.key, 'gross_score': e.value})
          .toList();
      final ok = await rp.submitHole(
        foursomeId: widget.foursomeId,
        holeNumber: _selectedHole,
        scores:     scores,
      );
      if (!mounted) return;
      if (!ok) {
        _snack(ctx, rp.error ?? 'Failed to save hole.',
            () => _finishRound(ctx, players));
        return;
      }
      setState(() { _pending.remove(_selectedHole); });
    }

    await sync.waitUntilIdle();
    if (!mounted) return;
    if (roundId != null) {
      // Mark the round complete so it leaves the active list (without this
      // "Done" only opens the leaderboard and the round stays in_progress).
      final lb = await rp.completeRound(roundId);
      if (!mounted) return;
      if (lb == null) {
        _snack(ctx, rp.error ?? 'Could not complete round.',
            () => _finishRound(ctx, players));
        return;
      }
      // Round over (settle-up handoff §1) before the board: the receipt
      // is what the group acts on, the leaderboard is what it reads.
      if (mounted) await showRoundOverIfAny(ctx, lb);
      if (!mounted) return;
      Navigator.of(ctx).pushReplacementNamed('/leaderboard', arguments: roundId);
    }
  }

  /// Per-hole row legend ("?" in the hole header) — explains the Wolf-specific
  /// row markings, matching the legend the other score screens offer.
  void _showWolfLegend(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(Widget lead, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 28, child: Center(child: lead)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        );
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Wolf row guide',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            row(Icon(Icons.pets, size: 20, color: theme.colorScheme.primary),
                'The Wolf',
                'The paw marks who is the Wolf this hole — they tee off last and choose a partner, go Lone Wolf, or call Blind Wolf.'),
            row(Container(width: 16, height: 16,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(3))),
                'Team color',
                'The left stripe / tint groups the teams for this hole — the Wolf side vs. the others.'),
            row(Text('-8 •', style: theme.textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
                'Handicap',
                'The playing handicap used for this game; each dot is a stroke received on this hole.'),
            row(Container(width: 22, height: 20,
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(4)),
                  child: const Center(child: Text('4',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))),
                'Score box',
                'Tap a player’s box to enter their gross score. Tap an already-scored row to correct it.'),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Got it'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _snack(BuildContext ctx, String msg, VoidCallback retry) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Theme.of(ctx).colorScheme.error,
      action: SnackBarAction(
        label: 'Retry',
        textColor: Theme.of(ctx).colorScheme.onError,
        onPressed: retry,
      ),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  /// **Grey, because Wolf has no side to name.** The partnership is re-drawn
  /// every hole — the wolf picks a man off the tee and they are partners for
  /// one hole and opponents on the next — so no side lasts long enough to wear
  /// a colour. Stroke Play reached the same answer from the other direction.
  ///
  /// And no `hole` argument, unlike every other game on this row: Wolf
  /// accumulates rather than resetting, so backing up to the 4th does not
  /// change where a golfer stands.
  StandingRibbon? _standingRibbon(RoundProvider rp) {
    final round = rp.round;
    if (round == null || !round.isCasual) return null;
    final me = context.read<AuthProvider>().player?.id;
    final standing = wolfStanding(rp.wolfSummary, me);
    if (standing == null) return null;
    return StandingRibbon(
      kind: StandingKind.result,
      standing: standing.standing,
      figure: standing.figure,
      onOpenLeaderboard: () => Navigator.of(context)
          .pushNamed('/leaderboard', arguments: round.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final sc   = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';

    if (!_initialJumpDone &&
        sc != null &&
        rp.activeFoursomeId == widget.foursomeId) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstUnplayed(context.read<RoundProvider>());
      });
    }

    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadWolf(widget.foursomeId);
      });
    }
    _prevHadPending = nowHasPending;

    // On a single-foursome casual round, once a score is entered swap the back
    // arrow for an explicit ✕ Exit (back is easily mistaken for "previous hole")
    // that returns to the casual rounds list.
    final isCasualSingle = (rp.round?.isCasual ?? false) &&
        (rp.round?.foursomes.length ?? 1) == 1;
    final showExit = isCasualSingle && _hasAnyScore;

    final ribbon = _standingRibbon(rp);

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Wolf',
        // D2: the standing becomes the bar's second line, and the pill in it
        // replaces the leaderboard ICON below.
        bottom: ribbon,
        titleStyle: ribbon == null
            ? null
            : const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: showExit ? 'Exit to rounds' : 'Close',
          onPressed: showExit
              ? () => Navigator.of(context).popUntil(
                  (r) => r.settings.name == '/casual-rounds' || r.isFirst)
              : () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (sync.hasPending)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Badge(
                label: Text('${sync.pendingCount}'),
                child: IconButton(
                  icon: sync.state == SyncState.syncing
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.cloud_upload_outlined),
                  tooltip: sync.state == SyncState.syncing
                      ? 'Syncing…'
                      : 'Tap to sync ${sync.pendingCount} score(s)',
                  onPressed: sync.state == SyncState.syncing
                      ? null : () => sync.recheck(),
                ),
              ),
            ),
          if (rp.round != null)
            RoundChatButton(roundId: rp.round!.id),
          // The named pill in the ribbon is this, done properly — so the icon
          // stands down wherever the ribbon draws.
          if (ribbon == null)
            IconButton(
              tooltip: 'Leaderboard',
              icon: const Icon(Icons.leaderboard_outlined),
              onPressed: rp.round == null
                  ? null
                  : () => Navigator.of(context).pushNamed(
                      '/leaderboard', arguments: rp.round!.id),
            ),
          // Overflow: low-frequency actions — set rotation, end the round
          // early (soft gate), and the icon-legend help.
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'rotation':
                  if (rp.wolfSummary != null) _promptRotation();
                  break;
                case 'end':
                  final holeInfo = rp.wolfSummary?.holeFor(_selectedHole);
                  _finishRound(
                      context, _orderedPlayers(rp.round, holeInfo));
                  break;
                case 'help':
                  showScoreEntryHelp(context);
                  break;
                case 'leaderboard':
                  if (rp.round != null) {
                    Navigator.of(context).pushNamed(
                        '/leaderboard', arguments: rp.round!.id);
                  }
                  break;
              }
            },
            itemBuilder: (_) => [
              // First, because the ribbon's pill is the primary way in and
              // this is where somebody looks when it is not drawn.
              const PopupMenuItem(
                value: 'leaderboard',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.leaderboard_outlined),
                  title: Text('Leaderboard'),
                ),
              ),
              PopupMenuItem(
                value: 'rotation',
                enabled: rp.wolfSummary != null,
                child: const ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.repeat),
                  title: Text('Set Wolf rotation'),
                ),
              ),
              if (!isComplete)
                const PopupMenuItem(
                  value: 'end',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.flag_outlined),
                    title: Text('End round'),
                  ),
                ),
              const PopupMenuItem(
                value: 'help',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.help_outline),
                  title: Text('What do these buttons do?'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(context, rp, sync, isComplete),
      bottomNavigationBar: sc == null ? null : _buildBottomNav(context, rp, sc),
    );
  }

  Widget _buildBody(
      BuildContext ctx, RoundProvider rp, SyncService sync, bool isComplete) {
    if (rp.loadingScorecard && rp.scorecard == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.scorecard == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        InlineMessage(kind: InlineMessageKind.error, text: rp.error!),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            rp.loadScorecard(widget.foursomeId);
            rp.loadWolf(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }

    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final summary  = rp.wolfSummary;
    final holeInfo = summary?.holeFor(_selectedHole);
    final players  = _orderedPlayers(rp.round, holeInfo);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final par      = holeData?.par ?? 4;
    _ensureCard(rp);
    final card     = _card(rp);
    // **The hot spot no longer waits for the call.** It used to be forced to
    // -1 until the Wolf had decided, which is what made the old sheet a gate.
    int hotSpot = isComplete ? -1 : _hotSpotIdx(players, scores);
    if (!isComplete && _editingPlayerId != null) {
      final idx = players.indexWhere((p) => p.player.id == _editingPlayerId);
      if (idx >= 0) hotSpot = idx;
    }

    return Column(children: [
      Expanded(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Hole header ──
              HoleHeader(
                holeData:    holeData,
                holeNumber:  _selectedHole,
                players:     players,
                holesInPlay: _playOrder(rp),
                standalone:  true,
                trailing: holeLegendButton(
                    context, () => _showWolfLegend(context)),
              ),
              const SizedBox(height: 12),

              // ── The Wolf's call ──
              //
              // **Chips, not a gate.** This used to be a bar that opened a
              // modal sheet, and until it was answered no score could be
              // entered at all. The call can now be set on the tee, after
              // the drives or after the scores — and if the hole fills up
              // without one, the tray asks for it.
              if (card != null)
                WolfCallCard(
                  card:  card,
                  busy:  _decisionBusy,
                  locked: _callLocked(card, players, scores),
                  onCall: (decision, {int? partnerId}) => _setDecision(
                      decision, partnerId: partnerId, hole: _selectedHole),
                  onTeeOrder: (summary != null && holeInfo != null)
                      ? () => _openTeeOrderSheet(_selectedHole)
                      : null,
                )
              else if (rp.loadingWolf)
                const Center(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: CircularProgressIndicator(strokeWidth: 2))),
              const SizedBox(height: 12),

              // ── Score entry ──
              _HoleScoreCard(
                holeData:   holeData,
                holeNumber: _selectedHole,
                players:    players,
                scorecard:  sc,
                scores:     scores,
                hotSpotIdx: hotSpot,
                par:        par,
                summary:    summary,
                holeInfo:   holeInfo,
                decided:    holeInfo?.isDecided ?? false,
                // **The keypad is the entry control when there is one.**
                // Drawing the inline picker underneath it as well puts two
                // full-width score pickers on one screen; it stays as the
                // fallback for a hole whose card has not arrived.
                showPicker: card == null,
                editingPlayerId: _editingPlayerId,
                onScoreSelected: (m, s) => _handleScore(ctx, m, s, players),
                onEditTap: (m) => setState(() => _editingPlayerId =
                    _editingPlayerId == m.player.id ? null : m.player.id),
                spotsActive:   spotsActive(rp),
                spotsTypesFor: (pid) =>
                    spotsTypesFor(pid, _selectedHole, rp.spotsSummary),
                onSpotsTap: (pid) =>
                    openSpotsSheet(widget.foursomeId, pid, _selectedHole),
                spotsSheetOpen: spotsSheetOpenFor,
              ),
              // Spots' greenie pick, on par 3s only — empty on
              // every other hole. The server decides which
              // holes are par 3s; it is walking the carry.
              ...greenieCards(rp, widget.foursomeId, _selectedHole),
              // `_WolfOutcomeLine` was here — `Wolf wins the hole · pot 3`,
              // directly above a tray whose two side rows say the same thing
              // with the nets that decided it. Survivor's `_OutcomeLine` came
              // off for the same reason.
              // **The scorecard was here and is the leaderboard's now**
              // (Paul, 10 Nov 2026) — the move Rabbit's grid, Survivor's
              // rail, and the Stroke Play, Nassau, Las Vegas, Fourball and
              // Skins cards each made: a card read after the hole has room
              // on the board and none under a keypad and a tray.
              const SizedBox(height: 16),
            ],
          ),
        ),
        ),
      ),
    ]);
  }

  Widget _buildBottomNav(BuildContext ctx, RoundProvider rp, Scorecard sc) {
    final summary  = rp.wolfSummary;
    final holeInfo = summary?.holeFor(_selectedHole);
    final players  = _orderedPlayers(rp.round, holeInfo);
    final scores   = _effectiveScores(sc, _selectedHole);
    final allDone  = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final order    = _playOrder(rp);
    final prevHole = prevInOrder(order, _selectedHole);
    final nextHole = nextInOrder(order, _selectedHole);

    // **The keypad, and the tray over the pager** — the same shape as
    // Points, Sixes and Rabbit. While the tray is up it IS the bottom bar,
    // because its forward button names the next hole's Wolf and finishes the
    // round on the last one, and a generic pager can say neither. The pager
    // still draws whenever the tray is not up, including while a result is
    // on its way, so a slow card never strands a group.
    final card = _card(rp);
    if (card != null && !isComplete) {
      // **The cursor decides.** A session always has a golfer under the
      // keypad, so asking `_trayEditing` here as well is redundant — and
      // redundant plus reachable is how a state nothing draws becomes
      // reachable (Rabbit, 30 Oct 2026).
      if (allDone && _editingPlayerId == null) {
        return SafeArea(
          child: WolfHoleTray(
            card: card,
            busy: _decisionBusy,
            gettingResult: _pending[_selectedHole]?.isNotEmpty ?? false,
            notSynced: rp.trayHoleUnsynced(_selectedHole),
            picking: _trayEditing,
            onEdit: () => setState(() {
              _trayEditing = !_trayEditing;
              _editingPlayerId = null;
            }),
            onCall: (decision, {int? partnerId}) => _setDecision(
                decision, partnerId: partnerId, hole: _selectedHole),
            onPrev: prevHole == null ? null : _retreat,
            // **On the last hole the tray IS the way out**, because it
            // covers the pager — a forward button that only advanced left
            // the 18th a dead end (reported on Rabbit).
            onNext: rp.submitting
                ? null
                : (nextHole == null
                    ? () => _finishRound(ctx, players)
                    : () => _saveAndAdvance(ctx, players)),
          ),
        );
      }

      final m = _keypadMember(players, scores);
      if (m != null) {
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FortyBallsKeypad(
              playerName: m.player.name,
              // HIS par, not the hole's — on mixed tees one golfer's 4 is
              // another's 5.
              par: sc.holeData(_selectedHole)
                      ?.scoreFor(m.player.id)?.par ?? (card.par ?? 4),
              // The strokes WOLF issues, off the low man — not the round's
              // stored full-net allocation, which is a different number
              // whenever the game is strokes-off.
              strokes: card.playerById(m.player.id)?.strokes ?? 0,
              netStyle: ctx.watch<SettingsProvider>().netStyleEntry,
              onDone: _trayEditing
                  ? () => setState(() {
                        _trayEditing = false;
                        _editingPlayerId = null;
                      })
                  : null,
              onScore: (n) {
                _handleScore(ctx, m, n, players);
                // A TAP is a one-shot; only `Edit scores` is a session.
                if (!_trayEditing) {
                  setState(() => _editingPlayerId = null);
                }
                // **The hole is POSTED on its last score.** The tray reports
                // the SERVER's figures, so a hole left unsent raises a tray
                // with nothing in it — the bug Annandale and then Sixes both
                // hit. `_handleScore` only posts when Auto-advance is on, so
                // this covers the group that has it off.
                final now = _effectiveScores(sc, _selectedHole);
                if (n > 0 && _allScored(players, now)) {
                  final hole = _selectedHole;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted || _selectedHole != hole) return;
                    final r = context.read<RoundProvider>();
                    if (r.submitting || (_pending[hole]?.isEmpty ?? true)) {
                      return;
                    }
                    _saveHole(ctx, hole, players);
                  });
                }
              },
              // **`-1` is the clear, not `0`.** `_selectScore` reads −1 as
              // "take this golfer out of pending" and anything else as a
              // score, so passing 0 wrote a gross of ZERO: the row read as
              // scored, the cursor moved on, and the hole counted complete
              // with nothing in it (reported on Rabbit, 30 Oct 2026).
              onClear: () => _selectScore(m, -1, _selectedHole),
            ),
            _pager(ctx, rp, players, allDone, isComplete, prevHole, nextHole),
          ]),
        );
      }
    }

    return SafeArea(
      child: _pager(ctx, rp, players, allDone, isComplete,
                    prevHole, nextHole),
    );
  }

  Widget _pager(
    BuildContext ctx,
    RoundProvider rp,
    List<Membership> players,
    bool allDone,
    bool isComplete,
    int? prevHole,
    int? nextHole,
  ) {
    return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: prevHole != null ? _retreat : null,
              icon: const Icon(Icons.chevron_left, size: 20),
              label: Text(
                  prevHole != null ? 'Hole $prevHole' : 'Previous'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: nextHole == null || isComplete
                ? FilledButton.icon(
                    onPressed: rp.submitting
                        ? null : () => _finishRound(ctx, players),
                    icon: const Icon(Icons.emoji_events, size: 20),
                    label: const Text('Done'),
                  )
                : FilledButton.icon(
                    onPressed: (allDone && !rp.submitting)
                        ? () => _saveAndAdvance(ctx, players) : null,
                    icon: rp.submitting
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.chevron_right, size: 20),
                    label: Text(rp.submitting
                        ? 'Saving…' : 'Hole $nextHole'),
                    iconAlignment: IconAlignment.end,
                  ),
          ),
        ]),
    );
  }
}

// ===========================================================================
// Hole header
// ===========================================================================
//
// `_HoleHeader` was here. **Replaced by the shared `HoleHeader`
// (`widgets/hole_header.dart`) 25 Sep 2026** — and this was not a cosmetic
// swap: its subtitle read `hole.par` and `hole.strokeIndex`, which are the
// SHARED first-player values on `ScorecardHole`. On a mixed men's / women's
// card that is one golfer's par and one golfer's index stated for everybody,
// and the index is what decides where a stroke falls. The shared header
// collapses both across the tees actually in play and slashes what they
// disagree on.

// Wolf's copy already TOOK a `players` list and never read it — somebody set
// out to fix exactly this and stopped at the parameter. It is read now.
// ===========================================================================
// Wolf tee order — the overlay that used to pick the call
// ===========================================================================
//
// `_WolfBar` and `_WolfChoice` were here: a slim bar that opened a modal
// picker, which had to be answered before a single score could be entered.
// The call is the chips above the scores now (`widgets/wolf_entry.dart`), so
// what is left of the overlay is the one thing nothing else shows — the
// hole’s reverse-honors tee order, and who gets a stroke on it.

/// The hole's tee order — reverse honors, the Wolf last — and the strokes
/// it turns on. Read-only: it picks nothing.
class _WolfDecisionSheet extends StatelessWidget {
  final WolfHole    hole;
  final WolfSummary summary;
  final Scorecard   scorecard;
  final bool        anyScored;

  const _WolfDecisionSheet({
    required this.hole,
    required this.summary,
    required this.scorecard,
    required this.anyScored,
  });

  bool get _fourPlayer => summary.players.length == 4;

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final decision = hole.decision;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Icon(Icons.pets, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Hole ${hole.hole} — Wolf: ',
                    style: theme.textTheme.titleMedium),
                Flexible(
                  child: Text(hole.wolfShort,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                ),
              ]),
              const SizedBox(height: 2),
              Text(
                'Tee order — worst on the last hole tees first, Wolf last.'
                '${!_fourPlayer ? '  Go Lone or Blind.' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              if (hole.partnerLocked)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Icon(Icons.lock_outline, size: 16,
                        color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Last solo-required turn — ${hole.wolfShort} must go '
                        'Lone or Blind.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: 10),

              ...hole.teeOrder.map((s) => _teeRow(context, s, decision)),

              // **No picker here.** The call is the chips above the scores,
              // which can be set at any point in the hole; a second control
              // that did the same thing differently is what they replace.
              if (anyScored && decision != 'blind')
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text('Blind Wolf is called before anyone drives.',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _teeRow(BuildContext context, WolfTeeSlot slot, String decision) {
    final theme     = Theme.of(context);
    final isWolf    = slot.isWolf;
    final isPartner = decision == 'partner' && hole.partnerId == slot.playerId;
    final prevGross = scorecard.holeData(hole.hole - 1)
        ?.scoreFor(slot.playerId)?.grossScore;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 26,
          child: isWolf
              ? Icon(Icons.pets, size: 16, color: theme.colorScheme.primary)
              : Text('${slot.orderNum}.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.primary)),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text(slot.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isWolf || isPartner
                          ? FontWeight.bold : FontWeight.w500,
                      color: isWolf ? theme.colorScheme.primary : null)),
            ),
            // Strokes on THIS hole — the fact the partner choice turns on.
            //
            // **The same dot as the score box**, drawn from `kStrokeDot` and
            // `kStrokeDotGap` rather than this sheet's own 5px one, so a
            // stroke looks the same in the picker as on the row it is picking
            // from. `StrokeDotRow` itself returns a `Positioned` for a Stack;
            // here the run sits inline beside a name, so it borrows the
            // geometry and not the widget.
            //
            // **No cap.** This clamped at three, the same cap removed from the
            // other nine surfaces — it drew two dots for a man getting three.
            // And no `gets N` beside it: the dots say it, and a number there
            // invites subtracting the stroke a second time.
            if (slot.strokes > 0) ...[
              const SizedBox(width: 6),
              for (var i = 0; i < slot.strokes; i++)
                Container(
                  width: kStrokeDot, height: kStrokeDot,
                  margin: const EdgeInsets.only(left: kStrokeDotGap),
                  decoration: BoxDecoration(
                      color: theme.colorScheme.primary, shape: BoxShape.circle),
                ),
            ],
            if (isWolf) ...[
              const SizedBox(width: 6),
              Text('tees last',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
            if (prevGross != null) ...[
              const SizedBox(width: 6),
              Text('last: $prevGross',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
        ),
        // The "Take as partner" button was here. This sheet reports the tee
        // order; the chips above the scores take the partner.
        if (isPartner)
          Text('partner',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700)),
      ]),
    );
  }

}

// ===========================================================================
// Score-entry card (modeled on points_531_screen's hole card)
// ===========================================================================

List<SpotTypeInfo> _wolfZeroSpots(int _) => const [];
bool _wolfZeroSpotsClosed(int _) => false;
void _wolfNoopPid(int _) {}

/// Handicap strokes for [m] on one hole — **the screen's one stroke source**.
///
/// The score box's dots, the inline picker's and the by-hole grid's all come
/// from here. Two copies of this on one screen is how a row shows one dot and
/// the grid shows two for the same golfer on the same hole, which reads as a
/// bug in the scoring rather than in the drawing.
///
/// (The partner picker takes `WolfTeeSlot.strokes` off the SERVER instead,
/// which is the authoritative figure. They agree; the sheet is the one place
/// the server sends a per-hole allocation for this game.)
int wolfStrokesForHole(Membership m, ScorecardHole? h,
    {required String mode, required int netPercent, required int? lowPlaying}) {
  if (h == null || mode == 'gross') return 0;
  final entry = h.scoreFor(m.player.id);
  final mySi  = entry?.strokeIndex ?? h.strokeIndex;
  if (mode == 'net') {
    if (netPercent == 100 && entry != null) return entry.handicapStrokes;
    final eff = roundHalfUp(m.playingHandicap * netPercent / 100.0);
    return strokesOnHole(eff, mySi);
  }
  if (lowPlaying == null) return 0;
  // Scale the strokes-off differential by Net %, matching the backend
  // (nassau.py / sixes.py / rabbit.py) and the "SO {n}%" chip.
  final so = roundHalfUp((m.playingHandicap - lowPlaying) * netPercent / 100.0);
  if (so <= 0) return 0;
  return strokesOnHole(so, mySi);
}

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final int              holeNumber;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, int>    scores;
  final int              hotSpotIdx;
  final int              par;
  final WolfSummary?     summary;
  final WolfHole?        holeInfo;
  final bool             decided;

  /// Draw the inline picker under the active row. False while the keypad is
  /// up — two full-width score pickers on one screen is one too many — and
  /// true as the fallback for a hole whose card has not arrived.
  final bool             showPicker;
  final int?             editingPlayerId;   // scored row tapped for correction
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership) onEditTap;
  // Spots add-on (capture in this dedicated entry screen).
  final bool                   spotsActive;
  final List<SpotTypeInfo> Function(int pid) spotsTypesFor;
  final void Function(int pid) onSpotsTap;
  final bool Function(int pid) spotsSheetOpen;

  const _HoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.summary,
    required this.holeInfo,
    required this.decided,
    required this.showPicker,
    required this.editingPlayerId,
    required this.onScoreSelected,
    required this.onEditTap,
    this.spotsActive   = false,
    this.spotsTypesFor = _wolfZeroSpots,
    this.onSpotsTap    = _wolfNoopPid,
    this.spotsSheetOpen = _wolfZeroSpotsClosed,
  });

  String get _mode       => summary?.handicapMode ?? 'net';
  int    get _netPercent => summary?.netPercent   ?? 100;

  int? get _lowPlaying {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  int _strokesForHole(Membership m, ScorecardHole? h) =>
      wolfStrokesForHole(m, h,
          mode: _mode, netPercent: _netPercent, lowPlaying: _lowPlaying);

  Widget _legendDot(ThemeData theme, Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 10, height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant)),
    ]);
  }

  /// A player's team/role on this hole, derived from the decision so the
  /// colors show as soon as the teams are chosen (before any score is in).
  String? _roleFor(int playerId) {
    final h = holeInfo;
    if (h == null || !h.isDecided) return null;
    if (playerId == h.wolfId) return 'wolf';
    if (h.decision == 'partner' && playerId == h.partnerId) return 'partner';
    return 'opponent';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The inline picker is suppressed until the Wolf has chosen
    // partner / lone / blind — scoring a hole before the Wolf acts would
    // record points against an undefined hole.
    //
    // **The call is no longer a gate.** `effHot` used to be forced to -1
    // until the Wolf had decided, so a group could not enter a single score
    // before somebody answered a modal sheet. The chips above this card can
    // be answered at any point in the hole, and the tray asks for the call
    // if the hole fills up without one.
    final effHot = hotSpotIdx;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The "tap to set the Wolf's play before entering scores" banner
          // was here. It described a rule this screen no longer has.
          if (decided)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Row(children: [
                _legendDot(theme, GameColors.team1,
                    holeInfo?.decision == 'partner' ? 'Wolf + partner' : 'Wolf'),
                const SizedBox(width: 16),
                _legendDot(theme, GameColors.team2, 'Opponents'),
              ]),
            ),
          ...players.asMap().entries.expand((entry) {
            final idx = entry.key;
            final m   = entry.value;
            final gross = scores[m.player.id];
            final isHot = idx == effHot;
            final isEditing = editingPlayerId == m.player.id;
            // A scored row that isn't the live hot-spot can be tapped to fix
            // it — a completed hole has no hot-spot, so without this there'd be
            // no way to edit a past hole.
            final editable = gross != null && !isHot;
            final strokes = _strokesForHole(m, holeData);
            final role = _roleFor(m.player.id);

            final teamColor =
                _wolfTeamColor(role) ?? Theme.of(context).colorScheme.primary;
            final row = _PlayerRow(
                comboTee: m.comboTeeOnHole(holeData?.holeNumber ?? 0),
                member:    m,
                gross:     gross,
                isHot:     isHot,
                strokes:   strokes,
                role:      role,
                isEditing: isEditing,
                onTap:     editable ? () => onEditTap(m) : null,
                spotsActive:  spotsActive,
                spotsTypes:   spotsActive ? spotsTypesFor(m.player.id) : const [],
                onSpotsTap:   spotsActive ? () => onSpotsTap(m.player.id) : null,
                spotsSheetOpen: spotsActive && spotsSheetOpen(m.player.id),
              );
            if ((isHot || isEditing) && showPicker) {
              // Active player + score entry share ONE team-coloured bounding
              // box with a white fill (matches the universal score-entry
              // screen). The picker inherits the same team colour + white fill.
              return [
                Container(
                  // Flush on the LEFT so the bold accent bar lines up with the
                  // unpicked rows' left bars; inset on the RIGHT so the right
                  // line stays visible (not clipped by the card edge).
                  margin: const EdgeInsets.fromLTRB(0, 6, 8, 6),
                  decoration: BoxDecoration(
                    // Match the universal (Nassau) screen: faint team-colour
                    // wash + a bold left accent, thin line on the other sides.
                    color: teamColor.withOpacity(0.10),
                    border: Border(
                      top:    BorderSide(color: teamColor, width: 1.5),
                      bottom: BorderSide(color: teamColor, width: 1.5),
                      right:  BorderSide(color: teamColor, width: 1.5),
                      left:   BorderSide(color: teamColor, width: 4.0),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      row,
                      InlineScorePicker(
                        par:          par,
                        strokes:      strokes,
                        currentScore: gross,
                        boxBorderColor: teamColor,
                        boxFillColor:   Colors.white,
                        onScoreSelected: (s) => onScoreSelected(m, s),
                      ),
                    ],
                  ),
                ),
              ];
            }
            // The keypad covers the last row of a four-man card, so the
            // golfer being scored is brought into view — keyed on hole and
            // golfer, like the universal screen.
            if (isHot || isEditing) {
              return [
                RevealOnMount(
                  key: ValueKey('entry-$holeNumber-${m.player.id}'),
                  child: row),
              ];
            }
            return [row];
          }),
        ],
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  final Membership member;
  /// This golfer's tee for the hole being entered — combo sets only.
  final String?    comboTee;
  final int?       gross;
  final bool       isHot;
  final int        strokes;
  final String?    role;   // wolf | partner | opponent
  final bool       isEditing;  // its inline picker is currently open
  final VoidCallback? onTap;
  final bool          spotsActive;
  final List<SpotTypeInfo> spotsTypes;
  final VoidCallback?      onSpotsTap;
  final bool               spotsSheetOpen;

  const _PlayerRow({
    required this.member,
    this.comboTee,
    required this.gross,
    required this.isHot,
    required this.strokes,
    required this.role,
    this.isEditing = false,
    this.onTap,
    this.spotsActive = false,
    this.spotsTypes = const [],
    this.onSpotsTap,
    this.spotsSheetOpen = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final teamColor = _wolfTeamColor(role);
    final active = isHot || isEditing;
    // Active score box: white fill + a team-colour ring (not the old green).
    final boxBg = active ? Colors.white : Colors.transparent;
    final boxBorder = active
        ? Border.all(color: teamColor ?? theme.colorScheme.primary, width: 2)
        : Border.all(color: teamColor ?? theme.colorScheme.outline,
            width: teamColor != null ? 1.5 : 1);

    final inner = Container(
      decoration: BoxDecoration(
        // Inside the active bounding box the row is transparent so the box's
        // white fill shows through; inactive rows keep their team tint + the
        // left accent bar (warm = Wolf side, cool = opponents).
        color: active ? Colors.transparent : teamColor?.withOpacity(0.07),
        border: active
            ? const Border()
            : Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
                left: teamColor != null
                    ? BorderSide(color: teamColor, width: 4)
                    : BorderSide.none,
              ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        if (role == 'wolf')
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.pets, size: 16, color: theme.colorScheme.primary),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
            Flexible(
              child: Text(member.player.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (role == 'partner') ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('partner',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer)),
              ),
            ],
            ComboTeeChip(tee: comboTee),
            // `gets N` was here — the ROUND's total allocation, in a chip, and
            // only ever drawn on a strokes-off round. It is replaced by the
            // dots on the score box, which say the thing the Wolf actually
            // needs off the tee: who is getting a shot on THIS hole.
              ]),
              if (spotsActive)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SpotsButton(
                    types:   spotsTypes,
                    onTap:   onSpotsTap ?? () {},
                    focused: spotsSheetOpen,
                  ),
                ),
            ],
          ),
        ),
        // Tapping a scored row opens its inline editor (no pencil affordance —
        // consistent with the other score screens, where tapping the score is
        // the edit gesture).
        const SizedBox(width: 8),
        // **The stroke dots, which Wolf was the last score screen without.**
        // They matter more here than anywhere else: the Wolf picks his partner
        // off the tee, and a man getting a shot on this hole is a different
        // proposition from the same man on the next one. The row showed
        // nothing at all on a NET round, which is most of them.
        //
        // Same 40x36 box and same horizontal run as every other score box —
        // three dots cost 15px of 40 here and clear the digit, which is why
        // this axis is the box's and the column is the grid's.
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 40, height: 36,
              decoration: BoxDecoration(
                color: boxBg, border: boxBorder,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: gross != null
                    ? Text('$gross',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold))
                    : const SizedBox.shrink(),
              ),
            ),
            StrokeDotRow(
                strokes: strokes, color: theme.colorScheme.primary),
          ],
        ),
      ]),
    );

    if (onTap == null) return inner;
    return InkWell(onTap: onTap, child: inner);
  }
}

// ===========================================================================
// Rotation bottom sheet — drag to re-set the Wolf order mid-round
// ===========================================================================

class _RotationSheet extends StatefulWidget {
  final List<int>        order;
  final List<Membership> members;
  /// First N positions are frozen (their hole has been played) — not draggable.
  final int              lockedCount;
  const _RotationSheet({
    required this.order,
    required this.members,
    this.lockedCount = 0,
  });

  @override
  State<_RotationSheet> createState() => _RotationSheetState();
}

class _RotationSheetState extends State<_RotationSheet> {
  late List<int> _order;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.order);
  }

  Membership? _memberOf(int id) {
    for (final m in widget.members) {
      if (m.player.id == id) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text('Wolf rotation',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
              widget.lockedCount > 0
                  ? 'Played holes are locked. Reorder only the later positions, '
                    'or reset the game to change an earlier Wolf.'
                  : 'Drag to set who is the Wolf, hole by hole.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: _order.length,
              onReorder: (a, b) {
                setState(() {
                  if (b > a) b -= 1;
                  // Never move into (or out of) the locked prefix.
                  if (a < widget.lockedCount) return;
                  if (b < widget.lockedCount) b = widget.lockedCount;
                  final id = _order.removeAt(a);
                  _order.insert(b, id);
                });
              },
              itemBuilder: (context, i) {
                final m = _memberOf(_order[i]);
                final locked = i < widget.lockedCount;
                return Container(
                  key: ValueKey(_order[i]),
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withOpacity(locked ? 0.25 : 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Text('${i + 1}',
                          style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(m?.player.name ?? 'Player',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: locked
                                ? theme.colorScheme.onSurfaceVariant
                                : null))),
                    locked
                        ? Icon(Icons.lock_outline, size: 18,
                            color: theme.colorScheme.onSurfaceVariant)
                        : ReorderableDragStartListener(
                            index: i,
                            child: Icon(Icons.drag_handle,
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                  ]),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_order),
              child: const Text('Save rotation'),
            ),
          ),
        ]),
      ),
    );
  }
}
