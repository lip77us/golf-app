/// widgets/forty_balls_picker.dart
/// ------------------------------
/// The 40 Balls picker — one card under the player rows in tournament score
/// entry.
///
/// **The card is drawn from the moment the hole opens**, counts and all, dim
/// until every net is in. It used to hide them behind `Waiting on the last
/// score`, which testing read as a failure rather than as the ordinary state
/// of a hole nobody has played yet: the picker is part of the hole, so it
/// stands there waiting like the score boxes above it.
///
/// There is no default. The buttons light when the last net lands, and the
/// pager names the pick only from that moment — before it, what is missing is
/// scores, and the pager says so.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import 'error_view.dart';
import '../theme/halved_brand.dart';

/// Every golfer on the hole has a net — locally or on the server.
///
/// **Two readers, one rule.** The picker lights its buttons on it and the
/// score-entry pager decides on it whether what is missing is a pick or a
/// score; written twice they would eventually disagree, and the pager would
/// name a pick the card was not offering.
bool fortyBallsReady(FortyBallsPickerState state, Map<int, int> localNets) {
  final nets = localNets.isNotEmpty ? localNets : state.nets;
  return state.activeHere > 0 && nets.length >= state.activeHere;
}

class FortyBallsPicker extends StatelessWidget {
  final FortyBallsPickerState state;
  /// Names by player id, for lighting the counted rows' owners.
  final Map<int, String> names;
  final ValueChanged<int> onPick;
  final bool busy;

  /// The hole's nets as ENTERED, including scores not yet posted. This is what
  /// lets the group pick while it is still filling the hole in — the server's
  /// own `nets` only ever holds what has landed. Empty falls back to those.
  final Map<int, int> localNets;

  /// The count the group has chosen but not yet sent, because the hole has
  /// not been posted. Overrides the server's.
  final int? pendingCount;

  /// Back to the scores for this hole. Null hides the link — the tray can be
  /// drawn without owning the way back when the screen keeps its own.
  final VoidCallback? onEditScores;

  /// Hole navigation, when the tray owns it. Both null leaves the action row
  /// off entirely, so the tray stays usable inside a screen that already has
  /// its own pager rather than growing a second one.
  final VoidCallback? onBack;
  final VoidCallback? onNext;

  const FortyBallsPicker({
    super.key,
    required this.state,
    required this.names,
    required this.onPick,
    this.busy = false,
    this.localNets = const {},
    this.pendingCount,
    this.onEditScores,
    this.onBack,
    this.onNext,
  });

  Map<int, int> get _nets =>
      localNets.isNotEmpty ? localNets : state.nets;

  int? get _count => pendingCount ?? state.count;

  bool get _ready => fortyBallsReady(state, localNets);

  // ---- the two figures ----------------------------------------------------
  //
  // **One position, and the pick decides which.** Nothing picked yet means the
  // hole has not happened: the balls and the holes both still include it, so
  // standing on the 1st a foursome reads `2.2 a hole, 18 to play`. It used to
  // read 17, because the server's figure counted the holes AFTER this one
  // while the slack beside it counted this one — two tiles describing two
  // different moments. Pick a count and both step forward together.

  int get _ballsLeft => _count == null ? state.left : state.left - _count!;

  int get _holesLeft =>
      _count == null ? state.holesAfter + 1 : state.holesAfter;

  /// The capacity the holes left can absorb. `state.capacity` counts this
  /// hole; once its count is picked, that share is gone.
  int get _capacityLeft => _count == null
      ? state.capacity
      : state.capacity - state.activeHere;

  int get _slack => (_capacityLeft - _ballsLeft).clamp(0, 1 << 30);

  /// `2.2 a hole` — balls left ÷ holes left. Null when there is nothing left
  /// to spread, either because the budget is gone or the round is.
  /// Balls committed so far, this hole's pending pick included — the other
  /// half of the pace question the average answers.
  ///
  /// **Rendered against the budget (`3/40`), and the denominator is what
  /// makes it readable at all.** A bare `3` sits inches from a picker
  /// offering 0–4 for THIS hole, so on the early holes it reads as three
  /// balls here rather than three of forty so far — the two are the same
  /// small number exactly when the round is young. The denominator is the
  /// only thing on the tile saying the figure is a running total.
  ///
  /// Never the literal 40: `state.budget` is 10 a golfer by STARTING size,
  /// so a threesome reads `3/30`.
  int get _chosen => state.budget - _ballsLeft;

  /// `E`, `-3`, `+2`. Level is a word everywhere else in the app and should
  /// be one here.
  static String _netLabel(int net) =>
      net == 0 ? 'E' : (net > 0 ? '+$net' : '$net');

