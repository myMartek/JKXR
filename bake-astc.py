#!/usr/bin/env python3
"""Backt die Texturen einer .pk3 nach ASTC.

Warum überhaupt: eine RGBA8-Textur belegt vier Byte je Bildpunkt, ASTC 6×6
knapp 3,6 Bit — Faktor neun. Beim 4×-Upscale-Paket ist das der Unterschied
zwischen "die Karte lädt" und SIGKILL (gemessen: ohne Halbierung fällt der
freie Speicher linear um 131 MB/s bis auf null).

KEIN EIGENES CACHE-SYSTEM. Ergebnis ist wieder eine .pk3 — also ein ZIP, das
die Engine ohnehin lesen kann. Jede Textur bekommt eine Datei mit demselben
Pfad und der Endung ".astc" daneben:

    textures/foo.jpg  ->  textures/foo.jpg.astc

Damit entfällt eine ganze Schicht: kein Cache-Verzeichnis, keine
Gültigkeitsprüfung, kein zweiter Suchpfad. Die Engine findet die Datei über
FS_ReadFile wie jede andere, und die Ladereihenfolge der pk3 gilt unverändert.

DER BEHÄLTER je Textur, weil eine .astc-Datei nur EINE Stufe hält, wir aber
die ganze Mip-Kette brauchen:

    Byte  0.. 3   "JKAT"
    Byte  4.. 5   Fassung (1)
    Byte  6.. 7   Blockbreite, Blockhöhe
    Byte  8..11   Breite, Höhe (je 16 Bit)
    Byte 12..13   Anzahl der Stufen
    Byte 14..15   Merkmale: Bit 0 = hat Alpha
    danach        je Stufe 4 Byte Länge, dann die Blöcke

Alpha wird MITGESCHRIEBEN, nicht später erraten: der Renderer entscheidet
daran, ob eine Fläche in den durchsichtigen Durchgang gehört. Wer die Textur
komprimiert lädt, sieht ihre Bildpunkte nie und kann es nicht mehr feststellen.

    python3 bake-astc.py quelle.pk3 ziel.pk3 [--block 6x6] [--jobs 8]
"""

from __future__ import annotations

import argparse
import io
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from concurrent.futures import ProcessPoolExecutor

from PIL import Image

MAGIE = b"JKAT"
FASSUNG = 1
ENDUNGEN = (".jpg", ".jpeg", ".tga", ".png")

# Der Kopf einer .astc-Datei, den astcenc schreibt und den wir abschneiden.
ASTC_KOPF = 16


def mipkette(bild: Image.Image) -> list[Image.Image]:
    """Alle Stufen bis hinunter zu 1×1.

    Vor der Kompression erzeugt, nicht danach: ASTC-Blöcke lassen sich nicht
    verkleinern, und eine aus komprimierten Daten gerechnete Stufe wäre
    zweimal verlustbehaftet.
    """
    stufen = [bild]
    b, h = bild.size
    while b > 1 or h > 1:
        b = max(1, b // 2)
        h = max(1, h // 2)
        stufen.append(stufen[-1].resize((b, h), Image.LANCZOS))
    return stufen


def kodiere(bild: Image.Image, block: str, astcenc: str) -> bytes:
    """Eine Stufe durch astcenc schicken.

    Über Dateien statt über eine Pipe, weil das Kommandozeilenwerkzeug nichts
    anderes kann. Das ist der Preis dafür, den Kodierer NICHT als Bibliothek
    einzubinden — astcenc steht unter Apache-2.0, JKXR unter GPLv2-only, und
    die beiden gelten als unvereinbar. Was auf dem Mac läuft, berührt die
    Lizenz der App nicht.
    """
    with tempfile.TemporaryDirectory() as tmp:
        ein = pathlib.Path(tmp) / "ein.png"
        aus = pathlib.Path(tmp) / "aus.astc"
        bild.save(ein)
        # -cl, nicht -cs: LINEAR. Die Engine lädt heute mit GL_RGBA hoch, ohne
        # sRGB-Wandlung. Auf dem Gerät gemessen -- mit dem sRGB-Format läse ein
        # mittleres Grau 55 statt 128 zurück, jede Textur wäre dunkler.
        r = subprocess.run([astcenc, "-cl", str(ein), str(aus), block, "-medium"],
                           capture_output=True)
        if r.returncode != 0 or not aus.exists():
            raise RuntimeError(r.stderr.decode()[:200])
        return aus.read_bytes()[ASTC_KOPF:]


def backe_eine(auftrag) -> tuple[str, bytes] | None:
    name, rohdaten, block, astcenc = auftrag
    try:
        bild = Image.open(io.BytesIO(rohdaten))
        hat_alpha = bild.mode in ("RGBA", "LA") or "transparency" in bild.info
        bild = bild.convert("RGBA")
    except Exception as fehler:
        print(f"  übersprungen  {name}: {fehler}", file=sys.stderr)
        return None

    bw, bh = (int(x) for x in block.split("x"))
    stufen = mipkette(bild)
    bloecke = [kodiere(s, block, astcenc) for s in stufen]

    # OHNE die Bildendung ablegen.
    #
    # Die Engine fragt nach "gfx/effects/bryar_blob" und probiert .jpg und .tga
    # selbst durch (R_LoadImage). Ein "bryar_blob.tga.astc" fände sie nie --
    # gemessen: null Treffer beim ersten Versuch.
    kopf = MAGIE + struct.pack("<HBBHHHH", FASSUNG, bw, bh,
                               bild.width, bild.height, len(stufen),
                               1 if hat_alpha else 0)
    koerper = b"".join(struct.pack("<I", len(b)) + b for b in bloecke)
    stamm = name
    for e in ENDUNGEN:
        if stamm.lower().endswith(e):
            stamm = stamm[:-len(e)]
            break
    return stamm + ".astc", kopf + koerper


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("quelle")
    p.add_argument("ziel")
    p.add_argument("--block", default="6x6")
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--astcenc", default="astcenc-neon",
                   help="Pfad zum Kodierer (aus ARM-software/astc-encoder gebaut)")
    p.add_argument("--filter", default="",
                   help="nur Pfade, die diesen Text enthalten")
    p.add_argument("--limit", type=int, default=0,
                   help="nur die ersten N Texturen — zum Ausprobieren")
    args = p.parse_args()

    astcenc = shutil.which(args.astcenc) or args.astcenc
    if not pathlib.Path(astcenc).exists():
        print(f"Kodierer nicht gefunden: {args.astcenc}", file=sys.stderr)
        return 1

    quelle = zipfile.ZipFile(args.quelle)
    namen = [n for n in quelle.namelist() if n.lower().endswith(ENDUNGEN)]
    if args.filter:
        namen = [n for n in namen if args.filter in n]
    if args.limit:
        namen = namen[:args.limit]
    print(f"{len(namen)} Texturen, Block {args.block}")

    auftraege = [(n, quelle.read(n), args.block, astcenc) for n in namen]

    fertig = 0
    roh = klein = 0
    with zipfile.ZipFile(args.ziel, "w", zipfile.ZIP_STORED) as ziel:
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            for ergebnis in pool.map(backe_eine, auftraege):
                fertig += 1
                if ergebnis is None:
                    continue
                name, daten = ergebnis
                ziel.writestr(name, daten)
                klein += len(daten)
                if fertig % 50 == 0 or fertig == len(namen):
                    print(f"  {fertig}/{len(namen)}  {klein/1048576:.0f} MB gebacken")

    print(f"\n{args.ziel}: {pathlib.Path(args.ziel).stat().st_size/1048576:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
