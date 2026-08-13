#!/usr/bin/env python3
"""Macht JKXRs Support-Bibliotheken auf Darwin/visionOS baubar.

Die Bibliotheken stammen aus den frühen 2000ern und nehmen an, dass "Apple"
gleich "Classic Mac OS" bedeutet. Auf modernen Apple-Plattformen greifen dadurch
Codepfade, die seit Mac OS 9 nicht mehr existieren.

Aufruf:

    python3 patch-supportlibs-darwin.py <SupportLibs-Verzeichnis>

Idempotent — bereits gepatchte Stellen werden übersprungen.
"""

import sys
from pathlib import Path

PATCHES = [
    (
        "libpng/pngpriv.h",
        """#  if (defined(__MWERKS__) && defined(macintosh)) || defined(applec) || \\
    defined(THINK_C) || defined(__SC__) || defined(TARGET_OS_MAC)""",
        """#  if (defined(__MWERKS__) && defined(macintosh)) || defined(applec) || \\
    defined(THINK_C) || defined(__SC__) || \\
    (defined(TARGET_OS_MAC) && !defined(__APPLE__))""",
        # TARGET_OS_MAC ist auf allen modernen Apple-Plattformen definiert — es
        # ist der Sammelbegriff für macOS, iOS, visionOS und die übrigen. Der
        # Zweig dahinter ist aber für Classic Mac OS gedacht und bindet <fp.h>
        # ein, das es seit Mac OS 9 nicht mehr gibt. __APPLE__ trennt beide
        # Welten: Classic Mac OS kannte es noch nicht.
        "libpng: <fp.h> nur noch für Classic Mac OS, nicht für modernes Apple",
    ),
    (
        "gl4es/include/EGL/eglplatform.h",
        """#else
#error "Platform not recognized"
#endif""",
        """#elif defined(__APPLE__)

/* Auf Apple-Plattformen gibt es keine nativen EGL-Fenstertypen: den Kontext
   erzeugt ANGLE, und gerendert wird in Texturen, die CompositorServices
   liefert. Die Typen müssen nur definiert sein, damit die Deklarationen
   übersetzen — benutzt werden sie nicht. */
typedef void *EGLNativeDisplayType;
typedef void *EGLNativePixmapType;
typedef void *EGLNativeWindowType;

#else
#error "Platform not recognized"
#endif""",
        "gl4es/EGL: native Typen für Apple definieren",
    ),
    (
        "../OpenJK/shared/qcommon/q_platform.h",
        """	#elif defined(__x86_64__)
		#define idx64
		#define ARCH_STRING "x86_64"
		#define Q3_LITTLE_ENDIAN
	#endif""",
        """	#elif defined(__x86_64__)
		#define idx64
		#define ARCH_STRING "x86_64"
		#define Q3_LITTLE_ENDIAN
	#elif defined(__aarch64__) || defined(__arm64__)
		// Apple Silicon — von OpenJK nie vorgesehen, der Block kannte nur
		// ppc, i386 und x86_64. Ohne diesen Zweig bleiben ARCH_STRING und
		// die Endianness undefiniert, und die Datei bricht später mit
		// "Architecture not supported" ab.
		#define idx64
		#define ARCH_STRING "arm64"
		#define Q3_LITTLE_ENDIAN
	#endif""",
        "OpenJK: arm64 als Apple-Architektur erkennen",
    ),
    (
        "../OpenJK/code/rd-gles/qgl.h",
        """#elif defined( __APPLE__ ) && defined( __MACH__ )

#include <MesaGL/gl.h>""",
        """#elif defined( __APPLE__ ) && defined( __MACH__ )

// Der ursprüngliche Zweig band <MesaGL/gl.h> ein — aus der Zeit, als Mac OS X
// OpenGL über Mesa bereitstellte. Auf Android greift stattdessen der
// __linux__-Zweig mit HAVE_GLES, weil Android Linux ist. Für visionOS gilt
// dasselbe wie dort: die GL-Header kommen von gl4es.
#ifdef HAVE_GLES
#include <GLES/gl.h>
// glext.h liefert die EXT-Konstanten, etwa GL_TEXTURE_MAX_ANISOTROPY_EXT.
// Auf Android zieht der NDK-Header sie mit herein, gl4es trennt sie.
#include <GLES/glext.h>
#else
#include <MesaGL/gl.h>
#endif""",
        "OpenJK/qgl.h: GLES-Header statt MesaGL auf Apple",
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Aufruf: {sys.argv[0]} <SupportLibs-Verzeichnis>")
        return 2

    root = Path(sys.argv[1])
    applied = skipped = failed = 0

    for rel, needle, replacement, description in PATCHES:
        path = root / rel
        if not path.is_file():
            print(f"  FEHLT   {rel}")
            failed += 1
            continue

        text = path.read_text(errors="surrogateescape")
        if replacement in text:
            print(f"  bereits {description}")
            skipped += 1
            continue
        if needle not in text:
            print(f"  FEHLER  {rel}: Suchtext nicht gefunden ({description})")
            failed += 1
            continue

        path.write_text(text.replace(needle, replacement, 1),
                        errors="surrogateescape")
        print(f"  ok      {description}")
        applied += 1

    print(f"\n{applied} angewandt, {skipped} bereits vorhanden, {failed} fehlgeschlagen")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
