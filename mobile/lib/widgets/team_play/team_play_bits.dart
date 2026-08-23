/// widgets/team_play/team_play_bits.dart
/// -------------------------------------
/// The small pieces the Team Play steps share — a radio card, a radio row, a
/// stepper, a stat and a note.
///
/// They live here rather than in each step because the wizard's five Team Play
/// screens are deliberately the same screen five times over: a question, the
/// options, and the consequence stated underneath. Drift between them would
/// read as five different products.
library;

import 'package:flutter/material.dart';

import '../../theme/halved_brand.dart';

/// A full-width option card — the shape every Team Play question uses.
class TeamRadioCard extends StatelessWidget {
  final String title;
  final String body;
  final bool   selected;
  final bool   enabled;
  /// A figure printed at the right of the row, with a caption under it —
  /// `4` / `STROKES`, `85%` / `EACH`.
  ///
  /// **The pair's own figure shows on every option before it is chosen**
  /// (docs/design-review/handoff-team-pairs/SPEC.md §4). The same two men play
  /// off 4 in a scramble and 12 in an alternate shot, so a TD picking Chapman
  /// because it sounds fun should see that it more than doubles his field's
  /// strokes.
  final String? trailing;
  final String? trailingCaption;
  final VoidCallback onTap;

  const TeamRadioCard({
    super.key,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.trailing,
    this.trailingCaption,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(Halved.rCard),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? Halved.pine.withValues(alpha: 0.06) : Halved.card,
          borderRadius: BorderRadius.circular(Halved.rCard),
          border: Border.all(
            color: selected ? Halved.pine : Halved.cardBorder,
            width: selected ? 2 : 1.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(selected ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                 color: selected ? Halved.pine : Halved.cardBorder, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Halved.body(weight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(body, style: Halved.body(color: Halved.muted)),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(trailing!,
                       style: Halved.sectionHead().copyWith(
                           fontSize: 24,
                           color: selected ? Halved.pine : Halved.deepPine)),
                  if (trailingCaption != null)
                    Text(trailingCaption!.toUpperCase(),
                         style: Halved.label()),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact radio inside a SectionCard — for a secondary choice that hangs
/// off the main one.
class TeamRadioRow extends StatelessWidget {
  final bool   selected;
  final String title;
  final String body;
  final bool   enabled;
  final VoidCallback onTap;

  const TeamRadioRow({
    super.key,
    required this.selected,
    required this.title,
    required this.body,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(Halved.rChip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(selected ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                 color: selected ? Halved.pine : Halved.cardBorder, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Halved.body(weight: FontWeight.w600)),
                  Text(body,
                      style: Halved.body(color: Halved.muted)
                          .copyWith(fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// − N + . Every Team Play number the TD sets moves through one of these.
class TeamStepper extends StatelessWidget {
  final String label;
  final String hint;
  final int    value;
  final int    min;
  final int    max;
  final int    step;
  final bool   enabled;
  /// Rendered instead of the bare number — `$25` on the fee, `50%` on a split.
  final String Function(int)? format;
  final ValueChanged<int> onChanged;

  const TeamStepper({
    super.key,
    required this.label,
    required this.hint,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.enabled = true,
    this.format,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, int next, bool on) => InkWell(
          onTap: on && enabled ? () => onChanged(next) : null,
          borderRadius: BorderRadius.circular(Halved.rPill),
          child: Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Halved.cardBorder, width: 1.5),
              color: Halved.card,
            ),
            child: Icon(icon, size: 18,
                color: on && enabled ? Halved.pine : Halved.disabledText),
          ),
        );

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Halved.body(weight: FontWeight.w600)),
              if (hint.isNotEmpty)
                Text(hint,
                    style: Halved.body(color: Halved.muted)
                        .copyWith(fontSize: 13)),
            ],
          ),
        ),
        btn(Icons.remove, value - step, value - step >= min),
        SizedBox(
          width: 66,
          child: Center(
            child: Text(format?.call(value) ?? '$value',
                style: Halved.sectionHead().copyWith(fontSize: 22)),
          ),
        ),
        btn(Icons.add, value + step, value + step <= max),
      ],
    );
  }
}

/// A big figure over a small caption — `36 / BALLS COUNTED`.
class TeamStat extends StatelessWidget {
  final String value;
  final String label;
  final Color? colour;

  const TeamStat({
    super.key, required this.value, required this.label, this.colour,
  });

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: Halved.sectionHead()
                    .copyWith(fontSize: 24, color: colour ?? Halved.deepPine)),
            Text(label, style: Halved.label()),
          ],
        ),
      );
}

/// The consequence, in a sentence. Nothing on a Team Play screen is disabled
/// or flagged without saying why — the house rule inherited from the Cup work.
class TeamNote extends StatelessWidget {
  final String text;
  final bool   warn;

  const TeamNote(this.text, {super.key, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final colour = warn ? Halved.warning : Halved.muted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(warn ? Icons.warning_amber_rounded : Icons.info_outline,
             size: 16, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: Halved.body(color: colour).copyWith(fontSize: 13)),
        ),
      ],
    );
  }
}

/// The team's colour block — six unfamiliar one-syllable names, and this is
/// how a man finds his row without reading.
class TeamColourBlock extends StatelessWidget {
  final String colour;
  final double size;

  const TeamColourBlock({super.key, required this.colour, this.size = 12});

  /// The palette is deliberately narrow and earthy: six blocks that stay
  /// distinguishable next to each other on a phone in sunlight.
  static const Map<String, Color> _swatches = {
    'Pine' : Color(0xFF0F6E56),
    'Clay' : Color(0xFFB2643F),
    'Slate': Color(0xFF546A7B),
    'Dune' : Color(0xFFC9A227),
    'Fern' : Color(0xFF4F9D4A),
    'Rust' : Color(0xFF9C4A24),
    'Moss' : Color(0xFF6B8E4E),
    'Ash'  : Color(0xFF7D8A85),
    'Ochre': Color(0xFFCC8B22),
    'Flint': Color(0xFF4A5459),
    'Reed' : Color(0xFF8FA860),
    'Cobalt': Color(0xFF2E5C8A),
  };

  static Color colourFor(String name) => _swatches[name] ?? Halved.muted;

  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size * 2.2,
        decoration: BoxDecoration(
          color: colourFor(colour),
          borderRadius: BorderRadius.circular(3),
        ),
      );
}
