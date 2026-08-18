#!/usr/bin/env python3
"""Baut jkxr-demo.pk3 — die Prüfdatei für das App-Review.

Ohne Spieldaten, die die App weder enthält noch enthalten darf, sieht ein
Prüfer ein Startfenster und dahinter nichts. Diese Datei ist der Weg hinein:
die App erkennt sie am SHA-256 und schaltet statt eines Spiels ihre eigene,
mitgelieferte Demo-Welt ein.

Es steckt also KEIN Spielinhalt darin, und es braucht auch keinen. Alles, was
die Demo zeigt, liegt in der App (visionos/App/Sources/App/DemoWelt.swift);
diese Datei ist der Schlüssel, der sagt „zeig es".

Sie ist ein echtes ZIP-Archiv, denn eine .pk3 ist genau das — wer sie mit einem
gewöhnlichen Werkzeug öffnet, soll nicht auf Bytesalat stoßen, sondern auf eine
Erklärung.

Für BEIDE Spiele dieselbe Datei. Der Prüfer soll nicht raten müssen, welche von
zwei Dateien zu welchem Titel gehört; die App nimmt sie in Outcast wie in
Academy an.

Absichtlich reproduzierbar: die App nagelt den Hash fest
(DemoWelt.swift, DEMO_SHA256), dieselbe Quelle muss also immer dieselben Bytes
ergeben. Nichts hier darf von der Uhr, der Maschine oder einer
Wörterbuchreihenfolge abhängen — deshalb der feste Zeitstempel je Eintrag und
die feste Reihenfolge unten.

    python3 make-demo-pk3.py [-o build-visionos/jkxr-demo.pk3]
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import sys
import zipfile

# Fester Zeitstempel für jeden Eintrag.
#
# ZIP speichert die Änderungszeit je Datei. Mit der echten Uhr wäre der Hash bei
# jedem Lauf ein anderer, und die Festnagelung in der App damit wertlos.
ZEITSTEMPEL = (2026, 1, 1, 0, 0, 0)

HINWEIS = """\
JKXR — DEMO FILE FOR APP REVIEW

This file contains no game data.

It is an identification key. The app recognises it by its SHA-256 hash and, in
place of a game, switches on the demo world that the app carries itself — so
that JKXR can be reviewed and tried without a copy of the original PC game.

It is not a game, not a copy of one, and not derived from one. It works for
both supported titles. Written and distributed by the author of the app.

https://www.martek.de
"""

# Was in der Datei steht, damit sie sich auch ohne Hash zu erkennen gibt.
KENNUNG = b"JKXR-DEMO-1\x00"


def baue() -> bytes:
    """Das Archiv im Speicher zusammensetzen.

    Im Speicher und nicht auf der Platte, weil der Hash über genau die Bytes
    gehen muss, die später ausgeliefert werden — und weil ein Zwischenstand auf
    der Platte die Reihenfolge der Einträge verwischen könnte.
    """
    import io

    puffer = io.BytesIO()
    # ZIP_STORED, nicht DEFLATE: die Kompression hängt an der zlib-Fassung, und
    # eine andere zlib ergäbe andere Bytes bei gleichem Inhalt. Die Datei ist
    # ohnehin winzig.
    with zipfile.ZipFile(puffer, "w", compression=zipfile.ZIP_STORED) as z:
        for name, inhalt in (
            ("README.txt", HINWEIS.encode("utf-8")),
            ("jkxr-demo.id", KENNUNG),
        ):
            eintrag = zipfile.ZipInfo(name, date_time=ZEITSTEMPEL)
            eintrag.external_attr = 0o644 << 16
            eintrag.create_system = 3          # Unix, unabhängig vom Bauwirt
            z.writestr(eintrag, inhalt)

    return puffer.getvalue()


def festgenagelter_hash() -> str | None:
    """Was die App von dieser Datei erwartet.

    Beide müssen übereinstimmen, sonst erkennt die App die Datei nicht mehr —
    und der Fehlschlag ist die unangenehmste Sorte: der Import sagt schlicht
    „unbekannte Datei" zu jemandem, dem wir genau diese Datei zum Laden gegeben
    haben.
    """
    quelle = (pathlib.Path(__file__).resolve().parent
              / "visionos" / "App" / "Sources" / "App" / "DemoWelt.swift")
    if not quelle.exists():
        return None
    for zeile in quelle.read_text(encoding="utf-8").splitlines():
        if "DEMO_SHA256" in zeile and '"' in zeile:
            return zeile.split('"')[1]
    return None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-o", "--output", default="build-visionos/jkxr-demo.pk3")
    args = p.parse_args()

    daten = baue()
    ziel = pathlib.Path(args.output)
    ziel.parent.mkdir(parents=True, exist_ok=True)
    ziel.write_bytes(daten)

    digest = hashlib.sha256(daten).hexdigest()
    print(f"{ziel}  {len(daten)} Bytes")
    print(f"sha256  {digest}")

    erwartet = festgenagelter_hash()
    if erwartet is None:
        print("Hinweis: DemoWelt.swift nicht gefunden, Festnagelung ungeprüft")
    elif erwartet != digest:
        print(f"\nFEHLER: die App erwartet {erwartet}.", file=sys.stderr)
        print("Sie wird diese Datei NICHT erkennen. Entweder den Hash oben nach",
              file=sys.stderr)
        print("DemoWelt.swift (DEMO_SHA256) übernehmen, oder herausfinden, was",
              file=sys.stderr)
        print("sich hier geändert hat.", file=sys.stderr)
        return 1
    else:
        print("Festnagelung stimmt mit DemoWelt.swift überein")
    return 0


if __name__ == "__main__":
    sys.exit(main())
