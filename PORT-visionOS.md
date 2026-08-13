# JKXR auf visionOS — Portierungsplan

Erkundungsergebnis nach dem Klonen von
[Team-Beef-Studios/JKXR](https://github.com/Team-Beef-Studios/JKXR).

## Die gute Nachricht: eine saubere Plattformschnittstelle

Der VR-Teil liegt in `Projects/Android/jni/OpenJK/JKXR/` und trennt bereits
plattformneutralen von plattformspezifischem Code:

```
JKXR/
├── OpenXrInput.cpp        plattformneutral (1078 Zeilen)
├── VrInput*.cpp           Spiellogik der VR-Steuerung
├── android/TBXR_Common.cpp   Quest, Pico   (2253 Zeilen)
└── windows/TBXR_Common.cpp   PCVR         (1257 Zeilen)
```

Ein visionOS-Port ist eine **dritte Implementierung derselben 16 Funktionen**.
Kein Umbau der Engine, kein Eingriff in die Spiellogik.

**Korrektur:** Es sind allerdings **zwei** Plattformschichten, nicht eine. Neben
der XR-Schicht hat die Engine selbst eine — Einstiegspunkt, Fenster, Sound,
Eingabe:

```
code/android/android_main.cpp     Einstiegspunkt
code/android/android_window.cpp   Fenster/Kontext      235 Zeilen
code/android/android_snd.cpp      Audio                308 Zeilen
code/android/in_android.cpp       Eingabe              464 Zeilen
                                                 rund 2000 Zeilen gesamt
```

Eine Windows-Entsprechung existiert dafür nicht in verwendbarer Form
(`code/win32/` enthält nur Ressourcendateien) — der PCVR-Build geht einen
anderen Weg. Als Vorlage für visionOS taugt also allein der Android-Zweig.

| TBXR-Funktion | visionOS | Stand aus S4 |
|---|---|---|
| `TBXR_InitialiseOpenXR` | ANGLE-Init | fertig |
| `TBXR_InitRenderer` | `LayerRenderer`-Konfiguration | fertig |
| `TBXR_EnterVR` | `openImmersiveSpace` | fertig |
| `TBXR_WaitForSessionActive` | `waitUntilRunning` | fertig |
| `TBXR_GetScreenRes` | 5087×4081 (Screen-Koordinaten) | gemessen |
| `TBXR_FrameSetup` | `queryNextFrame` / `predictTiming` | fertig |
| `TBXR_updateProjections` | `computeProjection` + `view.transform` | fertig |
| `TBXR_prepareEyeBuffer` | EGLImage-Import + FBO binden | fertig |
| `TBXR_finishEyeBuffer` | `glFlush` | fertig |
| `TBXR_submitFrame` | `encodePresent` + `commit` | fertig |
| `TBXR_GetRefresh` | 90 | trivial |
| `TBXR_Recenter` | ARKit-Origin zurücksetzen | klein |
| `TBXR_UpdateControllers` | PSVR2 Sense | **offen** |
| `TBXR_InitActions` | Controller-Bindings | **offen** |
| `TBXR_Vibrate` / `TBXR_ProcessHaptics` | Sense-Haptik | **offen** |

*Nachtrag: Diese Tabelle beschreibt den Stand vor der Umsetzung. Sowohl die
XR-Schicht als auch das Action-System sind inzwischen implementiert — siehe
Schritt 5 und 6 weiter unten.*

## Die schlechte Nachricht: drei Übersetzungsschichten

`rd-gles` ruft **Desktop-OpenGL im Immediate Mode** auf — `glBegin`,
`glCallList`, `glAlphaFunc`, `glClipPlane`, `glClientActiveTextureARB`. Also
GL 1.x von 1996. Übersetzt wird das von **gl4es**
(`SupportLibs/gl4es`, als `LOCAL_SHARED_LIBRARIES` eingebunden).

Der vollständige Stapel auf visionOS:

```
rd-gles      Desktop-GL 1.x, Immediate Mode
  └─ gl4es   GL → GLES 2/3
     └─ ANGLE   GLES → Metal
        └─ Metal
```

**Korrektur zur Projektauswahl:** Bei der Entscheidung zwischen JKXR und
Lambda1VR hatte ich Lambda1VRs Renderkette (`Xash3D → GLE4ES → GLES2`) als
Nachteil angeführt — „Wrapper auf einem Wrapper". JKXR hat dieselbe Struktur.
Das Argument war falsch.

Die übrigen Gründe für JKXR bleiben: aktive Wartung, drei bediente Plattformen,
die saubere TBXR-Schnittstelle, und ein Spiel, dessen Kern (Nahkampf mit
Lichtschwert) in VR tatsächlich gewinnt.

Praktisch heißt es: **gl4es muss ebenfalls für visionOS gebaut werden.** Es
bietet dafür passende Optionen — `NOX11=ON` (Kontexterzeugung außerhalb, genau
unser Fall, da ANGLE den Kontext liefert) und `STATICLIB=ON`.

## Schritt 1 erledigt: gl4es baut für visionOS

```
libGL.a — arm64, platform VISIONOS, minos 2.0
924 gl4es_gl*-Funktionen, 793 Linker-Aliase
```

Bauen:

```bash
python3 patch-gl4es-darwin.py Projects/Android/jni/SupportLibs/gl4es \
    build-visionos/gl4es-aliases.txt

cmake -S Projects/Android/jni/SupportLibs/gl4es -B build-visionos/gl4es \
  -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 \
  -DNOX11=ON -DNOEGL=ON -DSTATICLIB=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_C_FLAGS="-U__ARM_NEON__ -U__ARM_NEON"
cmake --build build-visionos/gl4es -j8

# Alias-Liste gegen die gebaute Bibliothek filtern
python3 patch-gl4es-darwin.py Projects/Android/jni/SupportLibs/gl4es \
    build-visionos/gl4es-aliases.txt build-visionos/gl4es/lib/libGL.a
```

### Vier Hindernisse, alle in [`patch-gl4es-darwin.py`](patch-gl4es-darwin.py)

**Compiler-Aliase gibt es auf Mach-O nicht.** gl4es exportiert seine
GL-Einstiegspunkte über `__attribute__((alias("gl4es_glFoo")))` — ein
ELF-Feature. Clang bricht mit *„aliases are not supported on darwin"* ab.

Mach-O kann Aliase trotzdem, nur im **Linker**. Also: `AliasExport` auf Darwin
leer definieren (Präzedenzfall im Projekt: unter Emscripten ist es das schon),
die Paare mechanisch aus den Quellen ziehen und als `-alias_list` mitgeben.

Beim Linken zusätzlich nötig:

```
-Wl,-alias_list,build-visionos/gl4es-aliases.txt
-Wl,-force_load,build-visionos/gl4es/lib/libGL.a
```

`-force_load`, weil ein Alias sein Ziel im Link braucht — Objekte einer
statischen Bibliothek werden aber nur eingebunden, wenn etwas sie referenziert,
und referenziert wird der Aliasname, den es ohne den Alias noch nicht gibt.

**Drei verschiedene Alias-Schreibweisen.** Neben dem `AliasExport`-Makro stehen
in `src/gl/wrap/gles.c` 238 wörtlich ausgeschriebene Aliase, und `glstub.c`
erzeugt Implementierung und Alias in einem `STUB`-Makro per Token-Verkettung —
dort taucht der Name gar nicht als Zeichenkette auf. Alle drei müssen erfasst
werden.

**ARMv7-NEON-Assembly.** Zehn Stellen sind mit `#ifdef __ARM_NEON__` eingezäunt,
enthalten aber ARMv7-Syntax (`vmov`, `q3`, `d6`). Auf AArch64 ist das Makro
definiert (NEON ist dort Pflicht), die Assembly aber ungültig. C-Rückfallpfade
existieren bereits, also genügt `-U__ARM_NEON__ -U__ARM_NEON` — kein Eingriff in
zehn Quelldateien.

**`<linux/limits.h>`** in `loader.c` — auf Darwin `<limits.h>` und
`<sys/syslimits.h>`.

### Warum die Alias-Liste gegen die Bibliothek gefiltert wird

46 Aliase zeigen auf Ziele, die je nach Konfiguration gar nicht entstehen —
überwiegend GLX, das außerhalb von Linux nicht gebaut wird. Ein Alias auf ein
fehlendes Ziel lässt den Linker scheitern. Das Skript nimmt deshalb optional die
gebaute Bibliothek entgegen und filtert dagegen.

## Spieldaten

Liegen bereit unter `build-visionos/assets/base/`:

| Datei | Herkunft | Größe |
|---|---|---|
| `assets0.pk3` … `assets3.pk3` | Jedi Academy (Steam) | ~1,2 GB |
| `z_vr_assets_base.pk3` | JKXR, aus `z_vr_assets_base/` gepackt | 23 MB |
| `z_vr_assets_jka.pk3` | JKXR, aus `z_vr_assets_jka/` gepackt | 300 KB |

Das mitgelieferte `make_z_vr_assets_pk3.bat` ist Windows-only (PowerShell). Eine
`.pk3` ist ein ZIP, also genügt:

```bash
cd z_vr_assets_jka && zip -rq ../build-visionos/assets/z_vr_assets_jka.pk3 . -x ".DS_Store"
```

## Schritt 2 erledigt: Support-Bibliotheken bauen

```
liblibpng.a       arm64  platform VISIONOS   394 Symbole
liblibjpeg.a      arm64  platform VISIONOS   159 Symbole
liblibzip.a       arm64  platform VISIONOS    73 Symbole
libsigc.a         arm64  platform VISIONOS   241 Symbole
liblibminizip.a   arm64  platform VISIONOS    39 Symbole
```

Erzeugt mit [`mk2cmake.py`](mk2cmake.py), das JKXRs Android-Makefiles nach CMake
übersetzt — die Quelldateilisten von Hand abzutippen wäre fehleranfällig und
liefe bei jedem JKXR-Update auseinander.

```bash
for lib in libpng jpeg8d libzip sigc++ minizip; do
    python3 mk2cmake.py Projects/Android/jni/SupportLibs/$lib \
        visionos/libs/$(basename $lib).cmake
done
python3 patch-supportlibs-darwin.py Projects/Android/jni/SupportLibs

cmake -S visionos -B build-visionos/libs \
  -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0
cmake --build build-visionos/libs -j8
```

### Der Umfang ist kleiner als gedacht

Die Android-Makefiles verraten, was tatsächlich gebraucht wird:

| Modul | Abhängigkeiten |
|---|---|
| `openjk_ja` (Client) | sigc, libzip, libpng, libminizip, gl4es |
| `rd-gles-ja` (Renderer) | libpng, libjpeg, gl4es |
| `jagame` | keine |

**libogg, libvorbis und openal werden von keinem Modul referenziert.** Audio
läuft auf Android über OpenSL ES (`-lOpenSLES` in `Android_client_ja.mk`) und
gehört damit in die Plattformschicht, nicht in eine dieser Bibliotheken. Auf
visionOS wäre das CoreAudio.

### `<fp.h>` — ein Gruß aus Mac OS 9

libpng bricht auf Apple-Plattformen ab:

```c
#if ... || defined(TARGET_OS_MAC)
#  include <fp.h>
```

`TARGET_OS_MAC` ist auf **allen** modernen Apple-Plattformen definiert — es ist
der Sammelbegriff für macOS, iOS und visionOS. Der Zweig dahinter ist aber für
*Classic* Mac OS gedacht, und `<fp.h>` gibt es seit Mac OS 9 nicht mehr.
`__APPLE__` trennt beide Welten sauber: Classic Mac OS kannte es noch nicht.
Behoben in [`patch-supportlibs-darwin.py`](patch-supportlibs-darwin.py).

## Schritt 3: Engine baut zu zwei Dritteln

```
libjagamearm.a         arm64  platform VISIONOS  4,2 MB   173 Quellen  Spielcode
librd-gles-ja_arm.a    arm64  platform VISIONOS  896 KB    44 Quellen  Renderer
libsigc.a / libzip.a / libpng.a / libjpeg.a / libminizip.a
```

**Spielcode und Renderer übersetzen vollständig für visionOS.** Der Client
(`openjk_ja`, 85 Quellen) hängt an genau einer Sache: `JKXR/android/TBXR_Common.h`
bindet `GLES3/gl3.h` und `jni.h` ein. Das ist die Android-XR-Schicht, die ohnehin
durch eine visionOS-Fassung ersetzt wird — kein Build-Problem, sondern die
eigentliche verbleibende Arbeit.

Erzeugt mit [`mk2cmake.py`](mk2cmake.py):

```bash
J=Projects/Android/jni
for mod in client_ja gles_ja game_ja; do
    python3 mk2cmake.py "$J/OpenJK" "visionos/libs/openjk_$mod.cmake" \
        --mk "Android_$mod.mk" \
        --context "$J/Application.mk" --context "$J/OpenJK/Android.mk" \
        --exclude "JKXR/android/" --exclude "/code/android/"
done
```

### Header-Reihenfolge: gl4es vor ANGLE

Der wichtigste strukturelle Punkt des Engine-Builds.

Die Engine ruft **Desktop-OpenGL im Immediate Mode** auf — `glBegin`,
`glColorPointer`, `glCallList`. Genau das emuliert gl4es, und **nur seine Header
deklarieren diese Funktionen**. ANGLE liefert das *echte* GLES ohne
Fixed-Function-Pipeline; stehen seine Header vorn, sieht die Engine die
Emulationsschicht nicht und der Compiler meldet hunderte unbekannte Funktionen.

```cmake
include_directories(BEFORE ${GL4ES_INCLUDE} compat)
```

ANGLE kommt erst beim Linken ins Spiel, unterhalb von gl4es.

### Weitere Fundstellen

**`<MesaGL/gl.h>` in `qgl.h`** — derselbe Fehlertyp wie libpngs `<fp.h>`: ein
Apple-Zweig aus der Zeit, als Mac OS X OpenGL über Mesa bereitstellte. Android
umgeht ihn, weil Android Linux ist und den `__linux__`-Zweig mit `HAVE_GLES`
nimmt. Auf visionOS greift der Apple-Zweig — und läuft ins Leere.

**`GLES/glext.h`** muss zusätzlich eingebunden werden: die EXT-Konstanten wie
`GL_TEXTURE_MAX_ANISOTROPY_EXT` liefert das NDK über `GLES/gl.h` mit, gl4es
trennt beides.

**arm64 war OpenJK unbekannt.** `q_platform.h` kannte im Apple-Block nur ppc,
i386 und x86_64 — ohne Ergänzung bleiben `ARCH_STRING` und die Endianness
undefiniert.

**`GLES3/gl3ext.h`** gibt es bei ANGLE nicht. Im NDK ist es eine leere Hülle aus
Abwärtskompatibilität; unter [`visionos/compat/`](visionos/compat/) liegt ein
entsprechender Platzhalter.

## Schritt 4: Die vollständige Engine übersetzt

```
libopenjk_ja.a        1,6 MB    85 Quellen   Client      ✓
libjagamearm.a        4,2 MB   173 Quellen   Spielcode   ✓
librd-gles-ja_arm.a   896 KB    44 Quellen   Renderer    ✓
libsigc / libzip / libpng / libjpeg / libminizip         ✓

alle: arm64, platform VISIONOS
```

**Alle 302 Engine-Quelldateien übersetzen für visionOS. Null Fehler.**

Gebunden ist damit noch nichts — die Plattformfunktionen sind deklariert, aber
nicht implementiert. Genau das ist die verbleibende Arbeit, und sie ist jetzt
abzählbar statt geschätzt:

```
$ nm -u build-visionos/engine/*.a | ...
TBXR-Funktionen:    6 undefiniert
OpenXR-Funktionen: 16 undefiniert
VR_-Funktionen:     7 undefiniert
```

### Der XR-Header wird abgeleitet, nicht abgeschrieben

`VrCommon.h` wählt die Plattformschicht über den Präprozessor; ein
`__APPLE__`-Zweig zeigt jetzt auf `visionos/TBXR_Common.h`. Diese Datei erzeugt
[`make-visionos-xr-header.py`](make-visionos-xr-header.py) aus der
Android-Fassung — 348 Zeilen zu duplizieren hieße, sie bei jedem JKXR-Update
neu abzugleichen.

Fünf Unterschiede, alle klar benennbar:

| | Android | visionOS |
|---|---|---|
| Plattform-Header | EGL/GLES3/JNI/android | EGL und GLES von ANGLE bzw. gl4es |
| `ovrFramebuffer` | OpenXR-Swapchain | importierte Drawable-Texturen |
| `ovrJava` | JNI-Handles | leere Hülle |
| `ovrAppThread` | Java-Thread, Surface-Queue | nur der Thread |
| Logging | `__android_log_print` | `fprintf(stderr, …)` |

**OpenXR-Typen bleiben, OpenXR-Funktionen nicht.** Die Typen aus dem
mitgelieferten SDK sind reine Structs und Handles und übersetzen für visionOS
unverändert — geprüft. Nur die Funktionen fehlen, und davon braucht der
neutrale Code lediglich sechzehn, alle aus dem **Action-System**:

```
xrCreateActionSet, xrCreateAction, xrCreateActionSpace,
xrAttachSessionActionSets, xrSuggestInteractionProfileBindings,
xrGetActionStateBoolean/Float/Vector2f, xrSyncActions, xrLocateSpace,
xrStringToPath, xrPathToString, xrGetCurrentInteractionProfile,
xrApplyHapticFeedback, xrStopHapticFeedback
```

Kein Rendering, keine Session- oder Frame-Verwaltung — die stecken in der
Android-Schicht, die ohnehin ersetzt wird.

**Das ist die wichtigste Erkenntnis für den weiteren Weg:** Statt
`OpenXrInput.cpp` (1078 Zeilen) neu zu schreiben, genügt ein schmaler Nachbau
des Action-Systems auf PSVR2-Sense-Controllern. JKXRs Eingabelogik — Bindings,
Waffenausrichtung, Gestenerkennung — bleibt dabei vollständig erhalten. Genau
der Teil, der den Wert des Projekts ausmacht.

Nebenbei: `os_log` taugt hier nicht als Ersatz für `__android_log_print`. Es
verlangt einen zur Übersetzungszeit bekannten Formatstring, JKXR reicht an
einigen Stellen aber Variablen durch.

## Schritt 5: XR-Schicht implementiert

[`JKXR/visionos/TBXR_Common.mm`](Projects/Android/jni/OpenJK/JKXR/visionos/TBXR_Common.mm)
— Gegenstück zu `android/TBXR_Common.cpp`, gebaut als `tbxr_visionos`.

**CompositorServices hat eine vollständige C-API** (`cp_layer_renderer_*`,
`cp_frame_*`, `cp_drawable_*`). Die Schicht ist damit reines Objective-C++;
Swift-Interop entfällt, und die C++-Engine spricht direkt mit dem Compositor.

Implementiert und übersetzt:

| Funktion | Umsetzung |
|---|---|
| `TBXR_FrameSetup` | `query_next_frame` → `predict_timing` → `wait` → `start_submission` → Kopfpose |
| `TBXR_prepareEyeBuffer` | EGLImage-Import von Farb- **und** Tiefentextur, FBO, Viewport, Rate Map |
| `TBXR_finishEyeBuffer` | `glFlush`, Import abräumen, Rate Map abmelden |
| `TBXR_submitFrame` | `encode_present` → `commit` → `end_submission` |
| `TBXR_GetRefresh` | 90 |
| `VR_GetVRProjection` | `cp_drawable_compute_projection`, Zoom über Spaltenskalierung |
| `VR_GetFovTangentsForEye` | aus der Projektionsmatrix zurückgerechnet |
| `VR_GetEyeStereoSeparation` | Abstand der beiden Ansichtstransformationen — visionOS kennt den echten Wert des Trägers |

Noch wirkungslos, weil vom Action-System abhängig: `VR_GetMove`,
`VR_HapticEvent`, `VR_HapticEndFrame`. Bewusst leer statt falsch.

### Header-Reihenfolge, ein zweites Mal

Für die **Engine** muss gl4es vor ANGLE stehen (Desktop-GL-Emulation). Für die
**XR-Schicht** genau umgekehrt: sie braucht echtes GLES3 und die
`EGL_METAL_*`-Erweiterungen, die gl4es' EGL-Header nicht kennen.

```cmake
target_include_directories(tbxr_visionos BEFORE PRIVATE ${ANGLE_INCLUDE})
```

Dieselbe Frage, gegenteilige Antwort — je nachdem, ob eine Übersetzungseinheit
zur Engine oder zur Plattformschicht gehört.

## Schritt 6: OpenXR-Action-System nachgebaut

[`JKXR/visionos/OpenXrActions.mm`](Projects/Android/jni/OpenJK/JKXR/visionos/OpenXrActions.mm)
— alle sechzehn Funktionen implementiert, keine undefinierten OpenXR-Symbole mehr.

### Apple hat die API an OpenXR modelliert

Der eigentliche Glücksfall des Ports. ARKits Accessory-Tracking (visionOS 26)
benutzt **wörtlich dieselben Namen** wie OpenXR:

```
ar_accessory_location_name_grip          →  /user/hand/*/input/grip
ar_accessory_location_name_aim           →  /user/hand/*/input/aim
ar_accessory_location_name_grip_surface  →  /input/grip_surface
ar_accessory_tracking_provider_predict_anchor_at_timestamp
                                         →  xrLocateSpace(time)
```

Die Zuständigkeiten teilen sich sauber:

| Bereich | visionOS-API |
|---|---|
| Posen, Geschwindigkeiten, Händigkeit | ARKit `ar_accessory_tracking_provider` |
| Tasten, Achsen | GameController, `GCProductCategorySpatialController` |
| Haptik | GameController |

Dass ARKit **Geschwindigkeiten** liefert (`ar_accessory_anchor_get_velocity`,
`..._get_angular_velocity`), ist entscheidend: JKXRs Schwung- und
Stichentdeckung beim Lichtschwertkampf hängt daran. In OpenXR kommen sie über
`XrSpaceVelocity` in der `next`-Kette von `xrLocateSpace` — die Brücke reicht
sie genau dort durch.

### Der Abruf ist zweistufig

```c
ar_accessory_tracking_provider_get_latest_anchors(provider)   // aktueller Anker
  → per ar_accessory_anchor_get_held_chirality die Hand finden
  → ar_accessory_tracking_provider_predict_anchor_at_timestamp(…)  // vorhersagen
```

Die Vorhersage ist nicht optional: zwischen Abfrage und Anzeige liegen einige
Millisekunden, und genau dafür nimmt `xrLocateSpace` einen Zeitstempel entgegen.

### Was bewusst einfach bleibt

`xrAttachSessionActionSets` friert in OpenXR die Aktionen ein — hier gibt es
nichts einzufrieren. `xrSyncActions` holt in OpenXR einen konsistenten
Schnappschuss; GameController und ARKit liefern jederzeit aktuelle Werte, sodass
nur die Controllerliste aufgefrischt wird.

`xrGetCurrentInteractionProfile` meldet das Oculus-Touch-Profil: JKXR kennt
`TOUCH_CONTROLLERS` und emuliert alles Unbekannte als Touch — und die Sense-
Controller entsprechen diesem Layout am ehesten.

## Was aus PocketSim/Gen1 Vision übernommen wurde

Im Nachbarprojekt `~/Documents/Projects/PocketSim` liegt ein fertiger
visionOS-Port (Pokémon Rot mit Voxel-Mod, über Fastlane nach TestFlight). Drei
Dinge daraus sind hier unmittelbar verwertbar.

### Tastenzuordnung ist Messsache, nicht Ratesache

Aus dessen `GRControllers.swift`:

> *Mapping work on this platform is otherwise guesswork … This reports the
> device and names each element as it is pressed, so a button that does nothing
> in the game can be identified rather than guessed at.*

> *`physicalInputProfile` rather than a concrete profile class: it exposes every
> element as a string-keyed dictionary, which is exactly what is needed to find
> out what a button is CALLED without knowing in advance which profile the
> device presents.*

**Das korrigiert einen Fehler in `OpenXrActions.mm`.** Die erste Fassung bildete
OpenXR-Pfade über `extendedGamepad` ab — also über genau die konkrete
Profilklasse, von der der Kommentar abrät, und mit nach Bedeutung geratenen
Namen (`GCInputRightTrigger` für `/input/trigger/value`).

Jetzt wird über `physicalInputProfile` gesucht: ein unbekannter Name liefert
nil, statt dass ein Profil angenommen wird, das das Gerät womöglich gar nicht
anbietet. Dazu kommt `TBXR_visionOS_DumpInputs()`, das die tatsächlichen Namen
der verbundenen Controller ausgibt — beim ersten Lauf auf echter Hardware
einmal aufrufen und die Tabelle gegen Gemessenes ersetzen.

### Es gibt keine Quad-Layer auf visionOS

> *CompositorServices has no equivalent of the OpenXR quad layer the mod uses
> for menus and the Pokédex screen on Windows.*

Das bestätigt unabhängig, warum `VR_UseScreenLayer()` hier `false` liefern muss:
JKXR zeichnet Menüs und Videosequenzen auf eine Quad-Layer, und die gibt es
schlicht nicht. Sie müssen über denselben Renderpfad laufen.

Nebenbei bestätigt der dortige Renderer auch `depthCompareFunction = .greater` —
dasselbe Reversed-Z, das S4 mühsam herausgefunden hat.

### Audio: der OpenAL-Umweg, und warum er nicht genommen wurde

`snd_dma.cpp` ruft OpenAL direkt auf, eingezäunt durch **`USE_OPENAL`** (38
Stellen dort, 5 in `snd_mem.cpp`, 5 in `snd_local.h`). Naheliegender Gedanke:
diesen fertigen Pfad aktivieren, statt ein Audio-Backend zu schreiben.

**Der Gedanke war falsch, und zwar aus zwei unabhängigen Gründen.**

*Erstens* taugen OpenJKs mitgelieferte Header nicht. Sie sind reine
Windows-Header: `ALCdevice` und `ALCcontext` sind nur im `_WIN32`-Zweig
typdefiniert, die Aufrufkonvention ist `__cdecl`, und `eax/EaxMan.h` verlangt
COM über `objbase.h`.

*Zweitens*, und entscheidend: der Pfad steht hinter `#if defined(_MSC_VER)`,
weil er an Windows gebunden **ist**. Er hängt an EAX — 50 verschiedene
Bezeichner, 207 Verwendungen, ohne eigenen Schalter, mit dem man sie abschalten
könnte —, am EAX-Manager als COM-Objekt und an `LoadLibrary`/`GetProcAddress`
(`HINSTANCE s_hEAXManInst`). Nicht durch `_WIN32` abgeschirmt, weil der ganze
Block ohnehin nie woanders übersetzt wurde.

**Was Android stattdessen tut, ist der richtige Weg:** Quakes
plattformneutraler Software-Mixer, der bei uns bereits übersetzt, plus eine
Senke aus fünf Funktionen.

```
SNDDMA_Init  SNDDMA_GetDMAPos  SNDDMA_BeginPainting  SNDDMA_Submit  SNDDMA_Shutdown
```

Der Mixer schreibt in `dma.buffer`, einen Ringpuffer; `dma.samples` zählt
Einzelsamples (beide Kanäle verschränkt), der Lesezeiger ebenso. Das gesamte
Android-Backend sind 308 Zeilen.

| | `USE_OPENAL` | DMA-Backend |
|---|---|---|
| Aufwand | 207 EAX-Stellen, COM, `LoadLibrary` | ~250 Zeilen CoreAudio |
| Mit JKXRs VR-Schicht erprobt | nein | ja — das ist der Quest-Pfad |
| Zusätzliche Abhängigkeit | openal-soft | keine |

`code/visionos/visionos_snd.mm` setzt die fünf Funktionen auf eine
RemoteIO-AudioUnit. Zwei Abweichungen von Android:

- **44100 Hz statt 22050.** Die Klangdateien sind überwiegend 22050 Hz und der
  Mixer rechnet beim Abspielen ohnehin um; die Hardwarerate spart die zweite
  Umrechnung im Audiosystem.
- **`AVAudioSessionCategoryAmbient`.** Ohne aktive Session bleibt eine
  RemoteIO-AudioUnit stumm, ohne einen Fehler zu melden. `.ambient` respektiert
  den Lautlos-Schalter und verdrängt anderen Ton nicht — in einem geteilten
  Raum das erwartete Verhalten.

Der Render-Rückruf läuft ohne Sperre, wie auf Android. Eine Sperre im
Echtzeit-Thread wäre der schlechtere Tausch: sie könnte den Puffer verspätet
füllen und hörbar aussetzen lassen, während der ungesicherte Zugriff schlimm-
stenfalls einen einzelnen Knacks erzeugt.

**openal-soft ist trotzdem gebaut.** `build-openal-visionos.sh` holt 1.24.3,
wendet `patch-openal-visionos.py` an und erzeugt `libopenal.a` für xrOS
(arm64, Plattform 11, CoreAudio-Backend enthalten, keine
Component-Manager-Reste). Gebraucht wird sie nicht; sie liegt bereit, falls
später echte 3D-Positionierung statt der Stereo-Panoramik des Mixers gewünscht
ist.

Der Patch ist eine einzige Stelle — derselbe blinde Fleck wie überall in diesem
Projekt, nur eine Ebene höher:

```c
#if TARGET_OS_IOS || TARGET_OS_TV     /* auf visionOS beide 0 */
#define CAN_ENUMERATE 0
#else
#include <IOKit/audio/IOAudioTypes.h> /* … also greift dieser Zweig */
```

Auf visionOS gilt `TARGET_OS_IOS=0`, `TARGET_OS_TV=0`, aber
`TARGET_OS_IPHONE=1` und `TARGET_OS_VISION=1`. Die Abfrage wurde auf
`!TARGET_OS_OSX` umgestellt: gefragt ist nicht „welche iOS-Variante ist das",
sondern „ist das der Mac" — nur dort gibt es die HAL-Geräteaufzählung.

## Schritt 7: Plattformschicht und erster Link

Die 19 offenen Funktionen sind erledigt, und das Programm linkt.

```
jkxr   5,2 MB   arm64   platform 11 (xrOS)   minos 2.0
```

### Zwei der drei Android-Dateien sind gar nicht Android-spezifisch

`android_main.cpp` enthält **null** JNI-Aufrufe — es ist ein POSIX-`main` in der
Tradition von ioquake3. Von den drei Dateien werden zwei unverändert
mitübersetzt, ohne Fork und ohne zweite Fassung:

| Datei | | |
|---|---|---|
| `android_window.cpp` | 235 Z. | unverändert übernommen |
| `in_android.cpp` | 464 Z. | unverändert, braucht `compat/android/log.h` |
| `android_main.cpp` | 934 Z. | ersetzt durch `code/visionos/visionos_main.mm` |

Ersetzt werden musste nur die dritte, und zwar aus einem Grund, der beim
Übersetzen sofort auffiel: `q_platform.h` definiert `MACOS_X` automatisch über
`__APPLE_CC__`. Damit schalten sich dort 17 Zweige für Desktop-macOS ein —
Programmbündel, `dlopen` von `.dylib`, Pfade unter `~/Library`. Einer ruft
`FS_LoadMachOBundle` auf, das es in dieser Codebasis nicht mehr gibt.

### Module: statisch statt nachgeladen

Die Engine lädt Renderer und Spielcode zur Laufzeit — `Sys_LoadDll` +
`Sys_LoadFunction("GetRefAPI")` und `Sys_LoadSPGameDll`. Auf Android sind das
`.so`-Dateien.

`Sys_LoadFunction` ist ein Makro auf `dlsym`. Daher genügt es, aus
`Sys_LoadDll` **`RTLD_DEFAULT`** zurückzugeben: `dlsym` findet damit die
statisch gelinkten Symbole des Hauptprogramms, und `cl_main.cpp` und
`sv_game.cpp` bleiben unangetastet.

Zwei Dinge sind dabei nötig, und beide fallen sonst erst zur Laufzeit auf:

- **Ein Anker.** `GetGameAPI` und `GetRefAPI` werden ausschließlich über
  Zeichenketten in `dlsym` referenziert. Ein Archivmitglied, das niemand
  referenziert, bindet der Linker gar nicht erst ein — und was er einbindet,
  entfernt `-dead_strip` womöglich wieder. Ein `__attribute__((used))`-Array
  mit beiden Adressen verhindert beides.
- **`Q_EXPORT` am Einsprungpunkt.** Der Client wird mit `-fvisibility=hidden`
  gebaut. Ohne das Makro landet `JKXR_visionOS_Main` als lokales Symbol im
  Binary (kleines `t`) und wäre für die SwiftUI-Hülle unerreichbar.

Geprüft wird beides am Ende von `link-visionos.sh`: die vier Einsprungpunkte
müssen im Export-Trie stehen.

### Der Teil-Link — das strukturelle Hindernis

Beim ersten Linkversuch kamen ein Dutzend doppelter Symbole:

```
duplicate symbol 'Com_Printf(char const*, ...)' in:
    libopenjk_ja.a(common.cpp.o)
    libjagamearm.a(g_main.cpp.o)
    librd-gles-ja_arm.a(tr_subs.cpp.o)
```

Das ist kein Fehler, sondern die Architektur: die drei Module sind auf Android
getrennte Shared Libraries, und jedes bringt seine eigene Fassung der
gemeinsamen Funktionen mit — einmal echt in `common.cpp`, je einmal als
Weiterleitung, die über die Importtabelle zurückruft. Dasselbe bei
`Com_DPrintf`, `SaberParms`, `animTable`, `sv_mapname`, `TranslateSaberColor`
und weiteren.

Gelöst mit einem Teil-Link je Modul:

```bash
ld -r -exported_symbols_list <(echo _GetRefAPI) \
   -o rd-gles-merged.o -all_load librd-gles-ja_arm.a
```

Alles außer dem Einsprungpunkt wird damit lokal. Danach exportiert das Modul
genau ein Symbol, die Kollisionen sind weg, und der Aufrufweg der Engine bleibt
unverändert — sie holt sich `GetRefAPI` ohnehin per `dlsym`.

Der naheliegende Gegenvorschlag wäre gewesen, die Module wie auf Android als
Dylibs im Programmbündel zu belassen. Das wäre auf visionOS erlaubt (mitgelieferte,
mit der App signierte Bibliotheken darf man nachladen), aber der Teil-Link ist
der kleinere Eingriff: kein `@rpath`, kein Bündellayout, keine Frage, ob die
Signatur trägt.

### gl4es: glx/ wird auf Darwin nicht gebaut

Der Link zeigte fünf fehlende gl4es-Symbole — `hardext`,
`GetHardwareExtensions`, `glx_init`, `LoadGBMFunctions`, `gl4es_getMainFBSize`.

Ursache: gl4es baut sein `glx/`-Verzeichnis nur unter Linux, Emscripten und
AmigaOS. `gl/init.c` ruft die Funktionen aber unbedingt auf — unter Emscripten
fällt das nicht auf, weil die Aufrufe dort in `#ifndef __EMSCRIPTEN__` stehen.

`patch-gl4es-darwin.py` schließt die Lücke:

- **`glx/hardext.c` kommt in die Bauliste.** Es definiert `hardext` und
  `GetHardwareExtensions` und behandelt `NOX11 + NOEGL` bereits selbst — der
  Emscripten-Zweig nimmt genau diese eine Datei ebenso auf.
- **`glx/darwin_stubs.c`** liefert die drei übrigen. Die Stubs sind nicht
  geraten: in unserer Konfiguration tut das Original nichts. `gl4es_getMainFBSize`
  ist in `glx/glx.c` vollständig von
  `#if !defined(NOX11) && !defined(NOEGL) && !defined(ANDROID)` umschlossen,
  mit dem Kommentar *„noegl, no updating of framebuffer size"*.

**Die 793 Aliase und `-force_load` tragen.** Im fertigen Binary stehen
`glBegin`, `glCallList`, `glAlphaFunc` und die übrigen als echte Symbole.

### JKXR_CLIENT: ein latenter Fehler

Das Target `tbxr_visionos` hatte `-DJKXR_CLIENT` nicht gesetzt. Ohne dieses
Makro deklariert `VrClientInfo.h` `vr` als **Zeiger** statt als Struktur, und
die gesamte VR-Schicht übersetzt gegen den falschen Typ. Auf Android fällt das
nicht auf, weil die JKXR-Quellen dort Teil des Client-Moduls sind und dessen
Flags erben.

Aufgefallen ist es erst, als `VR_Init` dazukam und `vr` tatsächlich benutzte.

### Reihenfolgebedingung für die App-Hülle

**CompositorServices gibt die Renderauflösung nirgends heraus** — die C-API hat
keinen einzigen Zugriff auf Breite oder Höhe, in keinem Header. Sie steht erst
fest, wenn eine Drawable existiert.

Die Engine fragt sie aber beim Start: `WIN_Init` ruft `TBXR_GetScreenRes` auf,
um `glConfig.vidWidth/vidHeight` zu setzen. Die Hülle muss daher einen Frame
holen, die Größe daraus ablesen und über `TBXR_visionOS_SetScreenRes`
hinterlegen, **bevor** sie `JKXR_visionOS_Main` startet.

Anzugeben ist die Größe in Screen-Koordinaten, nicht die der physischen Textur:
bei aktiver Foveation ist die Textur kleiner, und die Rate-Map bildet dazwischen
ab. Auf Texturgröße zu rendern verschenkt genau die Auflösung, für die die
Foveation da ist.

## Schritt 8: App-Hülle — die App baut, ist signiert und installiert

```
JKXR.app   5,0 MB   arm64   platform 11 (xrOS)   de.martek.jkxr
```

Erzeugt aus `visionos/App/project.yml` über XcodeGen. Die Engine kommt über
`OTHER_LDFLAGS` hinein — derselbe Linkweg wie in `link-visionos.sh`,
einschließlich Teil-Link, `-force_load` und `-alias_list`.

### Die Reihenfolge in EngineHost

Das eigentliche Stück Arbeit ist keine Zeile Rendercode, sondern eine
Reihenfolge:

1. ANGLE hochfahren und den Kontext **auf dem Engine-Thread** aktivieren
   (EGL-Kontexte sind threadgebunden, und `TBXR_visionOS_SetLayerRenderer`
   holt sich den Display über `eglGetCurrentDisplay`)
2. MTLDevice von ANGLE und CompositorServices vergleichen — stimmen sie nicht
   überein, lehnt `EGL_ANGLE_metal_texture_client_buffer` den Import ab.
   Vorgeben lässt sich das Device nicht: `eglCreateDeviceANGLE` gibt es nur
   für D3D11.
3. `TBXR_visionOS_SetLayerRenderer`
4. **einen Frame holen, nur um die Auflösung abzulesen**
5. `TBXR_visionOS_SetScreenRes`
6. erst jetzt `JKXR_visionOS_Main`, auf einem eigenen `Thread` mit
   `.userInteractive` — niemals auf einer Warteschlange von Swift Concurrency;
   die Schleife gibt nie ab, und genau das war in S4 die Ursache dafür, dass
   ARKit keine Posen mehr lieferte.

Schritt 4 ist der, den man nicht erwartet. Der Frame wird vollständig
durchlaufen — `startUpdate`/`startSubmission`/`endSubmission` —, aber ohne zu
zeichnen: ein angefangener, nie abgeschlossener Frame würde den Compositor
blockieren.

Abgelesen wird `rasterizationRateMap.screenSize`, nicht `colorTexture.width`.
Bei aktiver Foveation ist die Textur kleiner, und die Rate-Map bildet dazwischen
ab; auf Texturgröße zu rendern verschenkt genau die Auflösung, für die die
Foveation da ist.

### World Tracking über die C-API

`TBXR_Common.mm` braucht ein `ar_world_tracking_provider_t`. Swifts
`WorldTrackingProvider` kapselt diesen Handle und gibt ihn nicht heraus — aus
Swift ist er also nicht durchreichbar. Deshalb liegt die ARKit-Sitzung in
`Sources/Bridge/WorldTracking.m` und benutzt die C-API direkt
(`ar_session_create`, `ar_world_tracking_provider_create`, `ar_session_run`).

Der S4-Spike kam mit der Swift-Fassung aus, weil dort in Swift gerendert wurde
und `queryDeviceAnchor` gleich daneben stand.

### Drei Bau-Stolpersteine

**`-lc++` fehlte.** Xcode linkt eine Swift-App mit `clang`, nicht `clang++`, und
zieht die C++-Standardbibliothek daher nicht von selbst hinzu. Der Fehler kam
als fehlendes `std::logic_error` aus `rd-gles-merged.o` — an einer Stelle, die
nichts mit der Ursache zu tun hat.

**`ENABLE_DEBUG_DYLIB: "NO"`.** Xcode baut Debug-Ziele sonst zweiteilig: einen
Ladestub namens `JKXR` und daneben `JKXR.debug.dylib` mit dem eigentlichen Code
(für SwiftUI-Vorschauen). Das App-Binary war dadurch 92 KB statt 5 MB, was
zunächst wie ein verlorener Link aussah. Abgeschaltet, weil `Sys_LoadDll`
`RTLD_DEFAULT` zurückgibt und `dlsym` sonst über zwei Images suchen müsste.

**`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`.** Die
Spieldateien sind rund 1,2 GB und lassen sich nicht mitliefern. Erst beide
Schlüssel zusammen machen das Dokumentenverzeichnis in der Dateien-App sichtbar
und beschreibbar — dieselbe Stelle, die `Sys_DefaultInstallPath` in
`visionos_main.mm` liefert.

## Was jetzt noch fehlt

**Spieldateien aufs Gerät.** `assets0.pk3` bis `assets3.pk3` plus die beiden
`z_vr_assets`-Dateien nach *Dateien → Auf meinem Apple Vision Pro → JKXR →
base/*. Das Startfenster prüft und meldet, ob sie da sind.

**Der erste Lauf.** Bis hierher ist nichts ausgeführt worden. Was dabei
zuschlagen wird, steht unten unter „Fallstricke aus S4".

**Auf Hardware:** `TBXR_visionOS_DumpInputs()` läuft beim Start und gibt die
tatsächlichen Namen der Controller-Elemente aus. Damit die geratene
Tastenzuordnung in `OpenXrActions.mm` gegen Gemessenes tauschen (S3).

**Feinschliff:** `TBXR_visionOS_Vibrate` über `GCDeviceHaptics`, `VR_GetMove` an
JKXRs Bewegungslogik.

## Restliche Reihenfolge

1. **Plattformschicht** in `code/visionos/`: die 19 offenen Funktionen, Vorlage
   `code/android/`. `Sys_LoadSPGameDll` ist dabei kein echtes `dlopen` — das
   Spielmodul ist statisch gelinkt und gibt nur seinen Einsprungpunkt zurück.
2. **Linken**: erst dann zeigt sich, ob die gl4es-Alias-Liste und `-force_load`
   tragen. Bis hierher ist alles nur übersetzt.
3. **SwiftUI-Hülle**: Immersive Space öffnen, ANGLE initialisieren,
   `LayerRenderer` und Accessory-Tracking-Provider an die XR-Schicht
   durchreichen, `TBXR_visionOS_GetWorldTracking` bereitstellen, Asset-Import
   für `base/`.
4. **Auf Hardware**: `TBXR_visionOS_DumpInputs()` einmal aufrufen und die
   geratene Tastenzuordnung gegen die gemessenen Namen tauschen (S3).
5. **Feinschliff**: `TBXR_visionOS_Vibrate` über `GCDeviceHaptics`, `VR_GetMove`
   an JKXRs Bewegungslogik.

## Fallstricke aus S4, die hier zuschlagen werden

Vollständig in [spikes/s4-angle/README.md](../spikes/s4-angle/README.md). Die
beiden, die diese Codebasis direkt betreffen:

**Farbe erscheint nur, wo Tiefe geschrieben wurde.** id Tech 3 zeichnet den
Himmel klassisch mit abgeschaltetem Tiefenschreiben, weil er auf flachen
Bildschirmen ohnehin hinter allem liegt. Auf visionOS wäre er unsichtbar — und
man würde die Ursache im Renderer suchen statt im Compositor.

**Foveation verlangt `dedicated`-Layout.** Bei `layered` wählt Metal die
Rate-Map-Ebene über den Render-Target-Array-Index; ein GLES-Pfad, der jedes Auge
einzeln importiert, hat dort immer 0 und gäbe beiden Augen die Foveation des
linken.
