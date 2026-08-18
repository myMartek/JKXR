#!/usr/bin/env bash
#
# Alles, was existieren muss, bevor fastlane archivieren kann.
#
# Xcode allein baut dieses Projekt nicht. Die Engine ist C++ und wird von CMake
# uebersetzt, aus ihren Modulen macht link-visionos.sh Teil-Link-Objekte, und
# erst die traegt project.yml als OTHER_LDFLAGS in ein Xcode-Projekt ein, das
# xcodegen ebenfalls erst erzeugen muss. Vier Schritte also, und keiner davon
# steht in der .xcodeproj -- sie ist selbst eines der Ergebnisse.
#
# Auf einem Runner mit leerem Arbeitsverzeichnis laeuft das vollstaendig durch;
# auf einem Entwicklungsrechner ueberspringt es, was schon da ist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

say() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mprepare:\033[0m %s\n' "$1" >&2; exit 1; }

# DAS AUSGEWAEHLTE XCODE MUSS GEWINNEN.
#
# Xcode.app/Contents/Developer/usr/bin steht in einem gewoehnlichen PATH VOR
# /usr/bin. Ein blosses `xcodebuild` nimmt deshalb das Xcode, dem dieses
# Verzeichnis gehoert, und ignoriert xcode-select wie DEVELOPER_DIR gleichermassen.
# Auf einer Maschine mit Beta daneben ist das der Unterschied zwischen zwei SDKs,
# und der Fehler nennt dann ein Quellsymbol statt des SDK.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export PATH="$DEVELOPER_DIR/usr/bin:/opt/homebrew/bin:$PATH"
say "Werkzeugkette: $DEVELOPER_DIR"

command -v cmake    >/dev/null 2>&1 || fail "cmake fehlt: brew install cmake"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen fehlt: brew install xcodegen"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

# --- 1. gl4es ---------------------------------------------------------------
#
# Der Desktop-GL-Emulator, ueber den der Renderer laeuft. Sein Bauergebnis ist
# gitignoriert, auf einem frischen Klon also nicht da.
#
# Die Quellen sind bereits gepatcht eingecheckt; patch-gl4es-darwin.py erzeugt
# hier nur noch die Alias-Liste. Zweimal aufgerufen, und das ist kein Versehen:
# der zweite Lauf bekommt die fertige Bibliothek und filtert die 46 Aliase
# heraus, deren Ziele in dieser Konfiguration gar nicht entstehen (ueberwiegend
# GLX). Ein Alias ohne Ziel laesst den Linker scheitern.
if [ ! -f build-visionos/gl4es/lib/libGL.a ]; then
    say "gl4es bauen (fehlt auf diesem Rechner)"
    # Das Verzeichnis anlegen, bevor jemand hineinschreibt. Auf einem
    # Entwicklungsrechner steht es laengst da; auf einem frischen Klon ist es
    # gitignoriert und damit nicht vorhanden, und patch-gl4es-darwin.py bricht
    # dann beim OEFFNEN seiner Ausgabedatei ab -- mit einem FileNotFoundError,
    # der nach einer fehlenden Eingabe aussieht statt nach einem fehlenden Ordner.
    mkdir -p build-visionos
    python3 patch-gl4es-darwin.py Projects/Android/jni/SupportLibs/gl4es \
        build-visionos/gl4es-aliases.txt

    # -U__ARM_NEON__: zehn Stellen sind mit #ifdef __ARM_NEON__ eingezaeunt,
    # enthalten aber ARMv7-Syntax. Auf AArch64 ist das Makro definiert, die
    # Assembly aber ungueltig; C-Rueckfallpfade gibt es bereits.
    cmake -S Projects/Android/jni/SupportLibs/gl4es -B build-visionos/gl4es \
        -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.4 \
        -DNOX11=ON -DNOEGL=ON -DSTATICLIB=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_C_FLAGS="-U__ARM_NEON__ -U__ARM_NEON"
    cmake --build build-visionos/gl4es -j"$JOBS"

    python3 patch-gl4es-darwin.py Projects/Android/jni/SupportLibs/gl4es \
        build-visionos/gl4es-aliases.txt build-visionos/gl4es/lib/libGL.a
else
    say "gl4es liegt vor"
fi

# --- 2. Engine --------------------------------------------------------------
#
# Beide Spiele: Outcast und Academy sind derselbe Quellbaum mit anderen Makros,
# und daraus entstehen acht Bibliotheken statt vier.
say "Engine uebersetzen (Outcast und Academy)"
cmake -S visionos -B visionos/build -DBUILD_ENGINE=ON \
    -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.4
cmake --build visionos/build -j"$JOBS"

# --- 3. Teil-Link -----------------------------------------------------------
#
# Macht aus jedem Spielsatz ein Objekt, in dem alles ausser dem Einsprungpunkt
# lokal ist -- sonst kollidieren die beiden Com_Printf im selben Bild. Prueft
# am Ende ausserdem gegen, dass sich die Saetze kein Symbol teilen, und wirft
# das App-Buendel weg, damit Xcode neu linkt.
say "Module teil-linken"
./link-visionos.sh

# --- 4. Xcode-Projekt -------------------------------------------------------
say "Xcode-Projekt erzeugen"
(cd visionos/App && xcodegen generate)

say "bereit"
