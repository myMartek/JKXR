#!/usr/bin/env bash
#
# Linkt die Engine zu einem ausführbaren arm64/xrOS-Programm.
#
# Zwei Dinge daran sind nicht offensichtlich.
#
# 1. TEIL-LINK DER SPIELSÄTZE
#
# JKXR besteht aus drei Modulen, die auf Android getrennte Shared Libraries
# sind: Client, Renderer (rd-gles) und Spielcode (jagame). Jedes bringt seine
# eigene Fassung der gemeinsamen Funktionen mit — Com_Printf existiert dreimal,
# einmal echt in common.cpp und je einmal als Weiterleitung in tr_subs.cpp und
# g_main.cpp, die über die Importtabelle zurückrufen. Dasselbe gilt für
# Com_DPrintf, SaberParms, animTable, sv_mapname und rund ein Dutzend weitere.
#
# Seit BEIDE Spiele im Programm stecken, kommt das doppelt vor: Outcast und
# Academy bringen jeweils diese drei Module mit.
#
# Statisch zusammengelinkt kollidiert das zwangsläufig. Die Lösung ist ein
# Teil-Link je SPIEL (ld -r) mit -exported_symbols_list: alles außer der
# Spieltabelle wird lokal, und damit verschwinden die Kollisionen restlos.
#
# Der Aufrufweg der Engine musste dafür einmal angefasst werden: sie holte ihre
# Module per dlsym, und lokale Symbole findet dlsym nicht. Stattdessen führt
# visionos_main.mm eine Tabelle mit Zeigern (Begründung dort und in
# shared/sys/sys_loadlib.h).
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
         "$BUILD/libjagamearm.a" "$BUILD/libtbxr_visionos_ja.a" \
         "$BUILD/libopenjk_jo.a" "$BUILD/librd-gles-jo_arm.a" \
         "$BUILD/libjogamearm.a" "$BUILD/libtbxr_visionos_jo.a" \
         "$HERE/build-visionos/gl4es/lib/libGL.a" \
         "$HERE/build-visionos/gl4es-aliases.txt"; do
    if [ ! -e "$f" ]; then
        echo "FEHLT: $f"
        echo "Erst visionos/CMakeLists.txt bauen und patch-gl4es-darwin.py laufen lassen."
        exit 1
    fi
done

# --- Zwei Stufen zu einem Objekt je Spiel ----------------------------------
#
# Stufe 1, je MODUL. Client, Renderer und Spielcode bringen jeder seine eigene
# Fassung der gemeinsamen Quellen mit — q_math.c, q_string.c, genericparser2.cpp
# und rund zwei Dutzend weitere. Direkt zusammengeworfen sind das 220 doppelte
# Symbole. Der Teil-Link je Modul macht alles außer dem Einsprungpunkt lokal,
# und lokale Symbole kollidieren nicht.
#
# Möglich ist das, weil die Module untereinander KEINE Symbole brauchen: Renderer
# und Spielcode rufen die Engine ausschließlich über ihre Importtabellen zurück
# (refimport_t, game_import_t). Nur die XR-Schicht ruft direkt (Com_Printf,
# Cvar_*), deshalb gehört sie mit dem Client in dasselbe Objekt.
#
# Stufe 2, je SPIEL. Die drei Objekte werden zu einem zusammengefasst, in dem nur
# noch die Spieltabelle global ist. Erst das erlaubt Outcast und Academy
# nebeneinander: sonst gäbe es Com_Printf, GetRefAPI und vmMain je zweimal.
#
# Der Aufrufweg der Engine musste dafür einmal angefasst werden. Sie holte ihre
# Module per dlsym, und lokale Symbole findet dlsym nicht — stattdessen führt
# visionos_main.mm eine Tabelle mit Zeigern (Begründung dort und in
# shared/sys/sys_loadlib.h).
partial_link() {
    local out="$1" symbole="$2"
    shift 2
    local name="$(basename "$out" .o)"
    : > "$WORK/$name.syms"
    for symbol in $symbole; do
        echo "_$symbol" >> "$WORK/$name.syms"
    done

    # Archive vollständig laden, Objekte einfach anhängen. Ohne -all_load nimmt
    # der Linker nur referenzierte Archivmitglieder, und was über die
    # Importtabellen erreicht wird, referenziert niemand.
    local eingaben=()
    for f in "$@"; do
        case "$f" in
            *.a) eingaben+=(-all_load "$f");;
            *)   eingaben+=("$f");;
        esac
    done

    xcrun --sdk xros ld -r -arch arm64 -platform_version xros 26.4 26.4 \
        -exported_symbols_list "$WORK/$name.syms" \
        -o "$out" "${eingaben[@]}"

    local exportiert fehlend
    exportiert="$(xcrun nm -g "$out" | awk '$1!="U" && $2!="U" {print $3}' | tr '\n' ' ')"
    echo "  $(basename "$out"): exportiert $exportiert"

    # Platzhalter (VR_*) werden nicht geprüft: sie stehen für eine Menge, die
    # sich mit dem Code ändert, und ihr Fehlen ist kein Fehler.
    fehlend=""
    for symbol in $symbole; do
        case "$symbol" in *"*"*) continue;; esac
        case " $exportiert " in *" _$symbol "*) ;; *) fehlend="$fehlend _$symbol";; esac
    done
    if [ -n "$fehlend" ]; then
        echo "  FEHLER: nicht exportiert:$fehlend"
        exit 1
    fi
}

