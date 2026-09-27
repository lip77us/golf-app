/// widgets/forty_balls_picker.dart
/// ------------------------------
/// The 40 Balls picker — one card under the player rows in tournament score
/// entry.
///
/// **It appears once the LAST score on the hole is in**, because the whole
/// game is that the group chooses having seen its nets. Before that there is
/// nothing to choose between, and the card says what is missing rather than
/// showing a row of dead buttons.
///
/// There is no default. The pager stays live but reads `Pick how many balls
/// count to move on` — the same pattern a missing score uses, because it is the
/// same kind of gap.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import 'error_view.dart';
import '../theme/halved_brand.dart';
import '../utils/stroke_play_standing.dart';

class FortyBallsPicker extends StatelessWidget {
  final FortyBallsPickerState state;
  /// Names by player id, for lighting the counted rows' owners.
  final Map<int, String> names;
  final ValueChanged<int> onPick;
  final bool busy;

  const FortyBallsPicker({
    super.key,
    required this.state,
    required this.names,
    required this.onPick,
    this.busy = false,
  });

  /// The nets that would count at [n] — the best ones, which is what the
  /// picker lights up as the scorer moves across the buttons.
  List<int> countedAt(int n) {
    final sorted = state.nets.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return sorted.take(n).map((e) => e.key).toList();
  }

  /// `−2` for the hole, at the count currently picked.
  int? get result {
    final n = state.count;
    if (n == null || state.par == null) return null;
    final sorted = state.nets.values.toList()..sort();
    return sorted.take(n).fold<int>(0, (a, b) => a + b) - n * state.par!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (state.dq) {
      return _shell(context, child: _Note(
        icon: Icons.block,
        colour: theme.colorScheme.error,
        title: 'Out of 40 Balls',
        body: 'This group owes ${state.left} balls with room for '
              '${state.capacity}. The budget cannot come out. Scores still '
              'count for the championship.',
      ));
    }

    if (!state.scoresIn) {
      return _shell(context, child: _Note(
        icon: Icons.hourglass_empty,
        colour: theme.colorScheme.onSurfaceVariant,
        title: 'Waiting on the last score',
        body: 'The group picks once it has seen every net on this hole.',
      ));
    }

    return _shell(
      context,
      header: Row(children: [
        Text('40 Balls · how many count?',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const Spacer(),
        Text('best nets count',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
      child: Column(children: [
        Row(children: [
          for (var n = 0; n <= state.groupSize; n++) ...[
            if (n > 0) const SizedBox(width: 8),
            Expanded(child: _CountButton(
              n        : n,
              selected : state.count == n,
              // Outside `lo..hi` the budget would not come out, so the button
              // is dead rather than a pick that gets refused.
              enabled  : !busy && state.canPick && n >= state.lo && n <= state.hi,
              onTap    : () => onPick(n),
            )),
          ],
        ]),
        const SizedBox(height: 10),
        _resultLine(context),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _Figure(
            label: 'To reach ${state.budget}',
            value: state.average == null
                ? '–'
                : '${state.average!.toStringAsFixed(1)} a hole',
            note : state.average == null
                ? 'budget spent'
                : '${state.holesAfter} to play',
            // Both figures grey BEFORE a pick — they show the position
            // before this hole, which is not yet the position after it.
            muted: state.count == null,
          )),
          const SizedBox(width: 10),
          Expanded(child: _Figure(
            label: 'Slack',
            value: state.left == 0 ? '–' : '${state.slack}',
            note : state.left == 0
                ? 'budget spent'
                : (state.slack == 0
                    ? 'every ball counts from here'
                    : 'balls you can still skip'),
            muted: state.count == null,
            // Amber at zero: the group has no choices left, which is a
            // different thing from having made them.
            alert: state.slack == 0 && state.left > 0,
          )),
        ]),
        if (state.lo == state.hi) ...[
          const SizedBox(height: 10),
          _LockNote(
            text: state.left == 0
                ? 'Budget spent. Every remaining hole counts 0, and the app '
                  'has filled them in.'
                : 'No slack left. Every remaining hole counts '
                  '${state.hi}, and the app has filled them in.',
          ),
        ],
      ]),
    );
  }

  Widget _resultLine(BuildContext context) {
    final theme = Theme.of(context);
    final n = state.count;
    if (n == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('Pick how many balls count to move on',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    if (n == 0) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('No balls counted — the hole is level.',
            style: theme.textTheme.bodySmall),
      );
    }
    final r = result;
    final counted = countedAt(n)
        .map((id) => names[id] ?? '')
        .where((s) => s.isNotEmpty)
        .join(' · ');
    return Align(
      alignment: Alignment.centerLeft,
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '$counted  '),
        TextSpan(
          text: r == null ? '' : toParLabel(r),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: r == null || r == 0
                ? theme.colorScheme.onSurface
                : (r < 0 ? Halved.pine : Halved.caution),
          ),
        ),
      ]), style: theme.textTheme.bodySmall),
    );
  }

  Widget _shell(BuildContext context, {Widget? header, required Widget child}) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header != null) ...[header, const SizedBox(height: 10)],
        child,
      ]),
    );
  }
}

