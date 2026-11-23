#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(grep '^APP=' build.sh | head -1 | cut -d'"' -f2)"
if [[ -z "$APP" ]]; then
  APP="$(basename "$(pwd)")"
fi
VERSION="$(grep '^VERSION=' build.sh | head -1 | cut -d'"' -f2)"
PROFILE="sashay-notary"

echo "▸ Zipping $APP for submission…"
rm -f "build/$APP-$VERSION-notary.zip"
ditto -c -k --keepParent "$APP.app" "build/$APP-$VERSION-notary.zip"

echo "▸ Submitting $APP to Apple — waits for approval (usually 2–15 min)…"
xcrun notarytool submit "build/$APP-$VERSION-notary.zip" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling ticket…"
xcrun stapler staple "$APP.app"
xcrun stapler validate "$APP.app"

echo "▸ Packing distributable…"
rm -f "build/$APP-$VERSION.zip"
ditto -c -k --keepParent "$APP.app" "build/$APP-$VERSION.zip"

echo "✓ Notarized + stapled: build/$APP-$VERSION.zip"
