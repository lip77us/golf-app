/// providers/settings_provider.dart
///
/// Per-device user preferences backed by shared_preferences.  Currently
/// hosts a single flag — Net Style Entry — but is the home for any
/// future on-device toggle that should follow the user across rounds
/// but not across devices.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsProvider extends ChangeNotifier {
  static const _netStyleEntryKey = 'net_style_entry';

  bool _netStyleEntry = true;
  bool _loaded        = false;

  /// True when the score-entry button should color and shape its squares
  /// relative to NET par (par + the player's strokes on the hole).  When
  /// false, the white square shows gross par instead, which is easier for
  /// players who think in gross terms.  Defaults to true to preserve the
  /// behavior that existed before the toggle was introduced.
  bool get netStyleEntry => _netStyleEntry;

  bool get loaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _netStyleEntry = prefs.getBool(_netStyleEntryKey) ?? true;
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
}
