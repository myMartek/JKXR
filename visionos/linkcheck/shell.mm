// Platzhalter-Hülle für den Prüflink in link-visionos.sh.
//
// Der Prüflink baut aus denselben Objekten wie die App ein eigenständiges
// Programm. Er ersetzt NICHT den Xcode-Build — er beantwortet eine Frage, die
// Xcode nicht stellt: ob die 793 gl4es-Aliase samt -force_load tragen und ob
// alle Einsprungpunkte im Export-Trie landen.
//
// Dafür braucht ld ein main und das eine Symbol, das sonst aus der SwiftUI-
// Hülle käme. Mehr steht hier bewusst nicht drin.
//
// Diese Datei lag früher unversioniert unter build-visionos/link/ und wurde von
// Hand übersetzt — auf einem frischen Klon war link-visionos.sh damit kaputt.

#import <ARKit/ARKit.h>

#include "visionos/JKXR_visionOS_Spiel.h"

// Was sonst im App-Ziel liegt (Sources/Bridge). Hier als Attrappe, damit der
// Prüflink nicht das ganze App-Ziel braucht.
extern "C" void *TBXR_visionOS_GetWorldTracking(void) { return nullptr; }
extern "C" void *TBXR_visionOS_GetAccessoryTracking(void) { return nullptr; }
extern "C" void *TBXR_visionOS_GetSpatialDevice(int hand) { (void)hand; return nullptr; }
extern "C" void TBXR_visionOS_StartWorldTracking(void) {}
extern "C" void TBXR_visionOS_StartAccessoryTracking(void) {}
// Die Leistungsanzeige (Sources/Leistung/Leistungsanzeige.swift): verborgen,
// und beide Menuetasten gehen unveraendert durch.
extern "C" bool JKXR_Leistung_Sichtbar(void) { return false; }
extern "C" void JKXR_Leistung_Bild(void) {}
extern "C" int JKXR_Leistung_Tasten(bool links, bool rechts, double) { return (links ? 1 : 0) | (rechts ? 2 : 0); }
extern "C" void JKXR_Leistung_Auge(void *, void *, const float *, const float *, void *,
                                   double, double, double, double) {}

// BEIDE Tabellen anfassen, sonst prüft der Link nur einen Spielsatz. Genau das
// soll er ja beantworten: ob Outcast und Academy zusammen ein Programm ergeben.
int main(int argc, char *argv[])
{
    const JKXR_visionOS_Spiel *spiele[] = {
        &JKXR_visionOS_Spiel_ja,
        &JKXR_visionOS_Spiel_jo,
    };
    return spiele[0]->Main(argc, argv) + (spiele[1] != nullptr ? 0 : 1);
}
