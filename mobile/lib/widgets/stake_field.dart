import 'package:flutter/material.dart';

import 'golf_text_field.dart';

/// Round-level stake input paired with a "Play for fun — no stakes" opt-in.
///
/// Reports via [onChanged] whether a stake decision has been made — a positive
/// stake entered, OR the no-stakes box ticked — so the caller can keep its
/// Start button disabled until the user has consciously chosen. The two stay
/// consistent: ticking "no stakes" zeros the field; typing a stake unticks it.
class StakeField extends StatefulWidget {
  final TextEditingController controller;

  /// Called with `true` once a stake is set or "no stakes" is ticked.
  final ValueChanged<bool> onChanged;

  /// Card heading (e.g. 'Stake').
  final String label;

  /// Optional helper line under the field.
  final String? helpText;

  const StakeField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.label = 'Stake',
    this.helpText,
  });

  @override
  State<StakeField> createState() => _StakeFieldState();
}

class _StakeFieldState extends State<StakeField> {
  bool _noStakes = false;

  bool get _chosen =>
      _noStakes || (double.tryParse(widget.controller.text.trim()) ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onBet);
    // Report initial validity (e.g. a pre-filled stake) after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(_chosen);
    });
  }

  void _onBet() {
    // Entering a real stake clears the "no stakes" opt-in.
    if ((double.tryParse(widget.controller.text.trim()) ?? 0) > 0 &&
        _noStakes) {
      _noStakes = false;
    }
    if (mounted) setState(() {});
    widget.onChanged(_chosen);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onBet);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.label,
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          GolfTextField(
            controller: widget.controller,
            label: 'Stake (\$)',
            prefixIcon: Icons.attach_money,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          if (widget.helpText != null) ...[
            const SizedBox(height: 6),
            Text(widget.helpText!,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Play for fun — no stakes'),
            value: _noStakes,
            onChanged: (v) {
              setState(() {
                _noStakes = v ?? false;
                if (_noStakes) widget.controller.text = '0';
              });
              widget.onChanged(_chosen);
            },
          ),
        ]),
      ),
    );
  }
}
