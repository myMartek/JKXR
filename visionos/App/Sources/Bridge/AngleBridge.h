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

/* angle_render_view aus dem S4-Spike ist hier entfallen: dort zeichnete es ein
 * Dreieck zur Prüfung der Kette. Bei JKXR rendert die XR-Schicht selbst
 * (JKXR/visionos/TBXR_Common.mm) — sie importiert die Drawable-Texturen, setzt
 * die Rate-Map über ANGLESetDrawFramebufferRateMapMTL und übergibt der Engine
 * einen fertigen Framebuffer. Diese Brücke muss ANGLE nur noch hochfahren. */


#ifdef __cplusplus
}
#endif
