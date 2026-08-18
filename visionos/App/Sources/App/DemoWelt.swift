import ARKit
import CompositorServices
import CryptoKit
import Foundation
import Metal
import simd

/// Die Prüfdatei für das App-Review.
///
/// Ohne Spieldaten, die die App weder enthält noch enthalten darf, sieht ein
/// Prüfer das Startfenster und dahinter nichts. `jkxr-demo.pk3` ist der Weg
/// hinein: die App erkennt sie am Hash und zeigt statt eines Spiels die Welt in
/// dieser Datei.
///
/// Am HASH erkannt, nicht am Namen. Ein Name wäre geraten — jemand könnte eine
/// beliebige Datei so nennen, und die App verspräche dann eine Demo und liefe
/// ins Leere. Der Hash sagt genau: das ist die Datei, die wir verteilt haben.
enum DemoDatei {
    /// Erzeugt von make-demo-pk3.py; das Skript prüft diese Zeile gegen sich
    /// selbst. Wer eines von beiden ändert, muss das andere mitändern, sonst
    /// erkennt die App die verteilte Datei nicht mehr.
    static let DEMO_SHA256 = "a429eece0db64a900e405f7e045739725999b5fc846c1aa2f990dbd58cff72a7"

    static let dateiname = "jkxr-demo.pk3"

    static func istDemodatei(_ url: URL) -> Bool {
        guard let daten = try? Data(contentsOf: url) else { return false }
        // Vor dem Hashen die Größe prüfen: die Datei ist unter einem Kilobyte,
        // und eine 1,2-GB-Spieldatei bei jedem Import komplett einzulesen wäre
        // eine spürbare Pause für nichts.
        guard daten.count < 64 * 1024 else { return false }
        let digest = SHA256.hash(data: daten).map { String(format: "%02x", $0) }.joined()
        return digest == DEMO_SHA256
    }

    /// Liegt die Demodatei im base-Ordner dieses Spiels?
    static func vorhanden(in ordner: URL) -> Bool {
        let pfad = ordner.appendingPathComponent(dateiname)
        guard FileManager.default.fileExists(atPath: pfad.path) else { return false }
        return istDemodatei(pfad)
    }
}

/// Welcher Weg beim Öffnen des Immersive Space genommen wird.
///
/// Wird im Fenster gesetzt, bevor der Raum aufgeht, und dort gelesen — derselbe
/// Ablauf wie bei der Spielauswahl. Ein Umschalten mitten im Lauf gibt es
/// nicht: der Raum wird geschlossen und neu geöffnet.
enum Laufmodus {
    static var demo = false
}

// MARK: - Die Welt

/// Eine kleine, mitgelieferte Welt für das App-Review.
///
/// Sie zeichnet NICHT über die Engine, sondern unmittelbar in Metal. Das ist
/// hier der Punkt, nicht eine Abkürzung: die Engine braucht die gekauften
/// Spieldateien schon für ihr Hauptmenü — Schriften, Menügrafiken, Zeichenketten
/// stehen alle in assets0.pk3. Ohne sie kommt sie nicht bis zu einem Bild.
///
/// Dieser Weg berührt den Spielpfad an keiner Stelle. Was hier schiefgeht, kann
/// dem Spiel nichts anhaben, und umgekehrt.
///
/// Gezeigt wird, was die Store-Beschreibung behauptet und ein Prüfer prüfen
/// können soll: eine Welt, die im Raum steht statt vor dem Gesicht zu kleben,
/// je Auge gerechnet, mit Kopfverfolgung und Foveation.
final class DemoWelt {
    private let layerRenderer: LayerRenderer
    private let geraet: MTLDevice
    private let warteschlange: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var tiefenzustand: MTLDepthStencilState?
    private var eckenPuffer: MTLBuffer?
    private var eckenAnzahl = 0
    /// Nur fürs erste Bild: was der Compositor tatsächlich liefert.
    private var gezaehlt = false
    private var zahlenGemeldet = false

    private let sitzung = ARKitSession()
    private let weltverfolgung = WorldTrackingProvider()

