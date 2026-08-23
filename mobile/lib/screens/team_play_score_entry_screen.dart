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
/// Two formats, and only the middle of the card differs:
///
///   * **Scramble** — four men make ONE number, so there is one row: TEAM.
///     Its picker is always open, because there is nothing to choose between.
///   * **Shamble** — four balls, so four rows. Tap one to aim the picker; the
///     counting scores tint and the rest grey as they land.
///
/// **The drive is its own question**, so it gets its own control above the
/// rows rather than being smuggled onto a golfer: a chip per man, the pips on
/// the chip, and the consequence stated beside it. It never blocks the tap —
/// the team may knowingly take the shortfall, and by default a shortfall costs
/// nothing.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/round_chat_button.dart';
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
  /// Shamble only: whose ball the picker is aimed at.
  int? _selected;
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

  Future<void> _setTeamScore(int? gross) async {
    await context.read<AuthProvider>().client
        .postTeamPlayScore(widget.foursomeId, hole: _hole!, gross: gross);
    await _load();
  }

  /// A shamble keeps per-golfer scores — four balls, best N net count — so
  /// these are ordinary HoleScores through the ordinary endpoint. Only the
  /// reading of them is Foursome Play's.
  Future<void> _setGolferScore(int playerId, int? gross) async {
    await context.read<AuthProvider>().client.submitScores(
      foursomeId: widget.foursomeId,
      holeNumber: _hole!,
      scores    : [{'player_id': playerId, 'gross_score': gross}],
    );
    await _load();
  }

  Future<void> _setDrive(int? playerId) async {
    await context.read<AuthProvider>().client
        .postTeamPlayDrive(widget.foursomeId, hole: _hole!, playerId: playerId);
    await _load();
  }

  void _goto(int? hole) {
    if (hole == null) return;
    setState(() { _hole = hole; _selected = null; });
    _load();
  }

  /// The golfer the picker is aimed at: the tap, else the first man still
  /// without a score, else the first row. Auto-advancing to whoever is missing
  /// is what makes four entries four taps.
  int? _activeGolfer(TeamPlayCard card) {
    final rows = card.shamble?.rows ?? const <TeamPlayShambleRow>[];
    if (rows.isEmpty) return null;
    if (_selected != null && rows.any((r) => r.playerId == _selected)) {
      return _selected;
    }
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
  String? _outstanding(TeamPlayCard card) {
    final needsScore = card.isScramble
        ? card.teamScore == null
        : !(card.shamble?.complete ?? false);

    // Only a quota needs a pick. An alternating rota already names the pair,
    // and "no requirement" has nothing to record.
    final needsDrive = card.drive.isQuota &&
        !card.drive.windows.any(
            (w) => w.golfers.any((g) => g.holes.contains(_hole)));

    if (needsScore && needsDrive) return 'Score and drive needed';
    if (needsScore) {
      return card.isScramble ? 'Enter the score' : 'Enter all four scores';
    }
    if (needsDrive) return 'Pick whose drive';
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
    if (card.isScramble) {
      // No "plays off N" here — the team row's `gets N` chip says it, in the
      // place every other card says it.
      return ('Scramble', 'All four hit, you play the best ball.');
    }
    final n = card.shamble?.count ?? 2;
    return (
      'Shamble',
      'Best drive, then everyone plays his own ball in. '
      'The ${n == 1 ? 'lowest net counts' : '$n lowest nets count'}; '
      'the rest are recorded and ignored.',
    );
  }

  Widget _body(TeamPlayCard card) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _HoleHeader(card: card, hole: _hole!),
        const SizedBox(height: 12),

        if (!card.drive.isOff) ...[
          _DriveStrip(card: card, hole: _hole!, onPick: _setDrive),
          const SizedBox(height: 12),
        ],

        IgnorePointer(
          // Nothing is tappable while a save is in flight — two taps on one
          // hole would race each other's reload.
          ignoring: _busy,
          child: card.isScramble
              ? _TeamScoreRow(
                  card    : card,
                  teamName: widget.teamName,
                  onSet   : _setTeamScore,
                )
              : _ShambleRows(
                  card    : card,
                  selected: _activeGolfer(card),
                  onSelect: (id) => setState(() => _selected = id),
                  onSet   : _setGolferScore,
                ),
        ),

        const SizedBox(height: 16),
        // The card so far, under the entry — the same place every other score
        // screen keeps its by-hole grid. It is the team's row either way: on a
        // shamble the counted balls are already summed into it, because that
        // is the number the board ranks.
        _CardScorecard(
          card    : card,
          hole    : _hole!,
          onGo    : _goto,
          golferId: card.isScramble ? null : _activeGolfer(card),
        ),

      ],
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
      if (card.shamble != null) '${card.shamble!.count} of 4 count',
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
/// the team, and hanging it off a man's row would say otherwise.
class _DriveStrip extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  final Future<void> Function(int?) onPick;

  const _DriveStrip({
    required this.card, required this.hole, required this.onPick,
  });

  TeamPlayDriveWindow? get _window {
    for (final w in card.drive.windows) {
      if (hole >= w.start && hole <= w.end) return w;
    }
    return card.drive.windows.isEmpty ? null : card.drive.windows.first;
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

    // A schedule needs one line on the tee, not a tracker.
    if (card.drive.isAlternating) {
      final rota = card.drive.rotaFor(hole);
      return _Panel(
        label: 'WHOSE TEE SHOT',
        child: Text(
          rota == null || rota.upLabel.isEmpty
              ? 'The team sets the pairs on the 1st tee.'
              : rota.upLabel +
                  (rota.phantomCoverName.isEmpty
                      ? ''
                      : '  ·  ${rota.phantomCoverName} → phantom'),
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
    }

    final w = _window;
    if (w == null) return const SizedBox.shrink();
    final driver = _driver;

    return _Panel(
      label   : 'WHOSE DRIVE',
      trailing: w.owed == 0
          ? Text('all square', style: theme.textTheme.labelSmall)
          : Text(
              '${w.owed} owed, ${w.holesLeft} left',
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
          if (w.owed > 0 && (w.tight || w.impossible)) ...[
            const SizedBox(height: 8),
            // The consequence in a sentence, on the tee — the moment a quota
            // becomes unsatisfiable is invisible to four men who have had a
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
  final String teamName;
  final Future<void> Function(int?) onSet;
  const _TeamScoreRow({
    required this.card, required this.teamName, required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final box   = theme.colorScheme.primary;
    final par   = card.par ?? 4;
    final label = teamName.isEmpty ? 'Team' : teamName;

    // Always open: four men make one number, so there is nothing to choose
    // between and no reason to make the TD tap a row first.
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              Expanded(
                child: Row(children: [
                  Text(label,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  // "gets N" is the ROUND's figure, as it is on every other
                  // card — how many strokes this team has all day. Which HOLES
                  // carry one is the dot's job.
                  if ((card.round.allowance ?? 0) > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('gets ${card.round.allowance}',
                          style: theme.textTheme.labelSmall),
                    ),
                  ],
                ]),
              ),
              _ScoreBox(
                score     : card.teamScore,
                active    : true,
                strokeHere: card.teamStrokes > 0,
              ),
            ]),
          ),
          InlineScorePicker(
            // The team's strokes ARE passed, so the strip anchors on net par
            // and the handicap dots appear on the holes the team gets one.
            // The packet argued for gross-only here to stop anyone subtracting
            // the figure per hole; seeing WHICH holes carry a stroke turned out
            // to matter more, and the dots are the app's existing way of
            // saying it.
            par            : par,
            strokes        : card.teamStrokes,
            currentScore   : card.teamScore,
            boxBorderColor : box,
            boxFillColor   : Colors.white,
            onScoreSelected: (v) => onSet(v == -1 ? null : v),
          ),
        ],
      ),
    );
  }
}

