/// screens/team_play_score_entry_screen.dart
/// -----------------------------------------
/// The two cards, one format apart
/// (docs/design-review/handoff-team-play/SPEC.md §10.1).
///
/// Everything else in the app enters **a score per golfer**. A scramble does
/// not have one: four men make one number, and pretending otherwise — four
/// boxes, three of them ignored — is the single easiest way to get a scramble
/// card wrong.
///
///   * **Scramble** — a stepper and one huge number. It is tapped by a man
///     standing on the next tee holding a beer, so the value is the largest
///     thing on the phone and it says what it IS (birdie, par, bogey) rather
///     than just the digit.
///   * **Shamble** — the four-man grid with the counting scores tinted live
///     and the rest greyed. A man who shot 5 needs to see instantly that his 5
///     was not used, or the total looks wrong and someone re-enters it.
///
/// The drive row sits on **both**. It warns on the tee, never at the scoring
/// table, and it never blocks the tap.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/error_view.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/team_play/team_play_bits.dart';

class TeamPlayScoreEntryScreen extends StatefulWidget {
  final int    foursomeId;
  final String teamName;
  final String colour;

  const TeamPlayScoreEntryScreen({
    super.key,
    required this.foursomeId,
    required this.teamName,
    required this.colour,
  });

  @override
  State<TeamPlayScoreEntryScreen> createState() =>
      _TeamPlayScoreEntryScreenState();
}

class _TeamPlayScoreEntryScreenState extends State<TeamPlayScoreEntryScreen> {
  int  _hole = 1;
  /// Shamble only: whose ball the picker is entering. Same idiom as every
  /// other four-man card in the app — tap a golfer, then tap his score.
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
      setState(() { _card = card; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setScore(int? gross) async {
    final client = context.read<AuthProvider>().client;
    await client.postTeamPlayScore(widget.foursomeId,
        hole: _hole, gross: gross);
    await _load();
  }

  /// One golfer's ball on this hole.
  ///
  /// A shamble keeps per-golfer scores — four balls, and the best N net count
  /// — so these are ordinary HoleScores through the ordinary endpoint. Only
  /// the reading of them is Foursome Play's.
  Future<void> _setGolferScore(int playerId, int? gross) async {
    final client = context.read<AuthProvider>().client;
    await client.submitScores(
      foursomeId: widget.foursomeId,
      holeNumber: _hole,
      scores    : [{'player_id': playerId, 'gross_score': gross}],
    );
    await _load();
  }

  Future<void> _setDrive(int? playerId) async {
    final client = context.read<AuthProvider>().client;
    await client.postTeamPlayDrive(widget.foursomeId,
        hole: _hole, playerId: playerId);
    await _load();
  }

  void _goto(int hole) {
    if (hole < 1 || hole > 18) return;
    setState(() { _hole = hole; _selected = null; });
    _load();
  }

  /// The golfer the picker is aimed at: the TD's pick, else the first man
  /// still without a score, else the first row. Auto-advancing to whoever is
  /// missing is what makes four entries four taps.
  int? _activeGolfer(TeamPlayCard card) {
    final rows = card.shamble?.rows ?? const <TeamPlayShambleRow>[];
    if (rows.isEmpty) return null;
    if (_selected != null &&
        rows.any((r) => r.playerId == _selected)) {
      return _selected;
    }
    for (final r in rows) {
      if (r.gross == null) return r.playerId;
    }
    return rows.first.playerId;
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        title: Row(
          children: [
            TeamColourBlock(colour: widget.colour, size: 10),
            const SizedBox(width: 8),
            Text(widget.teamName, style: Halved.appBarTitle()),
          ],
        ),
        actions: [
          if (card != null)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Text(_formatChip(card), style: Halved.label()),
              ),
            ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: '$_error', onRetry: _load)
          : card == null
              ? const Center(child: CircularProgressIndicator())
              : _body(card),
    );
  }

