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
raise_pkg() {
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
}
raise_pkg

# 2. Build WITHOUT pub. Editing in place was the third answer and it is also
#    wrong on its own: `flutter build ipa` re-runs pub resolution after a
#    clean, which regenerates the package at 13.0 AFTER the edit above, and
#    the archive fails Target Integrity anyway. Build 58 (30 Oct 2026) failed
#    exactly that way with this script's "Raised" line in the log. `--no-pub`
#    is what keeps the edit: dependencies were resolved by the `pub get`
#    above, so there is nothing for the build to resolve.
# Clear the export directory BEFORE building. `flutter clean` does this for
# us, but `--no-clean` does not — and a failed export then leaves the PREVIOUS
# release's IPA sitting in the folder you drag into Transporter. Removing it
# first means a broken run leaves nothing to upload by mistake, which is the
# same reason `website/build-zip.sh` removes `dist/` before it builds rather
# than after.
rm -rf build/ios/ipa

# 4. The fourth way this fails, and the first that is not this script's
#    doing (2.14.1+63, 10 Nov 2026 — three failed archives in one evening).
#    The package was raised to 15.0, the build ran with --no-pub, and Xcode
#    still archived it at 13.0: a SECOND `pub get` ran while the archive was
#    starting and regenerated it. `pubspec.lock` moves during the build,
#    which `--no-pub` never does on its own.
#
#    It follows a change the IDE can see — `flutter clean` wiping
#    `.dart_tool`, or `pubspec.yaml` being edited for the version bump — by
#    up to forty seconds, which is long enough to land inside the archive.
#    VS Code was open with the Dart extension's `flutter daemon` running;
#    that is the likely author, inferred from timestamps rather than caught.
#    Both times the same tree built first try once the lockfile had settled.
#
#    Nothing here can stop another process running pub, so the script does
#    what a person would: raise the package again and build once more. By
#    then the stray fetch has happened and there is nothing left to trigger
#    another. One retry only — a second failure is something else.
for attempt in 1 2; do
  lock_before="$(stat -f %m pubspec.lock 2>/dev/null || echo 0)"
  if flutter build ipa --no-pub; then
    break
  fi
  lock_after="$(stat -f %m pubspec.lock 2>/dev/null || echo 0)"
  echo
  if [[ "$attempt" == 1 ]] && grep -q '\.iOS("13' "$pkg" 2>/dev/null \
       && [[ "$lock_after" != "$lock_before" ]]; then
    echo "The generated Swift package went back to iOS 13 DURING the build:"
    echo "pubspec.lock changed while it ran, so something else ran \`pub get\`"
    echo "(most likely an open IDE). Raising it again and building once more."
    echo
    raise_pkg
    rm -rf build/ios/ipa
    continue
  fi
  if grep -q '\.iOS("13' "$pkg" 2>/dev/null; then
    echo "FAIL: the generated Swift package is at iOS 13 after the build."
    echo "      Close the IDE and run:   ./build-ipa.sh --no-clean"
  fi
  exit 1
done

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

# 4. The IPA that came out is the version that went in.
#
#    Two ways it can fail to be, and neither looks like a failure:
#
#      * the export did not run at all (signing is Xcode CLOUD-MANAGED — there
#        is no distribution certificate in the login keychain — so a shell with
#        no Xcode account session archives fine and exports nothing);
#      * `manageAppVersionAndBuildNumber` is true in the export options, so the
#        build number is not ours to assume.
#
#    Read it out of the artifact rather than from `DistributionSummary.plist`
#    beside it: the IPA is what Transporter uploads, and a sidecar describing
#    it is one remove from the thing.
want=$(grep '^version:' pubspec.yaml | sed 's/^version:[[:space:]]*//')
want_short="${want%%+*}"
want_build="${want##*+}"

shopt -s nullglob
ipas=(build/ios/ipa/*.ipa)
if [[ ${#ipas[@]} -eq 0 ]]; then
  echo "FAIL: no IPA in build/ios/ipa — the archive built and the export did"
  echo "      not run. Signing here is Xcode cloud-managed, so the export"
  echo "      needs Xcode signed in to the developer account: run this from"
  echo "      your own Terminal, or distribute"
  echo "      build/ios/archive/Runner.xcarchive from Xcode's Organizer."
  exit 1
elif [[ ${#ipas[@]} -gt 1 ]]; then
  echo "FAIL: ${#ipas[@]} IPAs in build/ios/ipa — cannot say which is this"
  echo "      build. Remove the directory and run again."
  printf '      %s\n' "${ipas[@]}"
  exit 1
fi
ipa="${ipas[0]}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -o -q "$ipa" 'Payload/*.app/Info.plist' -d "$tmp"
inner=$(find "$tmp/Payload" -maxdepth 2 -name Info.plist | head -1)
if [[ -z "$inner" ]]; then
  echo "FAIL: no Payload/*.app/Info.plist inside $ipa"
  exit 1
fi
got_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$inner")
got_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$inner")
if [[ "$got_short" != "$want_short" || "$got_build" != "$want_build" ]]; then
  echo "FAIL: $ipa is $got_short+$got_build, pubspec says $want_short+$want_build."
  echo "      Do not upload it. Either the export failed and this is an older"
  echo "      release, or App Store Connect renumbered the build."
  exit 1
fi

[[ $fail -eq 0 ]] || exit 1
echo "OK: when-in-use + always strings present, no background location mode."
echo "OK: $(basename "$ipa") is $got_short ($got_build) — ready for Transporter."
ls -la "$ipa"
