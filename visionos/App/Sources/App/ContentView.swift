import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Zwei Sprachen, Englisch als Vorgabe.
///
/// Kein Localizable-Katalog, sondern beide Fassungen nebeneinander im Aufruf.
/// Das Fenster hat ein knappes Dutzend Saetze, und nebeneinander bleiben sie
/// beim Aendern zusammen -- eine getrennte Tabelle waere fuer diese Menge mehr
/// Buchhaltung als Nutzen, und ein fehlender Eintrag faellt dort erst im
/// Headset auf.
///
/// Deutsch nur, wenn das Geraet deutsch spricht. Gefragt wird nach
/// preferredLanguages und nicht nach der Region: wer in Deutschland ein
/// englisches System fuehrt, will Englisch.
enum Sprache {
    static let deutsch: Bool = {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
    }()

    /// Erst Englisch, dann Deutsch — in der Reihenfolge der Vorgabe.
    static func t(_ english: String, _ deutsch: String) -> String {
        Self.deutsch ? deutsch : english
    }
}

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

    /// Was aus der gekauften Installation kommen muss.
    ///
    /// Nur diese. Die z_vr_assets-Dateien gehoeren zum Port und liegen im
    /// App-Bundle; `AssetStore.legeMitgelieferteAb` legt sie beim Start selbst
    /// in `base/`. Sie hier aufzuzaehlen hiesse, nach etwas zu fragen, das
    /// schon da ist.
    var erwarteteDateien: String {
        switch self {
        case .academy:
            return "assets0.pk3 bis assets3.pk3 aus einer Jedi-Academy-Installation."
        case .outcast:
            return "assets0.pk3, assets1.pk3, assets2.pk3 und assets5.pk3 aus einer "
                 + "Jedi-Outcast-Installation."
        }
    }

    /// Dasselbe auf Englisch, fuer die Datei im Ordner.
    ///
    /// Das Fenster spricht Deutsch, weil Marcel es liest. Die Datei im
    /// Dokumentenverzeichnis liest, wer die App aus TestFlight bekommt -- und
    /// von denen spricht nicht jeder Deutsch.
    var requiredFilesEnglish: String {
        switch self {
        case .academy:
            return "assets0.pk3 through assets3.pk3 from a Jedi Academy installation."
        case .outcast:
            return "assets0.pk3, assets1.pk3, assets2.pk3 and assets5.pk3 from a "
                 + "Jedi Outcast installation."
        }
    }

    /// Die Dateien, die die App selbst mitbringt.
    ///
    /// z_vr_assets_base.pk3 ist fuer beide Spiele dieselbe (gleiche
    /// Pruefsumme), deshalb liegt sie nur einmal im Bundle.
    var mitgelieferteDateien: [String] {
        switch self {
        case .academy: return ["z_vr_assets_base", "z_vr_assets_jka"]
        case .outcast: return ["z_vr_assets_base", "z_vr_assets_jko"]
        }
    }

    /// Woran erkennbar ist, dass die gekauften Dateien da sind.
    ///
    /// Nicht "irgendeine pk3": seit die App ihre eigenen mitbringt, liegt immer
    /// eine da, und "irgendeine" hiesse ab sofort immer "bereit" -- der
    /// Spielen-Knopf fuehrte dann in eine Engine, die nichts findet.
    var pflichtDatei: String { "assets0.pk3" }
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
    @AppStorage("jkxr.letztesSpiel") private var letztesSpiel: Int = Int(Spiel.outcast.rawValue)

    /// Outcast beim ersten Start.
    ///
    /// Es steht in der Auswahl vorn, weil es das aeltere Spiel ist, und wer den
    /// Port zum ersten Mal einrichtet, faengt sinnvollerweise dort an. Nach der
    /// ersten Wahl entscheidet ohnehin letztesSpiel.
    @State private var spiel: Spiel = .outcast
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
            Picker(Sprache.t("Game", "Spiel"), selection: $spiel) {
                ForEach(Spiel.allCases) { s in
                    Text(s.name).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            switch assets {
            case .ready(let names):
                Label(Sprache.t("\(names.count) pk3 files in \(spiel.ordner)/base/",
                                "\(names.count) pk3-Dateien in \(spiel.ordner)/base/"),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(names.sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(Sprache.t("Play \(spiel.name)", "\(spiel.name) spielen")) {
                    Task { await startGame() }
                }
                .buttonStyle(.borderedProminent)

            case .missing:
                Label(Sprache.t("Game files for \(spiel.name) are missing",
                                "Spieldateien für \(spiel.name) fehlen"),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(Sprache.t("Required: \(spiel.requiredFilesEnglish)",
                     "Benötigt werden \(spiel.erwarteteDateien)"))
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
                Button(Sprache.t("Choose files…", "Dateien auswählen…")) { importing = true }
                Button(Sprache.t("Open in Files", "In Dateien öffnen")) { AssetStore.revealInFiles(spiel) }
                Button(Sprache.t("Check again", "Erneut prüfen")) { assets = AssetStore.status(spiel) }
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
                progress = Sprache.t("Selection failed: \(error.localizedDescription)",
                                     "Auswahl fehlgeschlagen: \(error.localizedDescription)")
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
            progress = Sprache.t("The immersive space was cancelled.",
                                 "Der Immersive Space wurde abgebrochen.")
        case .error:
            progress = Sprache.t("The immersive space could not be opened.",
                                 "Der Immersive Space ließ sich nicht öffnen.")
        @unknown default:
            break
        }
    }

    /// Kopiert im Hintergrund: die Dateien sind zusammen rund 1,2 GB, das würde
    /// die Oberfläche sonst für Minuten einfrieren.
    private func copy(_ urls: [URL]) async {
        let ziel = spiel
        for (index, url) in urls.enumerated() {
            progress = Sprache.t(
                "Copying \(url.lastPathComponent) (\(index + 1)/\(urls.count)) "
                    + "to \(ziel.ordner)…",
                "Kopiere \(url.lastPathComponent) (\(index + 1)/\(urls.count)) "
                    + "nach \(ziel.ordner)…")
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
            legeMitgelieferteAb(spiel)

            // Englisch, und README statt ANLEITUNG.
            //
            // Diese Datei liest, wer die App aus TestFlight bekommt, und von
            // denen spricht nicht jeder Deutsch. Das Fenster der App bleibt
            // deutsch -- es ist eine andere Leserschaft.
            let spielOrdner = documentsDirectory.appendingPathComponent(spiel.ordner)
            let readme = spielOrdner.appendingPathComponent("README.txt")

            // Die deutsche Vorgaengerin wegraeumen, sonst stehen zwei
            // Anleitungen nebeneinander und die aeltere ist die falsche.
            try? fm.removeItem(at: spielOrdner.appendingPathComponent("ANLEITUNG.txt"))

            if !fm.fileExists(atPath: readme.path) {
                let text = """
                Jedi Knight XR — game files for \(spiel.name)

                Copy these into the "base" folder:

                \(spiel.requiredFilesEnglish)

                They come from your own copy of the game. Put them here with the
                Files app, or use "Dateien auswählen" in the app window.

                You do NOT need the z_vr_assets files. They belong to the VR port,
                ship inside the app, and are placed here automatically on launch.

                Saved games and settings are NOT stored here. They live under
                Library/Application Support — OpenJK for Academy, OpenJO for
                Outcast. The two games keep them apart.
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

        // Nach der Pflichtdatei fragen, nicht nach "irgendeiner pk3".
        //
        // Seit die App ihre eigenen mitbringt, liegt immer eine da. Die alte
        // Pruefung haette ab sofort auf jedem frischen Geraet "bereit"
        // gemeldet, und der Spielen-Knopf haette in eine Engine gefuehrt, die
        // nichts findet.
        let vorhanden = pk3.contains { $0.lowercased() == spiel.pflichtDatei }
        return vorhanden ? .ready(names: pk3) : .missing
    }

    /// Die VR-Zusatzdateien aus dem Bundle nach `base/` legen.
    ///
    /// Sie gehoeren zum Port und nicht zum gekauften Spiel; wer die App aus
    /// TestFlight bekommt, hat keine Bezugsquelle dafuer. Also bringt die App
    /// sie mit und legt sie selbst ab -- fuer den Nutzer bleibt genau eine
    /// Aufgabe, naemlich die gekauften Dateien.
    ///
    /// Kopiert wird, wenn nichts da ist ODER die Groesse abweicht. Das faengt
    /// den Fall ab, dass eine spaetere Fassung der App neue Zusatzdateien
    /// mitbringt: ein blosses "existiert schon" liesse die alte liegen, und der
    /// Fehler waere von aussen nicht zu sehen.
    private static func legeMitgelieferteAb(_ spiel: Spiel) {
        let fm = FileManager.default
        for name in spiel.mitgelieferteDateien {
            guard let quelle = Bundle.main.url(forResource: name, withExtension: "pk3") else {
                print("[JKXR] \(name).pk3 fehlt im Bundle")
                continue
            }
            let ziel = baseDirectory(spiel).appendingPathComponent("\(name).pk3")

            let groesseQuelle = (try? quelle.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let groesseZiel   = (try? ziel.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if groesseZiel != nil, groesseZiel == groesseQuelle { continue }

            do {
                try? fm.removeItem(at: ziel)
                try fm.copyItem(at: quelle, to: ziel)
                print("[JKXR] \(name).pk3 nach \(spiel.ordner)/base gelegt")
            } catch {
                print("[JKXR] \(name).pk3 liess sich nicht ablegen: "
                    + "\(error.localizedDescription)")
            }
        }
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