    init?(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.geraet = layerRenderer.device
        guard let q = geraet.makeCommandQueue() else { return nil }
        self.warteschlange = q
    }

    func start() {
        Task {
            do {
                try await sitzung.run([weltverfolgung])
            } catch {
                // Kein Abbruch. Ohne Kopfverfolgung steht die Welt still,
                // statt zu verschwinden — für eine Demo ist das immer noch
                // besser als ein schwarzes Bild ohne Begründung.
                print("[Demo] Weltverfolgung nicht gestartet: \(error)")
            }
        }

        // Eigener Thread, und die Schleife läuft UNMITTELBAR darauf.
        //
        // Hier stand zuerst ein Thread, der innen ein Task { @MainActor ... }
        // aufmachte. Das hebt den eigenen Thread wieder auf: die Schleife lief
        // auf dem Hauptthread, blockierte ihn, und der Compositor brachte die
        // App nach wenigen Sekunden mit SIGKILL um -- nachdem sie noch
        // "Demo-Welt läuft" gemeldet hatte. Ein Prozess, der keine Bilder mehr
        // abliefert, wird beendet, und die Meldung davor führt in die Irre.
        let t = Thread { [weak self] in
            self?.schleife()
        }
        t.name = "de.martek.jkxr.demo"
        t.qualityOfService = .userInteractive
        t.start()
    }

    // MARK: Aufbau

    private func baueAuf() -> Bool {
        do {
            let bibliothek = try geraet.makeLibrary(source: Self.shader, options: nil)
            let beschreibung = MTLRenderPipelineDescriptor()
            beschreibung.vertexFunction = bibliothek.makeFunction(name: "demo_vertex")
            beschreibung.fragmentFunction = bibliothek.makeFunction(name: "demo_fragment")
            beschreibung.colorAttachments[0].pixelFormat = .rgba16Float
            beschreibung.depthAttachmentPixelFormat = .depth32Float
            // Beide Augen in einem Durchgang wären mit "layered" möglich; wir
            // fahren "dedicated" (siehe JKXRApp), also je Auge ein Pass.
            pipeline = try geraet.makeRenderPipelineState(descriptor: beschreibung)

        } catch {
            print("[Demo] Pipeline ließ sich nicht bauen: \(error)")
            return false
        }

        let tiefe = MTLDepthStencilDescriptor()
        // GREATER und Löschtiefe 0: CompositorServices arbeitet mit
        // umgekehrter Tiefe. Mit LESS wäre alles verdeckt, was nicht am
        // äußersten Rand liegt — das Bild bliebe leer, ohne Fehlermeldung.
        tiefe.depthCompareFunction = .greater
        tiefe.isDepthWriteEnabled = true
        tiefenzustand = geraet.makeDepthStencilState(descriptor: tiefe)

        let ecken = Self.baueSzene()
        eckenAnzahl = ecken.count
        eckenPuffer = geraet.makeBuffer(bytes: ecken,
                                        length: MemoryLayout<Ecke>.stride * ecken.count,
                                        options: .storageModeShared)
        return pipeline != nil && tiefenzustand != nil && eckenPuffer != nil
    }

    // MARK: Schleife

    private func schleife() {
        guard baueAuf() else {
            print("[Demo] Aufbau gescheitert — es bleibt schwarz")
            return
        }
        print("[Demo] Demo-Welt läuft, \(eckenAnzahl) Ecken")

        while true {
            switch layerRenderer.state {
            case .invalidated:
                print("[Demo] Ebene beendet")
                return
            case .paused:
                layerRenderer.waitUntilRunning()
                continue
            default:
                break
            }

            guard let frame = layerRenderer.queryNextFrame() else { continue }
            frame.startUpdate()
            frame.endUpdate()
            guard let takt = frame.predictTiming() else { continue }
            LayerRenderer.Clock().wait(until: takt.optimalInputTime)

            frame.startSubmission()

            // ALLE Drawables, nicht die erste.
            //
            // Eine geholte Drawable MUSS präsentiert werden. Hier stand
            // queryDrawables().first, und der Prozess endete mit SIGABRT --
            // kommentarlos, ohne Metal-Meldung, mitten im Lauf. Eine liegen
            // gelassene Drawable ist für CompositorServices kein Auslassen,
            // sondern ein Fehler.
            let drawables = frame.queryDrawables()
            if drawables.isEmpty {
                frame.endSubmission()
                continue
            }
            if !gezaehlt {
                gezaehlt = true
                print("[Demo] \(drawables.count) Drawable(s), "
                    + "\(drawables[0].views.count) Sicht(en), "
                    + "\(drawables[0].colorTextures.count) Textur(en)")
            }

            for drawable in drawables {
                let zeit = LayerRenderer.Clock.Instant.epoch
                    .duration(to: drawable.frameTiming.trackableAnchorTime).sekunden
                if let anker = weltverfolgung.queryDeviceAnchor(atTimestamp: zeit) {
                    drawable.deviceAnchor = anker
                }
                zeichne(drawable)
            }
            frame.endSubmission()
        }
    }

