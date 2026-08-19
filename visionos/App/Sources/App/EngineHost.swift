import CompositorServices
import Foundation
import Metal
import os

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
        // Der Herzschlag meldet zusätzlich den VERBLEIBENDEN Speicher.
        //
        // Beide Todesarten sehen von außen gleich aus — der Prozess endet mit
        // SIGKILL. Der Compositor tut das, wenn Bilder ausbleiben; das System
        // tut es bei Speicherdruck. Die verstrichene Zeit allein unterscheidet
        // sie nicht zuverlässig.
        //
        // os_proc_available_memory sagt, wie viel bis zur Grenze noch übrig
        // ist. Fällt der Wert vor dem Abbruch gegen null, war es der Speicher;
        // bleibt er hoch, war es der Wächter. Damit ist die Frage beim nächsten
        // Absturz beantwortet, statt wieder vermutet zu werden.
        let beat = Thread {
            var seconds = 0
            var tiefstand = Int.max
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                seconds += 1
                let frei = os_proc_available_memory()
                if frei > 0 { tiefstand = min(tiefstand, frei) }
                NSLog("[Herzschlag] %d s · frei %d MB · Tiefstand %d MB",
                      seconds, frei / (1024 * 1024),
                      tiefstand == Int.max ? -1 : tiefstand / (1024 * 1024))
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
        spiel?.pointee.RequestShutdown()
    }

    /// Die Tabelle des gewählten Spiels.
    ///
    /// Outcast und Academy bringen jede Engine-Funktion je einmal mit; welche
    /// gilt, entscheidet die Auswahl im Startfenster. Ist nichts gewählt, ist
    /// hier nil — dann darf die Engine auch nicht laufen.
    private var spiel: UnsafePointer<JKXR_visionOS_Spiel>? {
        JKXR_visionOS_Gewaehlt
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

        // Ohne Auswahl gibt es keine Engine, in die etwas übergeben werden
        // könnte. Das ist kein erwarteter Zustand, sondern ein Fehler in der
        // Reihenfolge — deshalb eine Meldung, die ihn benennt.
        guard let spiel else {
            print("[JKXR] FEHLER: kein Spiel gewählt, Engine startet nicht. "
                + "JKXR_visionOS_Waehle muss vor dem Immersive Space laufen.")
            return
        }
        print("[JKXR] Spiel: \(String(cString: spiel.pointee.name))")

        print("[JKXR] übergebe LayerRenderer an die XR-Schicht")
        spiel.pointee.SetLayerRenderer(layerRenderer)

        print("[JKXR] messe Auflösung an einem Probe-Frame")
        guard let size = probeResolution() else {
            print("[JKXR] Auflösung nicht ermittelbar — Abbruch")
            return
        }
        print("[JKXR] Renderauflösung je Auge: \(size.width)x\(size.height)")
        spiel.pointee.SetScreenRes(Int32(size.width), Int32(size.height))

        // Zubehör-Provider ans Action-System: er liefert die Posen der
        // Controller und ist zugleich die Voraussetzung dafür, dass visionOS
        // sie überhaupt als Spatial Controller ausweist statt als kombiniertes
        // MFi-Gamepad.
        // Die Zubehörverfolgung startet sich selbst, sobald ARKit die Freigabe
        // erteilt hat (WorldTracking.m). Vorher aufzuzählen liefert eine leere
        // Liste, gemessen.

        print("[JKXR] frage Controller ab")
        spiel.pointee.DumpInputs()

        print("[JKXR] starte Engine")

        // Die Befehlszeile der Engine.
        //
        // JKXR_visionOS_Main setzt aus argv[1...] eine Zeichenkette zusammen und
        // gibt sie an Com_Init -- der klassische Weg von id Tech 3. Ein "+set"
        // darin wirkt, BEVOR die erste Textur geladen wird, und genau darauf
        // kommt es bei r_picmip an: als gelatchte Variable würde ein späteres
        // Setzen erst beim nächsten vid_restart greifen.
        var teile = ["jkxr"]
        if UserDefaults.standard.bool(forKey: "jkxr.picmip") {
            // Halbe Kantenlänge heißt ein Viertel Texturspeicher. Bei einem
            // 4x-Upscale bleibt damit immer noch die doppelte Auflösung des
            // Originals übrig.
            teile += ["+set", "r_picmip", "1"]
        }
        // Zusätzliche Argumente aus der Umgebung, für die Fehlersuche.
        //
        // Damit lässt sich vom Mac aus eine bestimmte Karte laden oder eine
        // cvar setzen, ohne neu zu bauen:
        //
        //   devicectl ... --environment-variables '{"JKXR_ARGS":"+map kejim_post"}'
        //
        // Im gewöhnlichen Start ist die Variable nicht gesetzt und die Zeile
        // bleibt folgenlos -- dieselbe Bauart wie JKXR_AUTO_START.
        if let zusatz = ProcessInfo.processInfo.environment["JKXR_ARGS"],
           !zusatz.trimmingCharacters(in: .whitespaces).isEmpty {
            teile += zusatz.split(separator: " ").map(String.init)
        }
        print("[JKXR] Befehlszeile: \(teile.joined(separator: " "))")

        var zeiger: [UnsafeMutablePointer<CChar>?] = teile.map { strdup($0) }
        defer { zeiger.forEach { free($0) } }
        zeiger.withUnsafeMutableBufferPointer { puffer in
            _ = spiel.pointee.Main(Int32(teile.count), puffer.baseAddress)
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
        // Der Compositor liefert erst Frames, wenn die Ebene läuft — und der
        // Zustand kann sich zwischen Prüfung und Abfrage wieder ändern.
        //
        // Genau das passierte hier: das Startfenster wird unmittelbar nach dem
        // Öffnen des Immersive Space geschlossen, und dabei wechselt kurz der
        // Szenenzustand. queryNextFrame lieferte dann nil, die Auflösung blieb
        // unbekannt, und die Engine startete gar nicht erst — im Headset sah
        // man nach dem Fenster einfach nichts mehr.
        //
        // Deshalb mehrere Versuche statt eines einzigen. Der Abbruch bleibt
        // erhalten, greift aber erst, wenn die Ebene dauerhaft nichts liefert.
        // Warten, bis ein Bild kommt — ohne Frist.
        //
        // Ein Zeitlimit ist hier falsch: wie lange es dauert, hängt allein
        // davon ab, wann der Benutzer den Immersive Space betritt und die
        // Brille aufsetzt. Eine feste Schranke (erst gar keine, dann vier
        // Sekunden) hat genau das abgewürgt — die Hülle gab auf, bevor die
        // Ebene lief, meldete "Auflösung nicht ermittelbar" und startete die
        // Engine nie. Im Headset kam nach dem Fenster einfach nichts.
        //
        // Abgebrochen wird nur beim einzigen echten Endzustand: die Ebene ist
        // ungültig, weil der Immersive Space geschlossen wurde. Die Schleife
        // dreht dabei nicht heiß, denn waitUntilRunning blockiert.
        var frame: LayerRenderer.Frame?
        var attempts = 0
        while frame == nil {
            if layerRenderer.state == .invalidated {
                print("[JKXR] Ebene ungültig — Immersive Space wurde geschlossen")
                return nil
            }
            while layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
            }
            frame = layerRenderer.queryNextFrame()
            if frame == nil {
                attempts += 1
                if attempts % 250 == 0 {
                    print("[JKXR] warte weiter auf das erste Bild (\(attempts) Versuche)")
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        guard let frame else { return nil }

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