  double? get _average =>
      (_ballsLeft == 0 || _holesLeft <= 0) ? null : _ballsLeft / _holesLeft;

  /// The nets that would count at [n] — the best ones, which is what the
  /// picker lights up as the scorer moves across the buttons.
  List<int> countedAt(int n) {
    final sorted = _nets.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return sorted.take(n).map((e) => e.key).toList();
  }

  /// `−2` for the hole, at the count currently picked.
  int? get result {
    final n = _count;
    if (n == null || state.par == null) return null;
    final sorted = _nets.values.toList()..sort();
    return sorted.take(n).fold<int>(0, (a, b) => a + b) - n * state.par!;
  }

  @override
  Widget build(BuildContext context) {
    if (state.dq) {
      return _tray(child: const _TrayNote(
        icon: Icons.block,
        title: 'Out of 40 Balls',
        body: 'The budget cannot come out. Scores still count for the '
              'championship.',
      ));
    }
    if (state.locked) {
      return _tray(child: _TrayNote(
        icon: Icons.lock_outline,
        title: 'Settled',
        body: "The group has moved on, so this hole's count is fixed"
              '${state.count == null ? '' : ' at ${state.count}'}.',
      ));
    }

    return _tray(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(),
        const SizedBox(height: 14),
        _rack(),
        const SizedBox(height: 16),
        _countRow(),
        const SizedBox(height: 10),
        _hint(),
        const SizedBox(height: 14),
        _figures(),
        if (state.lo == state.hi) ...[
          const SizedBox(height: 12),
          _TrayLockNote(
            text: state.left == 0
                ? 'Budget spent. Every remaining hole counts 0, and the app '
                  'has filled them in.'
                : 'No slack left. Every remaining hole counts '
                  '${state.hi}, and the app has filled them in.',
          ),
        ],
        if (onEditScores != null || onNext != null) ...[
          const SizedBox(height: 16),
          _actions(),
        ],
      ],
    ));
  }

  /// `All 4 scores in` + `Edit scores`.
  ///
  /// The tray only rises once every score is in, so the header states the
  /// thing that let it rise — and offers the way back, because the commonest
  /// reason to look at a finished hole is that one of the numbers is wrong.
  Widget _header() => Row(children: [
        Expanded(
          child: Text(
            state.scoresIn
                ? 'All ${state.activeHere} scores in'
                : 'Scores still coming in',
            style: const TextStyle(
                color: Halved.cream, fontWeight: FontWeight.w700),
          ),
        ),
        if (onEditScores != null)
          GestureDetector(
            onTap: onEditScores,
            child: const Text('Edit scores',
                style: TextStyle(
                    color: Halved.brightMint, fontWeight: FontWeight.w700)),
          ),
      ]);

  /// One dot per ball in the budget, filled as they are counted.
  ///
  /// **The rack is the only place the budget is a QUANTITY rather than a
  /// number.** `19 of 40` is arithmetic a group has to do something with;
  /// two rows of dots with a fifth of the second row left is a glance. The
  /// rows split the budget in half, so a threesome draws 15 and 15 rather
  /// than a ragged 20 and 10.
  Widget _rack() {
    final chosen = _chosen.clamp(0, state.budget);
    final perRow = (state.budget / 2).ceil();
    Widget dot(int i) => Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < chosen ? Halved.cream : Colors.transparent,
            border: Border.all(
                color: i < chosen ? Halved.cream : Halved.muted, width: 1.2),
          ),
        );
    Widget row(int from, int to) => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(children: [
            for (var i = from; i < to; i++) ...[
              if (i > from) const Spacer(),
              dot(i),
            ],
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('BALL BUDGET',
            style: TextStyle(
                color: Halved.muted, fontSize: 11,
                fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        const Spacer(),
        Text('$chosen of ${state.budget} counted',
            style: const TextStyle(
                color: Halved.cream, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 10),
      row(0, perRow),
      row(perRow, state.budget),
      const SizedBox(height: 4),
      Row(children: [
        _tally('$chosen', 'counted'),
        const Spacer(),
        _tally('${_ballsLeft.clamp(0, state.budget)}', 'left'),
      ]),
    ]);
  }

  Widget _tally(String value, String label) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(value,
              style: const TextStyle(
                  color: Halved.cream, fontSize: 17,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(color: Halved.muted, fontSize: 12)),
        ],
      );

  Widget _countRow() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('HOW MANY COUNT ON ${state.hole}?',
                style: const TextStyle(
                    color: Halved.muted, fontSize: 11,
                    fontWeight: FontWeight.w700, letterSpacing: 0.8)),
            const Spacer(),
            const Text('BEST NETS',
                style: TextStyle(
                    color: Halved.muted, fontSize: 11,
                    fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            for (var n = 0; n <= state.groupSize; n++) ...[
              if (n > 0) const SizedBox(width: 6),
              Expanded(child: _TrayCount(
                // Keyed so a test can reach one count without matching the
                // bare numerals the rack's tally also renders.
                key: ValueKey('fb-count-$n'),
                n: n,
                selected: _count == n,
                // Outside `lo..hi` the budget would not come out, so the
                // button is dead rather than a pick that gets refused.
                enabled: !busy && _ready && state.canPick &&
                         n >= state.lo && n <= state.hi,
                onTap: () => onPick(n),
              )),
            ],
          ]),
        ],
      );

  Widget _hint() => Text(
        _count == null
            ? 'Tap a count. The best nets light up.'
            : (result == null
                ? 'Tap a count. The best nets light up.'
                : 'Hole plays ${_netLabel(result!)}.'),
        style: const TextStyle(color: Halved.muted, fontSize: 12),
      );

  /// The two figures.
  ///
  /// **Pace and slack, and the NET is deliberately not here** — the packet
  /// moves it to the hole header, where it reads once for the whole screen
  /// instead of competing with the pace figure beside it. That was a real
  /// decision of Paul's (16 Oct: Status replaced Slack precisely so the
  /// number a group is ranked on came first), so the header badge is part of
  /// this change rather than a separate nicety: drop it from here without
  /// adding it there and the figure is simply gone.
  Widget _figures() => Row(children: [
        Expanded(child: _TrayFigure(
          value: _average == null ? '–' : _average!.toStringAsFixed(1),
          label: 'a hole to reach ${state.budget}',
          muted: _count == null,
        )),
        const SizedBox(width: 10),
        Expanded(child: _TrayFigure(
          value: '$_slack',
          label: 'slack · balls you can skip',
          muted: _count == null,
          // Amber at zero: the group has no choices left, which is a
          // different thing from having made them.
          alert: _slack == 0 && _ballsLeft > 0,
        )),
      ]);

  Widget _actions() => Row(children: [
        if (onBack != null) ...[
          GestureDetector(
            onTap: onBack,
            child: Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Halved.muted, width: 1.4),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.chevron_left,
                  color: Halved.cream, size: 22),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(child: _TrayCta(
          // **The label is the gate.** `Next hole` on a hole with no count
          // would be a button that refuses, so until a count is picked it
          // says what is missing instead.
          label: _count == null ? 'Pick a count' : 'Next hole',
          enabled: _count != null && onNext != null,
          onTap: onNext,
        )),
      ]);

  /// The dark sheet itself.
  Widget _tray({required Widget child}) => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Halved.deepPine,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Halved.rCard)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        child: child,
      );


}

