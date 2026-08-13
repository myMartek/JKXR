#!/usr/bin/env python3
"""Leitet JKXRs visionOS-XR-Header aus der Android-Fassung ab.

JKXR wählt die Plattformschicht in `VrCommon.h` über den Präprozessor:

    #ifdef _WIN32
    #include "windows/TBXR_Common.h"
    #else
    #include "android/TBXR_Common.h"
    #endif

Ein visionOS-Zweig braucht denselben Satz an Typen und Deklarationen. Die
Android-Fassung von Hand abzuschreiben hieße, 348 Zeilen zu duplizieren, die bei
jedem JKXR-Update auseinanderlaufen. Stattdessen wird sie hier mechanisch
umgeschrieben — die Unterschiede sind klein und klar benennbar:

* Plattform-Header: EGL, GLES3, JNI und android/* entfallen. Die OpenXR-*Typen*
  bleiben: sie sind reine Structs und Handles und übersetzen für visionOS
  problemlos. Nur die OpenXR-*Funktionen* fehlen — die ersetzt der
  Action-System-Nachbau.
* Logging: __android_log_print gibt es nicht, os_log schon.
* Die Android-Thread- und Surface-Verwaltung (ovrAppThread, JNIEnv,
  surfaceMessage*) entfällt ersatzlos; auf visionOS übernimmt das die
  SwiftUI-Hülle mitsamt CompositorServices.

Aufruf:

    python3 make-visionos-xr-header.py <JKXR-Verzeichnis>
"""

import re
import sys
from pathlib import Path

PREAMBLE_NEEDLE = """//OpenXR
#define XR_USE_GRAPHICS_API_OPENGL_ES 1
#define XR_USE_PLATFORM_ANDROID 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES3/gl3ext.h>
#include <jni.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr_helpers.h>

#include <android/native_window_jni.h>
#include <android/log.h>"""

PREAMBLE_REPLACEMENT = """// OpenXR-Typen ohne OpenXR-Laufzeit.
//
// visionOS hat keine OpenXR-Implementierung. Die Typen aus dem SDK sind aber
// reine Structs und Handles und übersetzen unverändert — nur die Funktionen
// fehlen. Die vom neutralen JKXR-Code benutzten sechzehn stammen alle aus dem
// Action-System und werden auf PSVR2-Sense-Controllern nachgebaut.
//
// XR_USE_PLATFORM_ANDROID und XR_USE_GRAPHICS_API_OPENGL_ES bleiben ungesetzt:
// beide ziehen Plattform-Header nach, die es hier nicht gibt.
#include <openxr/openxr.h>

// EGL und GLES kommen von ANGLE statt vom Android-NDK. Bewusst ANGLE und nicht
// gl4es: die XR-Schicht spricht mit dem echten GLES (Framebuffer-Objekte,
// EGL_METAL_TEXTURE_ANGLE), während gl4es' Header die Desktop-GL-Emulation für
// die Engine bereitstellen. Apples eigenes OpenGLES-Framework gibt es auf
// visionOS nicht.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

// openxr_helpers.h liefert Hilfsfunktionen wie ToXrTime, die der neutrale
// JKXR-Code benutzt. Reine Inline-Funktionen, keine Laufzeitabhängigkeit.
#include <openxr_helpers.h>

// pthread und stdio zog auf Android jni.h beziehungsweise android/log.h
// transitiv mit herein.
#include <pthread.h>
#include <stdio.h>

#ifdef __OBJC__
@class MTLDeviceHolder;
#endif

// Von der SwiftUI-Hülle bereitgestellt: der World-Tracking-Provider für die
// Kopfpose und der LayerRenderer des Immersive Space.
#ifdef __cplusplus
extern "C" {
#endif
void *TBXR_visionOS_GetWorldTracking(void);
#ifdef __cplusplus
}
#endif"""

LOG_NEEDLE = """#define ALOGE(...) __android_log_print( ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__ )"""

LOG_REPLACEMENT = """// fprintf statt os_log: os_log verlangt einen zur Übersetzungszeit bekannten
// Formatstring, JKXR reicht an einigen Stellen aber Variablen durch. Die
// Ausgabe landet über devicectl --console ohnehin dort, wo man sie braucht.
#define ALOGE(...) do { fprintf(stderr, "[TBXR] " __VA_ARGS__); fprintf(stderr, "\\n"); } while (0)"""

FRAMEBUFFER_NEEDLE = """typedef struct {
    int Width;
    int Height;
    int Multisamples;
    uint32_t TextureSwapChainLength;
    uint32_t TextureSwapChainIndex;
    ovrSwapChain ColorSwapChain;
    XrSwapchainImageOpenGLESKHR* ColorSwapChainImage;
    GLuint* DepthBuffers;
    GLuint* FrameBuffers;
} ovrFramebuffer;"""

