/// screens/team_play_score_entry_screen.dart
/// -----------------------------------------
/// Foursome Play score entry — the same card every other game in the app uses
/// (docs/design-review/handoff-team-play/SPEC.md §10.1).
///
/// Shaped after Survivor / Rabbit / Points 5-3-1: a tinted hole header, the
/// players stacked as rows, and [InlineScorePicker] expanding INSIDE the
/// active row's bounding box. A golfer who has entered a score anywhere in
/// this app already knows how it works, and the two earlier attempts here — a
/// full-screen stepper, then per-row steppers — were both a fourth idiom for
/// no gain.
///
/// **The card belongs to the playing GROUP, not the team.** Four golfers go
/// off one tee time with one scorer, so one person enters everything on it —
/// and in a pairs event that is TWO teams' worth. The screen stacks a block per
/// team; a foursome event always has exactly one, so it reads as it always did.
///
/// Six formats, **two cards**, and only the middle of each block differs:
///
///   * **One ball** — scramble, alternate shot, Scotch, Chapman. The team
///     makes ONE number, so there is one row: TEAM. Its picker is always open,
///     because there is nothing to choose between.
///   * **Own ball** — shamble (four balls) and best ball (two). One row a golfer;
///     tap one to aim the picker, and the counting scores tint while the rest
///     grey as they land.
///
/// **The drive is its own question**, so it gets its own control above the
/// rows rather than being smuggled onto a golfer. What that control DOES
/// differs by format (docs/design-review/handoff-team-pairs/SPEC.md §5), and
/// this screen is where getting it right matters:
///
///   * **A record** — scramble. Chips with pips, compliance against a quota.
///   * **An instruction** — Scotch. The pick says who hits NEXT, so the card
///     answers with a sentence: *Maiolini plays the second shot, then
///     alternate.* The tap is required every hole even with no quota.
///   * **A rota** — alternate shot. No choice; the card NAMES the tee, on
///     every hole without exception, because a pair that loses track plays a
///     hole out of order and the round is gone.
///   * **Absent** — best ball and Chapman. Both golfers drive every hole.
///
/// It never blocks the tap — the team may knowingly take the shortfall, and by
/// default a shortfall costs nothing.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/team_play/team_play_bits.dart';
import '../widgets/team_scorecard.dart';

class TeamPlayScoreEntryScreen extends StatefulWidget {
  final int    foursomeId;
  final String teamName;
  final String colour;
  /// For the chat button and the board link in the app bar — the same two the
  /// other entry screens carry.
  final int?   roundId;
  final int?   tournamentId;
  final String tournamentName;

  const TeamPlayScoreEntryScreen({
    super.key,
    required this.foursomeId,
    required this.teamName,
    required this.colour,
    this.roundId,
    this.tournamentId,
    this.tournamentName = '',
  });

  @override
  State<TeamPlayScoreEntryScreen> createState() =>
      _TeamPlayScoreEntryScreenState();
}

