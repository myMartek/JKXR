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
# Die gebauten ANGLE-Frameworks liegen im Repo (12 MB), nicht im 24-GB-Baum.
# Neu bauen lässt sich ANGLE über spikes/s4-angle/README.md.
ANGLE="$HERE/visionos/App/Frameworks"
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
    local lib="$1" out="$2"
    shift 2
    local name="$(basename "$out" .o)"
    : > "$WORK/$name.syms"
    for symbol in "$@"; do
        echo "_$symbol" >> "$WORK/$name.syms"
    done
    xcrun --sdk xros ld -r -arch arm64 -platform_version xros 2.0 2.0 \
        -exported_symbols_list "$WORK/$name.syms" \
        -o "$out" -all_load "$lib"

    local exported missing
    exported="$(xcrun nm -g "$out" | awk '$1!="U" && $2!="U" {print $3}' | tr '\n' ' ')"
    echo "  $(basename "$out"): exportiert $exported"

    missing=""
    for symbol in "$@"; do
        case " $exported " in *" _$symbol "*) ;; *) missing="$missing _$symbol";; esac
    done
    if [ -n "$missing" ]; then
        echo "  FEHLER: nicht exportiert:$missing"
        exit 1
    fi
}

echo "== Module teil-linken"
partial_link "$BUILD/librd-gles-ja_arm.a" "$WORK/rd-gles-merged.o" GetRefAPI

# Das Spielmodul hat DREI Einsprungpunkte, nicht einen.
#
# GetGameAPI holt sich sv_game.cpp, aber der Client sucht über
# CL_InitCGameVM zusätzlich dllEntry und vmMain — das ist der Clientteil des
# Spielcodes, der in derselben Bibliothek steckt. Fehlen sie im Export, findet
# dlsym sie nicht und das Spiel bricht beim Start mit "Failed to load client
# game functions" ab, obwohl die Bibliothek vollständig gelinkt ist.
partial_link "$BUILD/libjagamearm.a" "$WORK/jagame-merged.o" GetGameAPI dllEntry vmMain

# ---------------------------------------------------------------------------
# App-Bündel verwerfen, damit Xcode neu linkt.
#
# Die Engine-Bibliotheken stehen in OTHER_LDFLAGS, und was dort steht, verfolgt
# Xcode NICHT als Abhängigkeit: eine geänderte libopenjk_ja.a löst keinen
# erneuten Link aus. Das Bündel behält dann sein altes Binary, der Build meldet
# "BUILD SUCCEEDED", und man misst stundenlang gegen einen veralteten Stand.
#
# Genau das ist hier passiert — eine frisch eingebaute Protokollierung fehlte im
# Binary, obwohl sie in der Bibliothek stand.
DERIVED="$HERE/visionos/DerivedData/Build/Products/Debug-xros/JKXR.app"
if [ -d "$DERIVED" ]; then
    rm -rf "$DERIVED"
    echo "App-Bündel verworfen — Xcode linkt beim nächsten Build neu"
fi

# --- Gesamtlink ------------------------------------------------------------
#
# Dieser Link erzeugt ein eigenständiges Prüfprogramm und ist NICHT der Link der
# App — die baut Xcode selbst aus denselben Objekten. Er schlägt derzeit an
# einem doppelten _vmMain fehl, seit das Spielmodul es exportieren muss;
# aussagekräftig bleibt er trotzdem für die gl4es-Aliase. Deshalb steht das
# Verwerfen des App-Bündels davor: sonst nimmt "set -e" es mit.
echo "== linken (Prüfprogramm)"
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

