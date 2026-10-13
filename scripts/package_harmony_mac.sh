#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
ARCH=${ARCH:-arm64}
swift build --package-path "$ROOT/MacHost" -c release --arch "$ARCH"
BIN=$(swift build --package-path "$ROOT/MacHost" -c release --arch "$ARCH" --show-bin-path)
APP="$ROOT/dist/Harmony Side Screen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HarmonyScreen" "$APP/Contents/MacOS/HarmonyScreen"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$APP/Contents/Resources/"
# Empty/unconfigured payment destinations never produce a support prompt.
python3 - "$ROOT/resources/SupportOffer.json" "$APP/Contents/Resources/SupportOffer.json" <<'PY'
import pathlib,sys,shutil
source,destination=map(pathlib.Path,sys.argv[1:])
if source.is_file(): shutil.copyfile(source,destination)
elif destination.exists(): destination.unlink()
PY
python3 - "$APP" "$VERSION" <<'PY'
import plistlib,sys,pathlib
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
d={'CFBundleExecutable':'HarmonyScreen','CFBundleIdentifier':'com.shonnli.harmonyscreen.mac','CFBundleName':'Harmony Side Screen','CFBundleDisplayName':'Harmony Side Screen','CFBundleVersion':sys.argv[2],'CFBundleShortVersionString':sys.argv[2],'CFBundlePackageType':'APPL','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSScreenCaptureUsageDescription':'Capture the virtual display and send it to your connected HarmonyOS device.','NSLocalNetworkUsageDescription':'Connect to a paired display on your local network.'}
p.write_bytes(plistlib.dumps(d))
PY
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Harmony Side Screen" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/HarmonySideScreen-$VERSION-mac-$ARCH.dmg"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --timestamp --sign "$SIGNING_IDENTITY" "$ROOT/dist/HarmonySideScreen-$VERSION-mac-$ARCH.dmg"
fi
