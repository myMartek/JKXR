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

        // Foveation an.
        //
        // Ohne sie deckelt CompositorServices die Drawable-Auflösung: die
        // Textur bleibt bei 2048x1984 statt der 5087x4081 Screen-Koordinaten,
        // auf die mit Rate-Map gerendert wird. Die Vision Pro käme dann nicht
        // über das hinaus, was günstigere Headsets liefern.
        //
        // Zwei Pfade nutzen sie unterschiedlich:
        //   - das native Metal-Quad für 2D setzt pass.rasterizationRateMap
        //     direkt aus der Drawable
        //   - die 3D-Szene rendert über ANGLE und braucht dafür unseren Patch
        //     im Metal-Backend (patch-angle-foveation.py), der die Rate-Map
        //     über ANGLESetDrawFramebufferRateMapMTL entgegennimmt
        configuration.isFoveationEnabled = capabilities.supportsFoveation
        if !configuration.isFoveationEnabled {
            print("[JKXR] WARNUNG: Foveation nicht verfügbar. Ohne sie deckelt "
                + "CompositorServices die Drawable-Auflösung, und die Vision Pro "
                + "kommt nicht über das hinaus, was günstigere Headsets liefern.")
        }

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
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .shared
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
    }
}
