# S1 — JIT-Spike für visionOS

## ERGEBNIS: NO-GO

Gemessen am 11.08.2026 auf einer **Apple Vision Pro M5**, visionOS 26, mit einem
dev-signierten Build (`get-task-allow` gesetzt).

```
CodeSign: 0x22003305 [VALID GET_TASK_ALLOW HARD KILL ENFORCEMENT REQUIRE_LV DYLD_PLATFORM SIGNED]

[FEHL] 1. mmap MAP_JIT              EPERM
[TOT ] 2. mmap RWX                  gemappt — Sprung beendet den Prozess
[TOT ] 3. mmap RW -> mprotect RX    gemappt — Sprung beendet den Prozess
[TOT ] 4. vm_remap Dual-Mapping     gemappt — Sprung beendet den Prozess
[FEHL] 5. shm_open Dual-Mapping     EPERM
[FEHL] 6. vm_protect VM_PROT_COPY   Policy-Ablehnung trotz max=rwx
[TOT ] 7. vm_map max=RWX            gemappt — Sprung beendet den Prozess
```

Kontrollgruppe: derselbe Code auf macOS lässt Probe 1, 3, 4 und 7 durchlaufen.
Der Spike misst also die Plattform, nicht sich selbst.

### Die Sperre sitzt nicht beim Mappen, sondern beim Ausführen

Das ist der eigentliche Befund. Bei allen vier tödlichen Proben hat visionOS das
Vorbereiten **erlaubt**: `mprotect(RX)` akzeptiert, `vm_map` mit `max=rwx`
akzeptiert, RX-Alias über `vm_remap` angelegt. Erst der Sprung in den fertig
präparierten Speicher beendet den Prozess.

Verantwortlich sind `CS_KILL` + `CS_ENFORCEMENT` + `CS_REQUIRE_LV`: der Kernel
beendet den Prozess, sobald dessen Code-Signatur ungültig wird — und das Ausführen
ungesignierter Seiten tut genau das. `SIGKILL` ist nicht abfangbar, der
Signal-Handler greift deshalb nicht.

**Konsequenz:** Es gibt keinen Mapping-Trick, der hilft. Die Schranke liegt gar
nicht in der Mapping-API. Jede ausführbare Seite braucht eine gültige Signatur,
und die kann ein Recompiler zur Laufzeit nicht liefern. Der einzige legitime Weg
bliebe `MAP_JIT` mit dem `dynamic-codesigning`-Entitlement, das Apple nicht
vergibt.

### Der Debugger rettet es nicht

Zweiter Lauf, mit angehängtem Xcode:

```
ohne Debugger:  0x22003305 [VALID GET_TASK_ALLOW HARD KILL ENFORCEMENT REQUIRE_LV DYLD_PLATFORM SIGNED]
mit  Debugger:  0x32003005 [VALID GET_TASK_ALLOW      ENFORCEMENT REQUIRE_LV DYLD_PLATFORM DEBUGGED SIGNED]
```

Der Debugger nimmt `HARD` und `KILL` weg und setzt `DEBUGGED`. Der Prozess wird
dadurch nicht mehr abgeschossen, sondern hält als `EXC_BAD_ACCESS (code=2)` im
Debugger an. **Er fügt aber kein `dynamic-codesigning` hinzu** — `mmap(MAP_JIT)`
scheitert weiterhin mit `EPERM`, und der Sprung faultet weiterhin.

Die verbreitete Annahme "`get-task-allow` plus angehängter Debugger ergibt JIT
auf iOS-Familie-OSen" gilt hier nicht. Der Debugger macht Speicherverletzungen
*debuggbar*, nicht *erlaubt*.

**Damit ist auch der Fallback "getetherter Dev-Build" tot.**



**Die Go/No-Go-Frage des gesamten Projekts.** Cemus PowerPC-Recompiler emittiert
ARM64-Code zur Laufzeit. Bekommt ein dev-signierter Dritt-App-Prozess auf
visionOS keinen ausführbaren Speicher, bleibt nur der Interpreter — und damit ist
BotW auf dem Gerät nicht spielbar.

Diese App probiert sieben Wege durch, führt jeweils einen generierten
ARM64-Stub (`mov w0, #42 ; ret`) aus und meldet, welcher davon trägt.

## Die sieben Proben

| # | Weg | Warum er interessant ist |
|---|-----|--------------------------|
| 1 | `mmap(MAP_JIT)` + `pthread_jit_write_protect_np` | Der von Apple vorgesehene Weg auf macOS. Braucht `dynamic-codesigning`. |
| 2 | `mmap(PROT_READ\|WRITE\|EXEC)` | Direkt RWX. Auf gehärteten Systemen praktisch immer abgelehnt. |
| 3 | `mmap(RW)` → `mprotect(RX)` | Der naive W^X-Weg. |
| 4 | `vm_remap` Dual-Mapping | Zwei Aliase auf dieselbe Seite, einer RW, einer RX. Klassiker aus iOS-Emulatoren. |
| 5 | `shm_open` Dual-Mapping | Variante von 4 über POSIX-SHM. Sandbox verlangt evtl. App-Group-Präfix. |
| 6 | `vm_protect` mit `VM_PROT_COPY` | Erzwingt private Kopie und kann dabei Rechte anheben. |
| 7 | `vm_map` mit `max=RWX` → `vm_protect(RX)` | **Der stärkste Kandidat.** Max-Protection lässt sich nachträglich nur senken, nie anheben — also fordert man sie gleich bei der Allokation an. |

