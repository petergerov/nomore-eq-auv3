#!/bin/zsh
# Builds a macOS installer package for NoMore EQ: "NoMore EQ.app" (with the
# AUv3 extension inside) goes to /Applications, and a postinstall step
# registers the Audio Unit for the logged-in user.
#
#   scripts/make-pkg.sh
#
# Configuration is read from .env in the repo root (copy .env.example), and
# variables already set in the environment take precedence over it.
#
# Required:
#   TEAM_ID           Apple Developer team ID used for Developer ID export
#   BUNDLE_ID_PREFIX  reverse-DNS prefix, e.g. com.example
# Optional:
#   PKG_ID            package identifier (default: $BUNDLE_ID_PREFIX.nomoreeq.pkg)
#   NOTARY_PROFILE    notarytool keychain profile; when set, the app and the pkg are
#                     notarized and stapled. Create one with:
#                     xcrun notarytool store-credentials <name> --apple-id … --team-id <TEAM_ID>
#   INSTALLER_ID      pkg signing identity (default: first "Developer ID Installer" found)
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

CONFIG_VARS=(TEAM_ID BUNDLE_ID_PREFIX PKG_ID NOTARY_PROFILE INSTALLER_ID)
if [[ -f .env ]]; then
  typeset -A preset
  for var in $CONFIG_VARS; do
    [[ -n ${(P)var:-} ]] && preset[$var]=${(P)var}
  done
  set -a; source ./.env; set +a
  for var value in ${(kv)preset}; do
    typeset -gx $var=$value
  done
fi

: ${TEAM_ID:?set TEAM_ID in .env (see .env.example)}
: ${BUNDLE_ID_PREFIX:?set BUNDLE_ID_PREFIX in .env (see .env.example)}

TEAM=$TEAM_ID
APP_NAME="NoMore EQ"
PKG_NAME=NoMoreEQ
PKG_ID=${PKG_ID:-$BUNDLE_ID_PREFIX.nomoreeq.pkg}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)
OUT=build/pkg
ARCHIVE=$OUT/$PKG_NAME.xcarchive
EXPORT=$OUT/export
PAYLOAD=$OUT/payload
PKG=$OUT/$PKG_NAME-$VERSION.pkg

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Generating Xcode project"
xcodegen generate --quiet

echo "==> Archiving $APP_NAME $VERSION (Release, macOS)"
xcodebuild archive \
  -project NoMoreEQ.xcodeproj \
  -scheme NoMoreEQ_macOS \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  -quiet

echo "==> Exporting with Developer ID signing"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -quiet

APP=$EXPORT/$APP_NAME.app
codesign --verify --deep --strict "$APP"

if [[ -n ${NOTARY_PROFILE:-} ]]; then
  echo "==> Notarizing app"
  ditto -c -k --keepParent "$APP" "$OUT/$PKG_NAME.zip"
  xcrun notarytool submit "$OUT/$PKG_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "==> Building package"
mkdir -p "$PAYLOAD/Applications"
ditto "$APP" "$PAYLOAD/Applications/$APP_NAME.app"

# Keep the app at /Applications even if a copy exists elsewhere.
pkgbuild --analyze --root "$PAYLOAD" "$OUT/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$OUT/components.plist"

pkgbuild \
  --root "$PAYLOAD" \
  --component-plist "$OUT/components.plist" \
  --scripts packaging/scripts \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location / \
  "$OUT/component.pkg"

sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@PKG_ID@/$PKG_ID/g" \
    -e "s/@ORGANIZATION@/$BUNDLE_ID_PREFIX/g" \
    packaging/distribution.xml > "$OUT/distribution.xml"

INSTALLER_ID=${INSTALLER_ID:-$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)}
SIGN_ARGS=()
if [[ -n $INSTALLER_ID ]]; then
  SIGN_ARGS=(--sign "$INSTALLER_ID" --timestamp)
else
  echo "warning: no Developer ID Installer identity found, so the package will be unsigned" >&2
fi

productbuild \
  --distribution "$OUT/distribution.xml" \
  --package-path "$OUT" \
  "${SIGN_ARGS[@]}" \
  "$PKG"

if [[ -n ${NOTARY_PROFILE:-} && -n $INSTALLER_ID ]]; then
  echo "==> Notarizing package"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

echo "==> Done: $PKG"
