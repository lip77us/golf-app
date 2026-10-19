/// Cutting a device position down before it leaves the phone.
///
/// Pure and dependency-free so both the API client and the location fetch
/// share ONE statement of the rule — the guarantee is worth nothing if two
/// call sites each round in their own way.
library;

/// Decimal places a position is cut to before it is sent anywhere.
///
/// Two, which is about 1.1 km of latitude, and the number is a **privacy**
/// decision rather than a precision one. Apple defines its App Privacy label
/// by the resolution of what an app transmits — three or more decimal places
/// is *Precise Location* — and CoreLocation hands back full float precision
/// whatever accuracy it authorised. So asking iOS for reduced accuracy is not
/// on its own enough to earn the Coarse Location declaration; this is.
///
/// `docs/location-permission.md` carries the whole argument, including why
/// the distance is then shown in whole miles.
const int kCoarseDecimals = 2;

/// `degrees` as the string to put in a request — never more than
/// [kCoarseDecimals] places.
///
/// Returns a **String**, deliberately. A double cannot carry the guarantee:
/// `double.parse('36.57')` is a value somebody can go on to format with more
/// places, where a string that has already been cut cannot grow them back.
/// This is the last point at which the full-precision fix exists.
String coarsenForPrivacy(double degrees) =>
    degrees.toStringAsFixed(kCoarseDecimals);
