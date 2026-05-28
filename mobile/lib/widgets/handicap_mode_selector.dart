/// widgets/handicap_mode_selector.dart
/// -----------------------------------
/// Shared "Handicap" picker used by every casual-round setup screen
/// (Skins, Sixes, Nassau, Points 5-3-1, Multi-Group Skins).
///
/// One source of truth for the look and feel:
///   • SegmentedButton — Net / Gross / SO Low
///   • Slider (50–130%, divisions=16) when mode == 'net'
///   • Short descriptive blurb for Gross and Strokes-Off-Low
///
/// Wrap in a Card on the caller's side or render flat as you prefer.
/// This widget owns no state — parent passes (mode, netPercent) and
/// receives change callbacks.

import 'package:flutter/material.dart';

class HandicapModeSelector extends StatelessWidget {
  /// 'net' | 'gross' | 'strokes_off'
  final String mode;
  /// 50–130. Ignored when mode != 'net'.
  final int netPercent;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<int>    onPercentChanged;

  /// When true, render inside a bordered Card (matches Skins/Nassau).
  /// When false, render flat — useful inside a list page that already
  /// supplies its own card structure.
  final bool wrapInCard;

  /// Optional override for the Strokes-Off-Low blurb.  Tournament-scope
  /// games (Irish Rumble, Stroke Play) anchor on the round-wide low
  /// handicap rather than the foursome low; pass a custom note to make
  /// that explicit.  Defaults to the per-foursome wording.
  final String? soNote;

  const HandicapModeSelector({
    super.key,
    required this.mode,
    required this.netPercent,
    required this.onModeChanged,
    required this.onPercentChanged,
    this.wrapInCard = true,
    this.soNote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body  = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Handicap',
            style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'net',         label: Text('Net')),
            ButtonSegment(value: 'gross',       label: Text('Gross')),
            ButtonSegment(value: 'strokes_off', label: Text('SO Low')),
          ],
          selected: {mode},
          onSelectionChanged: (s) => onModeChanged(s.first),
        ),
        if (mode == 'gross') ...[
          const SizedBox(height: 8),
          Text('No strokes given — raw scores used.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ] else ...[
          // Net OR Strokes-Off-Low — both scale the resulting stroke
          // allocation by net_percent (100% = full allowance, 90% =
          // USGA recommended for 2v2 best-ball, etc.).
          const SizedBox(height: 12),
          Row(children: [
            // The same Net % is used in both modes — in SO Low it scales
            // each player's handicap before subtracting the low handicap.
            // Calling it "Net %" in both modes avoids confusing "SO %"
            // with the "50%" lower bound of the slider value.
            const Text('Net %  '),
            Expanded(
              child: Slider(
                min: 50, max: 130, divisions: 16,
                value: netPercent.toDouble().clamp(50.0, 130.0),
                label: '$netPercent%',
                onChanged: (v) => onPercentChanged(v.round()),
              ),
            ),
            SizedBox(width: 48, child: Text('$netPercent%')),
          ]),
          if (mode == 'strokes_off') ...[
            const SizedBox(height: 4),
            Text(
              soNote ??
                  'The lowest-handicap player plays to 0.  Every other '
                  'player gets one stroke on each hole whose stroke '
                  'index is ≤ their (own HCP − low HCP), scaled by Net %.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ],
    );

    if (!wrapInCard) return body;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(padding: const EdgeInsets.all(14), child: body),
    );
  }
}
