#!/bin/zsh
# Build SwiftXR Shell in release mode and install it as an app bundle.
#
# Usage: scripts/make-app.zsh [DESTINATION_DIR]   (default /Applications)
#
# Environment:
#   SIGN_IDENTITY  codesign identity (default "-", ad hoc). A stable identity
#                  such as "Apple Development: …" keeps Screen Recording and
#                  Accessibility permissions across rebuilds; ad hoc signing
#                  changes on every build, so macOS may ask again.
#   BUNDLE_ID      bundle identifier (default com.nickkennedy.swiftxr-shell)
#
# The app loads libopenxr_loader.dylib from /usr/local/lib, as `swift run` does,
# and finds the OpenXR runtime from the GUI environment (XR_RUNTIME_JSON set by
# launchctl) or /usr/local/share/openxr/1/active_runtime.json.
set -euo pipefail

repo=${0:A:h:h}
destination=${1:-/Applications}
name="SwiftXR Shell"
executable=swiftxr-shell
bundle_id=${BUNDLE_ID:-com.nickkennedy.swiftxr-shell}
identity=${SIGN_IDENTITY:--}

cd "$repo"

if [[ ! -d $destination ]]; then
  print -u2 "Destination folder does not exist: $destination"
  exit 1
fi

swift build -c release --product "$executable"
binary=$(swift build -c release --show-bin-path)/$executable

version=$(git describe --tags --always --dirty 2>/dev/null || print 0)
build=$(git rev-list --count HEAD 2>/dev/null || print 1)

# Assemble next to the destination, then swap it in, so a failed build or
# signing never leaves a half-written app behind.
staging=$(mktemp -d "$destination/.${executable}.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$executable"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
plutil -lint -s "$app/Contents/Info.plist"

codesign --force --sign "$identity" --identifier "$bundle_id" "$app"
codesign --verify --strict "$app"

target="$destination/$name.app"
rm -rf "$target"
mv "$app" "$target"
print "Installed $target ($version, build $build, signed: $identity)"
