#!/usr/bin/env python3
"""Macht gl4es auf Darwin/visionOS baubar.

gl4es exportiert seine 850+ GL-Einstiegspunkte über
`__attribute__((alias("gl4es_glFoo")))`. Das ist ein ELF-Feature; Mach-O kennt
es nicht, und Clang bricht mit "aliases are not supported on darwin" ab.

Mach-O kann Aliase trotzdem — nur im Linker statt im Compiler. Der Weg:

1. `AliasExport` auf Darwin leer definieren. Dafür gibt es bereits einen
   Präzedenzfall im Projekt: unter Emscripten ist es ebenfalls leer.
2. Die Alias-Paare mechanisch aus den Quellen ziehen und als `-alias_list`
   ausgeben, die beim Linken des Endprodukts mitgegeben wird.

Beim Linken ist zusätzlich `-force_load` auf die statische Bibliothek nötig:
Ein Alias verlangt, dass sein Ziel im Link vorhanden ist, aber Objekte einer
statischen Bibliothek werden nur eingebunden, wenn etwas sie referenziert —
und referenziert wird hier der Aliasname, den es ohne den Alias noch nicht gibt.

Aufruf:

    python3 patch-gl4es-darwin.py <gl4es-verzeichnis> <ausgabe-alias-liste>
"""

import re
import sys
from pathlib import Path

ATTRIBUTES_H = "src/gl/attributes.h"
LOADER_C = "src/gl/loader.c"

# <linux/limits.h> gibt es auf Darwin nicht; PATH_MAX steht dort in <limits.h>
# und <sys/syslimits.h>.
LOADER_NEEDLE = """#else
#include <linux/limits.h>
#endif"""

LOADER_REPLACEMENT = """#elif defined(__APPLE__)
#include <limits.h>
#include <sys/syslimits.h>
#else
#include <linux/limits.h>
#endif"""

NEEDLE = """#ifndef AliasExport
 #ifdef __EMSCRIPTEN__
  #define AliasExport(name)
 #else
  #define AliasExport(name)   __attribute__((alias(name))) __attribute__((visibility("default")))
 #endif
#endif // AliasExport"""

REPLACEMENT = """#ifndef AliasExport
 #if defined(__EMSCRIPTEN__)
  #define AliasExport(name)
 #elif defined(__APPLE__)
  // Mach-O kennt keine Compiler-Aliase ("aliases are not supported on darwin").
  // Die Aliase entstehen stattdessen beim Linken über -alias_list; die Liste
  // erzeugt patch-gl4es-darwin.py aus genau diesen Deklarationen.
  #define AliasExport(name)
 #else
  #define AliasExport(name)   __attribute__((alias(name))) __attribute__((visibility("default")))
 #endif
#endif // AliasExport"""

# void glBlendColorEXT(GLclampf red, ...) AliasExport("gl4es_glBlendColor");
#      ^^^^^^^^^^^^^^^ Aliasname                       ^^^^^^^^^^^^^^^^^^ Ziel
#
# Nicht mit einer einzigen Regex über den ganzen Text: eine mehrzeilige,
# nicht-gierige Suche greift über Anweisungsgrenzen hinweg und fischt
# Makronamen wie THUNK oder GL_RECT als vermeintliche Funktionen ein.
# Stattdessen erst an Semikola trennen, dann je Anweisung auswerten.
TARGET = re.compile(r"AliasExport\s*\(\s*\"([^\"]+)\"\s*\)")
FUNCTION_NAME = re.compile(r"(\w+)\s*\(")


def extract_pairs(text: str) -> list[tuple[str, str]]:
    pairs = []
    for statement in text.split(";"):
        target_match = TARGET.search(statement)
        if not target_match:
            continue
        # Alles ab AliasExport abschneiden; übrig bleibt die Deklaration.
        declaration = statement[: target_match.start()]
        # Der Funktionsname ist der Bezeichner vor der ersten Klammer —
        # ein Rückgabetyp enthält keine.
        name_match = FUNCTION_NAME.search(declaration)
        if name_match:
            pairs.append((name_match.group(1), target_match.group(1)))
    return pairs


