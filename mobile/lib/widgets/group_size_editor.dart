/// widgets/group_size_editor.dart
/// ------------------------------
/// The TD's group-size override, shared by every flow that builds groups.
///
/// It began private to `new_round_wizard.dart`, which is why the CUP flow
/// never had it: a cup ends at Review and hands round setup to
/// `setup_round_players_screen.dart`, a screen that could only ever take the
/// server's auto-balance. Reported from a 46-golfer Ryder Cup build-up, where
/// the TD wanted 11 foursomes and a twosome and got 10 foursomes and two
/// threesomes with no way to say otherwise.
///
/// **The steppers now honour `minSize`/`maxSize`.** They were hardcoded to
/// `> 2` and `< 4` while `_inc`/`_dec` read the fields, so a pairs round could
/// not reach the trailing ONE that this widget's own doc comment says "has to
/// be representable here or a 13-golfer field cannot be saved at all".
library;

import 'package:flutter/material.dart';

/// Per-group accent colours, shared with the wizard's group list so one group
/// is the same colour in both places.
const kGroupColors = [
  Color(0xFF1565C0), // blue
  Color(0xFF2E7D32), // green
  Color(0xFFB71C1C), // red
  Color(0xFFE65100), // orange
  Color(0xFF6A1B9A), // purple
];

class GroupSizeEditor extends StatefulWidget {
  final List<int> initialSizes;
  final List<int> autoBalance;
  final int       totalPlayers;
  /// A foursome round groups in 2s to 4s. **A pairs round groups in twos** —
  /// with a trailing ONE when the field is odd, which has to be representable
  /// here or a 13-golfer field cannot be saved at all, and a THREE only when
  /// the format is best ball (the one way out that counts a third ball).
  final int       minSize;
  final int       maxSize;
  final String    noun;

  const GroupSizeEditor({
    super.key,
    required this.initialSizes,
    required this.autoBalance,
    required this.totalPlayers,
    this.minSize = 2,
    this.maxSize = 4,
    this.noun    = 'Group',
  });

  @override
  State<GroupSizeEditor> createState() => GroupSizeEditorState();
}

class GroupSizeEditorState extends State<GroupSizeEditor> {
  late List<int> _sizes;

  @override
  void initState() {
    super.initState();
    _sizes = List<int>.from(widget.initialSizes);
  }

  int  get _total     => _sizes.fold(0, (s, x) => s + x);
  int  get _remaining => widget.totalPlayers - _total;
  bool get _isValid   => _total == widget.totalPlayers &&
                         _sizes.every(
                             (s) => s >= widget.minSize && s <= widget.maxSize) &&
                         _sizes.isNotEmpty;

  void _inc(int idx) {
    if (_sizes[idx] >= widget.maxSize) return;
    setState(() => _sizes[idx] = _sizes[idx] + 1);
  }
  void _dec(int idx) {
    if (_sizes[idx] <= widget.minSize) return;
    setState(() => _sizes[idx] = _sizes[idx] - 1);
  }
  void _remove(int idx) {
    if (_sizes.length <= 1) return;
    setState(() => _sizes.removeAt(idx));
  }
  void _addGroup() {
    // Default a new group to the biggest size that fits, floored at the
    // minimum — a pairs field adds twos, a foursome field adds fours.
    final spaceLeft = widget.totalPlayers - _total;
    final initial   = spaceLeft >= widget.maxSize
        ? widget.maxSize
        : (spaceLeft >= widget.minSize ? spaceLeft : widget.maxSize);
    setState(() => _sizes.add(initial));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      // `scrollable: true` wraps the dialog body in a SingleChildScrollView
      // so a long group list (many players → many rows) scrolls inside the
      // dialog rather than overflowing the screen.  Combined with the
      // bounded-width SizedBox below, this also avoids the
      // "RenderShrinkWrappingViewport does not support returning intrinsic
      // dimensions" crash a bare ListView produces inside AlertDialog's
      // IntrinsicWidth wrapper.
      scrollable: true,
      title: Text('Edit ${widget.noun} Sizes'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each ${widget.noun.toLowerCase()} must have '
              '${[for (var n = widget.minSize; n <= widget.maxSize; n++) '$n']
                  .join(', ')} '
              'player${widget.maxSize == 1 ? '' : 's'}. Total must '
              'equal ${widget.totalPlayers}.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              'Auto-balance: ${widget.autoBalance.join(" + ")} '
              '= ${widget.totalPlayers}',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 12),
            // Group rows with steppers — built inline so the row height
            // grows with the group count rather than reserving a fixed
            // ListView height (which left a 280-px hole when only two
            // groups were configured and pushed the footer off-screen).
            for (int i = 0; i < _sizes.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              Row(children: [
                SizedBox(
                  width: 72,
                  child: Text('${widget.noun} ${i + 1}',
                      style: TextStyle(
                          color: kGroupColors[i % kGroupColors.length],
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  onPressed: _sizes[i] > widget.minSize ? () => _dec(i) : null,
                ),
                SizedBox(
                  width: 28,
                  child: Center(
                    child: Text('${_sizes[i]}',
                        style: theme.textTheme.titleMedium),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  onPressed: _sizes[i] < widget.maxSize ? () => _inc(i) : null,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove group',
                  onPressed: _sizes.length > 1 ? () => _remove(i) : null,
                ),
              ]),
            ],
            const SizedBox(height: 8),
            Row(children: [
              TextButton.icon(
                icon : const Icon(Icons.add, size: 18),
                label: const Text('Add group'),
                onPressed: _addGroup,
              ),
              const Spacer(),
              Text(
                'Total: $_total / ${widget.totalPlayers}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _isValid
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ]),
            if (!_isValid && _remaining != 0) ...[
              const SizedBox(height: 4),
              Text(
                _remaining > 0
                    ? '$_remaining more player${_remaining == 1 ? "" : "s"} '
                      'to place — add a group or +1 to an existing one.'
                    : '${(-_remaining)} too many — -1 from a group or '
                      'remove one.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(<int>[]),
          child: const Text('Reset to default'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isValid
              ? () => Navigator.of(context).pop(_sizes)
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
