/// utils/handicap_rounding.dart
/// ---------------------------
/// Rounding primitive shared by every handicap calculation on the client.
///
/// Dart's `num.round()` rounds half AWAY FROM ZERO, while Python's built-in
/// `round()` — which the backend used to call — is banker's rounding. The two
/// disagreed on any exact .5: a course handicap of 28.5 became 29 here and 28
/// on the server, and 90% of a 5-stroke strokes-off differential (4.5) became
/// 5 here and 4 there.
///
/// WHS Rule 6.1 says "0.5 or above is rounded upward", so both platforms now
/// use floor(x + 0.5). This is the exact counterpart of `round_half_up()` in
/// `core/handicap_math.py`; change one and you must change the other.
library;

int roundHalfUp(num value) => (value + 0.5).floor();