class _TeamPlayScoreEntryScreenState extends State<TeamPlayScoreEntryScreen> {
  /// Null until the first load: the server picks the opening hole — the first
  /// this group has not finished, IN ITS PLAY ORDER. A shotgun group starting
  /// on 9 must not open on 1.
  int? _hole;
  /// Own-ball formats only: whose ball the picker is aimed at, keyed by the
  /// team it belongs to — two pairs on one card each aim their own.
  final Map<int, int> _selected = {};
  TeamPlayCard? _card;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final card = await context.read<AuthProvider>().client
          .getTeamPlayCard(widget.foursomeId, _hole);
      if (!mounted) return;
      setState(() { _card = card; _hole = card.hole; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setTeamScore(int slot, int? gross) async {
    await context.read<AuthProvider>().client
        .postTeamPlayScore(widget.foursomeId,
                           hole: _hole!, gross: gross, slot: slot);
    await _load();
  }

  /// An own-ball format keeps per-golfer scores — four balls best N in a
  /// shamble, two balls best 1 in best ball — so these are ordinary HoleScores
  /// through the ordinary endpoint. Only the reading of them is Team Play's.
  Future<void> _setGolferScore(int playerId, int? gross) async {
    await context.read<AuthProvider>().client.submitScores(
      foursomeId: widget.foursomeId,
      holeNumber: _hole!,
      scores    : [{'player_id': playerId, 'gross_score': gross}],
    );
    await _load();
  }

  /// The rota, set on the 1st tee and then fixed for eighteen.
  ///
  /// This closes the one thing the fours build left open: the endpoint was
  /// written and tested and nothing called it, so a team on the alternating
  /// rule fell back to roster order. It matters more in pairs — an alternate
  /// shot played out of order is a lost round, not an untidy record.
  Future<void> _setRota(int slot, List<List<int>> pairs) async {
    setState(() => _busy = true);
    try {
      await context.read<AuthProvider>().client
          .postTeamPlayPairs(widget.foursomeId, pairs, slot: slot);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setDrive(int slot, int? playerId) async {
    await context.read<AuthProvider>().client
        .postTeamPlayDrive(widget.foursomeId,
                           hole: _hole!, playerId: playerId, slot: slot);
    await _load();
  }

  void _goto(int? hole) {
    if (hole == null) return;
    setState(() { _hole = hole; _selected.clear(); });
    _load();
  }

  /// The golfer the picker is aimed at: the tap, else the first golfer still
  /// without a score, else the first row. Auto-advancing to whoever is missing
  /// is what makes four entries four taps.
  int? _activeGolfer(TeamPlayCardTeam team) {
    final rows = team.shamble?.rows ?? const <TeamPlayShambleRow>[];
    if (rows.isEmpty) return null;
    final picked = _selected[team.slot];
    if (picked != null && rows.any((r) => r.playerId == picked)) return picked;
    for (final r in rows) {
      if (r.gross == null) return r.playerId;
    }
    return rows.first.playerId;
  }

  /// What this hole is still waiting on, or null when it is complete.
  ///
  /// **The hole is not complete until the drive is picked.** Advancing without
  /// one loses the record silently — the tracker then reports a shortfall
  /// nobody caused, and by the 18th nobody can reconstruct which hole it was.
  /// So the forward button names what is outstanding rather than going quiet.
  ///
  /// This is not the same as blocking the drive TAP, which never happens: the
  /// team may knowingly take a shortfall, it just has to say so by picking
  /// somebody.
  /// True when the rota rule is on and this team has not set it yet.
  bool _needsRota(TeamPlayCardTeam team) =>
      (team.driveControl == 'rota' || team.drive.isAlternating) &&
      !team.drive.pairsSet &&
      team.driveOptions.length >= 2;

  /// Every team on this card. A foursome event sends one; a pairs playing
  /// group sends one or two.
  List<TeamPlayCardTeam> _teams(TeamPlayCard card) => card.teams;

  /// What this hole is still waiting on, across EVERY team on the card.
  ///
  /// One card, one group, one button — so it names the first thing outstanding
  /// anywhere on it, and says which pair when there is more than one.
  String? _outstanding(TeamPlayCard card) {
    final teams = _teams(card);
    final many  = teams.length > 1;

    String tag(TeamPlayCardTeam t, String what) =>
        many ? '$what — ${t.name}' : what;

    for (final t in teams) {
      if (_needsRota(t)) {
        return tag(t, card.isPairs ? 'Set who tees the odd holes'
                                   : 'Set the rota');
      }
    }
    for (final t in teams) {
      final rows = t.shamble?.rows.length ?? 0;
      final needsScore = card.isOneBall
          ? t.teamScore == null
          : !(t.shamble?.complete ?? false);
      // A quota needs a pick. With no drive requirement there is nothing to
      // record in any format, so nothing is asked for.
      final needsDrive = t.requiresDrivePick &&
          t.showsDriveChips &&
          t.pickedDriver == null;

      if (needsScore && needsDrive) return tag(t, 'Score and drive needed');
      if (needsScore) {
        return tag(t, card.isOneBall ? 'Enter the score'
                                     : 'Enter all $rows scores');
      }
      if (needsDrive) {
        return tag(t, t.driveControl == 'instruction'
            ? 'Pick the drive — it says who plays next'
            : 'Pick whose drive');
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    return Scaffold(
      appBar: GolfAppBar(
        title: widget.teamName,
        automaticallyImplyLeading: false,
        // An X back to the hub, matching every other score-entry screen —
        // a back chevron reads as "undo a step", and this is a place you leave.
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Back to the round',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (widget.roundId != null) RoundChatButton(roundId: widget.roundId!),
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: widget.tournamentId == null
                ? null
                : () => Navigator.of(context).pushNamed(
                    '/team-play-leaderboard',
                    arguments: {
                      'tournamentId'  : widget.tournamentId,
                      'tournamentName': widget.tournamentName,
                    }),
          ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: '$_error', onRetry: _load)
          : card == null
              ? const Center(child: CircularProgressIndicator())
              : _body(card),
      bottomNavigationBar: card == null ? null : _HoleNav(
        card     : card,
        hole     : _hole!,
        onGo     : _goto,
        outstanding: _outstanding(card),
        onDone     : () => Navigator.of(context).maybePop(),
      ),
    );
  }

  /// The banner at the top, the way Survivor states what game you are in and
  /// what it is doing right now. Neither the allowance nor the ball count
  /// belongs on a row, and neither should be hidden either.
  (String, String) _context(TeamPlayCard card) {
    // No "plays off N" in any of these — the team row's `gets N` chip says it,
    // in the place every other card in the app says it.
    switch (card.format) {
      case 'scramble':
        return (card.formatName, card.isPairs
            ? 'Both hit, you play the better ball, repeat.'
            : 'All four hit, you play the best ball.');
      case 'alternate_shot':
        return (card.formatName,
            "One ball, hit in turn. Both mistakes are the pair's, which is why "
            'it is the most generous allowance of the five.');
      case 'scotch':
        return (card.formatName,
            'Both drive, take the better one, then alternate from there. The '
            'partner whose drive was not taken plays the second shot.');
      case 'chapman':
        return (card.formatName,
            'Both drive, swap for the second, then one ball in turn.');
      case 'best_ball':
        return (card.formatName,
            'Both play their own ball. The better NET counts — a higher gross '
            'can be the counting ball once strokes are in.');
    }
    final n = card.shamble?.count ?? 2;
    return (
      'Shamble',
      'Best drive, then everyone plays their own ball in. '
      'The ${n == 1 ? 'lowest net counts' : '$n lowest nets count'}; '
      'the rest are recorded and ignored.',
    );
  }

  Widget _body(TeamPlayCard card) {
    return ListView(
      // Same outer padding as Skins — 12 all round, 8 at the foot, with the
      // hole nav below taking its own safe-area inset.
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      children: [
        _HoleHeader(card: card, hole: _hole!),
        const SizedBox(height: 12),

        // One block per TEAM. A foursome event has exactly one, so this reads
        // as it always did; a pairs playing group has two, stacked, because
        // one person is entering for the whole group.
        for (final team in _teams(card)) ...[
          _TeamBlock(
            card    : card,
            team    : team,
            hole    : _hole!,
            busy    : _busy,
            needsRota  : _needsRota(team),
            selected   : card.isOneBall ? null : _activeGolfer(team),
            onSetRota  : (pairs) => _setRota(team.slot, pairs),
            onPickDrive: (pid) => _setDrive(team.slot, pid),
            onSetTeam  : (gross) => _setTeamScore(team.slot, gross),
            onSelect   : (id) => setState(() => _selected[team.slot] = id),
            onSetGolfer: _setGolferScore,
            onGo       : _goto,
          ),
          const SizedBox(height: 16),
        ],

        const SizedBox(height: 16),
        // The rules sit at the BOTTOM. They are read once on the 1st tee and
        // are furniture by the 3rd; the hole, the scores and the card are what
        // the screen is for.
        _Banner(context_: _context(card)),
      ],
    );
  }
}

/// One team's block on the card: who is up, the drive control, the score
/// row(s), and the card so far.
///
/// **A pairs playing group stacks two of these.** They share the hole header,
/// the rules banner and the hole navigation, because those belong to the group
/// — four golfers walking one course together — while everything in here belongs
/// to the pair.
class _TeamBlock extends StatelessWidget {
  final TeamPlayCard     card;
  final TeamPlayCardTeam team;
  final int  hole;
  final bool busy;
  final bool needsRota;
  final int? selected;

  final Future<void> Function(List<List<int>>) onSetRota;
  final Future<void> Function(int?)            onPickDrive;
  final Future<void> Function(int?)            onSetTeam;
  final ValueChanged<int>                      onSelect;
  final Future<void> Function(int, int?)       onSetGolfer;
  final ValueChanged<int?>                     onGo;

  const _TeamBlock({
    required this.card, required this.team, required this.hole,
    required this.busy, required this.needsRota,
    required this.selected,
    required this.onSetRota, required this.onPickDrive,
    required this.onSetTeam, required this.onSelect,
    required this.onSetGolfer, required this.onGo,
  });

  /// `E` / `+3` / `-2` — the app's to-par label, the same one the board prints.
  static String _toPar(int diff) =>
      diff == 0 ? 'E' : (diff > 0 ? '+$diff' : '$diff');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final net   = team.round.netToPar;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ONE header row for the whole block. It used to be three — the
          // team heading, the score row's own label with a `gets N` chip, and
          // the scorecard's "Scorecard" bar — each naming the same team and
          // between them eating a third of the screen. Name on the left, what
          // the round is worth and the number just made on the right.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(children: [
              TeamColourBlock(colour: team.colour, size: 10),
              const SizedBox(width: 8),
              Expanded(
                child: Text(team.name,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (team.round.thru > 0) ...[
                // Net only. Gross to par is not a number anybody plays for
                // here — on an own-ball format it is an aggregate against a
                // multiplied par, and on a one-ball format the net is the same
                // figure shifted by a constant.
                Text(
                  'thru ${team.round.thru}'
                  '${net == null ? '' : ' · Net ${_toPar(net)}'}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 10),
              ],
              if (card.isOneBall)
                _ScoreBox(
                  score     : team.teamScore,
                  active    : true,
                  strokeHere: team.teamStrokes > 0,
                )
              else if ((team.shamble?.count ?? 0) > 0)
                Text('${team.shamble!.count} of '
                     '${team.shamble!.rows.length} count',
                     style: theme.textTheme.labelSmall
                         ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),

          // The rota is set once, before the first score, and then fixed.
          // Until it is, this is the only thing on the block that matters — an
          // alternate shot with no agreed tee order is not a round.
          if (needsRota)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: _RotaSetup(team: team, busy: busy, onSet: onSetRota),
            ),

          // Drawn only when the format has something to say about the tee.
          // With no drive requirement there is nothing to record, so nothing
          // is asked.
          if (!needsRota &&
              (team.showsDriveChips ||
               team.driveControl == 'rota' ||
               team.teeNote.isNotEmpty))
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: _DriveStrip(
                  card: card, team: team, hole: hole, onPick: onPickDrive),
            ),

          // Nothing is tappable while a save is in flight — two taps on one
          // hole would race each other's reload.
          IgnorePointer(
            ignoring: busy,
            child: card.isOneBall
                ? _TeamScoreRow(
                    card    : card,
                    team    : team,
                    teamName: team.name,
                    onSet   : onSetTeam,
                  )
                : _ShambleRows(
                    team    : team,
                    selected: selected,
                    onSelect: onSelect,
                    onSet   : onSetGolfer,
                  ),
          ),

          // The card so far, in the SAME container as the entry rather than a
          // section of its own. It is the same team, the same hole strip and
          // the same colour — splitting it off bought a second border and a
          // second title and said nothing new.
          _CardScorecard(
            card    : card,
            team    : team,
            hole    : hole,
            onGo    : onGo,
            golferId: card.isOneBall ? null : selected,
          ),
        ],
      ),
    );
  }
}

/// The green context block Survivor opens with: what game this is, and what it
/// is doing on this hole.
class _Banner extends StatelessWidget {
  final (String, String) context_;
  const _Banner({required this.context_});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, body) = context_;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 2),
          Text(body, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

// ── Hole header ─────────────────────────────────────────────────────────────

class _HoleHeader extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  const _HoleHeader({required this.card, required this.hole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bits = <String>[
      if (card.par != null) 'Par ${card.par}',
      if (card.yards != null) '${card.yards} yds',
      if (card.strokeIndex != null) 'SI ${card.strokeIndex}',
      // On a shotgun start the hole number is not the position in the round,
      // so say both rather than leaving a group on 9 wondering whether it is
      // on its first hole or its ninth.
      if (card.playOrder.isNotEmpty && card.playOrder.first != 1)
        '${card.positionOf(hole)} of ${card.playOrder.length}',
      // Stated on EVERY hole, per the packet — it is the one piece of the
      // shamble's rule that is operative rather than reference, so it stays up
      // here even though the rule itself moved to the bottom.
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text('Hole $hole',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        if (bits.isNotEmpty)
          Text(bits.join('  ·  '),
              textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

// ── The drive ───────────────────────────────────────────────────────────────

/// A chip per golfer, the pips on the chip, and the consequence stated beside
/// it. Its own control because it is its own question — the score belongs to
/// the team, and hanging it off a golfer's row would say otherwise.
///
/// **The same control does three different jobs.** A scramble records
/// compliance; Scotch issues an instruction and answers with a sentence; an
/// alternate shot has nothing to choose and states who is up. Best ball and
/// Chapman never reach here.
class _DriveStrip extends StatelessWidget {
  final TeamPlayCard card;
  final TeamPlayCardTeam team;
  final int hole;
  final Future<void> Function(int?) onPick;

  const _DriveStrip({
    required this.card, required this.team,
    required this.hole, required this.onPick,
  });

  TeamPlayDriveWindow? get _window {
    for (final w in team.drive.windows) {
      if (hole >= w.start && hole <= w.end) return w;
    }
    return team.drive.windows.isEmpty ? null : team.drive.windows.first;
  }

  int? get _driver {
    for (final g in _window?.golfers ?? const <TeamPlayDriveGolfer>[]) {
      if (g.holes.contains(hole)) return g.playerId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A schedule needs one line on the tee, not a tracker. It is NEVER
    // conditional: a pair that loses track of an alternate-shot rota plays a
    // hole out of order and the round is gone.
    if (team.driveControl == 'rota' || team.drive.isAlternating) {
      final rota = team.drive.rotaFor(hole);
      final line = team.teeNote.isNotEmpty
          ? team.teeNote
          : (rota == null || rota.upLabel.isEmpty
              ? 'The team sets the rota on the 1st tee.'
              : rota.upLabel);
      return _Panel(
        label: card.isPairs ? 'WHO TEES' : 'WHOSE TEE SHOT',
        child: Text(
          line + (rota?.phantomCoverName.isEmpty ?? true
              ? ''
              : '  ·  ${rota!.phantomCoverName} → phantom'),
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
    }

    final w = _window;
    final driver = _driver ?? team.pickedDriver;

    // **Scotch with no quota.** The tap is still required, because it is not a
    // record at all — it tells the pair who plays the second shot. There are
    // no windows to read pips from, so the chips come off the card's roster
    // and the panel answers with the sentence instead of a slack figure.
    if (w == null) {
      if (!team.showsDriveChips) return const SizedBox.shrink();
      return _Panel(
        label: team.driveControl == 'instruction'
            ? 'WHOSE DRIVE' : 'WHOSE DRIVE',
        trailing: Text(
          team.driveControl == 'instruction' ? 'both hit' : '',
          style: theme.textTheme.labelSmall),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final o in team.driveOptions)
                  _DriveOptionChip(
                    option  : o,
                    selected: o.playerId == driver,
                    onTap   : () => onPick(
                        o.playerId == driver ? null : o.playerId),
                  ),
              ],
            ),
            if (team.teeNote.isNotEmpty) ...[
              const SizedBox(height: 8),
              // *Maiolini plays the second shot, then alternate.* A sentence,
              // not a tick — because that is what the pick MEANS here.
              Text(team.teeNote,
                   style: theme.textTheme.bodySmall?.copyWith(
                       fontWeight: FontWeight.w600,
                       color: theme.colorScheme.primary)),
            ],
          ],
        ),
      );
    }

    return _Panel(
      label   : 'WHOSE DRIVE',
      // "all square" was match-play language borrowed by accident and meant
      // nothing here. Say what the captain needs: who still owes, and how many
      // holes are not already spoken for.
      trailing: w.owed == 0
          ? Text('nobody owes', style: theme.textTheme.labelSmall)
          : Text(
              '${w.owed} owed · ${w.freeLeft} free',
              style: theme.textTheme.labelSmall?.copyWith(
                color: w.tight || w.impossible
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in w.golfers)
                _DriveChip(
                  golfer  : g,
                  selected: g.playerId == driver,
                  onTap   : () => onPick(
                      g.playerId == driver ? null : g.playerId),
                ),
            ],
          ),
          // Scotch with a quota on top: the instruction still has to be said,
          // because the tap did two jobs.
          if (team.driveControl == 'instruction' &&
              team.teeNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(team.teeNote,
                 style: theme.textTheme.bodySmall?.copyWith(
                     fontWeight: FontWeight.w600,
                     color: theme.colorScheme.primary)),
          ],
          if (w.owed > 0 && (w.tight || w.impossible)) ...[
            const SizedBox(height: 8),
            // The consequence in a sentence, on the tee — the moment a quota
            // becomes unsatisfiable is invisible to four golfers who have had a
            // few. It never blocks the tap.
            Text(
              w.impossible
                  ? '${w.label} cannot be satisfied now. Play on — a shortfall '
                    'is recorded, not blocked.'
                  : 'It still works, but only if every remaining hole goes to '
                    'a golfer who owes one.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

/// Setting the rota, on the 1st tee, once
/// (docs/design-review/handoff-team-pairs/SPEC.md §5.2).
///
/// **The app does not derive it from handicap.** The golfers decide in ten
/// seconds, it is the only part of the rule anyone enjoys, and a computed
/// order would be overridden on the spot. Then it is fixed for eighteen — a
/// rota that can be re-cut mid-round is not a rota, and the server refuses a
/// second POST for exactly that reason.
///
/// Two golfers → who tees the odd holes, two ways.
/// Four golfers → the two driving pairs, three ways to split four into two and two.
class _RotaSetup extends StatelessWidget {
  final TeamPlayCardTeam team;
  final bool busy;
  final Future<void> Function(List<List<int>>) onSet;

  const _RotaSetup({
    required this.team, required this.busy, required this.onSet,
  });

  /// Every legal split, as `(label, pairs)`.
  List<(String, List<List<int>>)> get _choices {
    final o = team.driveOptions;
    if (o.length == 2) {
      return [
        ('${o[0].short} odds / ${o[1].short} evens',
         [[o[0].playerId], [o[1].playerId]]),
        ('${o[1].short} odds / ${o[0].short} evens',
         [[o[1].playerId], [o[0].playerId]]),
      ];
    }
    if (o.length == 4) {
      const splits = [(0, 1, 2, 3), (0, 2, 1, 3), (0, 3, 1, 2)];
      return [
        for (final (a, b, c, d) in splits)
          ('${o[a].short} & ${o[b].short}  /  ${o[c].short} & ${o[d].short}',
           [[o[a].playerId, o[b].playerId], [o[c].playerId, o[d].playerId]]),
      ];
    }
    // Three golfers run AB / BC / AC — two drivers every hole, each sitting out
    // every third, which is as even as three into two goes.
    if (o.length == 3) {
      return [
        ('${o[0].short} & ${o[1].short}, then ${o[1].short} & ${o[2].short}, '
         'then ${o[0].short} & ${o[2].short}',
         [[o[0].playerId, o[1].playerId],
          [o[1].playerId, o[2].playerId],
          [o[0].playerId, o[2].playerId]]),
      ];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairs = team.driveOptions.length == 2;
    return _Panel(
      label: pairs ? 'SET THE TEE ROTA' : 'SET THE DRIVING PAIRS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pairs
                ? 'Who tees on the odd holes. Fixed for eighteen once set — '
                  'the card names the tee on every hole from here.'
                : 'Two golfers drive each hole, the other two the next. Fixed '
                  'for eighteen once set.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          for (final (label, choice) in _choices) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: busy ? null : () => onSet(choice),
                child: Text(label, textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

/// The chip for a format with no quota behind it — Scotch off a plain roster.
/// No pips, because there is nothing being counted.
class _DriveOptionChip extends StatelessWidget {
  final TeamPlayDriveOption option;
  final bool selected;
  final VoidCallback onTap;

  const _DriveOptionChip({
    required this.option, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : null,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: 1.5,
          ),
        ),
        child: Text(option.short,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : null,
            )),
      ),
    );
  }
}

class _DriveChip extends StatelessWidget {
  final TeamPlayDriveGolfer golfer;
  final bool selected;
  final VoidCallback onTap;

  const _DriveChip({
    required this.golfer, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owes  = golfer.owes > 0;
    // Last name only — four full names do not fit a phone, and the group knows
    // who Maiolini is.
    final short = golfer.name.split(' ').last;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : null,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : (owes ? theme.colorScheme.error.withValues(alpha: 0.5)
                        : theme.colorScheme.outlineVariant),
            width: 1.5,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(short,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : null,
              )),
          const SizedBox(width: 6),
          Text(
            golfer.holes.isEmpty ? 'owes ${golfer.owes}'
                                 : golfer.holes.map((h) => 'h$h').join(' '),
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected
                  ? Colors.white70
                  : (owes ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final String  label;
  final Widget  child;
  final Widget? trailing;
  const _Panel({required this.label, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(label,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6))),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

// ── Scramble: one row, one number ───────────────────────────────────────────

class _TeamScoreRow extends StatelessWidget {
  final TeamPlayCard card;
  final TeamPlayCardTeam team;
  final String teamName;
  final Future<void> Function(int?) onSet;
  const _TeamScoreRow({
    required this.card, required this.team,
    required this.teamName, required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final box   = theme.colorScheme.primary;
    final par   = card.par ?? 4;

    // Always open: the team makes one number, so there is nothing to choose
    // between and no reason to make the TD tap a row first.
    //
    // **No header of its own.** The team's name, its score box and its
    // to-par line all live on the block's single header row — this used to
    // repeat the name and add a `gets N` chip, which made three header rows
    // per team saying overlapping things.
    return Container(
      decoration: BoxDecoration(
        color: box.withValues(alpha: 0.10),
        border: Border(
          top:    BorderSide(color: box, width: 1.5),
          bottom: BorderSide(color: box, width: 1.5),
          right:  BorderSide(color: box, width: 1.5),
          left:   BorderSide(color: box, width: 4.0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineScorePicker(
            // The team's strokes ARE passed, so the strip anchors on net par
            // and the handicap dots appear on the holes the team gets one.
            // The packet argued for gross-only here to stop anyone subtracting
            // the figure per hole; seeing WHICH holes carry a stroke turned out
            // to matter more, and the dots are the app's existing way of
            // saying it.
            par            : par,
            strokes        : team.teamStrokes,
            currentScore   : team.teamScore,
            boxBorderColor : box,
            boxFillColor   : Colors.white,
            onScoreSelected: (v) => onSet(v == -1 ? null : v),
          ),
        ],
      ),
    );
  }
}

// ── Own ball: a row a golfer, the active one open ───────────────────────────

class _ShambleRows extends StatelessWidget {
  final TeamPlayCardTeam team;
  final int? selected;
  final ValueChanged<int> onSelect;
  final Future<void> Function(int playerId, int? gross) onSet;

  const _ShambleRows({
    required this.team, required this.selected,
    required this.onSelect, required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = team.shamble;
    if (h == null) return const SizedBox.shrink();
    final box = theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in h.rows)
          if (row.playerId == selected)
            Container(
              decoration: BoxDecoration(
                color: box.withValues(alpha: 0.10),
                border: Border(
                  top:    BorderSide(color: box, width: 1.5),
                  bottom: BorderSide(color: box, width: 1.5),
                  right:  BorderSide(color: box, width: 1.5),
                  left:   BorderSide(color: box, width: 4.0),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _GolferLine(row: row, onTap: null, active: true),
                  InlineScorePicker(
                    par            : h.par ?? 4,
                    strokes        : row.strokes,
                    currentScore   : row.gross,
                    boxBorderColor : box,
                    boxFillColor   : Colors.white,
                    onScoreSelected: (v) =>
                        onSet(row.playerId, v == -1 ? null : v),
                  ),
                ],
              ),
            )
          else
            _GolferLine(row: row, onTap: () => onSelect(row.playerId)),
      ],
    );
  }
}

/// One golfer's line: name, their strokes, their gross, and whether it counted.
///
/// The counting scores tint and the rest grey, live, as they are entered —
/// two golfers' cards do nothing on a given hole, and a golfer who shot 5 needs to
/// see instantly that their 5 was not used or the total looks wrong and someone
/// re-enters it.
class _GolferLine extends StatelessWidget {
  final TeamPlayShambleRow row;
  final bool active;
  final VoidCallback? onTap;
  const _GolferLine({
    required this.row, required this.onTap, this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final counts  = row.counts;
    final scored  = row.gross != null;
    final subdued = scored && !counts;

    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(
              color: theme.colorScheme.outlineVariant)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(
                  row.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontStyle: row.isPhantom
                        ? FontStyle.italic : FontStyle.normal,
                    color: subdued ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ),
              // No "gets N" chip. The dots on the grid below already say
              // where the strokes fall, which is the question anybody
              // standing on a tee is actually asking — the round total
              // restates it in a place nobody plays off.
              if (counts && scored) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle,
                     size: 15, color: theme.colorScheme.primary),
              ],
            ]),
          ),
          _ScoreBox(
            score     : row.gross,
            active    : active,
            strokeHere: row.strokes > 0,
            subdued   : subdued,
          ),
        ]),
      ),
    );
  }
}

/// The score box every card carries: the value, a PRIMARY border when this is
/// the row being entered, and a dot above it when the golfer (or the team) gets
/// a stroke on this hole. The dot is how the app says "stroke here" everywhere
/// else, so it says it here too.
class _ScoreBox extends StatelessWidget {
  final int?  score;
  final bool  active;
  final bool  strokeHere;
  final bool  subdued;

  const _ScoreBox({
    required this.score,
    required this.active,
    required this.strokeHere,
    this.subdued = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final box = Container(
      width: 46, height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active
              ? theme.colorScheme.primary
              : (subdued ? theme.colorScheme.outlineVariant
                         : theme.colorScheme.outline),
          width: active ? 2 : 1,
        ),
      ),
      child: Text(
        score?.toString() ?? '',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: subdued ? theme.colorScheme.onSurfaceVariant : null,
        ),
      ),
    );
    if (!strokeHere) return box;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 6, height: 6,
        margin: const EdgeInsets.only(bottom: 3),
        decoration: BoxDecoration(
          shape: BoxShape.circle, color: theme.colorScheme.primary),
      ),
      box,
    ]);
  }
}

/// The card so far, under the entry — the shared scorecard, so it reads as
/// the same object as the one inside a leaderboard row.
class _CardScorecard extends StatelessWidget {
  final TeamPlayCard card;
  final TeamPlayCardTeam team;
  final int hole;
  final ValueChanged<int?> onGo;
  /// Own-ball formats: whose strokes the dots mark. Null on a one-ball
  /// format, where the figure is the team's.
  final int? golferId;

  const _CardScorecard({
    required this.card, required this.team, required this.hole,
    required this.onGo, required this.golferId,
  });

  @override
  Widget build(BuildContext context) {
    if (card.pars.isEmpty) return const SizedBox.shrink();

    final scores = team.round.byHole;
    // The label on the score line. On a one-ball format the line IS the team,
    // and the header two rows up has already named it, so `Team` is the right
    // word for the grid's own column.
    final name = golferId == null
        ? 'Team'
        : (team.shamble?.rows
                .where((r) => r.playerId == golferId)
                .firstOrNull
                ?.name
                .split(' ')
                .last ??
            'Team');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        TeamScorecard(
          pars         : card.pars,
          strokeIndexes: card.strokeIndexes,
          currentHole  : hole,
          onTapHole    : (h) => onGo(h),
          rows         : [
            // One ball, so one line: what the team made, with its dots. TRUE
            // FOR ALL FOUR one-ball formats — an alternate shot, a Scotch and
            // a Chapman each play a single ball off a single team figure
            // exactly as a scramble does. Testing the format NAME here instead
            // sent the other three down the own-ball branch, where they
            // iterated a list the server correctly sends empty: no score line
            // and no dots, leaving the card with nothing on it but the net.
            if (card.isOneBall)
              TeamScorecardRow(
                label  : name,
                scores : scores,
                strokes: team.strokesFor(golferId),
              )
            // An own-ball format shows every ball — the same rows the board's
            // expanded team shows, counting balls tinted and the rest pale.
            // What it does NOT get is a team TOTAL line: that figure is the
            // sum of the counting balls, a "10" that is two 5s, and it is
            // arithmetic nobody performs.
            else
              for (final g in team.golfersByHole)
                TeamScorecardRow(
                  label  : g.shortName,
                  scores : g.scores,
                  strokes: g.strokes,
                  counted: g.counted,
                  italic : g.isPhantom,
                ),
            if (team.netToParByHole.isNotEmpty)
              TeamScorecardRow(
                label  : 'Net',
                scores : team.netToParByHole,
                total  : true,
                toPar  : true,
              ),
          ],
        ),
      ],
    );
  }
}

