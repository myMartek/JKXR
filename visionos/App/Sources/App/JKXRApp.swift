import CompositorServices
import SwiftUI

/// Konfiguration der Compositor-Schicht.
///
/// Wörtlich aus dem S4-Spike übernommen — die Begründungen dort sind teuer
/// erkauft und gelten hier unverändert.
struct JKXRLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float

        // rgba16Float, nicht bgra8Unorm_srgb: der Compositor rechnet in linearem
        // Extended-Range-Licht. Mit einem sRGB-Format schreibt die GPU kodierte
        // Werte, die dann als linear gelesen werden — das Bild kippt ins Weiße.
        configuration.colorFormat = .rgba16Float

        // Foveation.
        //
        // Ohne sie deckelt CompositorServices die Drawable-Auflösung: die Textur
        // bleibt bei 2048x1984 statt der 5087x4081 Screen-Koordinaten, auf die
        // mit Rate-Map gerendert wird. Die Vision Pro kommt dann nicht über das
        // hinaus, was günstigere Headsets liefern.
        //
        // Zwei Pfade nutzen sie unterschiedlich:
        //   - das native Metal-Quad für 2D setzt pass.rasterizationRateMap
        //     direkt aus der Drawable (drawMetalScreenPanel in TBXR_Common.mm)
        //   - die 3D-Szene rendert über ANGLE und braucht dafür unseren Patch im
        //     Metal-Backend (spikes/s4-angle/patch-angle-foveation.py), der die
        //     Map über ANGLESetDrawFramebufferRateMapMTL entgegennimmt
        //
        // WAS HIER FRÜHER STAND und nicht haltbar war: der ANGLE-Patch greife
        // "für den GL-Pfad nachweislich nicht". Belegt ist das Gegenteil --
        // spikes/s4-angle/README.md hält fest, dass alle vier Klemmglieder auf
        // dem Gerät gemessen wurden und die Kette danach mit 5087x4081 über den
        // vollen ANGLE-Pfad lief. Das Symbol ist im mitgelieferten Framework
        // vorhanden (nm -gU zeigt _ANGLESetDrawFramebufferRateMapMTL).
        //
        // Offen war nicht der Patch, sondern seine BENUTZUNG: JKXR setzte den
        // Viewport vor der Rate-Map, die Referenz macht es umgekehrt. Behoben in
        // TBXR_prepareEyeBuffer, Begründung dort.
        //
        // Der alte Text hat den nächsten Leser in die falsche Richtung geschickt
        // -- deshalb steht das hier und nicht nur im Commit.
        let useFoveation = false
        configuration.isFoveationEnabled = useFoveation && capabilities.supportsFoveation
        if useFoveation && !capabilities.supportsFoveation {
            print("[JKXR] WARNUNG: Foveation gewünscht, aber das Gerät meldet "
                + "supportsFoveation = false. Die Drawable-Auflösung bleibt "
                + "gedeckelt.")
        }
        print("[JKXR] Foveation: gewünscht \(useFoveation), "
            + "unterstützt \(capabilities.supportsFoveation), "
            + "aktiv \(configuration.isFoveationEnabled)")

        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            configuration.isFoveationEnabled ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)

        // dedicated, nicht layered.
        //
        // Bei layered liefert CompositorServices EINE Rate-Map mit einem Layer
        // pro Auge, und Metal wählt den Layer über den Render-Target-Array-Index.
        // Unser GLES-Pfad importiert jedes Auge einzeln als 2D-Textur, der Index
        // ist damit immer 0 — beide Augen bekämen die Foveation des linken. Da
        // Foveation dem Blick folgt, wandert der Fehler im rechten Auge mit der
        // Blickrichtung, was in S4 genau so gemessen wurde.
        //
        // Der zweite Renderpass kostet hier nichts: JKXR rendert ohnehin pro Auge.
        //
        // Der Rückfall auf shared ist KEIN gleichwertiger Ersatz, sondern ein
        // schwarzes Bild: shared liefert nur EINE Textur, und
        // cp_drawable_get_color_texture(.., 1) für das rechte Auge greift dann
        // ins Leere (siehe die Bestandsaufnahme in TBXR_FrameSetup). Deshalb die
        // Warnung mit der Folge, nicht bloß mit dem Namen.
        if layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = .shared
            print("[JKXR] WARNUNG: Layout dedicated nicht verfügbar, shared "
                + "gewählt. Damit gibt es nur EINE Augentextur — das rechte Auge "
                + "bleibt schwarz. Verfügbar: \(layouts)")
        }
        print("[JKXR] Layout: \(configuration.layout)")
    }
}

@main
struct JKXRApp: App {
    @State private var engineHost: EngineHost?

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 640, height: 480)

        ImmersiveSpace(id: "game") {
            CompositorLayer(configuration: JKXRLayerConfiguration()) { layerRenderer in
                let host = EngineHost(layerRenderer)
                engineHost = host
                host.start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)

        // Systemüberlagerungen ausblenden.
        //
        // Ohne das bleiben Home-Anzeige und Griffleiste sichtbar, und die
        // zugehörigen Gesten liegen mitten im Spielbereich — beim Fechten mit
        // dem Lichtschwert trifft man sie ständig versehentlich.
        //
        // War kurzzeitig draußen, weil die App nicht mehr startete. Das lag
        // aber am Zustand der Brille (behoben durch deren Neustart), nicht
        // hier.
        //
        // Was visionOS NICHT freigibt: den Druck auf die Digital Crown und den
        // Blick nach oben fürs Kontrollzentrum. Beides behält das System sich
        // vor, damit man aus jeder App wieder herausfindet.
        .persistentSystemOverlays(.hidden)
    }
}