LOADER_APPLE_NEEDLE = """    gles = open_lib((globals4es.es==1)?gles_lib:gles2_lib, gles_override);
    WARN_NULL(gles);"""

LOADER_APPLE_REPLACEMENT = """#ifdef __APPLE__
    /* visionOS-Portierung, siehe patch-gl4es-darwin.py.
     *
     * open_lib() setzt Pfade als <prefix><name>.<ext> zusammen und sucht in
     * /usr/lib und Verwandten. Auf visionOS gibt es dort kein GLES, und ANGLE
     * liegt als eingebettetes Framework im App-Bundle — ein anderes Namens-
     * schema, das die Tabelle nicht abbildet. Ohne diesen Zweig bleiben `gles`
     * und `egl` NULL, gl4es meldet drei Warnungen und liefert danach still
     * nichts mehr.
     *
     * dlopen mit dem Installationsnamen lädt nichts neu: das Framework hängt
     * bereits als LC_LOAD_DYLIB im Programm, dlopen gibt nur sein Handle
     * zurück. @rpath löst sich über @executable_path/Frameworks auf.
     *
     * NICHT RTLD_DEFAULT verwenden, so naheliegend es wirkt. Das Programm
     * exportiert glDrawArrays und die übrigen GL-Namen selbst — als Aliase auf
     * gl4es' eigene Wrapper (siehe -alias_list). dlsym(RTLD_DEFAULT, ...)
     * durchsucht das Hauptprogramm zuerst und gäbe gl4es seine eigene Funktion
     * zurück: endlose Rekursion statt eines Aufrufs an ANGLE.
     */
    gles = dlopen("@rpath/libGLESv2.framework/libGLESv2", flags_for_angle());
    WARN_NULL(gles);
#else
    gles = open_lib((globals4es.es==1)?gles_lib:gles2_lib, gles_override);
    WARN_NULL(gles);
#endif"""

LOADER_EGL_NEEDLE = """#ifdef NOEGL
    egl = gles;
#else"""

LOADER_EGL_REPLACEMENT = """#if defined(__APPLE__)
    /* Auch mit NOEGL braucht gl4es an einigen Stellen eglGetProcAddress, und
     * das exportiert libGLESv2 nicht — es liegt in libEGL. `egl = gles` wie im
     * NOEGL-Zweig unten wäre hier also falsch. */
    egl = dlopen("@rpath/libEGL.framework/libEGL", flags_for_angle());
#elif defined(NOEGL)
    egl = gles;
#else"""

LOADER_HELPER_NEEDLE = """void *open_lib(const char **names, const char *override) {"""

LOADER_HELPER_REPLACEMENT = """#ifdef __APPLE__
/* Dieselben Flags wie in open_lib, ohne RTLD_DEEPBIND (gibt es auf Darwin
 * nicht). Als Funktion, damit beide Aufrufstellen sie teilen. */
static int flags_for_angle(void) {
    return RTLD_LOCAL | RTLD_NOW;
}
#endif

void *open_lib(const char **names, const char *override) {"""


GLX_STUBS_C = "src/glx/darwin_stubs.c"