// ── Hole navigation ─────────────────────────────────────────────────────────

/// Prev / next in PLAY order, so a shotgun group walks its own round rather
/// than the course's numbering.
class _HoleNav extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  final ValueChanged<int?> onGo;
  /// What the hole is still waiting on; null when it is done.
  final String? outstanding;
  final VoidCallback onDone;

  const _HoleNav({
    required this.card, required this.hole, required this.onGo,
    required this.outstanding, required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final prev  = card.prevBefore(hole);
    final next  = card.nextAfter(hole);
    final ready = outstanding == null;

    // Going BACK is never gated — a half-finished hole you are walking away
    // from is a correction, not a mistake to trap someone in.
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: prev == null ? null : () => onGo(prev),
            icon: const Icon(Icons.chevron_left, size: 20),
            // Just "Hole" when there is nowhere back, matching every other
            // card — "First hole" reads like a destination you can tap.
            label: Text(prev == null ? 'Hole' : 'Hole $prev'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: ready ? 1 : 2,
          child: next == null
              // The last hole ends in Done, as the other cards do. It returns
              // to the hub rather than closing the round: this round belongs
              // to every team, and it is the TD who completes it once they are
              // all in — one team finishing its 18th is not the event ending.
              ? FilledButton.icon(
                  onPressed: ready ? onDone : null,
                  icon: const Icon(Icons.emoji_events, size: 20),
                  label: Text(ready ? 'Done' : outstanding!,
                      overflow: TextOverflow.ellipsis),
                )
              : FilledButton.icon(
                  onPressed: ready ? () => onGo(next) : null,
                  iconAlignment: IconAlignment.end,
                  icon: Icon(ready ? Icons.chevron_right : Icons.edit_outlined,
                             size: 20),
                  label: Text(ready ? 'Hole $next' : outstanding!,
                      overflow: TextOverflow.ellipsis),
                ),
        ),
      ]),
    );
  }
}
