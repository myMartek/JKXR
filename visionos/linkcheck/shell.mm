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

extern "C" void *TBXR_visionOS_GetWorldTracking(void) { return nullptr; }

extern "C" int JKXR_visionOS_Main(int argc, char *argv[]);

int main(int argc, char *argv[]) { return JKXR_visionOS_Main(argc, argv); }
