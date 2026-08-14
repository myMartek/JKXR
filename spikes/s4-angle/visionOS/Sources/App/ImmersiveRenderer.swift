import CompositorServices
import Metal
import simd
import ARKit

/// Rendert stereoskopisch in den Immersive Space.
///
/// Zweck im Rahmen von S4: die Zielfläche bereitstellen, in die ANGLE später
/// hineinrendern soll. Das Metal-Dreieck ist die Referenz — steht es korrekt im
/// Raum, ist die CompositorServices-Anbindung in Ordnung, und alles, was danach
/// schiefgeht, liegt an der GLES-Übersetzung.
final class ImmersiveRenderer {
    private let layerRenderer: LayerRenderer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let trianglePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let backgroundPipeline: MTLRenderPipelineState
    /// Schreibt Tiefe auf der fernen Ebene, ohne zu testen — der Hintergrund
    /// soll alles füllen und von allem anderen überzeichnet werden.
    private let backgroundDepthState: MTLDepthStencilState

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    /// Weltverankerung des Dreiecks, beim ersten Frame aus der Kopfpose
    /// abgeleitet: einen Meter vor dem Blick, wo es garantiert sichtbar ist.
    /// Danach bleibt es fest im Raum stehen, sodass sich Kopfbewegung und
    /// Rendering unterscheiden lassen — ein kopfgekoppeltes Dreieck würde
    /// selbst bei komplett kaputtem Tracking mitwandern und nichts beweisen.
    private var modelMatrix: simd_float4x4?
    private var frameCount = 0
    private var complaints: [String: Int] = [:]
    private var sawSuccessfulFrame = false

    /// Schalter aus der Fehlersuche: nur den Clear zeichnen. Trennt "der Weg
    /// zum Compositor ist kaputt" von "Geometrie ist kaputt". Bleibt drin, weil
    /// er beim nächsten schwarzen Bild wieder zwei Minuten spart.
    private let drawGeometry = true

    /// Meldet einen Fehlschlag im Frame-Pfad, aber nicht 90-mal pro Sekunde.
    ///
    /// Diese Pfade waren vorher stumme `guard … else { return }`. Genau daran
    /// lag es: schlägt etwa die Encoder-Erstellung fehl, läuft `encodePresent`
    /// trotzdem und der Compositor zeigt eine leere Drawable — im Headset nicht
    /// von "Renderer tot" zu unterscheiden.
    private func complain(_ what: String) {
        let count = (complaints[what] ?? 0) + 1
        complaints[what] = count
        if count == 1 || count % 90 == 0 {
            print("[S4] FEHLER (\(count)x) in Frame \(frameCount): \(what)")
        }
    }

    init?(_ layerRenderer: LayerRenderer) {
        guard let device = layerRenderer.device as MTLDevice?,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }

        self.layerRenderer = layerRenderer
        self.device = device
        self.queue = queue

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "triangle_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "triangle_fragment")
        descriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        // Bei .layered rendert ein Pass in beide Augen; die Amplification-Anzahl
        // muss die Pipeline kennen.
        descriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount

        do {
            self.trianglePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            // Früher verschluckte ein `try?` diesen Fehler und der Renderer gab
            // stillschweigend nil zurück — im Headset nicht von "läuft nicht"
            // zu unterscheiden.
            print("[S4] Pipeline-Erstellung fehlgeschlagen: \(error)")
            return nil
        }

        print("[S4] Renderer bereit — Layout: \(layerRenderer.configuration.layout), "
            + "viewCount: \(layerRenderer.properties.viewCount), "
            + "Farbformat: \(layerRenderer.configuration.colorFormat.rawValue)")

        Self.initializeAngle(compositorDevice: device)

        let bgDescriptor = MTLRenderPipelineDescriptor()
        bgDescriptor.vertexFunction = library.makeFunction(name: "background_vertex")
        bgDescriptor.fragmentFunction = library.makeFunction(name: "background_fragment")
        bgDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        bgDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        bgDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount

        do {
            self.backgroundPipeline = try device.makeRenderPipelineState(descriptor: bgDescriptor)
        } catch {
            print("[S4] Hintergrund-Pipeline fehlgeschlagen: \(error)")
            return nil
        }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater   // reversed-Z, wie von visionOS erwartet
        depth.isDepthWriteEnabled = true

