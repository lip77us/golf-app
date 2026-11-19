/// A handicap-index field that opens the number pad ([showIndexSheet])
/// instead of the system keyboard. On iOS the system keyboard for a signed
/// decimal is the numbers-and-punctuation one with an ABC key, and a plain
/// number pad has no Done key at all — either can be left on screen with
/// nothing to dismiss it. The pad has neither problem, and types a plus
/// handicap as `+2.1`.
///
/// [controller] holds the index as the server stores it (`14.2`, `-2.1`;
/// empty for none) so every caller keeps reading `controller.text` as it
/// always did; the field shows it the way golfers write it (`+2.1`).
library;

import 'package:flutter/material.dart';

import '../utils/golfer_index.dart';
import 'index_sheet.dart';

class IndexTapField extends FormField<String> {
  IndexTapField({
    super.key,
    required TextEditingController controller,
    required String name,
    required IndexOwner owner,
    double? myIndex,
    String label = 'Handicap index',
    String hint = 'Tap to enter',
    String? helper,
    InputDecoration? decoration,
    ValueChanged<String>? onChanged,
    super.validator,
  }) : super(
          initialValue: controller.text,
          builder: (state) {
            final shown = indexLabel(controller.text);
            Future<void> open() async {
              final r = await showIndexSheet(
                state.context,
                name: name,
                currentStored: controller.text,
                owner: owner,
                myIndex: myIndex,
              );
              if (r == null) return;
              controller.text = r.stored;
              state.didChange(r.stored);
              onChanged?.call(r.stored);
            }

            final base = decoration ??
                InputDecoration(
                  labelText: label,
                  hintText: hint,
                  helperText: helper,
                  border: const OutlineInputBorder(),
                );
            return InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: open,
              child: InputDecorator(
                isEmpty: shown == null,
                isFocused: false,
                decoration: base.copyWith(
                  hintText: base.hintText ?? hint,
                  errorText: state.errorText,
                  suffixIcon: const Icon(Icons.dialpad, size: 20),
                ),
                child: Text(shown ?? '',
                    style: Theme.of(state.context).textTheme.bodyLarge),
              ),
            );
          },
        );
}
