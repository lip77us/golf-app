import 'package:flutter/material.dart';

import '../utils/skin_rules_display.dart';

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
    this.ruleCopy = const [],
    this.enabled = true,
  });

  final String minimum;
  final bool birdieSteal;
  final ValueChanged<String> onMinimumChanged;
  final ValueChanged<bool> onBirdieStealChanged;
  /// `summary['skin_rule_copy']` — the server's catalogue of what each rule
  /// does. The card renders those words and writes none of its own: this
  /// screen was one of the five places the steal was spelled, and its
  /// sentence had drifted to something the engine never did.
  final List<dynamic> ruleCopy;
  final bool enabled;

  static const _options = <(String, String, String)>[
    ('none', 'No minimum',
     'Lowest score wins, however it was made.'),
    ('net_par', 'Net par or better',
     'A score over par cannot win, even as the low score.'),
    ('gross_par', 'Gross par or better',
     'Stricter: a net par made off a stroke is a gross bogey and fails.'),
  ];

  /// What the settings in force do, in the server's own sentences.
  ///
  /// Both are listed rather than one, unlike the board's footnote: a setup
  /// screen is where a TD decides, so the steal's rule is worth stating even
  /// when a minimum is also on.
  String _effect() {
    final bits = <String>[];
    void add(String? note) {
      if (note != null && note.isNotEmpty && !bits.contains(note)) {
        bits.add(note);
      }
    }
    if (minimum != 'none') add(skinRuleCopy(ruleCopy, minimum)?['note']);
    if (birdieSteal) add(skinRuleCopy(ruleCopy, 'birdie_steal')?['note']);
    if (bits.isEmpty) return 'Plain skins — the lowest score wins the hole.';
    return bits.join(' ');
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
              title: Text(
                  skinRuleCopy(ruleCopy, 'birdie_steal')?['label'] ??
                      'Gross birdies steal'),
              subtitle: Text(
                birdieSteal
                    // The server's words, so the setup screen and the board
                    // cannot describe one rule two ways.
                    ? (skinRuleCopy(ruleCopy, 'birdie_steal')?['note'] ?? '')
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