        let bgDepth = MTLDepthStencilDescriptor()
        bgDepth.depthCompareFunction = .always
        bgDepth.isDepthWriteEnabled = true

        guard let depthState = device.makeDepthStencilState(descriptor: depth),
              let bgDepthState = device.makeDepthStencilState(descriptor: bgDepth)
        else { return nil }
        self.depthState = depthState
        self.backgroundDepthState = bgDepthState
    }

    /// Startet ANGLE und prüft die Voraussetzung, auf der der ganze Plan steht.
    ///
    /// `eglCreateDeviceANGLE` gibt es nur für D3D11, nicht für Metal — ANGLE
    /// wählt sein `MTLDevice` also selbst, und wir können ihm keines vorgeben.
    /// `EGL_ANGLE_metal_texture_client_buffer` verlangt aber ausdrücklich, dass
    /// importierte Texturen vom selben Device stammen wie das Display.
    ///
    /// Auf Apple Silicon existiert nur eine GPU, die Devices *sollten* also
    /// identisch sein. Genau solche Annahmen haben in diesem Spike aber schon
    /// Stunden gekostet, deshalb wird verglichen statt gehofft.
    private static func initializeAngle(compositorDevice: MTLDevice) {
        guard angle_init() else {
            print("[ANGLE] Initialisierung fehlgeschlagen")
            return
        }

        var description = [CChar](repeating: 0, count: 1024)
        angle_describe(&description, description.count)
        print("[ANGLE]\n" + String(cString: description))

        let angleDevice = angle_metal_device()
        let compositorPointer = Unmanaged.passUnretained(compositorDevice).toOpaque()

        if angleDevice == nil {
            print("[ANGLE] MTLDevice ließ sich nicht abfragen — Texturimport "
                + "lässt sich damit nicht absichern")
        } else if angleDevice == UnsafeRawPointer(compositorPointer) {
            print("[ANGLE] MTLDevice stimmt mit CompositorServices überein — "
                + "Texturimport ist zulässig")
        } else {
            print("[ANGLE] ACHTUNG: ANGLE nutzt \(angleDevice!), "
                + "CompositorServices \(compositorPointer). Verschiedene "
                + "Devices — EGL_ANGLE_metal_texture_client_buffer verweigert "
                + "den Import. Ein Zwischenschritt über gemeinsamen Speicher "
                + "wäre nötig.")
        }
    }

    func start() {
        Task {
            let auth = await arSession.requestAuthorization(for: [.worldSensing])
            print("[S4] ARKit-Autorisierung: \(auth)")
            do {
                try await arSession.run([worldTracking])
                print("[S4] WorldTracking läuft, Status: \(worldTracking.state)")
            } catch {
                print("[S4] ARKit konnte nicht starten: \(error)")
            }
        }

        // Eigener Thread statt Swift Concurrency: der Renderloop ist eine
        // blockierende Endlosschleife. Auf dem Cooperative Pool würde sie
        // dauerhaft einen der wenigen Pool-Threads belegen und andere Arbeit
        // aushungern — unter anderem ARKits Updates, wodurch die Kopfpose nie
        // ankommt und der Compositor jeden Frame verwirft.
        let thread = Thread { [weak self] in
            // EGL-Kontexte sind threadgebunden: angle_init() hat ihn an den
            // Initialisierungsthread gebunden, gezeichnet wird aber hier.
            if !angle_make_current() {
                print("[ANGLE] Kontext ließ sich auf dem Renderthread nicht aktivieren")
            }
            self?.renderLoop()
        }
        thread.name = "S4 Render Loop"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func renderLoop() {
        while true {
            switch layerRenderer.state {
            case .invalidated:
                return
            case .paused:
                layerRenderer.waitUntilRunning()
            case .running:
                autoreleasepool { renderFrame() }
            @unknown default:
                return
            }
        }
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else {
            complain("queryNextFrame lieferte nil")
            return
        }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else {
            complain("predictTiming lieferte nil")
            return
        }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        defer { frame.endSubmission() }

        guard let drawable = frame.queryDrawable() else {
            complain("queryDrawable lieferte nil")
            return
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            complain("makeCommandBuffer lieferte nil")
            return
        }

        // Kopfpose so spät wie möglich holen — jede Millisekunde hier landet
        // direkt in der wahrgenommenen Latenz.
        // trackableAnchorTime, nicht presentationTime: Ersteres ist der
        // Zeitpunkt, für den der Compositor die Pose erwartet. Mit der
        // Präsentationszeit liegt die Pose ein Stück in der Zukunft, und die
        // Reprojektion rechnet gegen einen falschen Bezugspunkt.
        let anchor = worldTracking.queryDeviceAnchor(
            atTimestamp: LayerRenderer.Clock.Instant.epoch.duration(
                to: drawable.frameTiming.trackableAnchorTime).timeInterval
        )
        drawable.deviceAnchor = anchor

        frameCount += 1

        // Erst verankern, wenn eine echte Kopfpose vorliegt. Vorher wäre der
        // Bezugspunkt der Weltursprung, und das Dreieck stünde irgendwo.
        if modelMatrix == nil, let head = anchor?.originFromAnchorTransform {
            var forward = matrix_identity_float4x4
            forward.columns.3 = SIMD4<Float>(0, 0, -1, 1)
            modelMatrix = head * forward
            let p = modelMatrix!.columns.3
            print("[S4] Kopfpose nach \(frameCount) Frames da — Dreieck verankert "
                + "bei \(p.x), \(p.y), \(p.z)")
        }

        if frameCount == 1 {
            let tex = drawable.colorTextures[0]
            print("[S4] Frame 1: \(tex.width)x\(tex.height), "
                + "\(tex.arrayLength) Slice(s), \(drawable.views.count) View(s)")

            // Bei aktiver Foveation ist entscheidend, in welchem Koordinatenraum
            // der Viewport angegeben ist: die Rate Map bildet Screen- auf
            // physische Koordinaten ab, und ein Viewport im falschen Raum
            // verschiebt und beschneidet das gesamte Bild.
            for (i, view) in drawable.views.enumerated() {
                let vp = view.textureMap.viewport
                print("[S4]   View \(i): Viewport "
                    + "(\(vp.originX), \(vp.originY)) \(vp.width)x\(vp.height)")
            }
            let maps = drawable.rasterizationRateMaps
            print("[S4]   Rate Maps: \(maps.count)")
            for (i, map) in maps.enumerated() {
                let screen = map.screenSize
                let physical = map.physicalSize(layer: 0)
                print("[S4]   Map \(i): screen \(screen.width)x\(screen.height), "
                    + "physical \(physical.width)x\(physical.height), "
                    + "Layer \(map.layerCount)")
            }
        }
        // Weiterhin melden, auch nachdem die Pose da ist: nur so lässt sich
        // "rendert durchgehend" von "hängt nach dem ersten Frame" unterscheiden.
        if frameCount % 90 == 0 {
            if modelMatrix == nil {
                print("[S4] Frame \(frameCount): keine Kopfpose "
                    + "(WorldTracking-Status: \(worldTracking.state))")
            } else {
                let p = anchor?.originFromAnchorTransform.columns.3
                print("[S4] Frame \(frameCount): rendert, Kopf bei "
                    + (p.map { "\($0.x), \($0.y), \($0.z)" } ?? "Pose gerade weg"))
            }
        }

        encode(into: drawable, anchor: anchor, commandBuffer: commandBuffer)


        // Wird die Abgabefrist eingehalten? Verpasste Deadlines lässt der
        // Compositor fallen — jeden Frame verpasst hieße durchgehend schwarz,
        // ohne dass irgendwo ein Fehler auftaucht.
        if frameCount % 90 == 0 {
            let slack = LayerRenderer.Clock().now
                .duration(to: drawable.frameTiming.renderingDeadline)
            let ms = Double(slack.components.seconds) * 1000
                   + Double(slack.components.attoseconds) * 1e-15
            print(String(format: "[S4] Frame %d: %.2f ms bis zur Deadline%@",
                         frameCount, ms, ms < 0 ? "  ← VERPASST" : ""))
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        // Letzte stumme Stelle im Pfad: bisher wurde nur abgeschickt, nie
        // geprüft, ob die GPU den Buffer auch ausführt. Ein Fehler hier ließe
        // die Drawable unbeschrieben — schwarz, ohne jede Meldung.
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            if let error = cb.error {
                self.complain("Command Buffer fehlgeschlagen: \(error)")
            } else if !self.sawSuccessfulFrame {
                self.sawSuccessfulFrame = true
                print("[S4] Erster Command Buffer erfolgreich abgeschlossen "
                    + "(Status: \(cb.status.rawValue))")
            }
        }
        commandBuffer.commit()
    }

    /// Verteilt die Augen auf Render-Passes, je nach Layout.
    ///
    /// Beide Fälle müssen bedient werden, und sie unterscheiden sich stärker,
    /// als es zunächst aussieht:
    ///
    /// - `layered`: **eine** Textur mit einer Array-Slice pro Auge. Ein einziger
    ///   Pass, beide Augen über Vertex Amplification. Das ist der Pfad der
    ///   Vision Pro.
    /// - `dedicated`: **je Auge eine eigene** Textur. Ein Pass pro Auge, keine
    ///   Amplification. Das ist der Pfad des Simulators.
    ///
    /// Die vorherige Fassung bespielte immer nur `colorTextures[0]`. Im
    /// Simulator fiel das nicht auf, weil dort ohnehin nur ein Auge existiert —
    /// bei `dedicated` mit zwei Augen wäre das rechte leer geblieben.
    /// Zeichnet über ANGLE statt über Metal. Der Metal-Pfad bleibt als
    /// Kontrollgruppe erhalten — weicht das GLES-Bild ab, liegt es an der
    /// Übersetzung und nicht am Compositor.
    private let useAngle = true

    private func encode(into drawable: LayerRenderer.Drawable,
                        anchor: DeviceAnchor?,
                        commandBuffer: MTLCommandBuffer) {
        if useAngle {
            encodeViaAngle(drawable: drawable, anchor: anchor)
            return
        }

        if drawable.colorTextures.count == 1 {
            encodePass(drawable: drawable, textureIndex: 0,
                       views: Array(drawable.views.indices),
                       anchor: anchor, commandBuffer: commandBuffer)
        } else {
            for index in drawable.colorTextures.indices {
                encodePass(drawable: drawable, textureIndex: index,
                           views: [index],
                           anchor: anchor, commandBuffer: commandBuffer)
            }
        }
    }

    /// Rendert beide Augen über OpenGL ES direkt in die Drawable-Texturen.
    ///
    /// Kein Metal-Encoder, kein Blit: ANGLE schreibt über den EGLImage-Import
    /// unmittelbar in dieselben Texturen, die der Compositor anzeigt. Genau
    /// dieser Weg soll später JKXRs Renderer aufnehmen.
    private func encodeViaAngle(drawable: LayerRenderer.Drawable,
                                anchor: DeviceAnchor?) {
        let model = modelMatrix ?? matrix_identity_float4x4
        let layered = drawable.colorTextures.count == 1

        for viewIndex in drawable.views.indices {
            // layered: eine Textur, ein Slice pro Auge.
            // dedicated: eine Textur pro Auge, jeweils Slice 0.
            let textureIndex = layered ? 0 : viewIndex
            let slice = layered ? viewIndex : 0

            let view = drawable.views[viewIndex]
            let viewport = view.textureMap.viewport
            var mvp = mvp(viewIndex: viewIndex, view: view, drawable: drawable,
                          anchor: anchor, model: model)

            let color = Unmanaged.passUnretained(drawable.colorTextures[textureIndex])
                .toOpaque()
            let depth = Unmanaged.passUnretained(drawable.depthTextures[textureIndex])
                .toOpaque()

            // Bei aktiver Foveation liefert die Drawable pro Auge eine
            // Rasterization Rate Map. Ohne sie rastert ANGLE gleichmäßig,
            // während der Compositor foveiert entzerrt — das Bild wandert dann
            // mit doppelter Kopfgeschwindigkeit aus dem Blickfeld.
            let rateMaps = drawable.rasterizationRateMaps
            let rateMap: UnsafeRawPointer? = rateMaps.isEmpty
                ? nil
                : UnsafeRawPointer(Unmanaged.passUnretained(
                    rateMaps[min(viewIndex, rateMaps.count - 1)]).toOpaque())

            let ok = withUnsafeBytes(of: &mvp) { raw -> Bool in
                angle_render_view(color, depth, rateMap, Int32(slice),
                                  Int32(viewport.originX), Int32(viewport.originY),
                                  Int32(viewport.width), Int32(viewport.height),
                                  raw.bindMemory(to: Float.self).baseAddress)
            }

            if !ok {
                complain("angle_render_view schlug fehl (Auge \(viewIndex))")
            }
        }
    }

    private func encodePass(drawable: LayerRenderer.Drawable,
                            textureIndex: Int,
                            views: [Int],
                            anchor: DeviceAnchor?,
                            commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.colorTextures[textureIndex]
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // Deutlich von Schwarz unterscheidbar: in voller Immersion ist ein
        // dunkler Clear nicht von "Renderer läuft gar nicht" zu trennen.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.25,
                                                            blue: 0.35, alpha: 1.0)
        pass.depthAttachment.texture = drawable.depthTextures[textureIndex]
        pass.depthAttachment.loadAction = .clear
        // MUSS .store sein, nicht .dontCare: visionOS nutzt den Tiefenpuffer
        // für die Reprojektion, also das Nachführen des fertigen Bildes an die
        // aktuelle Kopfpose. Ohne gespeicherte Tiefe verwirft der Compositor den
        // Frame — lautlos, ohne Fehler, und die Farbtextur ist trotzdem korrekt
        // gefüllt. Für unser eigenes Rendering wäre .dontCare richtig; für den
        // Compositor ist die Tiefe Eingabe, nicht Abfall.
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0.0   // reversed-Z
        // Nur bei Array-Texturen setzen; bei einer gewöhnlichen 2D-Textur muss
        // die Länge 0 bleiben, sonst ist der Descriptor ungültig.
        pass.renderTargetArrayLength = views.count > 1 ? views.count : 0

        // Bei aktiver Foveation sind die Drawable-Texturen für variable
        // Rasterisierung angelegt. Fehlt die zugehörige Rate Map am Pass, ist
        // der Descriptor ungültig und makeRenderCommandEncoder liefert nil —
        // encodePresent läuft danach trotzdem, und der Compositor bekommt eine
        // nie beschriebene, also schwarze Drawable.
        if let rateMap = drawable.rasterizationRateMaps.first {
            pass.rasterizationRateMap = rateMap
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            complain("makeRenderCommandEncoder lieferte nil — Render-Pass-Descriptor "
                   + "ungültig (Foveation/Rate-Map, Formate oder Array-Länge)")
            return
        }

        guard drawGeometry else {
            encoder.endEncoding()
            return
        }

        // Zustand für beide Zeichenaufrufe zuerst setzen — sonst landet der
        // Hintergrund nur im linken Auge.
        //
        // Mehrere Augen in einem Pass: Vertex Amplification. Bei einem Auge
        // pro Pass entfällt sie — die Offsets wären dann ohnehin alle 0.
        if views.count > 1 {
            var mappings = views.indices.map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            encoder.setVertexAmplificationCount(views.count, viewMappings: &mappings)
        }

        encoder.setViewports(views.map { drawable.views[$0].textureMap.viewport })

        // Hintergrund zuerst zeichnen: füllt das Blickfeld auf der fernen Ebene
        // und schreibt dort Tiefe. Ohne ihn zeigt der Compositor an diesen
        // Stellen nichts, obwohl die Farbtextur den Clear enthält.
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setDepthStencilState(backgroundDepthState)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.setRenderPipelineState(trianglePipeline)
        encoder.setDepthStencilState(depthState)

        let model = modelMatrix ?? matrix_identity_float4x4
        var uniforms = views.map { viewIndex in
            Uniforms(modelViewProjection: mvp(viewIndex: viewIndex,
                                              view: drawable.views[viewIndex],
                                              drawable: drawable, anchor: anchor,
                                              model: model))
        }
        encoder.setVertexBytes(&uniforms,
                               length: MemoryLayout<Uniforms>.stride * uniforms.count,
                               index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Projektion × Ansicht für ein Auge, abgeleitet aus der Drawable und der
    /// aktuellen Kopfpose.
    private func mvp(viewIndex: Int,
                     view: LayerRenderer.Drawable.View,
                     drawable: LayerRenderer.Drawable,
                     anchor: DeviceAnchor?,
                     model: simd_float4x4) -> simd_float4x4 {
        let head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let eye = head * view.transform          // Auge → Welt
        return drawable.computeProjection(viewIndex: viewIndex) * eye.inverse * model
    }
}

struct Uniforms {
    var modelViewProjection: simd_float4x4
}

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) +
        TimeInterval(components.attoseconds) * 1e-18
    }
}
