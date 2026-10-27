import 'package:flutter/material.dart';

/// The two skins validation rules, as one control used by BOTH setup screens.
///
/// Round skins and the cross-group pool carry the same two settings and one
/// engine decides them (`services/skin_rules.py`), so they get one control
/// rather than two that drift. Same reasoning as `SpotsButton` and
/// `GreenieCard` being shared between Spots and junk.
///
/// The minimum values are the server's own slugs — `none` / `net_par` /
/// `gross_par` — passed through untranslated, because a second place that
/// names them is a second place to get them wrong.
class SkinValidationCard extends StatelessWidget {
  const SkinValidationCard({
    super.key,
    required this.minimum,
    required this.birdieSteal,
    required this.onMinimumChanged,
    required this.onBirdieStealChanged,
    this.enabled = true,
  });

  final String minimum;
  final bool birdieSteal;
  final ValueChanged<String> onMinimumChanged;
  final ValueChanged<bool> onBirdieStealChanged;
  final bool enabled;

  static const _options = <(String, String, String)>[
    ('none', 'No minimum',
     'Lowest score wins, however it was made.'),
    ('net_par', 'Net par or better',
     'A score over par cannot win, even as the low score.'),
    ('gross_par', 'Gross par or better',
     'Stricter: a net par made off a stroke is a gross bogey and fails.'),
  ];

  /// What the two settings do together, in a sentence.  Worth stating because
  /// the interesting case is not either rule alone — it is that a hole can now
  /// go unwon, which plain skins never does unless somebody ties.
  String _effect() {
    final bits = <String>[];
    if (minimum == 'net_par') {
      bits.add('a hole where nobody is net par or better goes unwon');
    } else if (minimum == 'gross_par') {
      bits.add('a hole where nobody makes a gross par goes unwon');
    }
    if (birdieSteal) {
      bits.add('a gross birdie beats any net score');
    }
    if (bits.isEmpty) return 'Plain skins — the lowest score wins the hole.';
    return '${bits.join(', and ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Validation',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 2),
            Text('What it takes to win a skin.', style: muted),
            const SizedBox(height: 8),

            for (final (value, label, blurb) in _options)
              RadioListTile<String>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: value,
                groupValue: minimum,
                title: Text(label),
                subtitle: Text(blurb, style: muted),
                onChanged: enabled
                    ? (v) { if (v != null) onMinimumChanged(v); }
                    : null,
              ),

            const Divider(height: 18),

            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Gross birdies steal'),
              subtitle: Text(
                birdieSteal
                    ? 'A real birdie beats a lower net score.'
                    : 'Strokes decide the hole however it was made.',
                style: muted,
              ),
              value: birdieSteal,
              onChanged: enabled ? onBirdieStealChanged : null,
            ),

            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_effect(),
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}
