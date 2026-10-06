/// test/picker_reselect_search_test.dart
/// ------------------------------------
/// After picking a golfer, the search text is left SELECTED so the next name
/// types straight over it.
///
/// Reported while building a 48-golfer cup roster out of 250 golfers: search,
/// tick, then reach up and erase — ~48 times. Four screens already did this;
/// the cup draft picker, which is the one a big roster actually goes through,
/// did not.
///
/// Source-level, like the other picker guards: what is at risk is the WIRING
/// — a controller that exists but is never attached, or a toggle that never
/// calls back — not the rendering.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final draft =
      File('lib/screens/ryder_cup_draft_screen.dart').readAsStringSync();

  group('the cup draft picker re-selects its search', () {
    test('it has a controller and a focus node', () {
      // `_search` was a bare String, so there was no handle on the text to
      // select — which is why this screen could not do what the others do.
      expect(draft.contains('TextEditingController _searchCtrl'), isTrue);
      expect(draft.contains('FocusNode             _searchFocus'), isTrue);
    });

    test('both are actually attached to the field', () {
      // A controller that is constructed and never passed is the failure this
      // test exists for — it looks right and changes nothing.
      expect(draft.contains('controller: _searchCtrl'), isTrue);
      expect(draft.contains('focusNode : _searchFocus'), isTrue);
    });

    test('picking a golfer re-selects the query', () {
      final i = draft.indexOf('void _toggle(PlayerProfile p)');
      expect(i, greaterThan(-1));
      final body = draft.substring(i, i + 260);
      expect(body.contains('_reselectSearch()'), isTrue,
          reason: 'the toggle must call it, or the text just sits there');
    });

    test('it selects the whole query rather than clearing it', () {
      // Clearing would also work but loses the query, so a typo means
      // retyping the whole name. Selecting lets one keystroke replace it and
      // leaves arrow-key escape if the pick was a mistake.
      expect(draft.contains('baseOffset: 0, extentOffset: _searchCtrl.text.length'),
          isTrue);
      expect(draft.contains('_searchCtrl.clear()'), isFalse);
    });

    test('an empty query is left alone', () {
      // Nothing to select, and requesting focus on an empty box would pop the
      // keyboard for no reason.
      final i = draft.indexOf('void _reselectSearch()');
      expect(draft.substring(i, i + 160).contains('if (_searchCtrl.text.isEmpty) return;'),
          isTrue);
    });

    test('the controller is disposed', () {
      final i = draft.indexOf('class _PlayerPickerDialogState');
      final body = draft.substring(i, draft.indexOf('List<PlayerProfile> get _filtered', i));
      expect(body.contains('_searchCtrl.dispose()'), isTrue);
      expect(body.contains('_searchFocus.dispose()'), isTrue);
    });
  });

  group('the behaviour is the same one the other pickers use', () {
    test('all four screens share the helper', () {
      for (final f in [
        'lib/screens/casual_round_screen.dart',
        'lib/screens/setup_round_players_screen.dart',
        'lib/screens/new_round_wizard.dart',
        'lib/screens/ryder_cup_draft_screen.dart',
      ]) {
        expect(File(f).readAsStringSync().contains('_reselectSearch'), isTrue,
            reason: '$f should re-select its search after a pick');
      }
    });
  });
}