  /// `Scramble · 6` / `Shamble · 85%` — the allowance is named in the header
  /// so it is not hidden, even though it never appears on the card itself.
  String _formatChip(TeamPlayCard card) {
    if (card.isScramble) {
      final a = card.round.allowance;
      return a == null ? 'Scramble' : 'Scramble · $a';
    }
    return 'Shamble';
  }

  Widget _body(TeamPlayCard card) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      children: [
        _HoleHeader(hole: _hole, card: card, onGo: _goto),
        const SizedBox(height: 14),

        // A shamble picks a tee shot exactly as a scramble does, so the row is
        // identical — the only difference is where it sits: above the four
        // scores rather than below the one.
        if (!card.isScramble && !card.drive.isOff) ...[
          _DriveRow(card: card, hole: _hole, onPick: _setDrive),
          const SizedBox(height: 14),
        ],

        if (card.isScramble)
          _ScrambleRows(card: card, hole: _hole, onDrive: _setDrive)
        else
          _ShambleCard(
            hole    : card.shamble,
            selected: _activeGolfer(card),
            onSelect: (id) => setState(() => _selected = id),
          ),

        const SizedBox(height: 14),
        // The same picker every other game renders — score entry, Nassau,
        // Skins, Wolf, Rabbit, Points 5-3-1, Quota Nassau. A golfer who enters
        // a score anywhere in the app already knows how this works, and a
        // bespoke stepper here would have been a fourth thing to learn.
        IgnorePointer(
          // Nothing is tappable while a save is in flight — two taps on the
          // same hole would race each other's reload.
          ignoring: _busy,
          child: _Picker(
          card    : card,
          par     : _parFor(card),
          selected: card.isScramble ? null : _activeGolfer(card),
          onTeam  : _setScore,
          onGolfer: _setGolferScore,
          ),
        ),

        const SizedBox(height: 16),
        _Strip(card: card, hole: _hole, onGo: _goto),

        const SizedBox(height: 16),
        _Footer(card: card, hole: _hole, onNext: () => _goto(_hole + 1)),
      ],
    );
  }

  int _parFor(TeamPlayCard card) => card.shamble?.par ?? 4;
}

// ── Header ──────────────────────────────────────────────────────────────────

class _HoleHeader extends StatelessWidget {
  final int hole;
  final TeamPlayCard card;
  final ValueChanged<int> onGo;

  const _HoleHeader({required this.hole, required this.card, required this.onGo});

  @override
  Widget build(BuildContext context) {
    final s = card.shamble;
    return Row(
      children: [
        IconButton(
          onPressed: hole > 1 ? () => onGo(hole - 1) : null,
          icon: const Icon(Icons.chevron_left),
          color: Halved.pine,
        ),
        Expanded(
          child: Column(
            children: [
              Text('$hole', style: Halved.emptyTitle().copyWith(fontSize: 34)),
              Text(
                s?.par == null
                    ? 'Hole $hole'
                    : 'Par ${s!.par} · Stroke index ${s.strokeIndex}',
                style: Halved.body(color: Halved.muted),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: hole < 18 ? () => onGo(hole + 1) : null,
          icon: const Icon(Icons.chevron_right),
          color: Halved.pine,
        ),
      ],
    );
  }
}

/// The app's standard picker, aimed at whatever this format scores.
///
/// A scramble enters ONE number for the team, so it anchors on gross par and
/// passes no strokes — the allowance is a whole-number team figure taken off
/// the round total, not a stroke on a hole, and feeding it in here would centre
/// the strip on a net par the team never plays to.
///
/// A shamble enters four, so it anchors on the selected golfer's own strokes,
/// exactly as the standard card does.
class _Picker extends StatelessWidget {
  final TeamPlayCard card;
  final int  par;
  final int? selected;
  final Future<void> Function(int?) onTeam;
  final Future<void> Function(int, int?) onGolfer;

  const _Picker({
    required this.card, required this.par, required this.selected,
    required this.onTeam, required this.onGolfer,
  });

  @override
  Widget build(BuildContext context) {
    if (card.isScramble) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('TEAM SCORE', style: Halved.label()),
          const SizedBox(height: 6),
          InlineScorePicker(
            par         : par,
            strokes     : 0,
            currentScore: card.teamScore,
            onScoreSelected: (v) => onTeam(v == -1 ? null : v),
          ),
        ],
      );
    }

    final rows = card.shamble?.rows ?? const <TeamPlayShambleRow>[];
    final row  = rows.where((r) => r.playerId == selected).firstOrNull;
    if (row == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(row.name.toUpperCase(), style: Halved.label()),
        const SizedBox(height: 6),
        InlineScorePicker(
          par         : par,
          strokes     : row.strokes,
          currentScore: row.gross,
          onScoreSelected: (v) => onGolfer(row.playerId, v == -1 ? null : v),
        ),
      ],
    );
  }
}

