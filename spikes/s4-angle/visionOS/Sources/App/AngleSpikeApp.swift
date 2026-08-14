import SwiftUI
import CompositorServices

/// Konfiguration der Compositor-Schicht.
///
/// `.layered` ist der bevorzugte Weg: beide Augen liegen als Slices in einem
/// Texture-Array und werden in einem Renderpass über Vertex Amplification
/// befüllt. `.dedicated` ist der Rückfall, falls das Gerät das nicht anbietet.
struct SpikeLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        // rgba16Float, nicht bgra8Unorm_srgb: der Compositor rechnet in linearem
        // Extended-Range-Licht. Mit einem sRGB-Format schreibt die GPU kodierte
        // Werte, die dann als linear gelesen werden — das Bild kippt ins Weiße.
        configuration.colorFormat = .rgba16Float

        // Foveation an. Ohne sie müsste über das gesamte Blickfeld in voller
        // Dichte gerastert werden, und CompositorServices deckelt die Drawable
        // entsprechend — die Vision Pro käme nicht über das hinaus, was
        // günstigere Headsets liefern.
        //
        // ANGLEs Metal-Backend kennt Rasterization Rate Maps im Original nicht;
        // die Unterstützung ist eine Fork-Ergänzung, siehe
        // patch-angle-foveation.py. Die Map wird pro Auge aus der Drawable
        // geholt und über angle_render_view durchgereicht.
        let useFoveation = true
        // dedicated statt layered: Bei layered liefert CompositorServices EINE
        // Rate Map mit einem Layer pro Auge, und Metal wählt den Layer über den
        // Render-Target-Array-Index. Unser GLES-Pfad importiert jedes Auge
        // einzeln als 2D-Textur, der Array-Index ist damit immer 0 — beide
        // Augen bekämen die Foveation des linken. Da Foveation den Augen folgt,
        // wandert der Fehler im rechten Auge mit der Blickrichtung.
        //
        // Mit dedicated hat jedes Auge eine eigene Textur und eine eigene,
        // einlagige Map. Kostet einen zweiten Renderpass — für JKXR belanglos,
        // das rendert ohnehin pro Auge.
        let preferLayered = false

        configuration.isFoveationEnabled = useFoveation && capabilities.supportsFoveation

        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            configuration.isFoveationEnabled ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)
        configuration.layout = (preferLayered && layouts.contains(.layered))
            ? .layered
            : (layouts.contains(.dedicated) ? .dedicated : .shared)

        let layoutName: String
        switch configuration.layout {
        case .layered:   layoutName = "layered"
        case .dedicated: layoutName = "dedicated"
        case .shared:    layoutName = "shared"
        @unknown default: layoutName = "unbekannt"
        }
        print("[S4] Konfiguration — Foveation möglich: \(capabilities.supportsFoveation), "
            + "genutzt: \(configuration.isFoveationEnabled), Layout: \(layoutName), "
            + "unterstützt: layered=\(layouts.contains(.layered)) "
            + "dedicated=\(layouts.contains(.dedicated)) shared=\(layouts.contains(.shared))")
    }
}

@main
struct AngleSpikeApp: App {
    @State private var immersiveSpaceOpen = false

    var body: some Scene {
        WindowGroup {
            ContentView(immersiveSpaceOpen: $immersiveSpaceOpen)
        }
        .defaultSize(width: 620, height: 420)

        ImmersiveSpace(id: "spike") {
            CompositorLayer(configuration: SpikeLayerConfiguration()) { layerRenderer in
                guard let renderer = ImmersiveRenderer(layerRenderer) else {
                    print("[S4] Renderer konnte nicht initialisiert werden")
                    return
                }
                renderer.start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