for spiel in ja jo; do
    case "$spiel" in
        ja) client=openjk_ja; renderer=rd-gles-ja_arm; spielcode=jagamearm;;
        jo) client=openjk_jo; renderer=rd-gles-jo_arm; spielcode=jogamearm;;
    esac

    # Die Hilfsbibliotheken gehören IN die Objekte, nicht daneben.
    #
    # Sie rufen die Engine zurück: minizip holt seinen Speicher über
    # openjk_minizip_malloc, libpng und libjpeg über die Fehler- und
    # Speicherhaken des Renderers. Nach dem Teil-Link sind diese Funktionen
    # lokal — daneben gelinkt fänden die Bibliotheken sie nicht mehr, und der
    # Linker meldete "symbol(s) not found" für ein Symbol, das sichtbar im Baum
    # steht.
    #
    # libpng und libjpeg stehen deshalb ZWEIMAL im Spielsatz, einmal beim
    # Renderer und einmal beim Client. Das kostet rund 700 KB und ist harmlos:
    # nach dem Teil-Link ist jede Fassung lokal, sie können sich nicht
    # gegenseitig sehen.
    hilfs_renderer=("$BUILD/liblibpng.a" "$BUILD/liblibjpeg.a")
    hilfs_client=("$BUILD/liblibzip.a" "$BUILD/liblibminizip.a"
                  "$BUILD/liblibpng.a" "$BUILD/libsigc.a")

    echo "== Module teil-linken ($spiel)"
    partial_link "$WORK/rd-gles-$spiel.o" "GetRefAPI" \
        "$BUILD/lib$renderer.a" "${hilfs_renderer[@]}"

    # Das Spielmodul hat DREI Einsprungpunkte, nicht einen.
    #
    # GetGameAPI holt sich sv_game.cpp, aber der Client sucht über
    # CL_InitCGameVM zusätzlich dllEntry und vmMain — das ist der Clientteil des
    # Spielcodes, der in derselben Bibliothek steckt. Fehlt einer davon, bricht
    # das Spiel im Hauptmenü mit "Failed to load client game functions" ab,
    # obwohl die Bibliothek vollständig gelinkt ist. Genau das ist passiert.
    partial_link "$WORK/spielcode-$spiel.o" "GetGameAPI dllEntry vmMain" \
        "$BUILD/lib$spielcode.a"

    # Client und XR-Schicht gemeinsam: die XR-Schicht ruft die Engine direkt.
    #
    # Exportiert wird hier mehr als die Tabelle, nämlich die ganze XR-Oberfläche
    # (VR_* und TBXR_*). Grund: der Renderer ruft sie DIREKT, nicht über
    # refimport_t — RB_SetGL2D holt VR_GetCurrentEye, RE_StretchRaw zusätzlich
    # VR_GetScreenWall. Blieben sie lokal, fänden die anderen Objekte sie in
    # Stufe 2 nicht.
    #
    # Global bleiben sie nur zwischen den Stufen. Stufe 2 sammelt sie ein und
    # lässt allein die Tabelle übrig — nach außen ist also nichts gewonnen und
    # nichts verloren. Bewusst mit Platzhalter statt einer Namensliste: welche
    # Funktionen der Renderer braucht, ändert sich mit jeder VR-Ergänzung, und
    # eine Liste zum Nachpflegen wäre die nächste Fehlerquelle.
    partial_link "$WORK/client-$spiel.o" "JKXR_visionOS_Spiel_$spiel VR_* TBXR_*" \
        "$BUILD/lib$client.a" "$BUILD/libtbxr_visionos_$spiel.a" \
        "${hilfs_client[@]}"

    echo "== Spielsatz zusammenfassen ($spiel)"
    partial_link "$WORK/spiel-$spiel.o" "JKXR_visionOS_Spiel_$spiel" \
        "$WORK/client-$spiel.o" "$WORK/rd-gles-$spiel.o" "$WORK/spielcode-$spiel.o"
