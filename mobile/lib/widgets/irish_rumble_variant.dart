import 'package:flutter/material.dart';

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
List<({int start, int end, int balls})> irishRumbleCollapseRuns(
    List<int> perHole) {
  final out = <({int start, int end, int balls})>[];
  var segStart = 1;
  var curBalls = perHole[0];
  for (var i = 1; i < 18; i++) {
    if (perHole[i] != curBalls) {
      out.add((start: segStart, end: i, balls: curBalls));
      segStart = i + 1;
      curBalls = perHole[i];
    }
  }
  out.add((start: segStart, end: 18, balls: curBalls));
  return out;
}

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
  Widget build(BuildContext context) {
    final perHole = irishRumbleBallsPerHole(
      variant: variant, holePars: holePars, customBalls: customBalls,
    );
    final runs = irishRumbleCollapseRuns(perHole);
    return SectionCard(
      title: 'Segment Preview',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in runs)
            _SegmentRow(
              r.start == r.end ? 'Hole ${r.start}'
                                : 'Holes ${r.start}–${r.end}',
              r.balls == 1 ? 'Best 1 net per group'
                           : 'Best ${r.balls} nets per group',
            ),
        ],
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget holeCell(int idx) {
      final hole = idx + 1;
      final par  = idx < holePars.length ? holePars[idx] : 4;
      final val  = customBalls[idx];
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$hole',
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text('Par $par',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10)),
            const SizedBox(height: 4),
            // Step the balls value 1→2→3→4→1 on tap.  Tight cycling
            // beats a full picker when there are 18 cells on screen.
            InkWell(
              onTap: () => onChanged(idx, val >= 4 ? 1 : val + 1),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 28, height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text('$val',
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      );
    }

    return SectionCard(
      title: 'Per-hole balls (tap to cycle 1→2→3→4)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Front 9',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Row(children: [
            for (var i = 0; i < 9; i++) Expanded(child: holeCell(i)),
          ]),
          const SizedBox(height: 10),
          Text('Back 9',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Row(children: [
            for (var i = 9; i < 18; i++) Expanded(child: holeCell(i)),
          ]),
        ],
      ),
    );
  }
}

class _SegmentRow extends StatelessWidget {
  final String holes;
  final String rule;
  const _SegmentRow(this.holes, this.rule);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 100,
          child: Text(holes,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(rule,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}
