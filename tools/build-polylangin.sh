#!/bin/bash
# Build the Polylangin input method (Squirrel fork) into vendor/squirrel-master/build/Polylangin.app
# Usage: bash tools/build-polylangin.sh [--sign ID]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/squirrel-master"
APP="$SRC/build/app/Polylangin.app"
# Ad-hoc signing by default; set SIGN_ID to a Developer ID / Apple Development
# identity when building a distributable app.
SIGN_ID="${SIGN_ID:--}"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0)"
STOCK="/Library/Input Methods/Squirrel.app/Contents"

# The public source snapshot does not ship prebuilt librime binaries. When the
# local vendor directories are absent (fresh clone), reuse the official Squirrel
# installation for librime, its plugins and helper binaries.
LIB_DIR="$SRC/lib"
FRAMEWORKS_DIR="$SRC/Frameworks"
BIN_DIR="$SRC/bin"
if [ ! -f "$LIB_DIR/librime.1.dylib" ]; then
  if [ -f "$STOCK/Frameworks/librime.1.dylib" ]; then
    LIB_DIR="$STOCK/Frameworks"
    FRAMEWORKS_DIR="$STOCK/Frameworks"
    BIN_DIR="$STOCK/MacOS"
    echo "== using librime from stock Squirrel =="
  else
    echo "missing librime: install official Squirrel 1.1.2 or vendor the prebuilt libs" >&2
    exit 1
  fi
fi

if [ ! -d "$SRC/sources" ]; then
  echo "missing fork source: $SRC" >&2
  exit 1
fi

echo "== prepare =="
mkdir -p "$SRC/build/tmp" "$SRC/build/modulecache" "$SRC/build/app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks/rime-plugins" "$APP/Contents/SharedSupport"