    private func zeichne(_ drawable: LayerRenderer.Drawable) {
        guard let pipeline, let tiefenzustand, let eckenPuffer,
              let befehle = warteschlange.makeCommandBuffer() else { return }

        let ankerMatrix = drawable.deviceAnchor?.originFromAnchorTransform
            ?? matrix_identity_float4x4

        for (i, sicht) in drawable.views.enumerated() {
            // Bei "shared" gibt es nur EINE Textur für beide Augen; der Index
            // liefe dann ins Leere. Wir fahren zwar dedicated, aber ein Absturz
            // wäre der teuerste Weg, das zu erfahren.
            let index = i < drawable.colorTextures.count ? i : 0

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.colorTextures[index]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor =
                MTLClearColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1.0)
            pass.depthAttachment.texture = drawable.depthTextures[index]
            pass.depthAttachment.loadAction = .clear
            // .store und ein Löschwert ÜBER null -- beides ist Bedingung dafür,
            // dass überhaupt etwas zu sehen ist.
            //
            // visionOS benutzt den Tiefenpuffer zur Reprojektion und verwirft
            // einen Frame ohne brauchbare Tiefe lautlos. Hier stand .dontCare
            // und clearDepth 0: der Compositor nahm 90 Bilder je Sekunde
            // entgegen, bestätigte sie, und zeigte schwarz. Kein Fehler, keine
            // Warnung, kein Hinweis.
            //
            // Bei umgekehrter Tiefe ist 0 der Fernwert und heißt "hier ist
            // nichts". 1e-4 ist ein sichtbarer Fernwert. Dieselbe Zahl und
            // dieselbe Begründung stehen in TBXR_submitFrame -- dort als
            // "teuerster Fehler in S4" vermerkt, und hier ein zweites Mal
            // hineingelaufen.
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1.0e-4
            if index < drawable.rasterizationRateMaps.count {
                pass.rasterizationRateMap = drawable.rasterizationRateMaps[index]
            }

            guard let enc = befehle.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.setViewport(sicht.textureMap.viewport)

            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(tiefenzustand)
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)

            // Blick = Umkehrung von (Geräteanker · Augenversatz), davor die
            // Projektion des Compositors. Sie selbst zu bauen wäre falsch: die
            // Sichtkegel der Vision Pro sind schief und je Auge verschieden.
            let blick = (ankerMatrix * sicht.transform).inverse
            let projektion = drawable.computeProjection(viewIndex: i)
            var u = Uniformen(mvp: projektion * blick)

            if !zahlenGemeldet, i == 0 {
                zahlenGemeldet = true
                let sichtfeld = sicht.textureMap.viewport
                print("[Demo] Viewport \(sichtfeld.width)x\(sicht.textureMap.viewport.height) "
                    + "Textur \(drawable.colorTextures[index].width)x\(drawable.colorTextures[index].height) "
                    + "Ratemaps \(drawable.rasterizationRateMaps.count)")
                print("[Demo] Tiefenbereich \(drawable.depthRange)")
                print("[Demo] Ankerposition \(ankerMatrix.columns.3)")
                // Ein bekannter Punkt: Mitte des naechsten Wuerfels, 1,5 m vor
                // dem Ursprung, 17 cm ueber dem Boden.
                let probe = SIMD4<Float>(-0.9, 0.17, -1.5, 1)
                let clip = u.mvp * probe
                print("[Demo] Probe -> clip \(clip), ndc \(SIMD3(clip.x, clip.y, clip.z) / clip.w)")
            }

