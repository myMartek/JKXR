#!/usr/bin/env bash
#
# Baut openal-soft für visionOS.
#
# JKXR liefert unter SupportLibs/openal eine openal-soft von etwa 2012 mit. Ihr
# CoreAudio-Backend nutzt den Component Manager (ComponentDescription,
# AudioDeviceID, kAudioDeviceUnknown) — APIs des klassischen macOS, die es auf
# iOS-Familie-Plattformen nie gab. Ihre config.h ist außerdem von Hand für
# 32-Bit-Android geschrieben, inklusive SIZEOF_LONG 4.
#
# Ein System-OpenAL gibt es im XROS-SDK nicht, also muss es aus Quellen kommen.
# Gebaut wird derselbe Stand, der sich im Nachbarprojekt PocketSim bewährt hat.
#
# Warum das die Mühe wert ist: OpenJKs snd_dma.cpp bringt hinter USE_OPENAL
# einen vollständigen OpenAL-Pfad mit. Ihn zu aktivieren ist erheblich weniger
# Arbeit, als ein eigenes Audio-Backend für die Plattformschicht zu schreiben.
#
# Aufruf:  ./build-openal-visionos.sh [--clean]

set -euo pipefail

VERSION="1.24.3"
REPO="https://github.com/kcat/openal-soft.git"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/build-visionos/openal-src"
BUILD="$HERE/build-visionos/openal"
OUT="$HERE/build-visionos/openal-out"

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$BUILD" "$OUT"
fi

if [ ! -d "$SRC/.git" ]; then
    echo "== openal-soft $VERSION holen"
    git clone --depth 1 --branch "$VERSION" "$REPO" "$SRC"
else
    echo "== openal-soft bereits vorhanden ($(git -C "$SRC" describe --tags --always))"
fi

# Auch die aktuelle openal-soft kennt visionOS noch nicht: ihre CoreAudio-
# Plattformweiche fragt TARGET_OS_IOS || TARGET_OS_TV ab, die auf visionOS beide
# 0 sind, und landet damit im macOS-Zweig samt IOKit-Header. Ein Patch, ein Ort.
echo "== visionOS-Patch anwenden"
"$HERE/patch-openal-visionos.py"

echo "== konfigurieren für xros/arm64"
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT=xros \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 \
    -DCMAKE_INSTALL_PREFIX="$OUT" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBTYPE=STATIC \
    -DALSOFT_BACKEND_COREAUDIO=ON \
    -DALSOFT_BACKEND_PIPEWIRE=OFF \
    -DALSOFT_BACKEND_PULSEAUDIO=OFF \
    -DALSOFT_BACKEND_ALSA=OFF \
    -DALSOFT_BACKEND_OSS=OFF \
    -DALSOFT_BACKEND_PORTAUDIO=OFF \
    -DALSOFT_BACKEND_JACK=OFF \
    -DALSOFT_BACKEND_SNDIO=OFF \
    -DALSOFT_BACKEND_WAVE=OFF \
    -DALSOFT_EXAMPLES=OFF \
    -DALSOFT_UTILS=OFF \
    -DALSOFT_TESTS=OFF \
    -DALSOFT_INSTALL_EXAMPLES=OFF \
    -DALSOFT_INSTALL_UTILS=OFF

echo "== bauen"
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"

echo "== installieren nach $OUT"
cmake --install "$BUILD"

LIB="$(find "$OUT" -name 'libopenal*.a' | head -1)"
if [ -z "$LIB" ]; then
    echo "FEHLER: keine statische Bibliothek erzeugt"
    exit 1
fi

echo
echo "Ergebnis: $LIB"
lipo -archs "$LIB"
otool -l "$LIB" 2>/dev/null | grep -A2 LC_BUILD_VERSION | grep -E "platform|minos" | head -2
