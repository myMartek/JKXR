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


def lies_tabellen(pfad: pathlib.Path) -> bytes | None:
    """Die Farbabbildung der Engine, aus visionos/farbtabellen.txt.

    Upload32 legt sie auf JEDE Textur, bevor sie hochgeladen wird
    (R_LightScaleTexture). Der ASTC-Weg umgeht Upload32 — ohne dieselbe
    Abbildung beim Backen ist alles zu hell, auf dem Gerät beobachtet.

    Zurückgegeben wird die FERTIGE Verkettung gamma[intens[v]], also der Fall
    für Texturen mit Mip-Kette. Das sind praktisch alle; die wenigen ohne
    bekämen nur Gamma, und der Unterschied liegt unter der Wahrnehmbarkeit.
    """
    if not pfad.exists():
        return None
    tabellen = {}
    for zeile in pfad.read_text().splitlines():
        if zeile.startswith("#") or not zeile.strip():
            continue
        name, hexwerte = zeile.split()
        tabellen[name] = bytes.fromhex(hexwerte)
    if "gamma" not in tabellen or "intens" not in tabellen:
        return None
    g, i = tabellen["gamma"], tabellen["intens"]
    return bytes(g[i[v]] for v in range(256))


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
        stufen.append(verkleinere(stufen[-1], b, h))
    return stufen


def verkleinere(bild: Image.Image, b: int, h: int) -> Image.Image:
    """Kanalweise, NICHT als RGBA am Stück.

    PIL multipliziert beim Verkleinern eines RGBA-Bildes die Farbe mit dem
    Alpha und macht es hinterher nicht rückgängig. Nachgestellt mit einem
    2×2-Bild (200,200,200,0):

        am Stück          -> (0, 0, 0, 0)
        Kanäle getrennt   -> (200, 200, 200, 0)

    Für Texturen mit Alphakanal heißt das: ab Stufe 1 ist die Farbe überall
    dort ausgelöscht, wo die Textur durchsichtig ist. Auf dem Gerät gemessen
    fiel der RGB-Mittelwert von textures/impdetention/deathcon1 zwischen
    Stufe 0 und Stufe 1 von (39, 13, 19) auf (0, 1, 8).

    Sichtbar wurde es an genau einer Wand, weil deren Shader mit
    SRCBLEND_ONE | DSTBLEND_SRC_ALPHA mischt: dort trägt das Alpha das Tor
    und RGB den Inhalt. Mit ausgelöschtem RGB blieb die Wand schwarz --
    und zwar nur in der Entfernung, in der die höheren Stufen gezogen werden,
    was als kopfabhängiger Ausschnitt mit dunkler werdenden Stufen erschien.

    Die Engine hat dieses Problem nicht: ihre Mip-Erzeugung läuft im Treiber
    und rührt das Alpha nicht an.
    """
    return Image.merge("RGBA", [k.resize((b, h), Image.LANCZOS)
                                for k in bild.split()])


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
    name, rohdaten, block, astcenc, abbildung = auftrag
    try:
        bild = Image.open(io.BytesIO(rohdaten))
        hat_alpha = bild.mode in ("RGBA", "LA") or "transparency" in bild.info
        bild = bild.convert("RGBA")
    except Exception as fehler:
        print(f"  übersprungen  {name}: {fehler}", file=sys.stderr)
        return None

    # Die Abbildung der Engine auf das Vollbild legen, VOR der Mip-Erzeugung.
    #
    # Genau diese Reihenfolge hat die Engine auch: R_LightScaleTexture wirkt auf
    # das Vollbild, die Stufen entstehen danach (GL_GENERATE_MIPMAP). Nur RGB,
    # Alpha bleibt unberührt.
    if abbildung:
        r, g, b, a = bild.split()
        bild = Image.merge("RGBA", (r.point(abbildung), g.point(abbildung),
                                    b.point(abbildung), a))

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
    p.add_argument("quelle", nargs="+",
                   help="eine oder mehrere .pk3 — Academy liefert elf Stueck")
    p.add_argument("ziel")
    p.add_argument("--block", default="6x6")
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--astcenc", default="astcenc-neon",
                   help="Pfad zum Kodierer (aus ARM-software/astc-encoder gebaut)")
    p.add_argument("--tabellen", default="visionos/farbtabellen.txt",
                   help="Farbabbildung der Engine (siehe R_visionOS_TabellenAusgeben)")
    p.add_argument("--filter", default="",
                   help="nur Pfade, die diesen Text enthalten")
    p.add_argument("--limit", type=int, default=0,
                   help="nur die ersten N Texturen — zum Ausprobieren")
    args = p.parse_args()

    astcenc = shutil.which(args.astcenc) or args.astcenc
    if not pathlib.Path(astcenc).exists():
        print(f"Kodierer nicht gefunden: {args.astcenc}", file=sys.stderr)
        return 1

    # MEHRERE QUELLEN in ein Ausgabepaket.
    #
    # Academy kommt als elf .pk3 (gfx, models_1..4, textures_1..N). Umpacken
    # von Hand braucht es dafür nicht — eine .pk3 ist ein ZIP, und hier werden
    # sie ohnehin alle gelesen.
    #
    # Bei gleichem Pfad in zwei Quellen gewinnt die SPÄTERE. Das ist dieselbe
    # Regel wie im Spiel, wo die alphabetisch letzte pk3 gewinnt — die Reihenfolge
    # auf der Kommandozeile entscheidet.
    herkunft = {}
    for pfad in args.quelle:
        z = zipfile.ZipFile(pfad)
        for n in z.namelist():
            if not n.lower().endswith(ENDUNGEN):
                continue
            if args.filter and args.filter not in n:
                continue
            herkunft[n] = z

    namen = sorted(herkunft)
    if args.limit:
        namen = namen[:args.limit]
    print(f"{len(namen)} Texturen aus {len(args.quelle)} Paket(en), Block {args.block}")

    abbildung = lies_tabellen(pathlib.Path(args.tabellen))
    if abbildung is None:
        print(f"WARNUNG: {args.tabellen} fehlt -- ohne die Farbabbildung der "
              f"Engine wird alles zu hell.", file=sys.stderr)
    else:
        print(f"Farbabbildung aus {args.tabellen}: "
              f"128 -> {abbildung[128]}, 64 -> {abbildung[64]}")

    auftraege = [(n, herkunft[n].read(n), args.block, astcenc, abbildung)
                 for n in namen]

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
