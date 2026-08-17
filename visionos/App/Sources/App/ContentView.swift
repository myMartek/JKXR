import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Welches der beiden Spiele.
///
/// Die Rohwerte müssen zu `JKXR_visionOS_SpielArt` in JKXR_visionOS_Spiel.h
/// passen, und die Ordnernamen zu `JKXR_SPIELORDNER` in visionos_main.mm — dort
/// sucht die Engine ihr `base/`.
enum Spiel: Int32, CaseIterable, Identifiable {
    // Die Rohwerte folgen der C-Aufzählung; die ANZEIGE folgt der Reihenfolge
    // der Fälle, und die ist chronologisch — Outcast (2002) vor Academy (2003).
    case outcast = 1
    case academy = 0

    var id: Int32 { rawValue }

    var name: String {
        switch self {
        case .academy: return "Jedi Academy"
        case .outcast: return "Jedi Outcast"
        }
    }

    /// Unterordner im Dokumentenverzeichnis. Beide Spiele nennen ihr
    /// Datenverzeichnis "base"; ohne die Trennung überschrieben sich die
    /// pk3-Dateien gegenseitig.
    var ordner: String {
        switch self {
        case .academy: return "JediAcademy"
        case .outcast: return "JediOutcast"
        }
    }

    /// Was in `base/` liegen muss. Die z_vr_assets-Dateien stammen aus JKXR,
    /// die assets aus dem jeweiligen Spiel.
    var erwarteteDateien: String {
        switch self {
        case .academy:
            return "assets0.pk3 bis assets3.pk3 aus einer Jedi-Academy-Installation, "
                 + "dazu z_vr_assets_base.pk3 und z_vr_assets_jka.pk3."
        case .outcast:
            return "assets0.pk3, assets1.pk3, assets2.pk3 und assets5.pk3 aus einer "
                 + "Jedi-Outcast-Installation, dazu z_vr_assets_base.pk3 und "
                 + "z_vr_assets_jko.pk3."
        }
    }
}

