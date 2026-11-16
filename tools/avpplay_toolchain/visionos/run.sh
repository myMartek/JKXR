#!/bin/sh
# run.sh device: build JKXR from this repository and install it on the player's Vision Pro, the way AVP Play
# (github.com/myMartek/avp-play) asks a toolchain to (its docs/recipes.md, "A toolchain of the game's own").
#
# AVP Play's side of the contract (core/Sources/AVPPlayCore/Toolchain.swift, buildAndInstall):
#   it runs `visionos/run.sh device` in this toolchain folder with PATH=/usr/bin:/bin:/usr/sbin:/sbin and
#     KLEPTON_TARGET     jkxr-outcast or jkxr-academy: one app per game (targets.py)
#     KLEPTON_TEAM       the player's Apple Developer Team ID (10 characters; a free team works, see KLEPTON_EVA)
#     KLEPTON_DEVICE     the Vision Pro's CoreDevice identifier
#     KLEPTON_BUNDLE_ID  the app's bundle id (optional: targets.py's `bundle`)
#     KLEPTON_APP_VERSION / KLEPTON_APP_BUILD   CFBundleShortVersionString / CFBundleVersion (optional)
#     KLEPTON_DISPLAY_OVERRIDE / KLEPTON_DISPLAY_SUFFIX   the app's name (optional)
#     KLEPTON_EVA=0      a free team: leave out the extended-virtual-addressing entitlement. JKXR never asks for
#                        it, so there is nothing to leave out
#     KL_SKIP_STAGE=1    AVP Play copies the game data itself afterwards
#   and it takes exit status 0 together with the line BUILD SUCCEEDED as success. A line starting with
#   `!! install FAILED:` means built but not installed; `!! signing:` a signing problem; anything else a build failure.
#   It then reads the built app's Info.plist and embedded.mobileprovision from
#   visionos/build/dd-device-<target>/Build/Products/Debug-xros/*.app.
#
# What this script does with that: prepare-visionos.sh (gl4es, the engines of both games, the partial link, the
# Xcode project), then xcodebuild with the player's team and bundle id, then devicectl. The first run takes about
# 45 minutes; a later one rebuilds only what changed.
#
# The games' data never pass through here. They are the recipe's data trees: AVP Play fetches them from the
# player's own Steam purchases and copies them to Documents/JediOutcast and Documents/JediAcademy (stage_sync.py
# says more). Nothing of the games leaves the player's Mac except to their own headset.
set -u

say() { printf '%s\n' "$*"; }
die() { say "!! build FAILED: $*"; exit 1; }

[ "${1:-}" = device ] || { say "usage: run.sh device   (see the comment at the top of this file)"; exit 2; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../../.." && pwd)
PY=/usr/bin/python3
[ -x "$PY" ] || die "no Python at $PY (it comes with Xcode's command line tools)"
[ -f "$REPO/prepare-visionos.sh" ] || die "this folder is not inside a JKXR checkout (no prepare-visionos.sh in $REPO)"

# make and the build tools cmake drives do not survive a blank in a path.
case "$REPO" in *" "*) die "this toolchain's folder has a blank in its path ($REPO); the build tools cannot work there. Move it to a path without blanks";; esac

TARGET=${KLEPTON_TARGET:-}
GAME=$("$PY" "$HERE/targets.py" "$TARGET" game) || die "this toolchain builds jkxr-outcast and jkxr-academy, not '$TARGET'"
TEAM=${KLEPTON_TEAM:-}
[ ${#TEAM} -eq 10 ] || die "KLEPTON_TEAM is not set to a 10-character Apple Developer Team ID"
case "$TEAM" in *[!A-Z0-9]*) die "KLEPTON_TEAM is not a Team ID ('$TEAM')";; esac
DEVICE=${KLEPTON_DEVICE:-}
[ -n "$DEVICE" ] || { say "!! no physical Vision Pro: KLEPTON_DEVICE is not set"; exit 1; }

BUNDLE=${KLEPTON_BUNDLE_ID:-$("$PY" "$HERE/targets.py" "$TARGET" bundle)}
[ -n "$BUNDLE" ] || die "no bundle id"
case "$BUNDLE" in *[!A-Za-z0-9.-]*) die "the bundle id has characters a bundle id cannot carry ('$BUNDLE')";; esac
NAME="${KLEPTON_DISPLAY_OVERRIDE:-$("$PY" "$HERE/targets.py" "$TARGET" display)}${KLEPTON_DISPLAY_SUFFIX:-}"
for V in "${KLEPTON_APP_VERSION:-}" "${KLEPTON_APP_BUILD:-}"; do
  case "$V" in *[!A-Za-z0-9.+-]*) die "the app version or build stamp has characters a build setting cannot carry ('$V')";; esac