// ── Scramble: the group card, with the driver's row live ────────────────────

/// Four men, one number.
///
/// Shaped after the Cup's alternate-shot card, which draws the ordinary group
/// card and dims the partner whose turn it isn't. Here the live row is
/// **whoever's drive the team took**: tap his radio, then put the team's
/// number on his row. One gesture covers the drive and the score, which is
/// the pair the hole was never complete without.
///
/// The score belongs to the TEAM, not to the man whose row it sits on — the
/// footer says so, and nothing per-golfer is stored.
///
/// When there is no drive to pick — no requirement, or an alternating rota
/// that already names the pair — the radios would be a question with one
/// answer, so the card falls back to a single TEAM row.
class _ScrambleRows extends StatelessWidget {
  final TeamPlayCard card;
  final int  hole;
  final Future<void> Function(int?) onDrive;

  const _ScrambleRows({
    required this.card, required this.hole, required this.onDrive,
  });

  bool get _picksDriver => card.drive.isQuota;

  TeamPlayDriveWindow? get _window {
    for (final w in card.drive.windows) {
      if (hole >= w.start && hole <= w.end) return w;
    }
    return card.drive.windows.isEmpty ? null : card.drive.windows.first;
  }

  int? get _driverId {
    for (final g in _window?.golfers ?? const <TeamPlayDriveGolfer>[]) {
      if (g.holes.contains(hole)) return g.playerId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final window = _window;
    final driver = _driverId;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(Halved.rCard),
        border: Border.all(
          color: (window?.tight ?? false) || (window?.impossible ?? false)
              ? Halved.warning : Halved.cardBorder,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_picksDriver ? 'Whose drive' : 'Team score',
                    style: Halved.body(weight: FontWeight.w700)),
              ),
              if (_picksDriver && window != null)
                Text('${window.perGolfer} each per '
                     '${window.end <= 9 || window.start >= 10 ? 'nine' : 'round'}',
                     style: Halved.label()),
            ],
          ),
          const SizedBox(height: 10),

          if (_picksDriver && window != null)
            for (final g in window.golfers)
              _GolferRow(
                golfer   : g,
                live     : g.playerId == driver,
                anyDriver: driver != null,
                onPick   : () => onDrive(
                    g.playerId == driver ? null : g.playerId),
              )
          else if (card.drive.isAlternating)
            // An alternating rota names the pair rather than asking.
            TeamNote(card.drive.rotaFor(hole)?.upLabel ??
                'The team sets the pairs on the 1st tee.'),

          if (_picksDriver && driver == null) ...[
            const SizedBox(height: 8),
            const TeamNote('Pick whose drive you took, then put the team\'s '
                           'number on his row.'),
          ],

          if (window != null && window.owed > 0) ...[
            const SizedBox(height: 10),
            // The consequence in a sentence, on the tee — the moment a quota
            // becomes unsatisfiable is invisible to four men who have had a
            // few. It never blocks the tap.
            TeamNote(
              window.impossible
                  ? '${window.owed} owed and only ${window.holesLeft} '
                    '${window.holesLeft == 1 ? 'hole' : 'holes'} left — '
                    '${window.label.toLowerCase()} cannot be satisfied. '
                    'Play on; a shortfall is recorded, not blocked.'
                  : window.tight
                      ? '${window.owed} owed, ${window.holesLeft} holes left. '
                        'It still works — but only if every remaining hole '
                        'goes to a man who owes one.'
                      : '${window.owed} still owed on the '
                        '${window.label.toLowerCase()}.',
              warn: window.tight || window.impossible,
            ),
          ],
        ],
      ),
    );
  }
}