Jede Probe meldet, wie weit sie kam: *kein Speicher* → *Code geschrieben* →
*ausführbar gemacht* → *ausgeführt*. Der Abbruchpunkt ist die eigentliche
Information. Scheitern an Stufe 3 bei `max=rwx` heißt Policy-Ablehnung;
Scheitern, weil `max` schon kein EXECUTE enthält, heißt strukturell zu.

## Bauen und laufen lassen

Projekt generieren (nach jeder Änderung an `project.yml`):

```bash
cd spikes/s1-jit && xcodegen generate
```

Vor dem Gerätelauf muss ein Signing-Team gesetzt werden — entweder in Xcode unter
*Signing & Capabilities*, oder in `project.yml` bei `DEVELOPMENT_TEAM`.

### Lauf A — mit angehängtem Debugger

In Xcode `JitSpike.xcodeproj` öffnen, Vision Pro als Ziel wählen, Run.

Das ist der Lauf, von dem wir **erwarten**, dass er gelingt: mit `get-task-allow`
und angehängtem Debugger bekommt der Prozess auf iOS-Familie-OSen
Debug-JIT-Status. Bestätigt er das, ist ein getetherter Dev-Build machbar.

Wichtig: Xcode fängt `EXC_BAD_ACCESS` vor der Signalzustellung ab und hält an,
statt den Signal-Handler der App laufen zu lassen. Falls der Debugger bei einer
Probe stoppt, in der Konsole `continue` eingeben — oder gleich Lauf B nehmen.

### Lauf B — ohne Debugger (der aussagekräftige)

App einmal per Xcode installieren, dann Xcode **stoppen** und die App auf der
Vision Pro vom Home-Screen starten.

Das ist der Alltagsbetrieb. Nur dieser Lauf beantwortet, ob der Port ohne
permanent angehängten Mac funktioniert.

### Ergebnis abholen

Drei Wege, absichtlich redundant — der Bericht muss auch überleben, wenn die App
beim Sprung in nicht-ausführbaren Speicher hart abgeschossen wird:

1. Auf dem Bildschirm der App
2. Button **Bericht kopieren** → Zwischenablage
3. `s1-jit-report.txt` im Documents-Verzeichnis, über Xcode →
   *Window → Devices and Simulators → App auswählen → Download Container*

Der Bericht wird **nach jeder einzelnen Probe** neu geschrieben. Bricht der
Prozess ab, steht im letzten Stand, welche Probe ihn erwischt hat.

## Simulator-Ergebnisse sind wertlos

Der Simulator erbt die Rechte des macOS-Hosts und meldet
`DYNAMIC_CODESIGNING` — dort gelingen Proben 1, 3, 4 und 7 immer. Die App weist
in der Umgebungsanzeige selbst darauf hin. Nur ein Lauf auf echter Hardware
zählt.

Der Simulatorlauf ist trotzdem nützlich, um den Harness zu prüfen: er bestätigt,
dass alle sieben Proben durchlaufen, dass der Signal-Handler einen echten Fault
abfängt (Probe 5) und dass die Stufenleiter Fehlerursachen unterscheidet.

## Wie das Ergebnis zu lesen ist

- **Probe 1 oder 7 gelingt ohne Debugger** → bester Fall. Recompiler kann direkt
  darauf aufsetzen, verteilbarer Build denkbar.
- **Gelingt nur mit Debugger** → getetherter Dev-Build. Für ein Hobbyprojekt
  tragbar, aber Xcode muss beim Spielen verbunden bleiben.
- **Nur Probe 4 oder 5 gelingt** → Dual-Mapping. Cemus Code-Cache muss auf
  getrennte Schreib- und Ausführadressen umgebaut werden; der Recompiler
  emittiert dann über den RW-Alias und springt in den RX-Alias.
- **Nichts gelingt** → nativer Port über den Recompiler ist tot. Weiter mit den
  Fallbacks im Plan (AOT-Übersetzung oder Streaming).

## Beobachtung am Rande

`<mach/mach_vm.h>` ist im XROS-SDK explizit als *unsupported* markiert und lässt
sich nicht einbinden. Probe 7 nutzt deshalb `vm_map()`/`vm_deallocate()` aus
`<mach/vm_map.h>` — gleiche Semantik, auf iOS-Familie-SDKs verfügbar.