done

# --- Tools ----------------------------------------------------------------------------------------------------
#
# prepare-visionos.sh needs cmake and xcodegen; Xcode brings neither. Homebrew's are used when they are there.
# Otherwise each is downloaded once from its own project's releases, checked against a SHA-256 written here, and
# kept beside the build (build-visionos/ is git-ignored). So the build uses the same tools on every Mac.
TOOLS="$REPO/build-visionos/avpplay-tools"

fetch_checked() {   # <url> <sha256> <file>
  curl --proto '=https' --tlsv1.2 -fsSL -o "$3" "$1" || return 1
  GOT=$(shasum -a 256 "$3" | cut -d' ' -f1)
  [ "$GOT" = "$2" ] && return 0
  rm -f "$3"
  say "   (expected sha256 $2, got $GOT)"
  return 1
}

# Kitware's release; the checksum is the one Kitware publishes in cmake-4.3.3-SHA-256.txt.
CMAKE_VERSION=4.3.3
CMAKE_SHA256=5221a13450c7a0219a2a0d1b6c9085eb06489721fafd8488ccebc1584175d2fb
CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz
find_cmake() {
  for d in /opt/homebrew/bin /usr/local/bin "$TOOLS/cmake-$CMAKE_VERSION-macos-universal/CMake.app/Contents/bin"; do
    [ -x "$d/cmake" ] && { CMAKE_DIR=$d; return 0; }
  done
  return 1
}
if ! find_cmake; then
  say "== $TARGET: downloading cmake $CMAKE_VERSION (github.com/Kitware/CMake, BSD-3-Clause)"
  mkdir -p "$TOOLS" || die "cannot create $TOOLS"
  fetch_checked "$CMAKE_URL" "$CMAKE_SHA256" "$TOOLS/cmake.tar.gz" || die "downloading cmake failed (no internet connection, or not the expected file)"
  tar -xzf "$TOOLS/cmake.tar.gz" -C "$TOOLS" && rm -f "$TOOLS/cmake.tar.gz" || die "unpacking cmake failed"
  find_cmake || die "cmake is not where its archive should have put it"
fi

# The same xcodegen release, with the same checksum, as the Skyrim VR toolchain uses.
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCODEGEN_URL=https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip
find_xcodegen() {
  for d in /opt/homebrew/bin /usr/local/bin "$TOOLS/xcodegen/bin"; do
    [ -x "$d/xcodegen" ] && { XCODEGEN_DIR=$d; return 0; }
  done
  return 1
}
if ! find_xcodegen; then
  say "== $TARGET: downloading xcodegen $XCODEGEN_VERSION (github.com/yonaskolb/XcodeGen, MIT)"
  mkdir -p "$TOOLS" || die "cannot create $TOOLS"
  fetch_checked "$XCODEGEN_URL" "$XCODEGEN_SHA256" "$TOOLS/xcodegen.zip" || die "downloading xcodegen failed (no internet connection, or not the expected file)"
  rm -rf "$TOOLS/xcodegen" && ditto -x -k "$TOOLS/xcodegen.zip" "$TOOLS" && rm -f "$TOOLS/xcodegen.zip" || die "unpacking xcodegen failed"
  find_xcodegen || die "xcodegen is not where its archive should have put it ($TOOLS/xcodegen/bin)"
fi

PATH="/usr/bin:/bin:/usr/sbin:/sbin:$CMAKE_DIR:$XCODEGEN_DIR"; export PATH

# --- Build ----------------------------------------------------------------------------------------------------
say "== $TARGET: game $GAME, bundle $BUNDLE, team $TEAM, name '$NAME'"
T0=$(date +%s)
mkdir -p "$HERE/build" || die "cannot create $HERE/build"

# The start picture AVP Play chose for this game (the player's own: a custom image, or the art of their Steam
# library) goes into the folder project.yml copies into the app (Generated/, git-ignored but for a placeholder).
# Written anew each time, so that a changed or withdrawn picture reaches the app, and so that the
# other game's picture never stays (both targets build in the same checkout). No picture: none in the app.
GEN="$REPO/visionos/App/Generated"
HERO="$HERE/Assets.xcassets/StartHero-$TARGET.imageset/hero.png"
mkdir -p "$GEN" && rm -f "$GEN/StartHero.png" || die "cannot prepare $GEN"
if [ -f "$HERO" ]; then cp "$HERO" "$GEN/StartHero.png" || die "cannot copy the start picture"; say "== $TARGET: start picture from AVP Play"; fi
# Xcode copies a folder reference when the folder's own date changes, not when a file in it does.
touch "$GEN"

