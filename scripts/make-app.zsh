#!/bin/zsh
# Build SwiftXR Shell in release mode and install it as an app bundle.
#
# Usage: scripts/make-app.zsh [DESTINATION_DIR]   (default /Applications)
#
# Environment:
#   SIGN_IDENTITY  codesign identity, or "-" for ad hoc. By default the one
#                  valid "Apple Development" identity in the keychain, else ad
#                  hoc. A stable identity keeps Screen Recording and
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
icon_source="$repo/Resources/AppIcon.png"

# The single valid Apple Development identity's SHA-1, or nothing when there
# are none or several (then the choice is the user's, via SIGN_IDENTITY).
apple_development_identity() {
  local -a hashes
  hashes=(${(f)"$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development: / { print $2 }')"})
  (( ${#hashes} == 1 )) && print -r -- $hashes[1]
}

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  identity=$SIGN_IDENTITY
elif identity=$(apple_development_identity) && [[ -n $identity ]]; then
  print "Signing with Apple Development identity $identity"
else
  identity=-
  print "No single Apple Development identity found; signing ad hoc (set SIGN_IDENTITY to choose)"
fi

cd "$repo"

if [[ ! -d $destination ]]; then
  print -u2 "Destination folder does not exist: $destination"
  exit 1
fi
if [[ ! -f $icon_source ]]; then
  print -u2 "App icon source is missing: $icon_source"
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

# Build every standard macOS icon size from the checked-in 1024px artwork.
# Keep intermediates inside staging so failures are cleaned up by the trap.
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$icon_source" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
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

# Register the final path after the swap. Apps/Finder may otherwise retain the
# generic icon from an earlier installation, especially when the version is
# unchanged. Touching the bundle also signals the replacement to file watchers.
touch "$target"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x $lsregister ]]; then
  if ! "$lsregister" -f "$target"; then
    print -u2 "Warning: macOS app registration could not be refreshed for $target"
  fi
fi
print "Installed $target ($version, build $build, signed: $identity)"
