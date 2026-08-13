#!/usr/bin/env bash
#
# Linkt die Engine zu einem ausführbaren arm64/xrOS-Programm.
#
# Zwei Dinge daran sind nicht offensichtlich.
#
# 1. TEIL-LINK DER MODULE
#
# JKXR besteht aus drei Modulen, die auf Android getrennte Shared Libraries
# sind: Client, Renderer (rd-gles) und Spielcode (jagame). Jedes bringt seine
# eigene Fassung der gemeinsamen Funktionen mit — Com_Printf existiert dreimal,
# einmal echt in common.cpp und je einmal als Weiterleitung in tr_subs.cpp und
# g_main.cpp, die über die Importtabelle zurückrufen. Dasselbe gilt für
# Com_DPrintf, SaberParms, animTable, sv_mapname und rund ein Dutzend weitere.
#
# Statisch zusammengelinkt kollidiert das zwangsläufig. Die Lösung ist ein
# Teil-Link je Modul (ld -r) mit -exported_symbols_list: alles außer dem einen
# Einsprungpunkt wird lokal, die Kollisionen verschwinden, und der Aufrufweg
# der Engine bleibt unverändert — sie holt sich GetRefAPI und GetGameAPI
# ohnehin per dlsym.
#
# 2. gl4es
#
# -force_load, weil ein Alias sein Ziel im Link braucht: Archivmitglieder
# werden nur eingebunden, wenn etwas sie referenziert, und referenziert wird
# der Aliasname, den es ohne den Alias noch nicht gibt.
#
# -alias_list, weil Mach-O keine Compiler-Aliase kennt (siehe
# patch-gl4es-darwin.py).
#
# Aufruf:  ./link-visionos.sh [ausgabedatei]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/visionos/build"
WORK="$HERE/build-visionos/link"
ANGLE="$HERE/../spikes/s4-angle/angle/out/xros"
OUT="${1:-$WORK/jkxr}"

mkdir -p "$WORK"

for f in "$BUILD/libopenjk_ja.a" "$BUILD/librd-gles-ja_arm.a" \
         "$BUILD/libjagamearm.a" "$BUILD/libtbxr_visionos.a" \
         "$HERE/build-visionos/gl4es/lib/libGL.a" \
         "$HERE/build-visionos/gl4es-aliases.txt"; do
    if [ ! -e "$f" ]; then
        echo "FEHLT: $f"
        echo "Erst visionos/CMakeLists.txt bauen und patch-gl4es-darwin.py laufen lassen."
        exit 1
    fi
done

# --- Teil-Link der beiden Nebenmodule -------------------------------------
partial_link() {
    local lib="$1" symbol="$2" out="$3"
    echo "_$symbol" > "$WORK/$symbol.syms"
    xcrun --sdk xros ld -r -arch arm64 -platform_version xros 2.0 2.0 \
        -exported_symbols_list "$WORK/$symbol.syms" \
        -o "$out" -all_load "$lib"

    local exported
    exported="$(xcrun nm -g "$out" | awk '$1!="U" && $2!="U" {print $3}' | tr '\n' ' ')"
    echo "  $(basename "$out"): exportiert $exported"
    if [ "$exported" != "_$symbol " ]; then
        echo "  FEHLER: erwartet wurde nur _$symbol"
        exit 1
    fi
}

echo "== Module teil-linken"
partial_link "$BUILD/librd-gles-ja_arm.a" GetRefAPI  "$WORK/rd-gles-merged.o"
partial_link "$BUILD/libjagamearm.a"      GetGameAPI "$WORK/jagame-merged.o"

# --- Gesamtlink ------------------------------------------------------------
echo "== linken"
xcrun --sdk xros clang++ -target arm64-apple-xros2.0 -o "$OUT" \
    "$WORK/shell.o" \
    "$WORK/rd-gles-merged.o" "$WORK/jagame-merged.o" \
    -Wl,-force_load,"$HERE/build-visionos/gl4es/lib/libGL.a" \
    -Wl,-alias_list,"$HERE/build-visionos/gl4es-aliases.txt" \
    "$BUILD/libopenjk_ja.a" "$BUILD/libtbxr_visionos.a" \
    "$BUILD/liblibpng.a" "$BUILD/liblibjpeg.a" \
    "$BUILD/liblibzip.a" "$BUILD/liblibminizip.a" "$BUILD/libsigc.a" \
    -F"$ANGLE" -framework libEGL -framework libGLESv2 \
    -lz \
    -framework Foundation -framework Metal -framework QuartzCore -framework ARKit \
    -framework CompositorServices -framework AudioToolbox \
    -framework AVFoundation -framework GameController -framework UIKit

echo
echo "Ergebnis: $OUT"
lipo -archs "$OUT"
otool -l "$OUT" | grep -A3 LC_BUILD_VERSION | grep -E "platform|minos" | head -2

echo
echo "Einsprungpunkte im Export-Trie (dlsym muss sie finden):"
xcrun dyld_info -exports "$OUT" 2>/dev/null | \
    grep -E "GetGameAPI|GetRefAPI|JKXR_visionOS_Main|JKXR_visionOS_RequestShutdown" || \
    echo "  KEINE — Q_EXPORT fehlt an den Definitionen"