class FortyBallsPickerCard extends StatefulWidget {
  final int foursomeId;
  final int hole;
  /// Names by player id, for the counted-golfer line.
  final Map<int, String> names;
  /// Any value that changes when the hole's scores might have. Bump it and the
  /// card re-reads.
  final Object? refreshToken;
  /// Reports the hole's state up — on LOAD as well as after a pick, because
  /// the pager's gate needs it before the scorer touches anything.
  final ValueChanged<FortyBallsPickerState?>? onState;

  /// The hole's nets as ENTERED, pending scores included.
  final Map<int, int> localNets;

  /// The count chosen but not yet sent, and the way to change it. The screen
  /// owns it so it can ride along in the save.
  final int? pendingCount;
  final ValueChanged<int>? onPending;

  const FortyBallsPickerCard({
    super.key,
    required this.foursomeId,
    required this.hole,
    this.names = const {},
    this.refreshToken,
    this.onState,
    this.localNets = const {},
    this.pendingCount,
    this.onPending,
  });

  @override
  State<FortyBallsPickerCard> createState() => _FortyBallsPickerCardState();
}

class _FortyBallsPickerCardState extends State<FortyBallsPickerCard> {
  FortyBallsPickerState? _state;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FortyBallsPickerCard old) {
    super.didUpdateWidget(old);
    if (old.hole != widget.hole || old.refreshToken != widget.refreshToken) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AuthProvider>().client
          .getFortyBallsHole(widget.foursomeId, widget.hole);
      if (!mounted) return;
      setState(() { _state = r.state; _error = null; });
      widget.onState?.call(r.state);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _pick(int n) async {
    // **Not posted yet? Hold it.** The count goes with the hole's scores in
    // one save — which is what lets the group pick while it is still entering,
    // instead of posting, picking, and only then moving on.
    if (!(_state?.scoresIn ?? false)) {
      widget.onPending?.call(n);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await context.read<AuthProvider>().client
          .postFortyBallsCount(widget.foursomeId, widget.hole, n);
      if (!mounted) return;
      setState(() { _state = r.state; _error = null; _busy = false; });
      widget.onState?.call(r.state);
    } catch (e) {
      if (!mounted) return;
      // A 409 means the round moved under us — the hole is settled, or the
      // group is out. Re-read rather than re-prompt; the card then says which.
      setState(() { _busy = false; _error = friendlyError(e); });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s == null) {
      if (_error == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(_error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    return FortyBallsPicker(
      state       : s,
      names       : widget.names,
      busy        : _busy,
      onPick      : _pick,
      localNets   : widget.localNets,
      pendingCount: widget.pendingCount,
    );
  }
}


// ---------------------------------------------------------------------------
// The tray's own controls. Dark-ground versions of the light card's, kept
// private here rather than generalised: nothing else in the app draws on
// deep pine at this size, and a shared "dark chip" with one caller is a
// guess about the second one.
// ---------------------------------------------------------------------------

class _TrayCount extends StatelessWidget {
  final int n;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  const _TrayCount({
    super.key,
    required this.n, required this.selected,
    required this.enabled, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color fill = selected
        ? Halved.brightMint
        : (enabled ? Halved.pine.withValues(alpha: 0.35) : Colors.transparent);
    final Color text = selected
        ? Halved.deepPine
        : (enabled ? Halved.cream : Halved.muted);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: '$n counting',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(Halved.rChip),
          onTap: enabled ? onTap : null,
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(Halved.rChip),
              border: selected
                  ? null
                  : Border.all(
                      color: enabled ? Halved.muted : Halved.muted
                          .withValues(alpha: 0.4),
                      width: 1.2),
            ),
            alignment: Alignment.center,
            child: Text('$n',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: text)),
          ),
        ),
      ),
    );
  }
}

