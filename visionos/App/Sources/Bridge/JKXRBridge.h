// Was die Hülle von der Engine und der XR-Schicht aus sieht.
//
// Alle diese Funktionen sind in C++ bzw. Objective-C++ definiert und mit
// Q_EXPORT bzw. extern "C" exportiert. Ohne Q_EXPORT wären sie lokale Symbole:
// der Client wird mit -fvisibility=hidden gebaut (aus Android_client_ja.mk
// übernommen), und Swift könnte sie dann nicht aufrufen.

#pragma once

#include <CompositorServices/CompositorServices.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- XR-Schicht (JKXR/visionos/TBXR_Common.mm) ----------------------------

/// Übergibt den LayerRenderer. Danach kann die XR-Schicht Frames holen.
///
/// Voraussetzung: ANGLE ist initialisiert und sein Kontext auf *diesem* Thread
/// aktiv — die Funktion holt sich den EGLDisplay über eglGetCurrentDisplay().
void TBXR_visionOS_SetLayerRenderer(cp_layer_renderer_t renderer);

/// Hinterlegt die Renderauflösung je Auge, in Screen-Koordinaten.
///
/// Muss vor JKXR_visionOS_Main aufgerufen werden: WIN_Init fragt die Auflösung
/// beim Start ab, CompositorServices gibt sie aber erst mit der ersten Drawable
/// heraus (die C-API hat überhaupt keinen Zugriff auf Breite oder Höhe).
void TBXR_visionOS_SetScreenRes(int width, int height);

/// Gibt die tatsächlichen Namen aller Elemente verbundener Controller aus.
///
/// Einmal auf echter Hardware aufrufen und die geratene Tastenzuordnung in
/// OpenXrActions.mm gegen die gemessenen Namen tauschen.
void TBXR_visionOS_DumpInputs(void);

// --- ARKit (Sources/Bridge/WorldTracking.m) -------------------------------

void TBXR_visionOS_StartWorldTracking(void);

// --- Engine (code/visionos/visionos_main.mm) ------------------------------

/// Die Hauptschleife der Engine. Blockiert bis zum Ende.
///
/// Auf einem eigenen Thread aufzurufen, niemals auf einer Warteschlange von
/// Swift Concurrency: die Schleife gibt nie ab und würde den Pool aushungern.
/// Genau dieser Fehler war in S4 die Ursache, dass ARKit keine Posen lieferte.
int JKXR_visionOS_Main(int argc, char *argv[]);

/// Beendet die Schleife nach dem laufenden Bild.
void JKXR_visionOS_RequestShutdown(void);

#ifdef __cplusplus
}
#endif