/// Fenster vor dem Start.
///
/// Drei Aufgaben: das Spiel wählen, die Spieldateien ins Dokumentenverzeichnis
/// bekommen und den Immersive Space öffnen. Ohne `base/assets0.pk3` startet die
/// Engine nicht, und die Fehlermeldung käme sonst erst im Headset — wo sie
/// niemand liest.
struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    /// Das Startfenster schließen, sobald das Spiel läuft.
    ///
    /// Es hat seine Aufgabe dann erledigt — die Spieldateien liegen bereit und
    /// der Immersive Space ist offen. Bleibt es stehen, hängt es mitten im
    /// Bild und muss von Hand weggeschoben werden.
    @Environment(\.dismissWindow) private var dismissWindow

    /// Die letzte Wahl überlebt den Neustart.
    ///
    /// Seit die App sich beim Schliessen des Immersive Space beendet
    /// (visionos_main.mm), ist jeder Spielwechsel ein Neustart -- eine
    /// Vorauswahl, die dann immer wieder auf Academy zurückfällt, wäre bei jedem
    /// Start erneut zu korrigieren.
    ///
    /// Der Rohwert wird gespeichert, nicht der Fall: AppStorage kann nur
    /// einfache Typen, und der Rohwert ist ohnehin die Zahl, die auch die
    /// C-Seite kennt.
    @AppStorage("jkxr.letztesSpiel") private var letztesSpiel: Int = Int(Spiel.academy.rawValue)

    @State private var spiel: Spiel = .academy
    @State private var assets: AssetStatus = .missing
    @State private var importing = false
    @State private var progress: String?
    @State private var didAutoStart = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Jedi Knight XR")
                .font(.largeTitle)

            // Die Auswahl steht ganz oben und nicht neben dem Spielen-Knopf:
            // sie entscheidet, worauf sich alles darunter bezieht — Dateiliste,
            // Pfad und Anleitung.
            Picker("Spiel", selection: $spiel) {
                ForEach(Spiel.allCases) { s in
                    Text(s.name).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            switch assets {
            case .ready(let names):
                Label("\(names.count) pk3-Dateien in \(spiel.ordner)/base/",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(names.sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("\(spiel.name) spielen") {
                    Task { await startGame() }
                }
                .buttonStyle(.borderedProminent)

            case .missing:
                Label("Spieldateien für \(spiel.name) fehlen",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Benötigt werden \(spiel.erwarteteDateien)")
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
                Button("In Dateien öffnen") { AssetStore.revealInFiles(spiel) }
                Button("Erneut prüfen") { assets = AssetStore.status(spiel) }
            }
            .font(.callout)

            Text(AssetStore.baseDirectory(spiel).path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(40)
        .onChange(of: spiel) { _, neu in
            progress = nil
            letztesSpiel = Int(neu.rawValue)
            assets = AssetStore.status(neu)
        }
        .task {
            // Die gemerkte Wahl VOR der Statusabfrage übernehmen, sonst zeigt
            // das Fenster einen Augenblick die Dateien des anderen Spiels.
            if let gemerkt = Spiel(rawValue: Int32(letztesSpiel)) {
                spiel = gemerkt
            }

            // Muss vor allem anderen passieren: ein leeres Dokumentenverzeichnis
            // erscheint in der Dateien-App überhaupt nicht, egal was in der
            // Info.plist steht. Erst wenn etwas darin liegt, wird der Ordner
            // sichtbar und man kann hineinkopieren.
            AssetStore.prepare()
            assets = AssetStore.status(spiel)

            // Hardware-Diagnose ohne UI-Automation. devicectl kann die App mit
            // JKXR_AUTO_START=1 starten; im normalen App-Start ist die Variable
            // nicht gesetzt und das Fenster verhält sich unverändert.
            if !didAutoStart,
               ProcessInfo.processInfo.environment["JKXR_AUTO_START"] == "1",
               case .ready = assets {
                didAutoStart = true
                print("[JKXR] Diagnose-Autostart des Immersive Space")
                await startGame()
            }
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

    /// Immersive Space öffnen und danach das Startfenster schließen.
    ///
    /// Geschlossen wird NUR bei Erfolg. Scheitert das Öffnen, bleibt das
    /// Fenster stehen — sonst stünde der Benutzer in einer leeren Umgebung
    /// ohne Bedienelemente und ohne Hinweis, was schiefging.
    ///
    /// Dass das Schließen den Ton nicht mehr abwürgt, hängt an der
    /// Audio-Kategorie: visionos_snd.mm benutzt seit dieser Änderung Playback
    /// statt Ambient. Ambient ist an den Vordergrundzustand gebunden und
    /// verstummt, sobald nur noch der Immersive Space offen ist.
    private func startGame() async {
        // ZUERST die Wahl setzen, dann den Space öffnen.
        //
        // Der CompositorLayer wird beim Öffnen aufgebaut und startet den
        // EngineHost; der liest die Tabelle sofort. Andersherum stünde dort nil
        // und die Engine liefe gar nicht an.
        JKXR_visionOS_Waehle(JKXR_visionOS_SpielArt(rawValue: UInt32(spiel.rawValue)))

        switch await openImmersiveSpace(id: "game") {
        case .opened:
            // Fenster schließen, sobald das Spiel läuft.
            //
            // War zwischenzeitlich draußen, weil die App nicht mehr startete
            // und dieser Aufruf verdächtig aussah: das Schließen unmittelbar
            // nach openImmersiveSpace könnte kurz den Vordergrundzustand
            // kosten, und der Compositor hält die Ebene dann pausiert.
            //
            // Das war eine Fehlvermutung. Die App startete auch ohne den
            // Aufruf nicht — behoben hat es erst ein Neustart der Brille. Es
            // lag also am Gerätezustand, nicht hier.
            //
            // Sollte der Start irgendwann wieder hängenbleiben, ist das hier
            // trotzdem der erste Kandidat zum Ausprobieren — dann aber messen
            // statt vermuten.
            dismissWindow()
        case .userCancelled:
            progress = "Der Immersive Space wurde abgebrochen."
        case .error:
            progress = "Der Immersive Space ließ sich nicht öffnen."
        @unknown default:
            break
        }
    }

    /// Kopiert im Hintergrund: die Dateien sind zusammen rund 1,2 GB, das würde
    /// die Oberfläche sonst für Minuten einfrieren.
    private func copy(_ urls: [URL]) async {
        let ziel = spiel
        for (index, url) in urls.enumerated() {
            progress = "Kopiere \(url.lastPathComponent) (\(index + 1)/\(urls.count)) "
                     + "nach \(ziel.ordner)…"
            let result = await Task.detached { AssetStore.copyIntoBase(url, ziel) }.value
            if case .failure(let message) = result {
                progress = message
                return
            }
        }
        progress = nil
        assets = AssetStore.status(spiel)
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

/// Alles rund um `Documents/<Spiel>/base` — demselben Ort, den
/// `Sys_DefaultInstallPath` in `visionos_main.mm` liefert.
enum AssetStore {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func baseDirectory(_ spiel: Spiel) -> URL {
        documentsDirectory
            .appendingPathComponent(spiel.ordner)
            .appendingPathComponent("base")
    }

    /// Legt für BEIDE Spiele `base/` an und hinterlegt je eine Handreichung.
    ///
    /// Beide, nicht nur das gewählte: die Ordner sollen in der Dateien-App
    /// sichtbar sein, bevor man etwas hineinkopieren kann, und wer Outcast
    /// einrichten will, sucht den Ordner dort — nicht erst nach einem
    /// Spielwechsel im Fenster.
    ///
    /// Die Textdatei ist nicht nur Freundlichkeit: sie sorgt dafür, dass der
    /// Ordner nicht leer ist. Ein leerer Ordner wird von der Dateien-App
    /// ausgeblendet, und dann führt auch der angezeigte Pfad nirgendwohin.
    static func prepare() {
        migriereAltesBase()

        let fm = FileManager.default
        for spiel in Spiel.allCases {
            try? fm.createDirectory(at: baseDirectory(spiel),
                                    withIntermediateDirectories: true)

            let readme = documentsDirectory
                .appendingPathComponent(spiel.ordner)
                .appendingPathComponent("ANLEITUNG.txt")
            if !fm.fileExists(atPath: readme.path) {
                let text = """
                Jedi Knight XR — Spieldateien fuer \(spiel.name)

                In den Ordner "base" gehoeren:

                \(spiel.erwarteteDateien)

                Sie lassen sich hier hineinkopieren oder im Fenster der App
                ueber "Dateien auswaehlen" einlesen.

                Spielstaende und Konfiguration liegen NICHT hier, sondern unter
                Library/Application Support (OpenJK fuer Academy, OpenJO fuer
                Outcast). Beide Spiele halten sie getrennt.
                """
                try? text.write(to: readme, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Einmaliger Umzug von `Documents/base` nach `Documents/JediAcademy/base`.
    ///
    /// Bis zur Spielauswahl gab es nur Academy, und deren Dateien lagen direkt
    /// im Dokumentenverzeichnis. Ein Umbenennen kostet nichts und dauert
    /// unabhängig von den 1,2 GB einen Augenblick; sie neu einzuspielen wäre
    /// eine Viertelstunde.
    ///
    /// Verschoben wird nur, wenn das Ziel noch nichts enthält — sonst gewinnt,
    /// was schon am neuen Ort liegt.
    private static func migriereAltesBase() {
        let fm = FileManager.default
        let alt = documentsDirectory.appendingPathComponent("base")
        let neu = baseDirectory(.academy)

        var istOrdner: ObjCBool = false
        guard fm.fileExists(atPath: alt.path, isDirectory: &istOrdner),
              istOrdner.boolValue else { return }

        let vorhanden = (try? fm.contentsOfDirectory(atPath: neu.path)) ?? []
        guard vorhanden.filter({ $0.lowercased().hasSuffix(".pk3") }).isEmpty else {
            return
        }

        do {
            try fm.createDirectory(at: neu.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: neu)          // leeres base/ aus prepare()
            try fm.moveItem(at: alt, to: neu)
            print("[JKXR] Documents/base nach \(Spiel.academy.ordner)/base verschoben")
        } catch {
            print("[JKXR] Umzug von Documents/base fehlgeschlagen: "
                + "\(error.localizedDescription)")
        }
    }

    static func status(_ spiel: Spiel) -> AssetStatus {
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: baseDirectory(spiel).path)) ?? []
        let pk3 = files.filter { $0.lowercased().hasSuffix(".pk3") }
        return pk3.isEmpty ? .missing : .ready(names: pk3)
    }

    static func copyIntoBase(_ source: URL, _ spiel: Spiel) -> CopyResult {
        // Ausgewählte Dateien liegen außerhalb der Sandbox; ohne diesen Zugriff
        // schlägt das Lesen mit einem Rechtefehler fehl.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = baseDirectory(spiel)
            .appendingPathComponent(source.lastPathComponent)
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
    static func revealInFiles(_ spiel: Spiel) {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = baseDirectory(spiel).path
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}