            enc.setVertexBuffer(eckenPuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniformen>.size, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: eckenAnzahl)
            enc.endEncoding()
        }

        drawable.encodePresent(commandBuffer: befehle)
        befehle.commit()
    }
}

// MARK: - Geometrie

private struct Ecke {
    var position: SIMD3<Float>
    var normale: SIMD3<Float>
    var farbe: SIMD3<Float>
}

private struct Uniformen {
    var mvp: simd_float4x4
}

extension DemoWelt {
    /// Boden, Horizontband und ein paar Körper.
    ///
    /// Bewusst schlicht. Was hier zu sehen sein muss, ist nicht Schönheit,
    /// sondern dass eine Welt IM RAUM steht: dass Nähe und Ferne stimmen, dass
    /// beim Vorbeugen die Verdeckung wandert, und dass beides in beiden Augen
    /// zusammenpasst. Dafür genügen Kanten in bekannten Abständen.
    fileprivate static func baueSzene() -> [Ecke] {
        var ecken: [Ecke] = []

        // Boden. Ein Rechteck; das Raster entsteht im Fragment-Shader aus den
        // Weltkoordinaten, nicht aus Geometrie.
        let weite: Float = 30
        let bodenfarbe = SIMD3<Float>(0.10, 0.12, 0.16)
        let hoch = SIMD3<Float>(0, 1, 0)
        for (x, z) in [(-weite, -weite), (weite, -weite), (weite, weite),
                       (-weite, -weite), (weite, weite), (-weite, weite)] {
            ecken.append(Ecke(position: SIMD3(x, 0, z), normale: hoch, farbe: bodenfarbe))
        }

        // Körper in bekannten Abständen: ein Ring aus Säulen und ein paar
        // Würfel davor. Die Farben sind linear gemeint -- der Compositor
        // rechnet in linearem Licht (siehe colorFormat in JKXRApp).
        let farben: [SIMD3<Float>] = [
            SIMD3(0.55, 0.16, 0.16), SIMD3(0.16, 0.42, 0.55),
            SIMD3(0.50, 0.42, 0.14), SIMD3(0.20, 0.48, 0.26),
            SIMD3(0.42, 0.20, 0.50), SIMD3(0.50, 0.30, 0.14),
        ]

        // Ring aus acht Säulen, damit man sich drehen kann und immer etwas sieht.
        for i in 0..<8 {
            let winkel = Float(i) / 8 * 2 * .pi
            let radius: Float = 6
            let hoehe: Float = 2.2 + Float(i % 3) * 0.6
            quader(&ecken,
                   mitte: SIMD3(cos(winkel) * radius, hoehe / 2, sin(winkel) * radius),
                   masse: SIMD3(0.6, hoehe, 0.6),
                   farbe: farben[i % farben.count])
        }

        // Drei Würfel in Griffweite, gestaffelt: der nächste bei anderthalb
        // Metern. In Stereo ist gerade der Nahbereich aussagekräftig.
        for (i, z) in [Float(-1.5), -2.5, -3.5].enumerated() {
            let s = 0.35 + Float(i) * 0.15
            quader(&ecken,
                   mitte: SIMD3(Float(i - 1) * 0.9, s / 2, z),
                   masse: SIMD3(s, s, s),
                   farbe: farben[(i + 2) % farben.count])
        }

        return ecken
    }

