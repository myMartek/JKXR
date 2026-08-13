#!/usr/bin/env python3
"""
Bringt openal-softs CoreAudio-Backend visionOS bei.

Ein einziger Fehler, immer derselbe blinde Fleck: die Plattformweiche kennt
visionOS nicht.

    #if TARGET_OS_IOS || TARGET_OS_TV
    #define CAN_ENUMERATE 0
    #else
    #include <IOKit/audio/IOAudioTypes.h>      <- greift auf visionOS
    #define CAN_ENUMERATE 1
    #endif

Auf visionOS gilt TARGET_OS_IOS=0 und TARGET_OS_TV=0, aber TARGET_OS_IPHONE=1
und TARGET_OS_VISION=1. Die Weiche fällt also in den macOS-Zweig und zieht
IOKit/audio/IOAudioTypes.h herein — einen Header, den es im XROS-SDK nicht gibt.

Die Abfrage wird auf TARGET_OS_OSX umgestellt: gefragt ist nicht „welche
iOS-Variante ist das", sondern „ist das der Mac". Nur dort gibt es die
HAL-Geräteaufzählung; jede andere Apple-Plattform hat genau ein Audiogerät.
Damit ist der Patch auch für kommende Plattformen richtig.

Der Rest der Datei braucht nichts: hinter CAN_ENUMERATE hängen elf Blöcke, die
sich damit sauber abschalten — inklusive der ComponentDescription- und
AudioDeviceID-Nutzung, an der die alte mitgelieferte openal-soft scheiterte.

Aufruf:  ./patch-openal-visionos.py [--check]
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TARGET = HERE / "build-visionos" / "openal-src" / "alc" / "backends" / "coreaudio.cpp"

OLD = """#if TARGET_OS_IOS || TARGET_OS_TV
#define CAN_ENUMERATE 0
#else"""

NEW = """/* visionOS-Portierung: siehe patch-openal-visionos.py.
 * Die Abfrage lautete TARGET_OS_IOS || TARGET_OS_TV. Auf visionOS sind beide 0
 * (TARGET_OS_VISION und TARGET_OS_IPHONE sind 1), also fiel sie in den
 * macOS-Zweig und zog IOKit/audio/IOAudioTypes.h herein — im XROS-SDK nicht
 * vorhanden. Die Geräteaufzählung über die HAL gibt es nur auf dem Mac; jede
 * andere Apple-Plattform hat genau ein Audiogerät.
 */
#if !TARGET_OS_OSX
#define CAN_ENUMERATE 0
#else"""


def main() -> int:
    check = "--check" in sys.argv

    if not TARGET.exists():
        print(f"FEHLER: {TARGET} fehlt — erst build-openal-visionos.sh laufen lassen")
        return 1

    src = TARGET.read_text()

    if NEW in src:
        print("bereits gepatcht")
        return 0

    if OLD not in src:
        print("FEHLER: erwartete Plattformweiche nicht gefunden.")
        print("openal-soft hat den Code geändert — von Hand prüfen:")
        print(f"  {TARGET}")
        return 1

    if check:
        print("ungepatcht, Weiche gefunden")
        return 0

    TARGET.write_text(src.replace(OLD, NEW, 1))
    print(f"gepatcht: {TARGET.relative_to(HERE)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
