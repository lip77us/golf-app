/// screens/enter_card_screen.dart
/// -----------------------------
/// Type a paper scorecard in.
///
/// Paul, 3 Nov 2026, of a 60-player event run in Golf Genius: *"some players
/// choose not to use halved. We have to allow the TD to enter scorecards at
/// the end of the round for those that are paper only… In the Ryder Cup,
/// there were a number of groups not using the app and it would have been
/// nice to enter the scores as they came in so the group on the course had an
/// accurate leaderboard."*
///
/// **He could already do it.** `foursome_for_scorer` gives him every foursome
/// in his own round and the hub has always drawn him an Enter Scores button on
/// each one. What he could not do is do it QUICKLY: the hole-by-hole flow is
/// eighteen screens per card, and eight paper groups is a hundred and
/// forty-four screen transitions.
///
/// So this is a WHOLE CARD on one screen — the shape of the piece of paper he
/// is reading. Nine holes down each column, a pad at the bottom, and one
/// request at the end.
///
/// **A partial card is the normal case**, not an error: transcribing for a
/// skins pool means entering the pool's golfers and leaving their partners
/// alone. The one thing it must not be is partial for a golfer who IS in the
/// pool — a skins hole counts only once every participant has a score, so a
/// pool member left half-entered removes those holes from the pool for
/// everybody, including the golfers who entered them themselves. The screen
/// says so, next to the golfers it applies to.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';

class EnterCardScreen extends StatefulWidget {
  final int foursomeId;
  const EnterCardScreen({super.key, required this.foursomeId});

  @override
  State<EnterCardScreen> createState() => _EnterCardScreenState();
}

class _EnterCardScreenState extends State<EnterCardScreen> {
  /// player id → hole → gross. Everything typed on this visit, across every
  /// golfer, so one Save covers the lot — the TD types a column, taps the
  /// next name, types that one, saves once.
  final Map<int, Map<int, int>> _typed = {};

  int? _playerId;
  int  _hole = 1;

  /// Armed by the `+10` key: the next digit makes 10 + d. Explicit rather
  /// than a timer, so nothing is ambiguous — a `2` is a 2 and `+10` then `2`
  /// is a 12.
  bool _tens = false;

  bool _saving = false;
  Object? _error;

  /// Pool members in this group, when the round is running a skins pool —
  /// the golfers whose cards have to go in COMPLETE.
  Set<int> _poolIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Foursome? get _fs {
    for (final f in context.read<RoundProvider>().round?.foursomes ??
        const <Foursome>[]) {
      if (f.id == widget.foursomeId) return f;
    }
    return null;
  }

  List<Membership> get _players =>
      [for (final m in _fs?.memberships ?? const <Membership>[])
        if (!m.player.isPhantom) m];

  Future<void> _load() async {
    final rp = context.read<RoundProvider>();
    final round = rp.round;
    if (round == null) return;
    setState(() => _playerId ??= _players.isEmpty ? null : _players.first.player.id);
    if (!round.activeGames.contains('multi_skins')) return;
    try {
      final s = await context
          .read<AuthProvider>()
          .client
          .getMultiSkinsSummary(round.id);
      if (!mounted) return;
      setState(() => _poolIds = s.players.map((p) => p.playerId).toSet());
    } catch (_) {/* best effort — the warning is a nicety, not a gate */}
  }

  // ── the card ───────────────────────────────────────────────────────────

  /// What is on the card for this golfer — typed this visit, else whatever
  /// the server already holds.
  int? _valueFor(int pid, int hole) {
    final t = _typed[pid]?[hole];
    if (t != null) return t;
    final hd = context.read<RoundProvider>().scorecard?.holeData(hole);
    if (hd == null) return null;
    for (final e in hd.scores) {
      if (e.playerId == pid) return e.grossScore;
    }
    return null;
  }

  /// The par the SELECTED golfer plays this hole at, which on mixed tees is
  /// not the card's shared par — a forward tee can play a long 4 as a 5.
  int? _parFor(int hole) {
    final hd = context.read<RoundProvider>().scorecard?.holeData(hole);
    if (hd == null) return null;
    final pid = _playerId;
    if (pid != null) {
      for (final e in hd.scores) {
        if (e.playerId == pid) return e.par;
      }
    }
    return hd.par;
  }

  int get _entered {
    var n = 0;
    for (final byHole in _typed.values) {
      n += byHole.length;
    }
    return n;
  }

