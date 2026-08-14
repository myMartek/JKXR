// S1 — JIT-Spike für visionOS
//
// Prüft, ob ein dev-signierter Dritt-App-Prozess auf visionOS ausführbaren
// Speicher bekommen kann. Das ist die Go/No-Go-Frage für den nativen Cemu-Port:
// Cemus PPC-Recompiler emittiert ARM64-Code zur Laufzeit und braucht dafür
// W^X-fähige Seiten.
//
// Jede Probe durchläuft dieselben vier Stufen, damit man genau sieht, wo es
// bricht: Speicher holen -> Code schreiben -> ausführbar machen -> ausführen.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Wie weit eine Probe gekommen ist. Absichtlich als Stufenleiter modelliert:
/// ein Fehlschlag bei `made_executable` ist eine völlig andere Aussage als
/// einer bei `allocated`.
typedef enum {
    JIT_STAGE_NONE = 0,        ///< nicht einmal Speicher bekommen
    JIT_STAGE_ALLOCATED = 1,   ///< Speicher da, aber nicht beschreibbar/nutzbar
    JIT_STAGE_WRITTEN = 2,     ///< Maschinencode liegt im Speicher
    JIT_STAGE_EXECUTABLE = 3,  ///< Kernel hat Ausführungsrecht gewährt
    JIT_STAGE_EXECUTED = 4,    ///< Code lief und lieferte den erwarteten Wert
} JitProbeStage;

typedef struct {
    char name[64];
    char detail[512];   ///< menschenlesbare Diagnose inkl. errno/kern_return
    int  stage;         ///< JitProbeStage — wie weit sind wir gekommen
    int  faulted;       ///< 1 = Sprung in den Speicher hat ein Signal ausgelöst
    int  returned;      ///< tatsächlicher Rückgabewert des generierten Codes
} JitProbeResult;

/// Erwarteter Rückgabewert des generierten ARM64-Stubs.
#define JITPROBE_MAGIC 42

/// Anzahl verfügbarer Proben.
size_t jitprobe_count(void);

/// Name einer Probe, ohne sie auszuführen. Nötig, um eine Probe zu benennen,
/// die den Prozess beendet hat, bevor sie ein Ergebnis liefern konnte.
void jitprobe_name(size_t index, char *out, size_t cap);

/// Wird unmittelbar vor dem Sprung in den vorbereiteten Speicher aufgerufen —
/// also an der einzigen Stelle, an der eine Probe den Prozess mitreißen kann.
///
/// Ohne diesen Zwischenstand ist ein Prozessabschuss nicht interpretierbar:
/// man weiß nicht, ob die Probe schon am Mappen scheiterte oder ob das Mappen
/// gelang und erst die Ausführung verweigert wurde. Für die Frage, ob ein
/// JIT-Pfad existiert, ist das der entscheidende Unterschied.
typedef void (*jitprobe_checkpoint_fn)(const JitProbeResult *partial);
void jitprobe_set_checkpoint(jitprobe_checkpoint_fn cb);

/// Führt genau eine Probe aus. Einzeln aufrufbar, damit der Aufrufer nach jeder
/// Probe persistieren kann — ein Sprung in nicht-ausführbaren Speicher kann den
/// Prozess trotz Signal-Handler hart beenden, und dann ist ein Zwischenstand
/// mehr wert als gar kein Ergebnis.
void jitprobe_run_one(size_t index, JitProbeResult *out);

/// Führt alle Proben aus. Schreibt höchstens `cap` Ergebnisse nach `out`,
/// gibt die Anzahl der geschriebenen Ergebnisse zurück.
size_t jitprobe_run_all(JitProbeResult *out, size_t cap);

/// Sammelt Kontext, ohne den die Ergebnisse nicht interpretierbar sind:
/// Simulator vs. Gerät, Debugger angehängt, Code-Signing-Flags, Seitengröße.
void jitprobe_environment(char *buf, size_t cap);

#ifdef __cplusplus
}
#endif
