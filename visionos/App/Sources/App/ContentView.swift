import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Fenster vor dem Start.
///
/// Zwei Aufgaben: die Spieldateien ins Dokumentenverzeichnis bekommen und den
/// Immersive Space öffnen. Ohne `base/assets0.pk3` startet die Engine nicht,
/// und die Fehlermeldung käme sonst erst im Headset — wo sie niemand liest.
struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    @State private var assets = AssetStore.status()
    @State private var importing = false
    @State private var progress: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Jedi Knight XR")
                .font(.largeTitle)

            switch assets {
            case .ready(let names):
                Label("\(names.count) pk3-Dateien in base/", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(names.sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Spielen") {
                    Task { _ = await openImmersiveSpace(id: "game") }
                }
                .buttonStyle(.borderedProminent)

            case .missing:
                Label("Spieldateien fehlen", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Benötigt werden assets0.pk3 bis assets3.pk3 aus einer "
                   + "Jedi-Academy-Installation, dazu z_vr_assets_base.pk3 und "
                   + "z_vr_assets_jka.pk3.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            if let progress {
                Label(progress, systemImage: "arrow.down.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button("Dateien auswählen…") { importing = true }
                Button("In Dateien öffnen") { AssetStore.revealInFiles() }
                Button("Erneut prüfen") { assets = AssetStore.status() }
            }
            .font(.callout)

            Text(AssetStore.baseDirectory.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(40)
        .task {
            // Muss vor allem anderen passieren: ein leeres Dokumentenverzeichnis
            // erscheint in der Dateien-App überhaupt nicht, egal was in der
            // Info.plist steht. Erst wenn etwas darin liegt, wird der Ordner
            // sichtbar und man kann hineinkopieren.
            AssetStore.prepare()
            assets = AssetStore.status()
        }
        // Der verlässliche Weg. Das Navigieren in der Dateien-App hängt davon
        // ab, dass der Ordner dort auftaucht; dieser Dialog nicht.
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await copy(urls) }
            case .failure(let error):
                progress = "Auswahl fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    /// Kopiert im Hintergrund: die Dateien sind zusammen rund 1,2 GB, das würde
    /// die Oberfläche sonst für Minuten einfrieren.
    private func copy(_ urls: [URL]) async {
        for (index, url) in urls.enumerated() {
            progress = "Kopiere \(url.lastPathComponent) (\(index + 1)/\(urls.count))…"
            let result = await Task.detached { AssetStore.copyIntoBase(url) }.value
            if case .failure(let message) = result {
                progress = message
                return
            }
        }
        progress = nil
        assets = AssetStore.status()
    }
}

enum AssetStatus {
    case ready(names: [String])
    case missing
}

enum CopyResult {
    case success
    case failure(String)
}

/// Alles rund um `Documents/base` — demselben Ort, den `Sys_DefaultInstallPath`
/// in `visionos_main.mm` liefert.
enum AssetStore {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var baseDirectory: URL {
        documentsDirectory.appendingPathComponent("base")
    }

    /// Legt `base/` an und hinterlegt eine Handreichung.
    ///
    /// Die Textdatei ist nicht nur Freundlichkeit: sie sorgt dafür, dass das
    /// Dokumentenverzeichnis nicht leer ist. Ein leerer Ordner wird von der
    /// Dateien-App ausgeblendet, und dann führt auch der angezeigte Pfad
    /// nirgendwohin.
    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let readme = documentsDirectory.appendingPathComponent("ANLEITUNG.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            Jedi Knight XR — Spieldateien

            In den Ordner "base" gehören:

              assets0.pk3   aus einer Jedi-Academy-Installation
              assets1.pk3
              assets2.pk3
              assets3.pk3
              z_vr_assets_base.pk3   aus JKXR
              z_vr_assets_jka.pk3

            Zusammen rund 1,2 GB. Sie lassen sich hier hineinkopieren oder im
            Fenster der App ueber "Dateien auswaehlen" einlesen.
            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    static func status() -> AssetStatus {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)) ?? []
        let pk3 = files.filter { $0.lowercased().hasSuffix(".pk3") }
        return pk3.isEmpty ? .missing : .ready(names: pk3)
    }

    static func copyIntoBase(_ source: URL) -> CopyResult {
        // Ausgewählte Dateien liegen außerhalb der Sandbox; ohne diesen Zugriff
        // schlägt das Lesen mit einem Rechtefehler fehl.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = baseDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return .success
        } catch {
            return .failure("\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Öffnet die Dateien-App direkt im Ordner der App.
    ///
    /// `shareddocuments://` ist Apples eigenes Schema für genau das. Es steht
    /// in keiner Dokumentation, wird aber seit iOS 11 unverändert unterstützt.
    /// Schlägt es fehl, bleibt der angezeigte Pfad zum Abtippen.
    static func revealInFiles() {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = baseDirectory.path
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}
