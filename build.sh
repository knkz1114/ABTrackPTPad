#!/bin/zsh
# Builds build/ABTrackPTPad.app with swiftc only (no Xcode project needed).
#
#   ./build.sh                          ad-hoc signature (macOS forgets permissions on every rebuild)
#   CODESIGN_IDENTITY=name ./build.sh   sign with a (self-signed) code-signing certificate instead
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ABTrackPTPad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling…"
swiftc -O -parse-as-library \
    -target arm64-apple-macosx14.0 \
    Sources/Engine/*.swift Sources/App/*.swift \
    -o "$APP/Contents/MacOS/ABTrackPTPad"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"

codesign -s "${CODESIGN_IDENTITY:--}" -i io.github.knkz1114.abtrackptpad -f "$APP"
echo "built $APP"
