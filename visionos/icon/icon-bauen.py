#!/usr/bin/env python3
"""Baut das visionOS-Programmsymbol aus den beiden Quellbildern.

visionOS zeigt kein flaches Symbol, sondern einen Stapel aus Schichten, die sich
beim Ansehen gegeneinander verschieben. Gebraucht werden deshalb zwei Bilder:
der Verlauf als Rueckseite und das Emblem samt Schriftzug als Vorderseite MIT
Alpha.

Die Vorderseite entsteht hier aus der HELLIGKEIT von full.png, nicht aus der
Differenz zu background.png. Naheliegend waere die Differenz, sie traegt aber
nicht: die beiden Verlaeufe stimmen nicht ueberein (in den oberen Ecken um 29
Stufen), und eine Differenzmaske haette den halben Hintergrund mitgenommen. Die
Helligkeit trennt dagegen eindeutig -- Ecke 17 gegen Emblem 183.

Aufruf:  python3 visionos/icon/icon-bauen.py
"""

from PIL import Image
import numpy as np
import pathlib

HIER = pathlib.Path(__file__).resolve().parent
ZIEL = (HIER / ".." / "App" / "Sources" / "Resources" / "Assets.xcassets"
        / "AppIcon.solidimagestack").resolve()

# Kantenlaenge der Schichten. Apple erwartet 1024x1024 je Schicht.
KANTE = 1024

# Wie gross das Emblem in seiner Schicht steht.
#
# Etwas kleiner als die Rueckseite, damit es nicht bis an den Rand laeuft: der
# Stapel wird kreisfoermig beschnitten, und die Parallaxe schiebt die
# Vorderseite zusaetzlich hin und her. Auf dem Geraet beurteilt.
INNEN = 0.92

# Weicher Uebergang statt harter Schwelle: der Saeberschein soll
# teildurchsichtig bleiben, sonst bekaeme er einen sichtbaren Rand.
SCHWELLE_UNTEN = 34.0
SCHWELLE_OBEN = 95.0


def main() -> int:
    hint = Image.open(HIER / "background.png").convert("RGB")
    hint = hint.resize((KANTE, KANTE), Image.LANCZOS)
    hint.save(ZIEL / "Back.solidimagestacklayer/Content.imageset/back.png")

    voll = Image.open(HIER / "full.png").convert("RGB")
    innen = max(1, int(round(KANTE * INNEN)))
    voll = voll.resize((innen, innen), Image.LANCZOS)

    v = np.asarray(voll, dtype=np.float32)
    lum = 0.2126 * v[:, :, 0] + 0.7152 * v[:, :, 1] + 0.0722 * v[:, :, 2]
    u = np.clip((lum - SCHWELLE_UNTEN) / (SCHWELLE_OBEN - SCHWELLE_UNTEN), 0.0, 1.0)
    alpha = u * u * (3.0 - 2.0 * u)          # smoothstep

    emblem = Image.fromarray(
        np.dstack([v, alpha * 255.0]).astype(np.uint8), "RGBA")

    # Mittig auf eine durchsichtige Flaeche voller Groesse, damit beide
    # Schichten dieselben Masse haben und deckungsgleich liegen.
    vorne = Image.new("RGBA", (KANTE, KANTE), (0, 0, 0, 0))
    rand = (KANTE - innen) // 2
    vorne.paste(emblem, (rand, rand))
    vorne.save(ZIEL / "Front.solidimagestacklayer/Content.imageset/front.png")

    print(f"Emblem auf {INNEN:.0%} ({innen} px), Rand {rand} px je Seite")
    print(f"Deckung: {(alpha > 0.5).mean() * 100:.1f} % der verkleinerten Flaeche")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
