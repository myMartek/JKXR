import SwiftUI

struct ContentView: View {
    @Binding var immersiveSpaceOpen: Bool
    @State private var status: String?
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("S4 — Renderer-Spike")
                    .font(.largeTitle.weight(.semibold))
                Text("Stufe 1: Metal-Referenzdreieck im Immersive Space")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("Steht das Dreieck stabil im Raum und wandert beim Kopfdrehen "
               + "nicht mit, ist die CompositorServices-Anbindung korrekt. Erst "
               + "danach wird das Bild durch eine von ANGLE gerenderte GLES-Textur "
               + "ersetzt.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status {
                Text(status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    if immersiveSpaceOpen {
                        await dismissSpace()
                        immersiveSpaceOpen = false
                        status = nil
                        return
                    }
                    // Das Ergebnis auswerten statt verwerfen: ein fehlender
                    // Info.plist-Eintrag lässt openImmersiveSpace scheitern,
                    // ohne dass im Headset irgendetwas passiert.
                    switch await openSpace(id: "spike") {
                    case .opened:
                        immersiveSpaceOpen = true
                        status = nil
                    case .error:
                        status = "openImmersiveSpace meldete einen Fehler."
                    case .userCancelled:
                        status = "Vom System oder Nutzer abgebrochen."
                    @unknown default:
                        status = "Unbekanntes Ergebnis von openImmersiveSpace."
                    }
                    if let status { print("[S4] \(status)") }
                }
            } label: {
                Label(immersiveSpaceOpen ? "Beenden" : "Starten",
                      systemImage: immersiveSpaceOpen ? "xmark" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.extraLarge)
        }
        .padding(28)
        .task {
            // Automatisch öffnen, damit der Spike ohne Tastendruck prüfbar ist —
            // insbesondere im Simulator, wo sich Screenshots skripten lassen.
            guard !immersiveSpaceOpen else { return }
            switch await openSpace(id: "spike") {
            case .opened:
                immersiveSpaceOpen = true
            case .error:
                status = "openImmersiveSpace meldete einen Fehler."
            case .userCancelled:
                status = "Vom System oder Nutzer abgebrochen."
            @unknown default:
                status = "Unbekanntes Ergebnis von openImmersiveSpace."
            }
            if let status { print("[S4] \(status)") }
        }
    }
}
