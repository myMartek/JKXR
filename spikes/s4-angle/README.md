# S4 — ANGLE (GLES → Metal) auf visionOS

Die offene Frage für den JKXR-Port: JKXR rendert mit OpenGL ES, visionOS hat kein
OpenGL. [ANGLE](https://github.com/google/angle) übersetzt GLES nach Metal —
aber unterstützt es visionOS?

## Ergebnis: ja, mit einem kleinen Patch

```
$ vtool -show-build-version out/xros/libGLESv2.framework/libGLESv2
 platform VISIONOS
    minos 2.0
      sdk 27.0
$ lipo -archs …
arm64
$ otool -L …
  /System/Library/Frameworks/Metal.framework/Metal (weak)
  /System/Library/Frameworks/Foundation.framework/Foundation
```

Kein UIKit, kein OpenGL. Metal-Backend ist drin, beide Interop-Extensions sind
einkompiliert — inklusive `EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE`.

## Warum das die Architektur trägt

`EGL_ANGLE_metal_texture_client_buffer` erzeugt ein EGLImage aus einer
bestehenden `MTLTexture`:

```c
eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                  (EGLClientBuffer)mtlTexture, attribs);
```

Seit Version 2 der Extension (2024) kennt sie `EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE`.
Das passt genau auf CompositorServices: im `.layered`-Layout liegen beide Augen
als Slices *eines* Texture-Arrays. Pro Auge ein EGLImage auf die passende Slice,
als FBO gebunden — JKXRs GLES-Renderer zeichnet direkt in die Compositor-Textur.
Keine Zwischenkopie, kein Blit, und am Renderer selbst ändert sich fast nichts.

Auflage aus der Spec: die `MTLTexture` muss vom selben `MTLDevice` stammen, das
ANGLE über `EGL_ANGLE_device_metal` benutzt. CompositorServices liefert dieses
Device über `layerRenderer.device` — ANGLE wird also darauf initialisiert.

## Der Patch

Chromiums `//build` kannte visionOS überhaupt nicht (`grep -ri xros build/config/`
lieferte nichts). Es ist aber bereits über iOS hinaus verallgemeinert: neben
`iphoneos` existiert `tvos` als `target_platform`. visionOS ließ sich deshalb als
weiterer Zweig derselben Struktur ergänzen statt als Sonderweg.

Acht Stellen in sieben Dateien, alle nach demselben Muster:

| Datei | Was |
|---|---|
| `build/config/apple/mobile_config.gni` | `xros` als gültige `target_platform` |
| `build/config/ios/ios_sdk.gni` | SDK-Namen `xros` / `xrsimulator` |
| `build/config/ios/BUILD.gn` | Clang-Triple `arm64-apple-xros2.0` |
| `build/config/ios/rules.gni` | BuildInfo.plist-Template |
| `build/config/clang/BUILD.gn` | Sanitizer-Runtime-Namen |
| `build/config/rust.gni` | Rust-ABI-Target (nur damit die Datei durchläuft) |
| `build/config/apple/sdk_info.py` | Plattform-Allowlist |
| `build/config/apple/codesign.py` | Bundle-Typ für `.framework` unter xros |

[`patch-angle-visionos.py`](patch-angle-visionos.py) wendet alles an, ist
idempotent und meldet, wenn ein Suchtext nicht mehr passt — damit ein
ANGLE-Update nicht stillschweigend einen halb gepatchten Baum hinterlässt.

Bemerkenswert: **kein einziger Fehler kam aus dem C++- oder Metal-Code.** Alle
2264 Compile-Schritte liefen durch; die zwei Fehlschläge steckten in
Python-Hilfsskripten mit hartkodierten Plattformlisten.

## Nachbauen

```bash
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"
git clone https://chromium.googlesource.com/angle/angle
cd angle && python3 scripts/bootstrap.py && gclient sync -D
cd .. && python3 patch-angle-visionos.py angle/
cd angle
gn gen out/xros --args='target_os="ios" target_platform="xros" target_environment="device" target_cpu="arm64" ios_deployment_target="2.0" ios_enable_code_signing=false is_debug=false angle_enable_metal=true angle_enable_vulkan=false angle_enable_gl=false angle_enable_null=false angle_build_all=false is_component_build=false enable_rust=false'
autoninja -C out/xros libEGL libGLESv2
```

Rechne mit rund 23 GB Checkout und ein paar Minuten Build.

Für den Simulator `target_environment="simulator"` setzen.

## Drei Fallstricke bei CompositorServices

Der Metal-Referenzrenderer unter [`visionOS/`](visionOS/) blieb auf dem Gerät
stundenlang schwarz, während **jede Messung grün war**: Farbtextur nachweislich
korrekt gefüllt (per Blit zurückgelesen, Pixel für Pixel), Command Buffer mit
Status `completed` und ohne Fehler, 7,9 ms Puffer bis zur Deadline, keine
ungültigen Descriptors. Drei Ursachen, alle stumm:

### 1. Der Tiefenpuffer muss gespeichert werden

```swift
pass.depthAttachment.storeAction = .store   // NICHT .dontCare
```

visionOS nutzt die Tiefe für die **Reprojektion** — das Nachführen des fertigen
Bildes an die aktuelle Kopfpose in den Millisekunden zwischen Rendern und
Anzeigen. Ohne gespeicherte Tiefe verwirft der Compositor den Frame, ohne
irgendetwas zu melden.

Für das eigene Rendering wäre `.dontCare` korrekt und schneller. Für den
Compositor ist die Tiefe **Eingabe, nicht Abfall**.

### 2. Farbe erscheint nur, wo Tiefe geschrieben wurde

Ein reiner `loadAction = .clear` ohne Geometrie bleibt **unsichtbar** — die
Textur enthält die Farbe nachweislich, angezeigt wird sie nicht. Erst
Geometrie, die Tiefe ungleich dem Clear-Wert schreibt, erscheint.

**Für den JKXR-Port entscheidend:** id Tech 3 zeichnet den Himmel traditionell
mit abgeschaltetem Tiefenschreiben, weil er auf flachen Bildschirmen ohnehin
hinter allem liegt. Auf visionOS wäre er damit unsichtbar — man säße in einer
Karte mit schwarzem Loch über sich und würde die Ursache vermutlich lange im
Renderer suchen.

Achtung bei der Prüfung: ein Vollbild-Quad mit NDC-`z = 0.0` beweist nichts,
denn bei Reversed-Z ist das exakt der Clear-Wert. Es braucht einen echten,
davon verschiedenen Tiefenwert (im Spike `1e-4`).

### 3. Farbformat `rgba16Float`, nicht `bgra8Unorm_srgb`

Der Compositor rechnet in linearem Extended-Range-Licht. Mit einem sRGB-Format
schreibt die GPU kodierte Werte, die dann als linear gelesen werden — Mitteltöne
kippen ins Weiße. Der Fehler ist tückisch, weil das Bild *erscheint*, nur falsch.

### Was die Fehlersuche wirklich gekostet hat

Zwei Fehlgriffe, beide vermeidbar:

**Die funktionierende Referenz kam zu spät.** Ein `git clone` von
[metal-spatial-rendering](https://github.com/metal-by-example/metal-spatial-rendering)
und ein Diff hätten den Tiefenpuffer in Minuten gezeigt. Stattdessen wurden
sechs Einzelhypothesen einzeln getestet — jede mit einem Gang ins Headset.

**Der Simulator führt in die Irre.** Er meldet `dedicated` mit **einem** Auge,
das Gerät `layered` mit **zwei**. Amplification-Code hinter
`if views.count > 1` läuft im Simulator also nie. Ein dort „end-to-end
validierter" Renderer sagt über das Gerät nichts aus. Immer beide Layouts
prüfen — der Spike beherrscht inzwischen beide.

## visionOS-Referenz-App

Unter [`visionOS/`](visionOS/) liegt eine minimale Immersive-Space-App, die mit
Metal ein Dreieck stereoskopisch rendert: `.layered`-Layout, beide Augen in einem
Pass über Vertex Amplification, Foveation aktiv, ARKit-Kopfpose spät gelatcht.

Sie ist die Referenz für den nächsten Schritt: steht das Dreieck korrekt im Raum,
ist die CompositorServices-Anbindung in Ordnung — was danach beim Umstellen auf
ANGLE schiefgeht, liegt dann an der GLES-Übersetzung und nicht am Compositor.

```bash
cd visionOS && xcodegen generate
xcodebuild -project AngleSpike.xcodeproj -scheme AngleSpike \
  -destination 'generic/platform=visionOS' -allowProvisioningUpdates build
```

## Vier Konventionsunterschiede zwischen OpenGL und Metal

Beim Rendern über ANGLE in eine importierte Metal-Textur fallen sie alle an —
und beim JKXR-Port genauso. Alle vier werden in `angle_render_view()` behandelt:

| | Metal / visionOS | OpenGL ES | Behandlung |
|---|---|---|---|
| Tiefenbereich | z in `[0,1]` | z in `[-1,1]` | `z' = 2z − w` pro Matrixspalte |
| Y-Achse | Texturursprung oben links | Framebuffer unten links | Y-Zeile der Matrix negieren |
| Tiefenrichtung | Reversed-Z | Standard | `glClearDepthf(0)` + `glDepthFunc(GL_GREATER)` |
| Hintergrund | Tiefe nötig (s.o.) | — | Vollbild-Quad statt bloßem Clear |

Die Y-Spiegelung ist besonders heimtückisch: **in der Bildmitte ist sie
unsichtbar.** Das Bild startet korrekt und läuft erst beim Kopfnicken weg — mit
doppelter Geschwindigkeit, weil die Kopfkompensation vertikal invertiert wirkt.

## Foveation: nachgerüstet

`grep -ri foveat src/libANGLE/renderer/metal/` liefert im Original **nichts** —
ANGLEs Metal-Backend kennt Metals Rasterization Rate Maps nicht. Die
Foveation-Extensions, die ANGLE führt (`GL_QCOM_framebuffer_foveated`,
`GL_EXT_fragment_shading_rate`), sind für andere Backends implementiert.

Das ist keine Kosmetik, sondern eine **Auflösungsgrenze**:

```
ohne Foveation:  Drawable 2048x1984 = 2048x1984 effektiv
mit  Foveation:  Drawable 2048x1984 = 5087x4081 effektiv   (Faktor 2,5 linear)
```

CompositorServices deckelt die Drawable-Größe. Ohne Foveation muss über das
gesamte Blickfeld gleichmäßig dicht gerastert werden, und die Vision Pro käme
nicht über das hinaus, was günstigere Headsets liefern.
[`patch-angle-foveation.py`](patch-angle-foveation.py) rüstet die Unterstützung
nach — neun Stellen in sieben Dateien.

### Die Kette der stillen Klemmungen

Vier Glieder, von denen jedes das vorherige zunichtemachte. Jedes für sich sah
korrekt aus; nur Messung an jeder Stufe hat sie sichtbar gemacht:

1. **`RenderPassDesc`** kennt die Map — inklusive `operator==`, denn die
   Struktur ist Cache-Schlüssel für Render-Encoder. Ohne den Vergleich gälte ein
   Pass mit anderer Map als identisch und behielte die alte.
2. **`convertToMetalDesc()`** reicht sie an den `MTLRenderPassDescriptor` durch.
3. **`updateScissor()`** klemmte den Scissor gegen die *physischen*
   Framebuffer-Maße, während der Viewport bei aktiver Map in *Screen*-
   Koordinaten steht. Die Screen-Größe steht in der Map selbst.
4. **`mRenderPassMaxScissorRect`** wird von jedem Anhang auf dessen physische
   Texturgröße heruntergezogen, und `setScissorRect()` klemmt darauf. Der
   fertige Scissor landete so wieder bei 2048x1984.

Sichtbar war das als Bild, von dem nur ein Eckstück übrig blieb — 2048/5087 der
Breite, 1984/4081 der Höhe.

### `dedicated` statt `layered` bei Foveation

Bei `layered` liefert CompositorServices **eine** Rate Map mit **einem Layer pro
Auge**, und Metal wählt den Layer über den Render-Target-Array-Index. Ein
GLES-Pfad, der jedes Auge einzeln als 2D-Textur importiert, hat aber immer
Array-Index 0 — beide Augen bekämen die Foveation des linken.

Weil Foveation den Augen folgt, äußert sich das als **rechtes Auge versetzt, und
der Versatz wandert mit der Blickrichtung**. Das linke Auge ist unauffällig.

Mit `dedicated` liefert CompositorServices **zwei** Maps mit je **einem** Layer,
eine pro Auge. Kostet einen zweiten Renderpass statt Vertex Amplification — für
eine Engine, die ohnehin pro Auge rendert, belanglos gegenüber dem, was die
Foveation einspart.

### Der Einstiegspunkt

```c
extern void ANGLESetDrawFramebufferRateMapMTL(const void *rateMap);
```

Bewusst eine schlichte exportierte C-Funktion statt einer echten GL-Extension:
eine Extension würde ANGLEs **generierte** Entry-Point-Tabellen berühren, die
bei jedem Update neu erzeugt werden — der Patch wäre nach jedem Rebase kaputt.

Die Implementierung liegt in `FrameBufferMtl.mm`, nicht in `global_state.cpp`:
Letzteres wird als reines C++ übersetzt und kann die Objective-C-Header des
Metal-Backends nicht einbinden.

Unterschied zum Build-System-Patch: dies ist ein echter Eingriff in ANGLEs
Renderer und muss bei ANGLE-Updates nachgezogen werden.

## Stand: S4 abgeschlossen

Verifiziert auf einer Apple Vision Pro M5, visionOS 26.

**Die vollständige Kette läuft:**

```
OpenGL ES 3.0  →  ANGLE (Metal-Backend)  →  CompositorServices-Drawable
```

- ANGLE baut nativ für visionOS (`platform VISIONOS`, `minos 2.0`, arm64)
- GLES rendert per `EGL_ANGLE_metal_texture_client_buffer` **direkt** in die
  Drawable-Texturen — keine Zwischenkopie, kein Blit
- Stereo, weltverankert über ARKit, farbrichtig
- Foveation aktiv: **5087x4081 effektive Auflösung pro Auge**
- Der Metal-Pfad bleibt als Kontrollgruppe im Code (`useAngle = false`)

**Zwei Patches, bewusst getrennt:**

| | Umfang | Wartung |
|---|---|---|
| [`patch-angle-visionos.py`](patch-angle-visionos.py) | 8 Stellen, nur Chromiums Build-System | unkritisch |
| [`patch-angle-foveation.py`](patch-angle-foveation.py) | 9 Stellen in ANGLEs Renderer | bei jedem ANGLE-Update nachziehen |

Beide sind idempotent und melden, wenn ein Suchtext nicht mehr passt — damit ein
ANGLE-Update nicht stillschweigend einen halb gepatchten Baum hinterlässt.

## Was davon für den JKXR-Port zählt

Die Checkliste, die dieser Spike teuer erkauft hat:

1. `depthAttachment.storeAction = .store` — sonst verwirft der Compositor jeden
   Frame, lautlos
2. Farbe erscheint nur, wo Tiefe geschrieben wurde — **id Tech 3 zeichnet den
   Himmel klassisch ohne Tiefenschreiben**
3. Farbformat `rgba16Float`, nicht `bgra8Unorm_srgb`
4. Vier GL/Metal-Konventionsunterschiede (Tiefenbereich, Y-Achse, Reversed-Z,
   Hintergrundgeometrie)
5. EGL-Kontexte sind threadgebunden — freigeben, bevor der Renderthread übernimmt
6. Foveation verlangt `dedicated`-Layout und den ANGLE-Patch
7. Der Renderloop gehört auf einen eigenen Thread, nicht auf Swift Concurrency

## ANGLE neu bauen

Der ANGLE-Baum ist 24 GB groß und liegt deshalb **nicht** im Repo. Im Repo
stehen nur die Header (`angle-include/`, 1,8 MB), die fertigen Frameworks
(`../../visionos/App/Frameworks/`, 12 MB) und die beiden Patch-Skripte.

Reproduzieren:

```bash
# depot_tools holen, dann
git clone https://chromium.googlesource.com/angle/angle
git -C angle checkout $(cat ANGLE-COMMIT)
cd angle && python3 scripts/bootstrap.py && gclient sync --no-history && cd ..

python3 patch-angle-visionos.py angle     #  9 Stellen: //build lernt visionOS
python3 patch-angle-foveation.py angle    # 10 Stellen: Rasterization Rate Maps

gn gen angle/out/xros --args='target_os="ios" target_platform="xros"
    target_environment="device" target_cpu="arm64" is_debug=false
    ios_enable_code_signing=false ios_deployment_target="2.0"'
                                            # eine Zeile, ohne Umbrüche
ninja -C angle/out/xros libEGL libGLESv2
```

Vier Fallen, jede einmal hineingetreten:

- **`bootstrap.py` gehört ins `angle/`-Verzeichnis**, nicht daneben. Von außen
  legt es `.gclient` in den Elternordner, und `gclient sync` schüttet den
  ANGLE-Baum dann über das aktuelle Verzeichnis aus. Kein `-D`: das löscht
  „nicht verwaltete" Dateien und damit fremde Nachbarordner gleich mit.
- **`target_os="xros"` gibt es nicht.** visionOS ist hier eine iOS-Variante
  (`target_platform`), wie tvos. Mit `target_os="xros"` bricht
  `//build/config/BUILDCONFIG.gn` bei der Toolchain-Wahl ab.
- **`ios_deployment_target` wandert ins Clang-Triple.** Der Ausdruck lautet
  `$triplet_cpu-$triplet_os$ios_deployment_target` — die iOS-Vorgabe ergibt
  `arm64-apple-xros18.0`, und diese Versionsnummer weist Clang ab. visionOS
  zählt eigene Fassungen; 1.0, 2.0 und 26.0 werden angenommen.
- **Der Baum wächst.** Der Rust-Hunk setzt `aarch64-apple-visionos`, und
  inzwischen prüft `//build/rust/known-target-triples.txt` diesen Namen gegen
  eine Allowlist — obwohl ANGLE gar kein Rust baut. Deshalb die neunte Stelle
  im visionOS-Skript.

Die beiden Skripte ändern zusammen **fünfzehn Dateien** im Baum; mehr steckt
nicht in unserer ANGLE-Fassung. Deshalb genügen Commit-Stand und Skripte, um
sie jederzeit wiederherzustellen.
