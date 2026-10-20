#!/usr/bin/env bash
# Build the App Store IPA, and check the two things that have bitten us.
set -euo pipefail
cd "$(dirname "$0")"

# 1. Let the BUILD regenerate ios/Flutter/ephemeral, and never run
#    `flutter pub get` in between. `pub get` writes a generated Swift package
#    pinned to iOS 13.0, which then fails against firebase and halved-sms at
#    15.0; `flutter build` writes 15.0. Cost a build to find.
if [[ "${1:-}" != "--no-clean" ]]; then
  flutter clean
fi
rm -rf ios/Flutter/ephemeral

flutter build ipa

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