done

# Keine Überschneidung mehr? Die Prüfung, die die ganze Konstruktion trägt.
#
# Zwei Objekte mit je einem globalen Symbol können sich nicht in die Quere
# kommen — aber genau das ist die Annahme, und sie hier zu prüfen kostet
# Millisekunden. Ohne sie wäre der Befund ein Linkerfehler mit mehreren Hundert
# Zeilen "duplicate symbol", in dem die Ursache nicht mehr zu erkennen ist.
doppelt="$(comm -12 \
    <(xcrun nm -g "$WORK/spiel-ja.o" | awk '$1!="U" && $2!="U" {print $3}' | sort -u) \
    <(xcrun nm -g "$WORK/spiel-jo.o" | awk '$1!="U" && $2!="U" {print $3}' | sort -u))"
if [ -n "$doppelt" ]; then
    echo "  FEHLER: beide Sätze exportieren dieselben Symbole:"
    echo "$doppelt" | sed 's/^/    /'
    exit 1
fi
echo "  keine gemeinsamen Symbole — die Sätze sind entkoppelt"

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
# App — die baut Xcode selbst aus denselben Objekten. Sein Wert liegt darin, dass
# er dieselben Objekte in derselben Reihenfolge zusammenführt: die gl4es-Aliase
# und die Vollständigkeit beider Spielsätze fallen hier auf, ohne Xcode zu
# starten.
#
# Die Prüf-Hülle liegt im Repo (visionos/linkcheck/shell.mm); früher wurde sie
# von Hand erzeugt und lag unversioniert unter build-visionos/link/, womit das
# Skript auf einem frischen Klon scheiterte.
echo "== Prüf-Hülle übersetzen"
xcrun --sdk xros clang++ -c -target arm64-apple-xros26.4 -fobjc-arc -w \
    -I"$HERE/Projects/Android/jni/OpenJK/code" \
    -o "$WORK/shell.o" "$HERE/visionos/linkcheck/shell.mm"

echo "== linken (Prüfprogramm)"
xcrun --sdk xros clang++ -target arm64-apple-xros26.4 -o "$OUT" \
    "$WORK/shell.o" \
    "$WORK/spiel-ja.o" "$WORK/spiel-jo.o" \
    -Wl,-force_load,"$HERE/build-visionos/gl4es/lib/libGL.a" \
    -Wl,-alias_list,"$HERE/build-visionos/gl4es-aliases.txt" \
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
echo "Spieltabellen im Export-Trie (die Hülle muss sie finden):"
xcrun dyld_info -exports "$OUT" 2>/dev/null | \
    grep -E "JKXR_visionOS_Spiel_(ja|jo)" || \
    echo "  KEINE — Q_EXPORT fehlt an den Tabellen in visionos_main.mm"