FRAMEBUFFER_REPLACEMENT = """// Auf visionOS gibt es keine OpenXR-Swapchain: CompositorServices reicht pro
// Frame eine Drawable heraus, deren Metal-Texturen über EGLImage als GL-Textur
// importiert und an ein FBO gehängt werden (siehe spikes/s4-angle).
//
// Die Felder Width/Height sind Screen-Koordinaten, nicht physische — bei
// aktiver Foveation unterscheiden sich beide um Faktor 2,5.
typedef struct {
    int Width;
    int Height;
    int Multisamples;
    GLuint  ColorTexture;   // aus der Drawable importiert, pro Frame neu
    GLuint  DepthTexture;   // desgleichen; der Compositor braucht die Tiefe
    GLuint  FrameBuffer;
} ovrFramebuffer;"""

JAVA_NEEDLE = """typedef struct ovrJava_ {
    JavaVM* Vm; //< Java Virtual Machine
    JNIEnv* Env; //< Thread specific environment
    jobject ActivityObject; //< Java activity object
} ovrJava;"""

JAVA_REPLACEMENT = """// Auf Android hält diese Struktur die JNI-Handles. Auf visionOS gibt es nichts
// Entsprechendes; sie bleibt als leere Hülle erhalten, weil neutraler Code
// "extern ovrJava java" referenziert.
typedef struct ovrJava_ {
    void* Reserved;
} ovrJava;"""

APPTHREAD_NEEDLE = """    JavaVM *\t\tJavaVm;
    jobject\t\t\tActivityObject;
    jclass          ActivityClass;
    pthread_t\t\tThread;
    surfaceMessageQueue\tMessageQueue;
    ANativeWindow * NativeWindow;
} ovrAppThread;"""

APPTHREAD_REPLACEMENT = """    // Java- und Surface-Verwaltung entfällt: auf visionOS übernimmt das die
    // SwiftUI-Hülle mit CompositorServices.
    pthread_t\t\tThread;
} ovrAppThread;"""

# Deklarationen, die auf visionOS ersatzlos entfallen. Auf Android verwalten sie
# den Java-seitigen Anwendungs-Thread und die Surface-Nachrichtenschlange; beides
# übernimmt hier die SwiftUI-Hülle mit CompositorServices.
ANDROID_ONLY = [
    "ovrAppThread_Create",
    "ovrAppThread_Destroy",
    "surfaceMessage_Init",
    "surfaceMessage_SetPointerParm",
    "surfaceMessage_GetPointerParm",
    "surfaceMessageQueue_Create",
    "surfaceMessageQueue_Destroy",
    "surfaceMessageQueue_Enable",
    "surfaceMessageQueue_PostMessage",
    "AppThreadFunction",
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Aufruf: {sys.argv[0]} <JKXR-Verzeichnis>")
        return 2

    jkxr = Path(sys.argv[1])
    source = jkxr / "android" / "TBXR_Common.h"
    target = jkxr / "visionos" / "TBXR_Common.h"

    if not source.is_file():
        print(f"FEHLER: {source} nicht gefunden")
        return 1

    text = source.read_text(errors="surrogateescape")

    for needle, replacement, what in (
        (PREAMBLE_NEEDLE, PREAMBLE_REPLACEMENT, "Plattform-Header"),
        (LOG_NEEDLE, LOG_REPLACEMENT, "Logging"),
        (FRAMEBUFFER_NEEDLE, FRAMEBUFFER_REPLACEMENT, "ovrFramebuffer"),
        (JAVA_NEEDLE, JAVA_REPLACEMENT, "ovrJava"),
        (APPTHREAD_NEEDLE, APPTHREAD_REPLACEMENT, "ovrAppThread"),
    ):
        if needle not in text:
            print(f"  FEHLER {what}: Suchtext nicht gefunden — hat sich die "
                  "Android-Fassung geändert?")
            return 1
        text = text.replace(needle, replacement, 1)

    # ANativeWindow ist Androids Fenster-Handle. Auf visionOS gibt es kein
    # Fenster in diesem Sinn — der Compositor liefert Drawables. Das Feld
    # bleibt als undurchsichtiger Zeiger erhalten, damit die Struktur ihre
    # Gestalt behält und der neutrale Code unverändert übersetzt.
    text = text.replace(
        "    ANativeWindow* NativeWindow;",
        "    void*          NativeWindow;   // [visionOS] kein Androidfenster")

    # Verbleibende __android_log_print-Aufrufe (ALOGV und Verwandte)
    text = re.sub(r"__android_log_print\(\s*ANDROID_LOG_\w+,\s*LOG_TAG,\s*",
                  "fprintf(stderr, ", text)

    # Android-only Deklarationen auskommentieren statt löschen: so bleibt beim
    # Abgleich mit einer neuen JKXR-Fassung sichtbar, was bewusst entfiel.
    removed = 0
    lines = []
    for line in text.splitlines():
        if any(name in line for name in ANDROID_ONLY) and line.strip().endswith(";"):
            lines.append(f"// [visionOS: entfällt] {line}")
            removed += 1
        else:
            lines.append(line)
    text = "\n".join(lines) + "\n"

    header = (
        "// Abgeleitet aus android/TBXR_Common.h durch make-visionos-xr-header.py.\n"
        "// Nicht von Hand ändern — bei einem JKXR-Update neu erzeugen lassen.\n\n"
    )

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(header + text, errors="surrogateescape")
    print(f"  ok      {target} ({removed} Android-Deklarationen entfernt)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