/// One man's row: his drive radio, his pips, and — when the team took his
/// drive — the team's number.
class _GolferRow extends StatelessWidget {
  final TeamPlayDriveGolfer golfer;
  final bool live;
  final bool anyDriver;
  final VoidCallback onPick;

  const _GolferRow({
    required this.golfer, required this.live,
    required this.anyDriver, required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final body = Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: live ? Halved.brightMint.withValues(alpha: 0.16) : Halved.surface,
        borderRadius: BorderRadius.circular(Halved.rChip),
        border: Border.all(
          color: live ? Halved.mint : Halved.cardBorder,
          width: live ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: onPick,
            borderRadius: BorderRadius.circular(Halved.rPill),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                live ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 22,
                color: live ? Halved.pine : Halved.cardBorder,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(golfer.name,
                    style: Halved.body(weight: FontWeight.w600)),
                Text(golfer.pipLabel,
                    style: Halved.label(
                        color: golfer.owes > 0 ? Halved.warning : Halved.pine)),
              ],
            ),
          ),
          if (live)
            Text('drive taken', style: Halved.label(color: Halved.pine)),
        ],
      ),
    );

    // Rows that are not the driver's are de-emphasised rather than hidden —
    // the team still needs to see who has driven and who owes.
    return anyDriver && !live ? Opacity(opacity: 0.55, child: body) : body;
  }
}

// ── Shamble: four scores, and the card says which counted ───────────────────

class _ShambleCard extends StatelessWidget {
  final TeamPlayShambleHole? hole;
  /// Whose ball the picker below is entering.
  final int? selected;
  final ValueChanged<int> onSelect;

