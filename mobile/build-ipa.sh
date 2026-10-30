#!/usr/bin/env bash
# Build the App Store IPA, and check the two things that have bitten us.
set -euo pipefail
cd "$(dirname "$0")"

# 1. The generated Swift package is pinned to iOS 13.0 and has to be RAISED.
#
#    firebase-core, firebase-messaging and halved-sms all require 15.0, and
#    the Xcode project IS 15.0 — but the generated package declares
#    `.iOS("13.0")`, which is Flutter's default, and the archive then fails
#    Target Integrity.
#
#    This script twice tried to fix it by ORDERING: delete the package and let
#    something else write it. Neither order works, and the note here has been
#    wrong in both directions:
#
#      * rm then build            -> the build runs pub resolution itself and
#                                    re-creates the package at 13.0
#      * pub get, rm, then build  -> same thing.  Claimed the build "reads the
#                                    Xcode project and writes 15.0"; it does
#                                    not.  Cost build 57 to discover (27 Oct
#                                    2026).
#
#    So stop deleting it and EDIT it. Generate the package (pub get), raise
#    the platform in place, and build WITHOUT removing it — the build only
#    regenerates the package when it is absent or pub resolution is stale, so
#    an edited one survives.
#
#    Checked, not trusted: if the platform line is not where we expect, this
#    fails here rather than ten minutes into an archive.
if [[ "${1:-}" != "--no-clean" ]]; then
  flutter clean
  flutter pub get
fi

pkg="ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
if [[ ! -f "$pkg" ]]; then
  # --no-clean on a tree that has never been built.
  flutter pub get
fi
if [[ ! -f "$pkg" ]]; then
  echo "FAIL: $pkg was not generated — cannot raise its platform." >&2
  exit 1
fi
if grep -q '\.iOS("13' "$pkg"; then
  sed -i '' 's/\.iOS("13\.[0-9]*")/.iOS("15.0")/' "$pkg"
  echo "Raised the generated Swift package to iOS 15.0."
fi
if ! grep -q '\.iOS("15' "$pkg"; then
  echo "FAIL: the generated Swift package is not at iOS 15 and could not be" >&2
  echo "      raised — its platform line has changed shape:" >&2
  grep -A3 'platforms:' "$pkg" | sed 's/^/      /' >&2
  exit 1
fi

# 2. Build WITHOUT pub. Editing in place was the third answer and it is also
#    wrong on its own: `flutter build ipa` re-runs pub resolution after a
#    clean, which regenerates the package at 13.0 AFTER the edit above, and
#    the archive fails Target Integrity anyway. Build 58 (30 Oct 2026) failed
#    exactly that way with this script's "Raised" line in the log. `--no-pub`
#    is what keeps the edit: dependencies were resolved by the `pub get`
#    above, so there is nothing for the build to resolve.
flutter build ipa --no-pub

# Re-check AFTER the archive: if the build regenerated the package despite the
# above, this is where we find out, and the failure names the cause.
if [[ -f "$pkg" ]] && ! grep -q '\.iOS("15' "$pkg"; then
  echo
  echo "FAIL: the generated Swift package is not at iOS 15 —"
  grep -A2 'platforms:' "$pkg" | sed 's/^/      /'
  echo "      firebase and halved-sms need 15.0. See the note above on ORDER."
  exit 1
fi

app="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app"
plist="$app/Info.plist"
get() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

echo
fail=0

# 2. Both location purpose strings must be present, and the reason is not
#    bureaucratic.
#
#    Apple demands the ALWAYS string (ITMS-90683) because geolocator_apple
#    references `requestAlwaysAuthorization` in a branch — static analysis
#    sees the symbol whether or not we can reach it. Fine.
#
#    What makes shipping that string HONEST is the WHEN-IN-USE one, because
#    the plugin's handler is:
#
#        if   (NSLocationWhenInUseUsageDescription present) requestWhenInUse();
#        else if (containsLocationAlwaysDescription())      requestAlways();
#
#    an if/else if. While the when-in-use key is there the always branch is
#    dead and the background prompt can never appear. Remove it and the app
#    silently starts asking to track people in the background, contradicting
#    the privacy policy and the App Privacy answers in one go.
#
#    So the pair is the invariant, and it is checked here rather than trusted.
for key in NSLocationWhenInUseUsageDescription \
           NSLocationAlwaysAndWhenInUseUsageDescription; do
  if [[ -z "$(get "$key")" ]]; then
    echo "FAIL: $plist is missing $key"
    [[ "$key" == NSLocationWhenInUseUsageDescription ]] && \
      echo "      Without it the app would request ALWAYS authorisation."
    fail=1
  fi
done

# 3. Background location must never be declared. The policy says the app
#    "never reads your location in the background"; this is that sentence,
#    checked.
if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$plist" 2>/dev/null \
     | grep -qi location; then
  echo "FAIL: UIBackgroundModes declares location."
  fail=1
fi

[[ $fail -eq 0 ]] || exit 1
echo "OK: when-in-use + always strings present, no background location mode."
ls -la build/ios/ipa/*.ipa
