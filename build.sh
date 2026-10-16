#!/bin/zsh
# Builds Daymare.app into build/.  `./build.sh install` also copies it to /Applications;
# `./build.sh test` runs the self-test (must say ALL PASSED).
set -euo pipefail
cd "${0:A:h}"

APP=build/Daymare.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

# Apple silicon and Intel, as one app.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 \
    -framework AppKit -framework AVFoundation -framework CoreMotion -framework MediaPlayer -framework AudioToolbox -framework CoreAudio \
    Sources/*.swift -o build/tmp/Daymare-$arch
done
lipo -create build/tmp/Daymare-arm64 build/tmp/Daymare-x86_64 -output "$APP/Contents/MacOS/Daymare"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/Sessions "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/"
[ -d Resources/Looks ] && cp -R Resources/Looks "$APP/Contents/Resources/"

# icon
swiftc -O tools/make-icon.swift -o build/tmp/make-icon
build/tmp/make-icon build/tmp/icon.png
ICONSET=build/tmp/AppIcon.iconset
mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s build/tmp/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/tmp/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/tmp

codesign --force --sign - "$APP"
echo "built $APP ($(du -sh $APP | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
  osascript -e 'quit app "Daymare"' 2>/dev/null || true
  rm -rf /Applications/Daymare.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
  echo "installed /Applications/Daymare.app"
fi

if [[ "${1:-}" == "test" ]]; then
  "$APP/Contents/MacOS/Daymare" --selftest
fi
