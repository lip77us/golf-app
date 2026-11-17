/// The index number pad and how an index is written, pure so the rules are
/// testable. A plus handicap is typed `+2.1` and stored `-2.1`.

/// Largest index the pad accepts.
const double kMaxIndex = 54.0;

/// One key press on the pad. [typed] is what is on screen (`19`, `+2.`).
///
/// * a digit appends; after two digits the decimal point is added for you, so
///   1-9-4 gives `19.4`; one decimal place only;
/// * `+/.` typed first makes a plus handicap, after a digit it adds the point;
/// * `back` removes the last character;
/// * anything that would pass 54.0 is refused (returns [typed] unchanged).
String padKey(String typed, String key) {
  if (key == 'back') {
    return typed.isEmpty ? typed : typed.substring(0, typed.length - 1);
  }
  final plus = typed.startsWith('+');
  final body = plus ? typed.substring(1) : typed;
  String next;
  if (key == '+.') {
    if (typed.isEmpty) return '+';
    if (body.isEmpty || body.contains('.')) return typed;
    next = '$typed.';
  } else {
    if (body.contains('.')) {
      // One decimal place.
      if (body.split('.')[1].isNotEmpty) return typed;
      next = '$typed$key';
    } else if (body.length >= 2) {
      next = '$typed.$key';
    } else {
      next = '$typed$key';
    }
  }
  final v = double.tryParse(next.replaceFirst('+', ''));
  if (v != null && v > kMaxIndex) return typed;
  return next;
}

/// What to put in the chip and the sheet for a STORED index (`-2.1` plays as
/// `+2.1`). Null/empty/unparseable is "no index yet".
String? indexLabel(String? stored) {
  final s = (stored ?? '').trim();
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null) return null;
  final txt = v.abs().toStringAsFixed(1);
  return v < 0 ? '+$txt' : txt;
}

/// The typed text as the string the server stores, or null when there is no
/// number yet.
String? storedFromTyped(String typed) {
  var t = typed.trim();
  if (t.isEmpty || t == '+' ) return null;
  final plus = t.startsWith('+');
  if (plus) t = t.substring(1);
  if (t.endsWith('.')) t = '${t}0';
  final v = double.tryParse(t);
  if (v == null) return null;
  return (plus ? -v : v).toStringAsFixed(1);
}