class _CountButton extends StatelessWidget {
  final int n;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  const _CountButton({
    required this.n, required this.selected,
    required this.enabled, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? Halved.pine
              : (enabled ? null : theme.colorScheme.surfaceContainerHighest),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? Halved.pine : theme.colorScheme.outlineVariant,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Text('$n',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: selected
                  ? Colors.white
                  : (enabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant.withOpacity(0.45)),
            )),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final String note;
  final bool muted;
  final bool alert;
  const _Figure({
    required this.label, required this.value, required this.note,
    this.muted = false, this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = alert
        ? Halved.caution
        : (muted ? theme.colorScheme.onSurfaceVariant
                 : theme.colorScheme.onSurface);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: alert
            ? Halved.cautionGround
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 9, letterSpacing: 0.5,
                color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.bold, color: fg)),
        Text(note,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
                color: alert ? Halved.caution
                             : theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _LockNote extends StatelessWidget {
  final String text;
  const _LockNote({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.lock_outline, size: 14,
          color: theme.colorScheme.onSurfaceVariant),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
    ]);
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final Color colour;
  final String title;
  final String body;
  const _Note({required this.icon, required this.colour,
               required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: colour),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.bold, color: colour)),
          const SizedBox(height: 2),
          Text(body, style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------

/// The picker, wired: it fetches its own hole state and posts the pick.
///
/// **Self-loading rather than provider-fed.** Its data is one hole of one
/// foursome and it is the only consumer; threading a summary through
/// `RoundProvider` and four load sites would be more moving parts for a card
/// that has to refetch after every score anyway. [refreshToken] is what makes
/// that work — the score-entry screen bumps it when a hole is saved or the
/// hole changes, and the card reloads.
class FortyBallsPickerCard extends StatefulWidget {
  final int foursomeId;
  final int hole;
  /// Names by player id, for the counted-golfer line.
  final Map<int, String> names;
  /// Any value that changes when the hole's scores might have. Bump it and the
  /// card re-reads.
  final Object? refreshToken;
  /// Called after a pick lands, so the screen can refresh anything else that
  /// reads the count (the pager's gate).
  final VoidCallback? onChanged;

  const FortyBallsPickerCard({
    super.key,
    required this.foursomeId,
    required this.hole,
    this.names = const {},
    this.refreshToken,
    this.onChanged,
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
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _pick(int n) async {
    setState(() => _busy = true);
    try {
      final r = await context.read<AuthProvider>().client
          .postFortyBallsCount(widget.foursomeId, widget.hole, n);
      if (!mounted) return;
      setState(() { _state = r.state; _error = null; _busy = false; });
      widget.onChanged?.call();
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
      state : s,
      names : widget.names,
      busy  : _busy,
      onPick: _pick,
    );
  }
}