GLX_STUBS_SOURCE = """/*
 * Erzeugt von patch-gl4es-darwin.py — nicht von Hand ändern.
 *
 * gl4es baut sein glx/-Verzeichnis nur unter Linux, Emscripten und AmigaOS.
 * Auf Darwin bleibt es außen vor, aber gl/init.c und gl/framebuffers.c rufen
 * drei Funktionen daraus trotzdem auf. Unter Emscripten fällt das nicht auf:
 * dort stehen die Aufrufe in `#ifndef __EMSCRIPTEN__`.
 *
 * Die Stubs sind nicht geraten. In der Konfiguration NOX11 + NOEGL, die wir
 * bauen, tut das Original genau nichts:
 *
 *   gl4es_getMainFBSize  ist in glx/glx.c vollständig von
 *                        `#if !defined(NOX11) && !defined(NOEGL) && !defined(ANDROID)`
 *                        umschlossen — der Rumpf ist leer, die übergebenen
 *                        Werte bleiben unverändert. Der Kommentar dort sagt es
 *                        ausdrücklich: "noegl, no updating of framebuffer size".
 *   glx_init             richtet die X11/EGL-Anbindung ein, die es hier nicht
 *                        gibt: ANGLE liefert den Kontext.
 *   LoadGBMFunctions     lädt libgbm, ein Linux-Grafikstack. Der Aufruf steht
 *                        ohnehin hinter `if (globals4es.usegbm)`, und usegbm
 *                        lässt sich außerhalb von Linux nicht einschalten.
 *
 * glx/hardext.c wird dagegen wirklich gebraucht (es definiert `hardext` und
 * GetHardwareExtensions) und behandelt NOX11+NOEGL bereits selbst. Es wird
 * darum in die Bauliste aufgenommen, genau wie im Emscripten-Zweig.
 */

#include <GL/gl.h>

void glx_init(void)
{
}

void LoadGBMFunctions(void)
{
}

void gl4es_getMainFBSize(GLint *width, GLint *height)
{
    (void)width;
    (void)height;
}
"""

GLX_CMAKE_NEEDLE = """else()
    message(STATUS "Not on Linux: building without GLX support.")
endif()"""

GLX_CMAKE_REPLACEMENT = """else()
    message(STATUS "Not on Linux: building without GLX support.")
    # visionOS-Portierung, siehe patch-gl4es-darwin.py.
    #
    # "Ohne GLX" heißt nicht "ohne glx/": hardext.c definiert `hardext` und
    # GetHardwareExtensions, die der gesamte GL-Kern benutzt, und behandelt
    # NOX11+NOEGL bereits selbst. Der Emscripten-Zweig weiter unten nimmt
    # genau diese eine Datei auf — hier ist es dieselbe Lage.
    #
    # darwin_stubs.c liefert die drei übrigen glx-Funktionen, die gl/init.c
    # und gl/framebuffers.c unbedingt aufrufen.
    if(APPLE)
        include_directories(glx)
        list(APPEND GL_SRC
            glx/hardext.c
            glx/darwin_stubs.c
        )
        list(APPEND GL_H
            glx/hardext.h
        )
    endif()
endif()"""


def patch_glx_gap(root: Path) -> bool:
    """Schließt die Lücke, die entsteht, weil glx/ auf Darwin nicht gebaut wird."""
    stubs = root / GLX_STUBS_C
    if stubs.is_file() and stubs.read_text() == GLX_STUBS_SOURCE:
        print(f"  bereits {GLX_STUBS_C}")
    else:
        stubs.write_text(GLX_STUBS_SOURCE)
        print(f"  ok      {GLX_STUBS_C}: glx_init, LoadGBMFunctions, gl4es_getMainFBSize")

    cmake = root / "src" / "CMakeLists.txt"
    text = cmake.read_text()
    if "glx/darwin_stubs.c" in text:
        print("  bereits src/CMakeLists.txt: glx/hardext.c + Stubs auf Apple")
    elif GLX_CMAKE_NEEDLE in text:
        cmake.write_text(text.replace(GLX_CMAKE_NEEDLE, GLX_CMAKE_REPLACEMENT, 1))
        print("  ok      src/CMakeLists.txt: glx/hardext.c + Stubs auf Apple")
    else:
        print("  FEHLER  src/CMakeLists.txt: Nicht-Linux-Zweig nicht gefunden")
        return False

    return True


