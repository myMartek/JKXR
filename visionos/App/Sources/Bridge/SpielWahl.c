// Welches Spiel läuft.
//
// Liegt bewusst im App-Ziel und nicht in einem der beiden teil-gelinkten Sätze:
// gelesen wird es aus der Hülle und aus WorldTracking.m, und zwar auch dann,
// wenn die Auswahl noch nicht gefallen ist. In einem Satz wäre es das falsche
// Symbol, weil es genau die Frage beantworten soll, welcher Satz gilt.

#include "JKXR_visionOS_Spiel.h"
#include "JKXRBridge.h"   // TBXR_visionOS_GetAccessoryTracking

#include <stdio.h>

const JKXR_visionOS_Spiel *JKXR_visionOS_Gewaehlt = NULL;

void JKXR_visionOS_Waehle(JKXR_visionOS_SpielArt art)
{
    switch (art) {
        case JKXR_visionOS_JediOutcast:
            JKXR_visionOS_Gewaehlt = &JKXR_visionOS_Spiel_jo;
            break;
        case JKXR_visionOS_JediAcademy:
        default:
            JKXR_visionOS_Gewaehlt = &JKXR_visionOS_Spiel_ja;
            break;
    }
    // Über printf, nicht über Com_Printf: die Engine läuft noch nicht, und ihre
    // Konsole gehört ohnehin dem gewählten Satz.
    printf("[JKXR] Spiel gewaehlt: %s\n", JKXR_visionOS_Gewaehlt->name);

    // Einen bereits laufenden Zubehör-Provider nachträglich zustellen.
    //
    // WorldTracking.m schiebt ihn beim Aufbau in die Tabelle, aber der Aufbau
    // kann VOR der Auswahl passieren — er wird auch von der Benachrichtigung
    // über neu verbundene Controller angestoßen. Ohne diesen Nachzug bliebe
    // gTracking in OpenXrActions.mm nil, xrLocateSpace lieferte keine Pose, und
    // die Controller würden nicht verfolgt, obwohl ARKit sie kennt.
    void *provider = TBXR_visionOS_GetAccessoryTracking();
    if (provider) {
        JKXR_visionOS_Gewaehlt->SetAccessoryTracking(provider);
        printf("[JKXR] Zubehoer-Provider stand schon, nachgereicht\n");
    }
}