# The game's icon, as AVP Play made it (a custom image, the Steam library's, or the game's own icon from Steam) in
# three layers. It goes into an asset catalog of its own that is checked in empty (Spielicon.xcassets) and is made
# the app icon on the command line; without one the app keeps JKXR's icon. Anew each time, as the picture above.
ICONSET="$HERE/Assets.xcassets/AppIcon-$TARGET.solidimagestack"
ICONCAT="$REPO/visionos/App/Sources/Resources/Spielicon.xcassets"
rm -rf "$ICONCAT/AppIconAVP.solidimagestack" || die "cannot prepare $ICONCAT"
ICONARG=""
if [ -d "$ICONSET" ]; then
  cp -R "$ICONSET" "$ICONCAT/AppIconAVP.solidimagestack" || die "cannot copy the icon"
  ICONARG="ASSETCATALOG_COMPILER_APPICON_NAME=AppIconAVP"
  say "== $TARGET: icon from AVP Play"
fi

# Both games' engines, the partially linked objects the app is made from, and the Xcode project. prepare skips gl4es
# when it is built, and cmake rebuilds only what changed, so the second game's build is quick.
say "== $TARGET: building the engines of both games (the first time about 45 minutes) ..."
/bin/bash "$REPO/prepare-visionos.sh" || die "prepare-visionos.sh failed (see the output above)"

# The project in visionos/App carries the maintainer's team and bundle id; the player's replace them here, on the
# command line, so nothing in the checkout changes.
DD="$HERE/build/dd-device-$TARGET"
LOG="$HERE/build/xcodebuild-$TARGET.log"
set -- -project "$REPO/visionos/App/JKXR.xcodeproj" -scheme JKXR -configuration Debug \
  -destination "generic/platform=visionOS" -derivedDataPath "$DD" -allowProvisioningUpdates \
  "DEVELOPMENT_TEAM=$TEAM" "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE" CODE_SIGN_STYLE=Automatic \
  "INFOPLIST_KEY_CFBundleDisplayName=$NAME" "JKXR_GAME=$GAME"
[ -z "$ICONARG" ] || set -- "$@" "$ICONARG"
[ -z "${KLEPTON_APP_VERSION:-}" ] || set -- "$@" "MARKETING_VERSION=$KLEPTON_APP_VERSION"
[ -z "${KLEPTON_APP_BUILD:-}" ] || set -- "$@" "CURRENT_PROJECT_VERSION=$KLEPTON_APP_BUILD"

# xcodebuild's own "** BUILD SUCCEEDED **" goes to the log, not to AVP Play: that line means success only at the
# very end, after the install.
say "== $TARGET: building the app ..."
if ! xcodebuild "$@" build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20
  SIGN=$(grep -iE "provisioning profile|signing certificate|No Account for Team|requires a development team|Signing for \"" "$LOG" | head -1 | cut -c1-200)
  [ -z "$SIGN" ] || { say "!! signing: $SIGN"; exit 1; }
  die "xcodebuild failed (the whole log: $LOG)"
fi

APP="$DD/Build/Products/Debug-xros/JKXR.app"
[ -f "$APP/Info.plist" ] || die "no usable app at $APP"
[ -f "$APP/embedded.mobileprovision" ] || { say "!! signing: the app was built without a provisioning profile"; exit 1; }

# --- Install --------------------------------------------------------------------------------------------------
say "== $TARGET: installing on the Vision Pro ..."
INSTALL_LOG="$HERE/build/install-$TARGET.log"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" > "$INSTALL_LOG" 2>&1; then
  cat "$INSTALL_LOG"
  say "!! install FAILED: $(grep -iE 'error|failed' "$INSTALL_LOG" | tail -1 | cut -c1-200)"
  exit 1
fi
grep -E 'bundleID|installationURL' "$INSTALL_LOG" || true

if [ "${KL_SKIP_STAGE:-0}" != 1 ]; then
  say "== $TARGET: the game data are not copied by this script. Through AVP Play they arrive by themselves; by hand,"
  say "   put them in with the Files app: Documents/JediOutcast/base and Documents/JediAcademy/base"
fi

say "== $TARGET: built and installed in $(( $(date +%s) - T0 )) s"
say "** BUILD SUCCEEDED **"
