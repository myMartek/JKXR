import SwiftUI

@main
struct JitSpikeApp: App {
    init() {
        // Bewusst hier und nicht in .task/.onAppear: auf visionOS ist nicht
        // garantiert, dass eine Szene sichtbar wird (Headset abgesetzt, App im
        // Hintergrund). Die Proben laufen in Mikrosekunden, das Blockieren des
        // Starts ist unkritisch — und so liefert jeder Start verlässlich den
        // nächsten Fortschritt.
        MainActor.assumeIsolated {
            ProbeRunner.shared.runPendingProbes()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 780)
    }
}