echo "== compile Swift =="
export TMPDIR="$SRC/build/tmp"
xcrun swiftc -O -swift-version 5 -enable-bare-slash-regex \
  -target arm64-apple-macos14.0 -module-name Squirrel \
  -import-objc-header "$SRC/sources/Squirrel-Bridging-Header.h" \
  -I "$SRC/librime/src" -I "$SRC/librime/include" -F "$FRAMEWORKS_DIR" \
  -framework AppKit -framework InputMethodKit -framework Carbon -framework UserNotifications \
  -framework NaturalLanguage \
  -L "$LIB_DIR" -lrime.1 -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -module-cache-path "$SRC/build/modulecache" \
  -Xcc -fmodules-cache-path="$SRC/build/modulecache" \
  "$SRC"/sources/*.swift -o "$APP/Contents/MacOS/Polylangin"

echo "== helper binaries =="
cp -f "$BIN_DIR/rime_deployer" "$BIN_DIR/rime_dict_manager" "$APP/Contents/MacOS/"

echo "== frameworks =="
cp -f "$LIB_DIR/librime.1.dylib" "$APP/Contents/Frameworks/"
if [ -d "$LIB_DIR/rime-plugins" ]; then
  cp -f "$LIB_DIR/rime-plugins/"*.dylib "$APP/Contents/Frameworks/rime-plugins/"
else
  cp -f "$FRAMEWORKS_DIR/rime-plugins/"*.dylib "$APP/Contents/Frameworks/rime-plugins/"
fi

echo "== resources =="
cp -f "$SRC/resources/rime.pdf" "$APP/Contents/Resources/" 2>/dev/null || true
[ -f "$STOCK/Resources/Rime.icns" ] && cp -f "$STOCK/Resources/Rime.icns" "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/polylangin"
cp -R "$SRC/resources/polylangin" "$APP/Contents/Resources/"
for lproj in en zh-Hans zh-Hant; do
  if [ -d "$SRC/resources/$lproj.lproj" ]; then
    mkdir -p "$APP/Contents/Resources/$lproj.lproj"
    sed "s/@VERSION@/$VERSION/g" "$SRC/resources/$lproj.lproj/InfoPlist.strings" > "$APP/Contents/Resources/$lproj.lproj/InfoPlist.strings"
  fi
done

if [ ! -f "$APP/Contents/SharedSupport/default.yaml" ]; then
  echo "== SharedSupport (first build, ~74MB) =="
  cp -R "$STOCK/SharedSupport/." "$APP/Contents/SharedSupport/"
fi

echo "== Rime seed (self-contained user data) =="
SEED="$APP/Contents/Resources/RimeSeed"
rm -rf "$SEED"
mkdir -p "$SEED"
RIME_DATA="$ROOT/vendor/rime-ice-main"
if [ -d "$RIME_DATA" ]; then
  cp "$RIME_DATA"/*.yaml "$SEED"/ 2>/dev/null || true
  cp "$RIME_DATA"/*.txt "$SEED"/ 2>/dev/null || true
  for dir in cn_dicts en_dicts lua opencc others; do
    [ -d "$RIME_DATA/$dir" ] && cp -R "$RIME_DATA/$dir" "$SEED/"
  done
fi
cp "$ROOT/resources/rime-seed/rime_ice.custom.yaml" "$SEED/" 2>/dev/null || true
# Polylangin always uses a horizontal candidate bar (the rime-ice default is stacked).
if [ -f "$SEED/squirrel.yaml" ]; then
  sed -i '' 's/^  candidate_list_layout: stacked/  candidate_list_layout: linear/' "$SEED/squirrel.yaml" 2>/dev/null || true
fi

echo "== Info.plist =="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>Polylangin</string>
  <key>CFBundleIconFile</key><string>Rime</string>
  <key>CFBundleIconName</key><string>Rime</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleIdentifier</key><string>app.polylangin.inputmethod.Polylangin</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Polylangin</string>
  <key>CFBundleDisplayName</key><string>Polylangin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSBackgroundOnly</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>InputMethodConnectionName</key><string>Polylangin_Connection</string>
  <key>TISInputSourceID</key><string>app.polylangin.inputmethod.Polylangin</string>
  <key>TICapsLockLanguageSwitchCapable</key><true/>
  <key>InputMethodServerControllerClass</key><string>Squirrel.SquirrelInputController</string>
  <key>InputMethodServerDelegateClass</key><string>Squirrel.SquirrelInputController</string>
  <key>ComponentInputModeDict</key>
  <dict>
    <key>tsInputModeListKey</key>
    <dict>
      <key>app.polylangin.inputmethod.Polylangin.Hans</key>
      <dict>
        <key>TISInputSourceID</key><string>app.polylangin.inputmethod.Polylangin.Hans</string>
        <key>TISIntendedLanguage</key><string>zh-Hans</string>
        <key>tsInputModeAlternateMenuIconFileKey</key><string>rime.pdf</string>
        <key>tsInputModeCharacterRepertoireKey</key>
        <array><string>Hans</string><string>Hant</string></array>
        <key>tsInputModeDefaultStateKey</key><true/>
        <key>tsInputModeIsVisibleKey</key><true/>
        <key>tsInputModeKeyEquivalentModifiersKey</key><integer>4608</integer>
        <key>tsInputModeMenuIconFileKey</key><string>rime.pdf</string>
        <key>tsInputModePaletteIconFileKey</key><string>rime.pdf</string>
        <key>tsInputModePrimaryInScriptKey</key><true/>
        <key>tsInputModeScriptKey</key><string>smUnicodeScript</string>
      </dict>
      <key>app.polylangin.inputmethod.Polylangin.Hant</key>
      <dict>
        <key>TISInputSourceID</key><string>app.polylangin.inputmethod.Polylangin.Hant</string>
        <key>TISIntendedLanguage</key><string>zh-Hant</string>
        <key>tsInputModeAlternateMenuIconFileKey</key><string>rime.pdf</string>
        <key>tsInputModeCharacterRepertoireKey</key><array><string>Hant</string><string>Hans</string></array>
        <key>tsInputModeDefaultStateKey</key><false/>
        <key>tsInputModeIsVisibleKey</key><true/>
        <key>tsInputModeKeyEquivalentModifiersKey</key><integer>4608</integer>
        <key>tsInputModeMenuIconFileKey</key><string>rime.pdf</string>
        <key>tsInputModePaletteIconFileKey</key><string>rime.pdf</string>
        <key>tsInputModePrimaryInScriptKey</key><true/>
        <key>tsInputModeScriptKey</key><string>smUnicodeScript</string>
      </dict>
    </dict>
    <key>tsVisibleInputModeOrderedArrayKey</key>
    <array>
      <string>app.polylangin.inputmethod.Polylangin.Hans</string>
      <string>app.polylangin.inputmethod.Polylangin.Hant</string>
    </array>
  </dict>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== codesign (in /tmp: the workspace is file-provider managed and its xattrs break codesign) =="
SIGN_DIR="/tmp/polylangin-sign"
rm -rf "$SIGN_DIR"
mkdir -p "$SIGN_DIR"
ditto "$APP" "$SIGN_DIR/Polylangin.app"
SIGN_APP="$SIGN_DIR/Polylangin.app"
rm -rf "$SIGN_APP/Contents/_CodeSignature"
dot_clean "$SIGN_APP" 2>/dev/null || true
find "$SIGN_APP" -exec xattr -c {} \; 2>/dev/null || true
xattr -c "$SIGN_APP" 2>/dev/null || true
for f in "$SIGN_APP"/Contents/MacOS/rime_deployer "$SIGN_APP"/Contents/MacOS/rime_dict_manager \
         "$SIGN_APP"/Contents/Frameworks/librime.1.dylib \
         "$SIGN_APP"/Contents/Frameworks/rime-plugins/*.dylib; do
  [ -e "$f" ] && codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || true
done
codesign --force --sign "$SIGN_ID" --entitlements "$SRC/resources/Squirrel.entitlements" "$SIGN_APP" 2>&1 | head -3 || true
codesign --verify --deep "$SIGN_APP" 2>&1 | head -3 || true
rm -rf "$APP"
ditto "$SIGN_APP" "$APP"
codesign --verify "$APP" 2>&1 | head -2 || true
# Prefer the signed /tmp copy for the final artifact (the workspace copy may
# carry file-provider xattrs again after ditto).
if [ -d /tmp/polylangin-sign/Polylangin.app ]; then
  rm -rf "$APP"
  ditto /tmp/polylangin-sign/Polylangin.app "$APP"
fi

echo "== built: $APP =="
du -sh "$APP"
