/// widgets/golf_text_field.dart
/// -----------------
/// Single consistent text-field wrapper used across every setup / form
/// screen in the app.  Per the May 2026 design audit (D-03), we had
/// 40-odd hand-rolled `TextFormField(decoration: InputDecoration(...))`
/// blocks that all needed `OutlineInputBorder()`, a prefix icon, label,
/// helper text, etc. — but each rebuilt the InputDecoration from scratch
/// and quietly drifted on tiny details (isDense, contentPadding, helper
/// truncation, suffix spacing).  This widget collapses that into one
/// shape so:
///
///   * Every field uses the same border + content padding.
///   * Common props (labelText, helperText, hintText, prefixIcon,
///     suffixIcon, suffixText) get first-class params instead of
///     deeply-nested decoration objects.
///   * Escape hatches stay open for the rare advanced cases — pass a
///     full `decoration:` to override, or use `decorationBuilder` to
///     start from the canonical decoration and tweak.
///
/// Usage:
///
/// ```dart
/// GolfTextField(
///   controller: ctrl,
///   label: 'Bet unit',
///   prefixIcon: Icons.attach_money,
///   keyboardType: const TextInputType.numberWithOptions(decimal: true),
/// )
/// ```
///
/// With validator (form mode — backed by TextFormField):
///
/// ```dart
/// GolfTextField(
///   controller: ctrl,
///   label: 'Handicap Index',
///   helper: 'WHS index between -10.0 and 54.0',
///   validator: (v) => (v?.isEmpty ?? true) ? 'Required' : null,
/// )
/// ```
///
/// The widget always renders a `TextFormField` underneath so validation
/// works inside `Form`s and the API stays uniform whether or not the
/// caller passes a `validator`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GolfTextField extends StatelessWidget {
  // ── Content / control ────────────────────────────────────────────
  final TextEditingController? controller;
  final String?                initialValue;
  final FocusNode?             focusNode;
  final bool                   enabled;
  final bool                   readOnly;
  final bool                   autofocus;
  final bool                   obscureText;
  final bool                   autocorrect;
  final bool                   enableSuggestions;
  final TextCapitalization     textCapitalization;
  final int?                   maxLength;
  final int?                   maxLines;
  final int?                   minLines;
  final TextAlign              textAlign;

  // ── Behaviour ────────────────────────────────────────────────────
  final TextInputType?         keyboardType;
  final TextInputAction?       textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>?  onChanged;
  final ValueChanged<String>?  onFieldSubmitted;
  final VoidCallback?          onTap;
  final FormFieldValidator<String>? validator;
  final AutovalidateMode?      autovalidateMode;

  // ── Decoration shortcuts ─────────────────────────────────────────
  /// Field label shown floating above the input.
  final String?  label;
  /// Placeholder text shown when the field is empty + unfocused.
  final String?  hint;
  /// Persistent helper text below the field (small grey).
  final String?  helper;
  /// Static error text shown below the field (red).  Useful for
  /// backend-validation errors that fall outside Form's [validator]
  /// flow — when non-null, the field renders in its error state.
  final String?  errorText;
  /// Material icon shown inside the field's leading edge.
  final IconData? prefixIcon;
  /// Short leading text — e.g. "$".  Used for currency-style inputs that
  /// don't merit a full icon.  Ignored when [prefixIcon] is set.
  final String?   prefixText;
  /// Trailing icon button widget (e.g. visibility toggle).  Use
  /// [suffixText] for a plain string like "%" or "$".
  final Widget?   suffix;
  /// Short trailing text — e.g. "%", "$", "yds".  Mutually exclusive
  /// with [suffix] (suffix wins if both are provided).
  final String?   suffixText;
  /// Compact rendering — uses `isDense: true` and tighter content
  /// padding.  Default true for visual consistency across forms; pass
  /// false on landing-page / single-field surfaces where you want air.
  final bool      dense;

  // ── Full escape hatches ──────────────────────────────────────────
  /// Replace the canonical decoration entirely.  When provided every
  /// shortcut param above is ignored.
  final InputDecoration? decoration;
  /// Start from the canonical decoration and tweak it (rare).  Ignored
  /// when [decoration] is set.
  final InputDecoration Function(InputDecoration base)? decorationBuilder;

  const GolfTextField({
    super.key,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.textCapitalization = TextCapitalization.none,
    this.maxLength,
    this.maxLines = 1,
    this.minLines,
    this.textAlign = TextAlign.start,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.onChanged,
    this.onFieldSubmitted,
    this.onTap,
    this.validator,
    this.autovalidateMode,
    this.label,
    this.hint,
    this.helper,
    this.errorText,
    this.prefixIcon,
    this.prefixText,
    this.suffix,
    this.suffixText,
    this.dense = true,
    this.decoration,
    this.decorationBuilder,
  }) : assert(controller == null || initialValue == null,
            'Provide either controller or initialValue, not both.');

  @override
  Widget build(BuildContext context) {
    final InputDecoration dec;
    if (decoration != null) {
      dec = decoration!;
    } else {
      final base = InputDecoration(
        labelText:  label,
        hintText:   hint,
        helperText: helper,
        // Helper can wrap to 3 lines before being truncated — matches
        // the longest existing helper string in the app.
        helperMaxLines: 3,
        errorText:  errorText,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
        prefixText: prefixIcon == null ? prefixText : null,
        suffixIcon: suffix,
        suffixText: suffix == null ? suffixText : null,
        border:     const OutlineInputBorder(),
        isDense:    dense,
      );
      dec = decorationBuilder == null ? base : decorationBuilder!(base);
    }

    return TextFormField(
      controller:         controller,
      initialValue:       initialValue,
      focusNode:          focusNode,
      enabled:            enabled,
      readOnly:           readOnly,
      autofocus:          autofocus,
      obscureText:        obscureText,
      autocorrect:        autocorrect,
      enableSuggestions:  enableSuggestions,
      textCapitalization: textCapitalization,
      maxLength:          maxLength,
      maxLines:           obscureText ? 1 : maxLines,
      minLines:           minLines,
      textAlign:          textAlign,
      keyboardType:       keyboardType,
      textInputAction:    textInputAction,
      inputFormatters:    inputFormatters,
      onChanged:          onChanged,
      onFieldSubmitted:   onFieldSubmitted,
      onTap:              onTap,
      validator:          validator,
      autovalidateMode:   autovalidateMode,
      decoration:         dec,
    );
  }
}