def patch_loader_angle(root: Path) -> bool:
    """Zeigt gl4es auf ANGLE statt auf ein /usr/lib, das es nicht gibt."""
    loader = root / LOADER_C
    text = loader.read_text()

    if "libGLESv2.framework" in text:
        print(f"  bereits {LOADER_C}: gles/egl aus dem App-Bundle")
        return True

    for needle, replacement, what in (
        (LOADER_HELPER_NEEDLE, LOADER_HELPER_REPLACEMENT, "flags_for_angle"),
        (LOADER_APPLE_NEEDLE, LOADER_APPLE_REPLACEMENT, "gles"),
        (LOADER_EGL_NEEDLE, LOADER_EGL_REPLACEMENT, "egl"),
    ):
        if needle not in text:
            print(f"  FEHLER  {LOADER_C}: Suchtext für {what} nicht gefunden")
            return False
        text = text.replace(needle, replacement, 1)

    loader.write_text(text)
    print(f"  ok      {LOADER_C}: gles/egl aus dem App-Bundle statt /usr/lib")
    return True


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(f"Aufruf: {sys.argv[0]} <gl4es-verzeichnis> <ausgabe-alias-liste> "
              "[gebaute-libGL.a]")
        print()
        print("Ohne dritten Parameter werden alle gefundenen Aliase geschrieben.")
        print("Mit gebauter Bibliothek wird gegen deren Symbole gefiltert — nötig,")
        print("weil manche Ziele je nach Konfiguration gar nicht entstehen (etwa")
        print("die GLX-Funktionen, die es außerhalb von Linux nicht gibt). Ein")
        print("Alias auf ein fehlendes Ziel lässt den Linker scheitern.")
        return 2

    root = Path(sys.argv[1])
    out = Path(sys.argv[2])
    library = Path(sys.argv[3]) if len(sys.argv) == 4 else None

    header = root / ATTRIBUTES_H
    if not header.is_file():
        print(f"FEHLER: {header} nicht gefunden")
        return 1

    text = header.read_text()
    if REPLACEMENT in text:
        print(f"  bereits {ATTRIBUTES_H}: AliasExport auf Darwin leer")
    elif NEEDLE in text:
        header.write_text(text.replace(NEEDLE, REPLACEMENT, 1))
        print(f"  ok      {ATTRIBUTES_H}: AliasExport auf Darwin leer")
    else:
        print(f"  FEHLER  {ATTRIBUTES_H}: Suchtext nicht gefunden")
        return 1

    # linux/limits.h
    loader = root / LOADER_C
    loader_text = loader.read_text()
    if LOADER_REPLACEMENT in loader_text:
        print(f"  bereits {LOADER_C}: Apple-Zweig für limits.h")
    elif LOADER_NEEDLE in loader_text:
        loader.write_text(loader_text.replace(LOADER_NEEDLE, LOADER_REPLACEMENT, 1))
        print(f"  ok      {LOADER_C}: Apple-Zweig für limits.h")
    else:
        print(f"  FEHLER  {LOADER_C}: Suchtext nicht gefunden")
        return 1

    if not patch_glx_gap(root):
        return 1

    if not patch_loader_angle(root):
        return 1

    # glstub.c erzeugt Implementierung und Alias in einem Makro. Der Aliasname
    # entsteht dort per Token-Verkettung, taucht also nicht als Zeichenkette auf
    # — die Extraktion unten wertet die STUB-Zeilen deshalb gesondert aus.
    stub = root / "src/gl/wrap/glstub.c"
    stub_needle = ('ret def args __attribute((alias("gl4es_"#def))) '
                   '__attribute__((visibility("default")));')
    stub_replacement = 'ret def args AliasExport("gl4es_"#def);'
    stub_text = stub.read_text(errors="surrogateescape")
    if stub_replacement in stub_text:
        print("  bereits src/gl/wrap/glstub.c: STUB-Makro auf AliasExport")
    elif stub_needle in stub_text:
        stub_text = stub_text.replace(stub_needle, stub_replacement, 1)
        if "attributes.h" not in stub_text:
            stub_text = stub_text.replace(
                "#include <string.h>",
                '#include <string.h>\n#include "../attributes.h"', 1)
        stub.write_text(stub_text, errors="surrogateescape")
        print("  ok      src/gl/wrap/glstub.c: STUB-Makro auf AliasExport")
    else:
        print("  FEHLER  src/gl/wrap/glstub.c: STUB-Makro nicht gefunden")
        return 1

    # In src/gl/wrap/gles.c stehen die Aliase wörtlich statt über das Makro —
    # die Datei sieht generiert aus. Auf AliasExport normalisieren, damit die
    # zentrale Definition greift und die Extraktion unten sie mitbekommt.
    literal = re.compile(
        r'__attribute__\(\(alias\("([^"]+)"\)\)\)\s*'
        r'__attribute__\(\(visibility\("default"\)\)\)'
    )
    for source in sorted((root / "src").rglob("*.c")):
        # surrogateescape: mindestens eine Quelldatei ist nicht UTF-8, und beim
        # Zurückschreiben dürfen ihre Bytes nicht verändert werden.
        text = source.read_text(errors="surrogateescape")
        converted, count = literal.subn(r'AliasExport("\1")', text)
        if count == 0:
            continue
        # attributes.h sicherstellen: gles.c bindet es nicht direkt ein.
        if "attributes.h" not in converted:
            converted = converted.replace(
                '#include "gles.h"',
                '#include "gles.h"\n#include "../attributes.h"', 1)
        source.write_text(converted, errors="surrogateescape")
        rel = source.relative_to(root)
        print(f"  ok      {rel}: {count} wörtliche Aliase auf AliasExport umgestellt")

    # Alias-Paare einsammeln
    pairs: dict[str, str] = {}
    for source in sorted((root / "src").rglob("*.c")):
        for alias, target in extract_pairs(source.read_text(errors="surrogateescape")):
            # Nur echte GL-Einstiegspunkte: Name beginnt mit "gl", ist aber
            # nicht selbst einer von gl4es' internen gl4es_*-Namen. Ohne die
            # zweite Bedingung rutscht gelegentlich ein internes Symbol als
            # vermeintlicher Alias durch.
            if alias != target and alias.startswith("gl") \
                    and not alias.startswith("gl4es_"):
                pairs[alias] = target

    # STUB(ret, name, args); — auskommentierte Zeilen überspringen.
    stub_decl = re.compile(r"^\s*STUB\s*\(\s*\w+\s*,\s*(\w+)\s*,", re.MULTILINE)
    for name in stub_decl.findall(stub.read_text(errors="surrogateescape")):
        pairs[name] = f"gl4es_{name}"
    print(f"  {len(stub_decl.findall(stub.read_text(errors='surrogateescape')))} "
          "STUB-Aliase ergänzt")

    # Gegen die gebaute Bibliothek filtern: ein Alias auf ein Ziel, das nicht
    # existiert, lässt den Linker scheitern. Betrifft vor allem GLX, das
    # außerhalb von Linux nicht gebaut wird.
    if library is not None:
        import subprocess
        symbols = subprocess.run(["nm", "-g", str(library)],
                                 capture_output=True, text=True).stdout
        present = {line.split()[-1].lstrip("_")
                   for line in symbols.splitlines()
                   if " T " in line or " S " in line}
        dropped = {a: t_ for a, t_ in pairs.items() if t_ not in present}
        pairs = {a: t_ for a, t_ in pairs.items() if t_ in present}
        if dropped:
            examples = ", ".join(sorted(dropped)[:4])
            print(f"  {len(dropped)} Aliase verworfen, Ziel nicht gebaut "
                  f"(z. B. {examples})")

    # -alias_list erwartet je Zeile: <vorhandenes Symbol> <Aliasname>
    # Führender Unterstrich, weil Mach-O C-Symbole so dekoriert.
    lines = [f"_{target} _{alias}" for alias, target in sorted(pairs.items())]
    out.write_text("\n".join(lines) + "\n")

    print(f"\n{len(pairs)} Aliase nach {out} geschrieben")
    print("Beim Linken mitgeben:")
    print(f"  -Wl,-alias_list,{out}  -Wl,-force_load,<pfad>/libGL.a")
    return 0


if __name__ == "__main__":
    sys.exit(main())