class _TrayFigure extends StatelessWidget {
  final String value;
  final String label;
  final bool muted;
  final bool alert;
  const _TrayFigure({
    required this.value, required this.label,
    this.muted = false, this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final colour = alert
        ? Halved.role
        : (muted ? Halved.muted : Halved.cream);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.pine.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(Halved.rChip),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700, color: colour)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: Halved.muted, fontSize: 11)),
        ],
      ),
    );
  }
}

class _TrayCta extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback? onTap;
  const _TrayCta({required this.label, required this.enabled, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: enabled
            ? Halved.brightMint
            : Halved.pine.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Halved.rCta),
        child: InkWell(
          borderRadius: BorderRadius.circular(Halved.rCta),
          onTap: enabled ? onTap : null,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: enabled ? Halved.deepPine : Halved.muted,
                )),
          ),
        ),
      );
}

class _TrayNote extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _TrayNote({
    required this.icon, required this.title, required this.body,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Halved.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Halved.cream, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(body,
                    style: const TextStyle(
                        color: Halved.muted, fontSize: 12, height: 1.35)),
              ],
            ),
          ),
        ],
      );
}

class _TrayLockNote extends StatelessWidget {
  final String text;
  const _TrayLockNote({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Halved.role.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(Halved.rChip),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Halved.role, fontSize: 12, height: 1.35)),
      );
}

/// The group's net to par, for [HoleHeader.badge].
///
/// **This is where the Net figure went.** It used to be one of the picker's
/// two boxes (Paul, 16 Oct: Status replaced Slack so the number a group is
/// ranked on came first); the reworked packet takes it out of the tray and
/// puts it on the hole header, where it reads once for the whole screen
/// instead of competing with the pace figure beside it. Removing it from one
/// place without adding it here would simply have deleted it — `state.net`
/// had exactly one reader in the app.
class FortyBallsNetBadge extends StatelessWidget {
  final int net;
  const FortyBallsNetBadge({super.key, required this.net});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Halved.pine,
          borderRadius: BorderRadius.circular(Halved.rChip),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            // `E`, `-3`, `+2` — level is a word everywhere else in the app.
            net == 0 ? 'E' : (net > 0 ? '+$net' : '$net'),
            style: const TextStyle(
                color: Halved.cream, fontSize: 16, fontWeight: FontWeight.w700,
                height: 1.05),
          ),
          const Text('GROUP',
              style: TextStyle(
                  color: Halved.cream, fontSize: 8.5,
                  fontWeight: FontWeight.w700, letterSpacing: 0.7)),
        ]),
      );
}