  const _ShambleCard({
    required this.hole, required this.selected, required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final h = hole;
    if (h == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(Halved.rCard),
        border: Border.all(color: Halved.cardBorder, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Scores',
                  style: Halved.body(weight: FontWeight.w700))),
              // Stated on EVERY hole. It usually does not change, and saying so
              // costs one line and settles the recurring question at the green.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Halved.pine.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(Halved.rPill),
                ),
                child: Text(h.countLabel,
                    style: Halved.label(color: Halved.pine)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('The ${h.count == 1 ? 'lowest net counts' : 'lowest nets count'}. '
               'The rest are recorded and ignored.',
               style: Halved.body(color: Halved.muted).copyWith(fontSize: 13)),
          const Divider(height: 18),
          Row(
            children: [
              const Expanded(child: SizedBox()),
              SizedBox(width: 46,
                  child: Text('GROSS', textAlign: TextAlign.right,
                      style: Halved.label())),
              SizedBox(width: 42,
                  child: Text('NET', textAlign: TextAlign.right,
                      style: Halved.label())),
            ],
          ),
          const SizedBox(height: 4),
          for (final row in h.rows)
            _ShambleRow(
              row     : row,
              selected: row.playerId == selected,
              onTap   : () => onSelect(row.playerId),
            ),
          const Divider(height: 18),
          Row(
            children: [
              Expanded(
                child: Text('Hole total',
                    style: Halved.body(weight: FontWeight.w700)),
              ),
              Text(
                h.teamNet == null
                    ? 'Waiting on ${h.rows.where((r) => r.gross == null).length}'
                    : '${h.teamNet}',
                style: Halved.body(weight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShambleRow extends StatelessWidget {
  final TeamPlayShambleRow row;
  final bool selected;
  final VoidCallback onTap;

  const _ShambleRow({
    required this.row, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Tinted when it counts, greyed when it does not — live, as they are
    // entered. Two men's cards do nothing on a given hole.
    final counts = row.counts;
    final fg = counts ? Halved.deepPine : Halved.disabledText;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Halved.rChip),
      child: Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: counts ? Halved.mint.withValues(alpha: 0.10) : null,
        borderRadius: BorderRadius.circular(Halved.rChip),
        // The row the picker is aimed at, same as the standard card marks its
        // active player.
        border: Border.all(
          color: selected ? Halved.pine : Colors.transparent,
          width: selected ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.name,
              style: Halved.body(weight: FontWeight.w600, color: fg).copyWith(
                fontStyle: row.isPhantom ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
          // The phantom's ball IS played — by whoever is not driving — so its
          // row shows a score like any other.
          SizedBox(width: 46,
              child: Text('${row.gross ?? '—'}', textAlign: TextAlign.right,
                  style: Halved.body(color: fg))),
          SizedBox(width: 42,
              child: Text('${row.net ?? '—'}', textAlign: TextAlign.right,
                  style: Halved.body(weight: FontWeight.w700, color: fg))),
        ],
      ),
      ),
    );
  }
}

// ── The drive row ───────────────────────────────────────────────────────────

class _DriveRow extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  final Future<void> Function(int?) onPick;

  const _DriveRow({required this.card, required this.hole, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final drive = card.drive;

    // A schedule needs one line on the tee, not a tracker.
    if (drive.isAlternating) {
      final rota = drive.rotaFor(hole);
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Halved.card,
          borderRadius: BorderRadius.circular(Halved.rCard),
          border: Border.all(color: Halved.cardBorder, width: 1.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('WHOSE TEE SHOT IS IN PLAY', style: Halved.label()),
                  const SizedBox(height: 3),
                  Text(
                    rota == null || rota.upLabel.isEmpty
                        ? 'The team sets the pairs on the 1st tee.'
                        : rota.upLabel,
                    style: Halved.body(
                        color: Halved.deepPine, weight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            if (rota != null && rota.phantomCover != null)
              Text('${rota.phantomCoverName} → phantom',
                   style: Halved.label()),
          ],
        ),
      );
    }

    if (!drive.isQuota) return const SizedBox.shrink();

    final window = drive.windows.firstWhere(
      (w) => hole >= w.start && hole <= w.end,
      orElse: () => drive.windows.isEmpty
          ? const TeamPlayDriveWindow(
              start: 1, end: 18, started: false, required: 0, perGolfer: 0,
              owed: 0, holesLeft: 0, tight: false, impossible: false,
              golfers: [])
          : drive.windows.first,
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(Halved.rCard),
        border: Border.all(
          color: window.tight || window.impossible
              ? Halved.warning : Halved.cardBorder,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Whose drive',
                  style: Halved.body(weight: FontWeight.w700))),
              Text(
                '${window.perGolfer} each per '
                '${window.end <= 9 || window.start >= 10 ? 'nine' : 'round'}',
                style: Halved.label(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final g in window.golfers)
            _DrivePip(golfer: g, hole: hole, onPick: onPick),

          if (window.owed > 0) ...[
            const SizedBox(height: 10),
            // The consequence in a sentence, on the tee — because the moment a
            // quota becomes unsatisfiable is invisible to four men who have
            // had a few. It never blocks the tap.
            TeamNote(
              window.impossible
                  ? '${window.owed} owed and only ${window.holesLeft} '
                    '${window.holesLeft == 1 ? 'hole' : 'holes'} left — '
                    '${window.label.toLowerCase()} cannot be satisfied. '
                    'Play on; a shortfall is recorded, not blocked.'
                  : window.tight
                      ? '${window.owed} owed, ${window.holesLeft} holes left. '
                        'It still works — but only if every remaining hole '
                        'goes to a man who owes one.'
                      : '${window.owed} still owed on the '
                        '${window.label.toLowerCase()}.',
              warn: window.tight || window.impossible,
            ),
          ],
        ],
      ),
    );
  }
}

class _DrivePip extends StatelessWidget {
  final TeamPlayDriveGolfer golfer;
  final int hole;
  final Future<void> Function(int?) onPick;

  const _DrivePip({
    required this.golfer, required this.hole, required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final tookThisHole = golfer.holes.contains(hole);
    return InkWell(
      onTap: () => onPick(tookThisHole ? null : golfer.playerId),
      borderRadius: BorderRadius.circular(Halved.rChip),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: tookThisHole
              ? Halved.brightMint.withValues(alpha: 0.20) : Halved.surface,
          borderRadius: BorderRadius.circular(Halved.rChip),
          border: Border.all(
            color: tookThisHole ? Halved.mint : Halved.cardBorder,
            width: tookThisHole ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(golfer.name,
                  style: Halved.body(weight: FontWeight.w600)),
            ),
            Text(
              golfer.pipLabel,
              style: Halved.label(
                  color: golfer.owes > 0 ? Halved.warning : Halved.pine),
            ),
          ],
        ),
      ),
    );
  }
}

// ── The strip and the footer ────────────────────────────────────────────────

/// The eighteen holes across the bottom, filled ones solid — position in the
/// round without leaving the card.
class _Strip extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  final ValueChanged<int> onGo;

