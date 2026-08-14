// Brücke zu ANGLE.
//
// ANGLEs Header sind reines C und vertragen sich nicht mit Swifts Importer,
// sobald man EGL- und GL-Typen mischt. Deshalb bleibt alles Heikle hier und
// Swift sieht nur eine Handvoll schlichter Funktionen.

#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialisiert ANGLE mit dem Metal-Backend.
///
/// Wichtige Einschränkung: `eglCreateDeviceANGLE` existiert nur für D3D11, nicht
/// für Metal. Wir können ANGLE also **kein** MTLDevice vorgeben — es wählt
/// selbst eines. `EGL_ANGLE_metal_texture_client_buffer` verlangt aber, dass
/// importierte Texturen vom selben Device stammen. Ob das zutrifft, muss
/// gemessen werden; dafür gibt es `angle_metal_device()`.
///
/// Gibt true zurück, wenn Display, Kontext und Bindung stehen.
bool angle_init(void);

/// Macht den ANGLE-Kontext auf dem *aufrufenden* Thread aktiv.
///
/// EGL-Kontexte sind threadgebunden. `angle_init()` bindet ihn an den Thread,
/// der initialisiert — gezeichnet wird hier aber auf einem eigenen Renderthread.
/// Ohne diesen Aufruf schlägt dort jeder GL-Aufruf fehl, und zwar lautlos:
/// Shader "übersetzen" nicht und liefern einen leeren Fehlertext.
bool angle_make_current(void);

/// Das MTLDevice, das ANGLE tatsächlich benutzt — als undurchsichtiger Zeiger
/// zum Vergleich mit dem Device von CompositorServices.
const void *angle_metal_device(void);

/// Zusammenfassung des EGL-Zustands: Version, Renderer und ob die beiden
/// Interop-Extensions vorhanden sind, auf denen der gesamte Plan aufbaut.
void angle_describe(char *out, size_t cap);

/// Prüft, ob eine bestimmte Extension vom Display gemeldet wird.
bool angle_has_extension(const char *name);

/// Zeichnet ein Dreieck per OpenGL ES direkt in die Texturen von
/// CompositorServices — ohne Zwischenkopie.
///
/// `colorTexture` und `depthTexture` sind `MTLTexture`-Zeiger aus der Drawable,
/// `slice` wählt bei `layered`-Layout das Auge. Die Tiefe muss mitgeschrieben
/// werden: der Compositor braucht sie für die Reprojektion und verwirft sonst
/// den Frame.
///
/// `mvp16` ist eine 4x4-Matrix in Spaltenordnung, aufgebaut für Metals
/// Clip-Raum (z in [0,1]). Die Umrechnung auf OpenGLs [-1,1] passiert hier.
///
/// Gibt false zurück, wenn Import oder Framebuffer fehlschlagen — mit
/// Begründung auf stdout.
/// `rateMap` ist eine `MTLRasterizationRateMap` aus der Drawable, oder NULL für
/// gleichmäßige Rasterisierung.
///
/// Ohne sie wird über das gesamte Blickfeld in voller Dichte gerastert, und
/// CompositorServices deckelt die Drawable-Auflösung entsprechend — die Vision
/// Pro käme dann nicht über das hinaus, was günstigere Headsets liefern.
///
/// Die Unterstützung dafür ist eine Fork-Ergänzung in ANGLEs Metal-Backend
/// (siehe patch-angle-foveation.py); im Original kennt es Rate Maps nicht.
bool angle_render_view(const void *colorTexture,
                       const void *depthTexture,
                       const void *rateMap,
                       int slice,
                       int originX, int originY,
                       int width, int height,
                       const float *mvp16);

#ifdef __cplusplus
}
#endif
