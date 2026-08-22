import 'package:flutter/material.dart';

import 'ball_count_grid.dart';
import 'section_card.dart';

/// Irish Rumble variant picker + segment preview + per-hole custom editor.
///
/// Shared between the standalone casual/tournament Irish Rumble setup and the
/// cup round-setup group builder so both offer the SAME variants and the
/// preview mirrors the backend's `compute_segments` / `_balls_per_hole`
/// verbatim.  Variant slugs must stay in sync with
/// `IrishRumbleConfig.VARIANT_CHOICES` on the server.

/// Returns the per-hole balls-to-count for a variant.  Mirrors the backend's
/// `_balls_per_hole` so the preview shown in the picker matches what the
/// server will actually compute at save time.
List<int> irishRumbleBallsPerHole({
  required String    variant,
  required List<int> holePars,
  required List<int> customBalls,
}) {
  switch (variant) {
    case 'arizona_shuffle':
      const pattern = [1, 2, 3, 1, 2, 3];
      return List.generate(18, (i) => pattern[i ~/ 3]);
    case 'shuffle':
      return List.generate(18, (i) {
        final par = i < holePars.length ? holePars[i] : 4;
        if (par == 3) return 3;
        if (par == 4) return 2;
        if (par == 5) return 1;
        return 2;
      });
    case 'custom':
      return List<int>.from(customBalls);
    case 'classic':
    default:
      return List.generate(18, (i) {
        final h = i + 1;
        if (h <= 6) return 1;
        if (h <= 12) return 2;
        if (h <= 17) return 3;
        return 4;
      });
  }
}

/// Group an 18-element per-hole list into contiguous-same-value runs for
/// compact display ("Holes 7-9 · best 3").
///
/// Delegates to [collapseBallRuns] — the Foursome Play shamble asks the same
/// question and gets the same answer from the same code.
List<({int start, int end, int balls})> irishRumbleCollapseRuns(
        List<int> perHole) =>
    collapseBallRuns(perHole);

class IrishRumbleVariantPicker extends StatelessWidget {
  final String variant;
  final ValueChanged<String> onChanged;
  const IrishRumbleVariantPicker({
    super.key,
    required this.variant,
    required this.onChanged,
  });

  static const _options = [
    ('classic',         'Classic',
     'Builds up: 1 ball, then 2, then 3, then all 4 on the closer.'),
    ('arizona_shuffle', 'Arizona Shuffle',
     'Rotate every 3 holes — 1 / 2 / 3 / 1 / 2 / 3 across the 18.'),
    ('shuffle',         'Shuffle (par-based)',
     'Par 3 = 3 balls, Par 4 = 2 balls, Par 5 = 1 ball.'),
    ('custom',          'Custom (per-hole)',
     'You pick how many balls count on each of the 18 holes.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Variant',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final opt in _options)
            InkWell(
              onTap: () => onChanged(opt.$1),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Radio<String>(
                      value: opt.$1,
                      groupValue: variant,
                      onChanged: (v) { if (v != null) onChanged(v); },
                      visualDensity: VisualDensity.compact,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(opt.$2,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(opt.$3,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class IrishRumbleSegmentPreview extends StatelessWidget {
  final String    variant;
  final List<int> holePars;
  final List<int> customBalls;
  const IrishRumbleSegmentPreview({
    super.key,
    required this.variant,
    required this.holePars,
    required this.customBalls,
  });

  @override
  Widget build(BuildContext context) => BallCountPreview(
        perHole: irishRumbleBallsPerHole(
          variant: variant, holePars: holePars, customBalls: customBalls,
        ),
      );
}

class IrishRumbleCustomBallsEditor extends StatelessWidget {
  final List<int> holePars;
  final List<int> customBalls;
  final void Function(int holeIdx, int value) onChanged;
  const IrishRumbleCustomBallsEditor({
    super.key,
    required this.holePars,
    required this.customBalls,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => BallCountGrid(
        holePars : holePars,
        perHole  : customBalls,
        onChanged: onChanged,
      );
}
