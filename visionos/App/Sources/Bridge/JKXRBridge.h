// Was die Hülle von der Engine und der XR-Schicht aus sieht.
//
// Alle diese Funktionen sind in C++ bzw. Objective-C++ definiert und mit
// Q_EXPORT bzw. extern "C" exportiert. Ohne Q_EXPORT wären sie lokale Symbole:
// der Client wird mit -fvisibility=hidden gebaut (aus Android_client_ja.mk
// übernommen), und Swift könnte sie dann nicht aufrufen.

#pragma once

#include <CompositorServices/CompositorServices.h>

// Alles, was in einem der beiden Spielsätze liegt, geht über die Tabelle dort:
// Outcast und Academy bringen jede dieser Funktionen je einmal mit, und nach dem
// Teil-Link ist keine davon global. Frühere Fassungen dieser Datei deklarierten
// sie einzeln — das ging nur, solange es genau eine Engine gab.
#include "JKXR_visionOS_Spiel.h"

#ifdef __cplusplus
extern "C" {
#endif

// --- ARKit (Sources/Bridge/WorldTracking.m) -------------------------------

void TBXR_visionOS_StartWorldTracking(void);

/// Der Zubehör-Provider für die Controller-Posen.
void *TBXR_visionOS_GetAccessoryTracking(void);

/// Lädt die räumlichen Zubehörgeräte und startet die Verfolgung.
void TBXR_visionOS_StartAccessoryTracking(void);

/// Das GCDevice einer Hand (0 = links, 1 = rechts), Händigkeit von ARKit.
void *TBXR_visionOS_GetSpatialDevice(int hand);

#ifdef __cplusplus
}
#endif