    /// Ein achsenparalleler Quader, zwölf Dreiecke, Normalen je Fläche.
    fileprivate static func quader(_ ecken: inout [Ecke],
                                   mitte: SIMD3<Float>,
                                   masse: SIMD3<Float>,
                                   farbe: SIMD3<Float>) {
        let h = masse / 2
        // Je Fläche: Normale und die vier Eckpunkte gegen den Uhrzeigersinn von
        // außen gesehen (setFrontFacing(.counterClockwise) oben).
        let flaechen: [(SIMD3<Float>, [SIMD3<Float>])] = [
            (SIMD3(0, 0, 1),  [SIMD3(-h.x, -h.y, h.z), SIMD3(h.x, -h.y, h.z),
                               SIMD3(h.x, h.y, h.z),   SIMD3(-h.x, h.y, h.z)]),
            (SIMD3(0, 0, -1), [SIMD3(h.x, -h.y, -h.z), SIMD3(-h.x, -h.y, -h.z),
                               SIMD3(-h.x, h.y, -h.z), SIMD3(h.x, h.y, -h.z)]),
            (SIMD3(1, 0, 0),  [SIMD3(h.x, -h.y, h.z),  SIMD3(h.x, -h.y, -h.z),
                               SIMD3(h.x, h.y, -h.z),  SIMD3(h.x, h.y, h.z)]),
            (SIMD3(-1, 0, 0), [SIMD3(-h.x, -h.y, -h.z), SIMD3(-h.x, -h.y, h.z),
                               SIMD3(-h.x, h.y, h.z),   SIMD3(-h.x, h.y, -h.z)]),
            (SIMD3(0, 1, 0),  [SIMD3(-h.x, h.y, h.z),  SIMD3(h.x, h.y, h.z),
                               SIMD3(h.x, h.y, -h.z),  SIMD3(-h.x, h.y, -h.z)]),
            (SIMD3(0, -1, 0), [SIMD3(-h.x, -h.y, -h.z), SIMD3(h.x, -h.y, -h.z),
                               SIMD3(h.x, -h.y, h.z),   SIMD3(-h.x, -h.y, h.z)]),
        ]
        for (normale, p) in flaechen {
            for i in [0, 1, 2, 0, 2, 3] {
                ecken.append(Ecke(position: mitte + p[i], normale: normale, farbe: farbe))
            }
        }
    }

    fileprivate static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Ecke {
        float3 position;
        float3 normale;
        float3 farbe;
    };

    struct Uniformen {
        float4x4 mvp;
    };

    struct AusVertex {
        float4 position [[position]];
        float3 welt;
        float3 normale;
        float3 farbe;
    };

    vertex AusVertex demo_vertex(uint id [[vertex_id]],
                                 const device Ecke *ecken [[buffer(0)]],
                                 constant Uniformen &u [[buffer(1)]])
    {
        Ecke e = ecken[id];
        AusVertex a;
        a.position = u.mvp * float4(e.position, 1.0);
        a.welt = e.position;
        a.normale = e.normale;
        a.farbe = e.farbe;
        return a;
    }

    fragment float4 demo_fragment(AusVertex a [[stage_in]])
    {
        float3 licht = normalize(float3(0.35, 1.0, 0.25));
        float diffus = saturate(dot(normalize(a.normale), licht)) * 0.7 + 0.3;
        float3 farbe = a.farbe * diffus;

        // Raster auf dem Boden: ein Meter Teilung. Es ist der eigentliche
        // Massstab der Szene -- ohne etwas Bekanntes am Boden laesst sich
        // Entfernung im Headset kaum beurteilen.
        if (a.normale.y > 0.9) {
            float2 g = fract(a.welt.xz);
            float2 d = min(g, 1.0 - g);
            float linie = 1.0 - smoothstep(0.0, 0.02, min(d.x, d.y));
            farbe = mix(farbe, float3(0.35, 0.55, 0.75), linie * 0.8);

            // Mit der Entfernung ausblenden, sonst flimmert das Raster am
            // Horizont.
            float weg = length(a.welt.xz);
            farbe = mix(farbe, float3(0.03, 0.04, 0.07),
                        saturate((weg - 8.0) / 18.0));
        }
        return float4(farbe, 1.0);
    }
    """
}

extension Duration {
    /// Sekunden als Fliesskommazahl -- ARKit will einen TimeInterval, der
    /// Compositor liefert eine Duration.
    var sekunden: TimeInterval {
        let (s, a) = components
        return TimeInterval(s) + TimeInterval(a) * 1e-18
    }
}
