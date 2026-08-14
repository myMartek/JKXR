import CompositorServices
import Foundation
import Metal

/// Fährt die Engine hoch und hält sie am Leben.
///
/// Die Reihenfolge hier ist nicht beliebig — sie ist der Grund, warum diese
/// Klasse überhaupt existiert:
///
///  1. ANGLE hochfahren und seinen Kontext auf dem Render-Thread aktivieren
///  2. LayerRenderer an die XR-Schicht übergeben
///  3. **Einen Frame holen und die Auflösung daraus ablesen**
///  4. Auflösung hinterlegen
///  5. erst jetzt die Engine starten
///
/// Schritt 3 ist der unerwartete. CompositorServices gibt die Renderauflösung
/// nirgends heraus: die C-API hat keinen einzigen Zugriff auf Breite oder Höhe,
/// in keinem Header. Sie existiert erst, wenn eine Drawable da ist. Die Engine
/// fragt sie aber beim Start — WIN_Init setzt daraus glConfig.vidWidth und
/// vidHeight.
final class EngineHost {
    private let layerRenderer: LayerRenderer
    private var thread: Thread?

    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
    }

    func start() {
        TBXR_visionOS_StartWorldTracking()

        // Herzschlag auf einem eigenen Thread.
        //
        // Wird der Prozess mit SIGKILL beendet, sagt die verstrichene Zeit,
        // WER ihn beendet hat: der Compositor beendet Anwendungen, die keine
        // Bilder mehr abliefern, nach wenigen Sekunden und immer nach derselben
        // Spanne. Speicherdruck schlägt dagegen unregelmäßig zu.
        //
        // Eigener Thread, keine Task: der Engine-Thread blockiert während des
        // Ladens, und eine Warteschlange von Swift Concurrency könnte davon
        // ausgehungert werden — genau der Fehler aus S4.
        let beat = Thread {
            var seconds = 0
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                seconds += 1
                NSLog("[Herzschlag] %d s", seconds)
            }
        }
        beat.name = "de.martek.jkxr.heartbeat"
        beat.qualityOfService = .utility
        beat.start()

        // Eigener Thread, kein Task.
        //
        // JKXR_visionOS_Main ist eine blockierende Endlosschleife. Auf einer
        // Warteschlange von Swift Concurrency würde sie den kooperativen Pool
        // aushungern — in S4 war genau das die Ursache dafür, dass ARKit keine
        // Posen mehr lieferte und das Bild stehen blieb.
        //
        // .userInteractive, weil der Thread die Bildrate bestimmt.
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "de.martek.jkxr.engine"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 * 1024 * 1024   // id Tech 3 rechnet tief auf dem Stack
        self.thread = thread
        thread.start()
    }

    func requestShutdown() {
        JKXR_visionOS_RequestShutdown()
    }

    // MARK: - Auf dem Engine-Thread

    private func run() {
        // ANGLE muss auf *diesem* Thread aktiv sein: EGL-Kontexte sind
        // threadgebunden, und TBXR_visionOS_SetLayerRenderer holt sich den
        // Display über eglGetCurrentDisplay().
        guard angle_init(), angle_make_current() else {
            print("[JKXR] ANGLE ließ sich nicht initialisieren — Abbruch")
            return
        }

        var description = [CChar](repeating: 0, count: 1024)
        angle_describe(&description, description.count)
        print("[JKXR] \(String(cString: description))")

        // Beide müssen dasselbe MTLDevice benutzen, sonst lehnt
        // EGL_ANGLE_metal_texture_client_buffer den Import der Drawable-Texturen
        // ab. ANGLE lässt sich kein Device vorgeben — eglCreateDeviceANGLE gibt
        // es nur für D3D11 —, also bleibt nur der Vergleich.
        let angleDevice = angle_metal_device()
        let layerDevice = Unmanaged.passUnretained(layerRenderer.device).toOpaque()
        if angleDevice != UnsafeRawPointer(layerDevice) {
            print("[JKXR] WARNUNG: ANGLE und CompositorServices nutzen "
                + "verschiedene MTLDevices — der Texturimport wird scheitern")
        }

        print("[JKXR] übergebe LayerRenderer an die XR-Schicht")
        TBXR_visionOS_SetLayerRenderer(layerRenderer)

        print("[JKXR] messe Auflösung an einem Probe-Frame")
        guard let size = probeResolution() else {
            print("[JKXR] Auflösung nicht ermittelbar — Abbruch")
            return
        }
        print("[JKXR] Renderauflösung je Auge: \(size.width)x\(size.height)")
        TBXR_visionOS_SetScreenRes(Int32(size.width), Int32(size.height))

        // Zubehör-Provider ans Action-System: er liefert die Posen der
        // Controller und ist zugleich die Voraussetzung dafür, dass visionOS
        // sie überhaupt als Spatial Controller ausweist statt als kombiniertes
        // MFi-Gamepad.
        // Die Zubehörverfolgung startet sich selbst, sobald ARKit die Freigabe
        // erteilt hat (WorldTracking.m). Vorher aufzuzählen liefert eine leere
        // Liste, gemessen.

        print("[JKXR] frage Controller ab")
        TBXR_visionOS_DumpInputs()

        print("[JKXR] starte Engine")

        var arg0 = strdup("jkxr")
        defer { free(arg0) }
        withUnsafeMutablePointer(to: &arg0) { argv in
            _ = JKXR_visionOS_Main(1, argv)
        }
        print("[JKXR] Engine beendet")
    }

    /// Holt einen Frame, nur um die Auflösung abzulesen.
    ///
    /// Der Frame wird vollständig durchlaufen (startUpdate/startSubmission/
    /// endSubmission), aber ohne zu zeichnen — ein angefangener, nie
    /// abgeschlossener Frame würde den Compositor blockieren.
    ///
    /// Zurückgegeben wird die Größe in **Screen-Koordinaten**: bei aktiver
    /// Foveation ist die physische Textur kleiner, und die Rate-Map bildet
    /// dazwischen ab. Die Engine muss auf die größere Fläche rendern, sonst
    /// verschenkt man genau die Auflösung, für die die Foveation da ist.
    private func probeResolution() -> (width: Int, height: Int)? {
        // Der Compositor liefert erst Frames, wenn die Ebene läuft.
        while layerRenderer.state == .paused {
            layerRenderer.waitUntilRunning()
        }

        guard let frame = layerRenderer.queryNextFrame() else {
            print("[JKXR] queryNextFrame lieferte nil")
            return nil
        }

        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else {
            print("[JKXR] predictTiming lieferte nil")
            return nil
        }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        defer { frame.endSubmission() }

        // queryDrawables, nicht queryDrawable: letzteres ist seit visionOS 26.0
        // abgekündigt. Bei unserem Layout ist die Liste einelementig, leer heißt
        // wie zuvor „diesen Frame auslassen".
        guard let drawable = frame.queryDrawables().first else {
            print("[JKXR] queryDrawables lieferte nichts")
            return nil
        }

        // Zurückgegeben wird die Größe in **Screen-Koordinaten**: bei aktiver
        // Foveation ist die physische Textur kleiner, und die Rate-Map bildet
        // dazwischen ab. Die Engine muss auf die größere Fläche rendern, sonst
        // verschenkt man genau die Auflösung, für die die Foveation da ist.
        let size: (width: Int, height: Int)
        if let rateMap = drawable.rasterizationRateMaps.first {
            let screen = rateMap.screenSize
            let physical = drawable.colorTextures[0]
            print("[JKXR] Foveation aktiv — Textur \(physical.width)x\(physical.height), "
                + "Screen \(screen.width)x\(screen.height)")
            size = (screen.width, screen.height)
        } else {
            let texture = drawable.colorTextures[0]
            print("[JKXR] keine Rate-Map — ohne Foveation")
            size = (texture.width, texture.height)
        }

        // Eine geholte Drawable MUSS präsentiert werden. Sie einfach fallen zu
        // lassen und endSubmission aufzurufen beendet den Prozess mit SIGABRT —
        // CompositorServices behandelt das als Fehler, nicht als Auslassung.
        //
        // Der Frame bleibt trotzdem leer: es wird nichts gezeichnet, nur
        // ordentlich abgeschlossen. Das kostet ein schwarzes Bild beim Start.
        if let queue = layerRenderer.device.makeCommandQueue(),
           let commandBuffer = queue.makeCommandBuffer() {
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        } else {
            print("[JKXR] WARNUNG: Probe-Frame ließ sich nicht präsentieren")
        }

        return size
    }
}