  void _digit(int d) {
    final pid = _playerId;
    if (pid == null) return;
    final v = _tens ? 10 + d : d;
    if (v < 1 || v > 20) return;
    setState(() {
      _typed.putIfAbsent(pid, () => {})[_hole] = v;
      _tens = false;
      if (_hole < 18) _hole += 1;
    });
  }

  void _clear() {
    final pid = _playerId;
    if (pid == null) return;
    setState(() {
      // A typed value goes; a value the SERVER holds becomes an explicit
      // null, which the endpoint reads as "delete this row".
      _typed.putIfAbsent(pid, () => {}).remove(_hole);
      _tens = false;
    });
  }

  Future<void> _save() async {
    final rows = <Map<String, int?>>[];
    _typed.forEach((pid, byHole) {
      byHole.forEach((hole, gross) {
        rows.add({'player_id': pid, 'hole_number': hole, 'gross_score': gross});
      });
    });
    if (rows.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final rp = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;
      await client.postFoursomeCard(widget.foursomeId, rows);
      final roundId = rp.round?.id;
      if (roundId != null) await rp.loadRound(roundId);
      await rp.loadScorecard(widget.foursomeId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _saving = false;
        });
      }
    }
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final players = _players;
    if (players.isEmpty) {
      return const Scaffold(
        appBar: GolfAppBar(title: 'Enter a card'),
        body: Center(child: Text('This group has no golfers.')),
      );
    }
    final pid = _playerId ?? players.first.player.id;

    return Scaffold(
      appBar: const GolfAppBar(title: 'Enter a card'),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            children: [
              // Who. Chips rather than a dropdown: the group is four names
              // and the TD is switching between them constantly.
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in players)
                  _NameChip(
                    label: m.player.name,
                    inPool: _poolIds.contains(m.player.id),
                    filled: _countFor(m.player.id),
                    selected: m.player.id == pid,
                    onTap: () => setState(() {
                      _playerId = m.player.id;
                      _hole = _firstEmpty(m.player.id);
                      _tens = false;
                    }),
                  ),
              ]),
              if (_poolIds.isNotEmpty) ...[
                const SizedBox(height: 10),
                _PoolNote(
                  anyIncomplete: players.any((m) =>
                      _poolIds.contains(m.player.id) &&
                      _countFor(m.player.id) > 0 &&
                      _countFor(m.player.id) < 18),
                ),
              ],
              const SizedBox(height: 14),
              _CardGrid(
                holes: const [1, 2, 3, 4, 5, 6, 7, 8, 9],
                label: 'OUT',
                par: _parFor,
                value: (h) => _valueFor(pid, h),
                current: _hole,
                onTapHole: (h) => setState(() {
                  _hole = h;
                  _tens = false;
                }),
              ),
              const SizedBox(height: 10),
              _CardGrid(
                holes: const [10, 11, 12, 13, 14, 15, 16, 17, 18],
                label: 'IN',
                par: _parFor,
                value: (h) => _valueFor(pid, h),
                current: _hole,
                onTapHole: (h) => setState(() {
                  _hole = h;
                  _tens = false;
                }),
              ),
              const SizedBox(height: 10),
              _TotalRow(
                values: [for (var h = 1; h <= 18; h++) _valueFor(pid, h)],
              ),
              if (_error != null && !_saving) ...[
                const SizedBox(height: 14),
                ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _save,
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
        _Pad(
          hole: _hole,
          tens: _tens,
          onDigit: _digit,
          onTens: () => setState(() => _tens = !_tens),
          onClear: _clear,
          onSkip: () => setState(() {
            _tens = false;
            if (_hole < 18) _hole += 1;
          }),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    // The count is in the label, the way every confirm in
                    // this app carries its own numbers.
                    : Text(_entered == 0
                        ? 'Nothing to save'
                        : _entered == 1
                            ? 'Save 1 score'
                            : 'Save $_entered scores'),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  int _countFor(int pid) {
    var n = 0;
    for (var h = 1; h <= 18; h++) {
      if (_valueFor(pid, h) != null) n += 1;
    }
    return n;
  }

  /// The first hole this golfer has no score on — where a transcription
  /// naturally resumes.
  int _firstEmpty(int pid) {
    for (var h = 1; h <= 18; h++) {
      if (_valueFor(pid, h) == null) return h;
    }
    return 1;
  }
}

class _NameChip extends StatelessWidget {
  final String label;
  final bool inPool;
  final int filled;
  final bool selected;
  final VoidCallback onTap;

  const _NameChip({
    required this.label,
    required this.inPool,
    required this.filled,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
                width: selected ? 1.6 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (inPool) ...[
              Icon(Icons.attach_money, size: 14, color: cs.primary),
              const SizedBox(width: 2),
            ],
            Text(label,
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
            const SizedBox(width: 6),
            Text('$filled/18',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

/// The one thing a partial card must not be.
class _PoolNote extends StatelessWidget {
  final bool anyIncomplete;
  const _PoolNote({required this.anyIncomplete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final warn = anyIncomplete;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: warn ? Halved.cautionGround
                    : cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(warn ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 16, color: warn ? Halved.caution : cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            warn
                ? 'A golfer in the skins pool needs all 18 — a hole counts '
                    'only once every pool member has a score on it, so a '
                    'half-entered card takes those holes away from everybody.'
                : 'The golfers marked \$ are in the skins pool. Their cards have '
                'to go in complete: a hole counts only once every pool '
                'member has a score on it.',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
          ),
        ),
      ]),
    );
  }
}

class _CardGrid extends StatelessWidget {
  final List<int> holes;
  final String label;
  final int? Function(int) par;
  final int? Function(int) value;
  final int current;
  final void Function(int) onTapHole;

  const _CardGrid({
    required this.holes,
    required this.label,
    required this.par,
    required this.value,
    required this.current,
    required this.onTapHole,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final vals = [for (final h in holes) value(h)];
    final sub = vals.whereType<int>().fold<int>(0, (a, b) => a + b);
    final whole = !vals.contains(null);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text(label,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: cs.onSurfaceVariant)),
        const Spacer(),
        // An em dash until the nine is whole — the rule every card in this
        // app uses, so a partial subtotal never reads as a finished one.
        Text(whole ? '$sub' : '—',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 4),
      Row(children: [
        for (final h in holes)
          Expanded(
            child: _Cell(
              hole: h,
              par: par(h),
              value: value(h),
              selected: h == current,
              onTap: () => onTapHole(h),
            ),
          ),
      ]),
    ]);
  }
}

class _Cell extends StatelessWidget {
  final int hole;
  final int? par;
  final int? value;
  final bool selected;
  final VoidCallback onTap;

  const _Cell({
    required this.hole,
    required this.par,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(children: [
          Text('$hole',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
          Container(
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: selected
                  ? cs.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              border: Border.all(
                  color: selected ? cs.primary : cs.outlineVariant,
                  width: selected ? 1.8 : 1),
            ),
            child: Text(value?.toString() ?? '',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          if (par != null)
            Text('$par',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final List<int?> values;
  const _TotalRow({required this.values});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final whole = !values.contains(null);
    final tot = values.whereType<int>().fold<int>(0, (a, b) => a + b);
    return Row(children: [
      Text('TOTAL',
          style: theme.textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const Spacer(),
      Text(whole ? '$tot' : '—',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800)),
    ]);
  }
}

/// Ten digits, a `+10`, a clear and a skip.
///
/// **`+10` is explicit rather than a timer.** Digits 1–9 write and advance,
/// which is every score a transcriber meets; 10 and up are one extra tap
/// instead of an ambiguity about whether a `1` is a 1 or the start of a 12.
/// Skip leaves a hole blank and moves on, because a partial card is normal.
class _Pad extends StatelessWidget {
  final int hole;
  final bool tens;
  final void Function(int) onDigit;
  final VoidCallback onTens;
  final VoidCallback onClear;
  final VoidCallback onSkip;

  const _Pad({
    required this.hole,
    required this.tens,
    required this.onDigit,
    required this.onTens,
    required this.onClear,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget key(Widget child, VoidCallback onTap, {Color? fill}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Material(
              color: fill ?? cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTap,
                child: SizedBox(height: 46, child: Center(child: child)),
              ),
            ),
          ),
        );
    Widget digit(int d) => key(
          Text(tens ? '1$d' : '$d',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          () => onDigit(d),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13),
      child: Column(children: [
        Row(children: [
          Text('Hole $hole',
              style: theme.textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (tens)
            Text('next tap makes 1x',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: Halved.caution)),
        ]),
        const SizedBox(height: 2),
        Row(children: [for (var d = 1; d <= 5; d++) digit(d)]),
        Row(children: [for (var d = 6; d <= 9; d++) digit(d), digit(0)]),
        Row(children: [
          key(
            Text(tens ? '+10 on' : '+10',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: tens ? Colors.white : null)),
            onTens,
            fill: tens ? Halved.caution : null,
          ),
          key(const Icon(Icons.backspace_outlined, size: 18), onClear),
          key(
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Skip', style: theme.textTheme.labelLarge),
              const Icon(Icons.chevron_right, size: 18),
            ]),
            onSkip,
          ),
        ]),
      ]),
    );
  }
}