// ── Shamble: four rows, the active one open ─────────────────────────────────

class _ShambleRows extends StatelessWidget {
  final TeamPlayCard card;
  final int? selected;
  final ValueChanged<int> onSelect;
  final Future<void> Function(int playerId, int? gross) onSet;

  const _ShambleRows({
    required this.card, required this.selected,
    required this.onSelect, required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = card.shamble;
    if (h == null) return const SizedBox.shrink();
    final box = theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in h.rows)
          if (row.playerId == selected)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
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
                    par            : card.par ?? h.par ?? 4,
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

/// One golfer's line: name, his strokes, his gross, and whether it counted.
///
/// The counting scores tint and the rest grey, live, as they are entered —
/// two men's cards do nothing on a given hole, and a man who shot 5 needs to
/// see instantly that his 5 was not used or the total looks wrong and someone
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
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
              // "gets N" is his figure for the ROUND — course handicap at the
              // shamble's allowance — matching every other card. Which holes
              // carry a stroke is the dots' job, on the box and on the grid.
              if (row.handicap > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('gets ${row.handicap}',
                      style: theme.textTheme.labelSmall),
                ),
              ],
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
  final int hole;
  final ValueChanged<int?> onGo;
  /// Shamble: whose strokes the dots mark. Null on a scramble.
  final int? golferId;

  const _CardScorecard({
    required this.card, required this.hole,
    required this.onGo, required this.golferId,
  });

  /// `E` / `+3` / `-2` — the app's to-par label, the same one the board
  /// prints. The raw totals are on the OUT / IN cells, where a scorecard puts
  /// them.
  static String _toPar(int diff) =>
      diff == 0 ? 'E' : (diff > 0 ? '+$diff' : '$diff');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (card.pars.isEmpty) return const SizedBox.shrink();

    final scores = card.round.byHole;
    final name = golferId == null
        ? 'Team'
        : (card.shamble?.rows
                .where((r) => r.playerId == golferId)
                .firstOrNull
                ?.name
                .split(' ')
                .last ??
            'Team');

    // Par over the holes actually PLAYED — a part round against the full 72
    // would read as twenty under through six.
    final parSoFar = card.pars.keys
        .where((h) => scores[h] != null)
        .map((h) => card.pars[h] ?? 0)
        .fold<int>(0, (a, b) => a + b);
    final gross = scores.values.fold<int>(0, (a, b) => a + b);
    final net   = card.round.net;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text('Scorecard',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold))),
          if (card.round.thru > 0)
            Text(
              'thru ${card.round.thru} · Gross ${_toPar(gross - parSoFar)}'
              '${net == null ? '' : ' · Net ${_toPar(net - parSoFar)}'}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ]),
        const SizedBox(height: 6),
        TeamScorecard.single(
          pars         : card.pars,
          strokeIndexes: card.strokeIndexes,
          scores       : scores,
          strokes      : card.strokesFor(golferId),
          label        : name,
          currentHole  : hole,
          onTapHole    : (h) => onGo(h),
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