  const _Strip({required this.card, required this.hole, required this.onGo});

  @override
  Widget build(BuildContext context) {
    final thru = card.round.thru;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 18,
        itemBuilder: (_, i) {
          final n       = i + 1;
          final current = n == hole;
          final filled  = n <= thru;
          return GestureDetector(
            onTap: () => onGo(n),
            child: Container(
              width: 38,
              margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              decoration: BoxDecoration(
                color: current
                    ? Halved.pine
                    : (filled ? Halved.mint.withValues(alpha: 0.18)
                              : Halved.card),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Halved.cardBorder),
              ),
              child: Center(
                child: Text('$n',
                    style: Halved.body(weight: FontWeight.w600).copyWith(
                        color: current ? Halved.cream : Halved.deepPine,
                        fontSize: 13)),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final TeamPlayCard card;
  final int hole;
  final VoidCallback onNext;

  const _Footer({required this.card, required this.hole, required this.onNext});

  /// **Auto-advance waits for BOTH** the score and the drive — the hole is not
  /// complete until the drive is picked, and the button names what is
  /// outstanding rather than going grey and silent.
  ({bool ready, String label}) get _state {
    final needsDrive = card.drive.isQuota &&
        !card.drive.windows.any((w) =>
            w.golfers.any((g) => g.holes.contains(hole)));
    final hasScore = card.isScramble
        ? card.teamScore != null
        : (card.shamble?.teamNet != null);

    if (!hasScore && needsDrive) {
      return (ready: false, label: 'Enter the score and pick whose drive');
    }
    if (!hasScore) return (ready: false, label: 'Enter the score to continue');
    if (needsDrive) {
      return (ready: false, label: 'Pick whose drive to continue');
    }
    return (ready: true, label: 'Save & next hole');
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final round = card.round;
    return Column(
      children: [
        HalvedCtaButton(
          label: state.label,
          icon : state.ready ? Icons.arrow_forward : null,
          trailingIcon: true,
          onPressed: state.ready && hole < 18 ? onNext : null,
        ),
        const SizedBox(height: 10),
        // Gross on the card, net on the leaderboard. A whole-number team
        // figure applied to the round is not a stroke on a hole, and showing
        // it here would invite subtracting it per hole.
        Text(
          card.isScramble && round.allowance != null
              ? 'Gross on the card. Your ${round.allowance} strokes come off '
                'the total on the leaderboard.'
              : 'Gross on the card, net on the leaderboard.',
          textAlign: TextAlign.center,
          style: Halved.body(color: Halved.muted).copyWith(fontSize: 13),
        ),
      ],
    );
  }
}
