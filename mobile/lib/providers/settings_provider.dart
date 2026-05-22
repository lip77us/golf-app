/// providers/settings_provider.dart
///
/// Per-device user preferences backed by shared_preferences.  Currently
/// hosts a single flag — Net Style Entry — but is the home for any
/// future on-device toggle that should follow the user across rounds
/// but not across devices.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsProvider extends ChangeNotifier {
  static const _netStyleEntryKey   = 'net_style_entry';
  static const _autoAdvanceHoleKey = 'auto_advance_hole';

  bool _netStyleEntry   = true;
  bool _autoAdvanceHole = false;
  bool _loaded          = false;

  /// True when the score-entry button should color and shape its squares
  /// relative to NET par (par + the player's strokes on the hole).  When
  /// false, the white square shows gross par instead, which is easier for
  /// players who think in gross terms.  Defaults to true to preserve the
  /// behavior that existed before the toggle was introduced.
  bool get netStyleEntry => _netStyleEntry;

  /// When true, the score-entry screen automatically saves and moves to
  /// the next hole the moment the final player's score is tapped.  When
  /// false (default), the user stays on the current hole and must press
  /// the next-hole button explicitly — useful for scorers who want to
  /// verify the entries before progressing.
  bool get autoAdvanceHole => _autoAdvanceHole;

  bool get loaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _netStyleEntry   = prefs.getBool(_netStyleEntryKey)   ?? true;
    _autoAdvanceHole = prefs.getBool(_autoAdvanceHoleKey) ?? false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setNetStyleEntry(bool value) async {
    if (value == _netStyleEntry) return;
    _netStyleEntry = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_netStyleEntryKey, value);
  }

  Future<void> setAutoAdvanceHole(bool value) async {
    if (value == _autoAdvanceHole) return;
    _autoAdvanceHole = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoAdvanceHoleKey, value);
  }
}
