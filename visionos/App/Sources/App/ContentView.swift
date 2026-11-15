import CryptoKit
import GameController
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

    /// Das Spiel, das diese App fest traegt -- oder keines.
    ///
    /// AVP Play baut je Spiel eine eigene App, zwei Kacheln dort, zwei Apps auf
    /// der Brille: so kann jemand, der nur eines der beiden Spiele besitzt, es
    /// trotzdem installieren. tools/avpplay_toolchain/visionos/run.sh setzt dafuer
    /// JKXR_GAME, das als JKXRGame in der Info.plist landet. Ohne den Eintrag --
    /// die TestFlight-Fassung -- traegt die App beide und laesst waehlen.
    static let fest: Spiel? = {
        switch Bundle.main.object(forInfoDictionaryKey: "JKXRGame") as? String {
        case "outcast": return .outcast
        case "academy": return .academy
        default: return nil
        }
    }()

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

    /// Die Dateien des gekauften Spiels, namentlich.
    ///
    /// NAMENTLICH und nicht ueber das Praefix "assets". Genau daran ist die
    /// Erkennung gescheitert: das Upscale-Paket heisst assets8_4x_upscale.pk3
    /// -- der Autor hat den Namen mit Bedacht gewaehlt, damit er hinter
    /// assets0-5 einsortiert -- und fiel damit durch ein Sieb, das eigentlich
    /// nur die Originaldateien fernhalten sollte. Es erschien nie als Zusatz,
    /// liess sich also weder an- noch abschalten, und der Ladeknopf blieb
    /// stehen, als waere nichts geladen worden.
    var spieleigeneDateien: Set<String> {
        switch self {
        case .academy: return ["assets0.pk3", "assets1.pk3", "assets2.pk3", "assets3.pk3"]
        case .outcast: return ["assets0.pk3", "assets1.pk3", "assets2.pk3", "assets5.pk3"]
        }
    }
}

/// Was das System an Controllern meldet.
///
/// Steht sichtbar im Fenster, weil zwei Tester unabhängig voneinander gemeldet
/// haben, ihre PSVR2-Sense-Controller reagierten nicht -- Tasten ja, Verfolgung
/// nein. Auf keinem unserer Geräte liess sich das nachstellen: die Melder sind
/// auf visionOS 26, das Entwicklungsgerät auf 27.
///
/// Statt weiter zu raten, zeigt das Fenster jetzt, was ihr System ueberhaupt
/// sieht. Ein Bildschirmfoto beantwortet dann drei Fragen auf einmal: kommen
/// die Controller an, gelten sie als räumlich, und gibt es GCSpatialAccessory
/// dort. Genau an dieser Unterscheidung hing der Fehler in der Gerätesuche.
private struct ControllerStand: View {
    @State private var text = ""

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            .onAppear(perform: lies)
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in lies() }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in lies() }
    }

    private func lies() {
        let alle = GCController.controllers()
        guard !alle.isEmpty else {
            text = Sprache.t("No controllers detected.", "Keine Controller erkannt.")
            return
        }
        let raeumlich = alle.filter { $0.productCategory == GCProductCategorySpatialController }
        let klasse = NSClassFromString("GCSpatialAccessory") != nil
        let namen = alle.map { "\($0.vendorName ?? "?") · \($0.productCategory)" }
                        .joined(separator: ", ")
        // Die Freigabe stammt vom LETZTEN Lauf im Immersive Space -- vorher gibt
        // es sie nicht. Steht sie auf verweigert, kommen Tasten weiter an, aber
        // keine Pose, und zurücknehmen lässt sich das nur in den
        // Systemeinstellungen.
        let vd = UserDefaults.standard
        let freigabe = vd.object(forKey: "jkxr.zubehoerfreigabe") as? Bool
        let frei = freigabe == false
            ? Sprache.t(" — accessory tracking DENIED, allow it in Settings",
                        " — Zubehörverfolgung VERWEIGERT, in den Einstellungen erlauben")
            : ""
        text = Sprache.t(
            "Controllers: \(namen) — \(raeumlich.count) spatial, "
                + "GCSpatialAccessory \(klasse ? "present" : "missing")\(frei)",
            "Controller: \(namen) — \(raeumlich.count) räumlich, "
                + "GCSpatialAccessory \(klasse ? "vorhanden" : "fehlt")\(frei)")
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
    @State private var zusaetze: [ZusatzDatei] = []
    /// Welches Angebot gerade geladen wird, und wie weit.
    @State private var laedt: String?
    @State private var ladeText = ""
    @State private var lader = ZusatzLader()
    /// Welcher Zusatz gerade zum Löschen angefragt ist.
    @State private var loeschKandidat: ZusatzDatei?
    /// Pakete, deren Prüfsumme gerade im Hintergrund nachgerechnet wird.
    @State private var pruefen: Set<String> = []

    /// Die Einstellungen statt der Startkarte.
    @State private var zeigeEinstellungen = false
    /// Ob die Dateien je Spiel da sind -- fuer die Startknoepfe der Karte, die
    /// in der TestFlight-Fassung beide Spiele zugleich anbietet. `assets` gilt
    /// nur dem gerade gewaehlten.
    @State private var stand: [Spiel: AssetStatus] = [:]

    /// Wirkt über die Befehlszeile der Engine (EngineHost) und damit erst beim
    /// nächsten Start des Immersive Space -- r_picmip ist gelatcht. Gesetzt
    /// wird es nicht mehr von Hand, sondern aus der Texturstufe.
    @AppStorage("jkxr.picmip") private var picmip: Bool = false

    /// Die gewählte Texturauflösung.
    @AppStorage("jkxr.texturstufe") private var stufeRoh: Int = Texturstufe.standard.rawValue

    /// Ob die Leistungsanzeige schon beim Start des Spiels steht (EngineHost).
    @AppStorage(Leistungsanzeige.schluessel) private var leistungsanzeige: Bool = false
    private var stufe: Texturstufe { Texturstufe(rawValue: stufeRoh) ?? .standard }

    var body: some View {
        Group {
            if zeigeEinstellungen { einstellungen } else { startkarte }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            Sprache.t("Delete \(loeschKandidat?.name ?? "")?",
                      "\(loeschKandidat?.name ?? "") löschen?"),
            isPresented: Binding(get: { loeschKandidat != nil },
                                 set: { if !$0 { loeschKandidat = nil } }),
            titleVisibility: .visible) {
            Button(Sprache.t("Delete", "Löschen"), role: .destructive) {
                if let z = loeschKandidat {
                    AssetStore.loesche(z)
                    zusaetze = AssetStore.zusatzDateien(spiel)
                }
                loeschKandidat = nil
            }
            Button(Sprache.t("Cancel", "Abbrechen"), role: .cancel) { loeschKandidat = nil }
        } message: {
            // Die Groesse gehoert in die Rueckfrage: erneut zu laden dauert bei
            // 1,7 GB Minuten, und das soll man vor dem Tippen wissen.
            Text(Sprache.t("\(groesse(loeschKandidat?.groesse ?? 0)) will be removed. "
                            + "Downloading it again takes a while.",
                           "\(groesse(loeschKandidat?.groesse ?? 0)) werden entfernt. "
                            + "Erneut zu laden dauert."))
        }
        .onChange(of: spiel) { _, neu in
            progress = nil
            letztesSpiel = Int(neu.rawValue)
            assets = AssetStore.status(neu)
            zusaetze = AssetStore.zusatzDateien(neu)
        }
        .task {
            // Die gemerkte Wahl VOR der Statusabfrage übernehmen, sonst zeigt
            // das Fenster einen Augenblick die Dateien des anderen Spiels.
            // Eine App, die fest ein Spiel traegt, hat keine Wahl zu merken.
            if let fest = Spiel.fest {
                spiel = fest
            } else if let gemerkt = Spiel(rawValue: Int32(letztesSpiel)) {
                spiel = gemerkt
            }

            // Muss vor allem anderen passieren: ein leeres Dokumentenverzeichnis
            // erscheint in der Dateien-App überhaupt nicht, egal was in der
            // Info.plist steht. Erst wenn etwas darin liegt, wird der Ordner
            // sichtbar und man kann hineinkopieren.
            AssetStore.prepare()


            // Zusaetze von aussen umschalten, fuer die Fehlersuche.
            //
            //   devicectl ... --environment-variables '{"JKXR_ZUSATZ":"an"}'
            //
            // Gebraucht, um beide Zustaende vom Mac aus messen zu koennen: das
            // Upscale-Paket wiegt 1,7 GB, und es nur zum Umbenennen erneut
            // hochzuschieben waere absurd. Ohne die Variable passiert nichts --
            // dieselbe Bauart wie JKXR_AUTO_START.
            if let wunsch = ProcessInfo.processInfo.environment["JKXR_ZUSATZ"] {
                let an = (wunsch == "an" || wunsch == "1")
                for z in AssetStore.zusatzDateien(spiel) where z.aktiv != an {
                    AssetStore.setzeAktiv(z, an)
                    print("[JKXR] Zusatz \(z.name) -> \(an ? "an" : "aus")")
                }
            }

            assets = AssetStore.status(spiel)
            zusaetze = AssetStore.zusatzDateien(spiel)
            aktualisiereStand()

            // Hardware-Diagnose ohne UI-Automation. devicectl kann die App mit
            // JKXR_AUTO_START=1 starten; im normalen App-Start ist die Variable
            // nicht gesetzt und das Fenster verhält sich unverändert.
            if !didAutoStart,
               ProcessInfo.processInfo.environment["JKXR_AUTO_START"] == "1" {
                // Auch der Demo-Fall, sonst laesst sich die Pruefdatei nur mit
                // aufgesetzter Brille testen -- und genau dieser Weg ist der,
                // den ein Pruefer geht.
                switch assets {
                case .ready:
                    didAutoStart = true
                    print("[JKXR] Diagnose-Autostart des Immersive Space")
                    await startGame()
                case .demo:
                    didAutoStart = true
                    print("[JKXR] Diagnose-Autostart der Demo-Welt")
                    await startGame(demo: true)
                case .missing:
                    break
                }
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


    // MARK: - Startkarte

    /// Das Startbild, wenn AVP Play eines mitgegeben hat (project.yml, Generated/).
    ///
    /// Es stammt aus der Steam-Bibliothek des Spielers und liegt nie im Repo:
    /// ohne AVP Play -- TestFlight, CI -- gibt es keines, und die Karte kommt
    /// ohne aus. So halten es alle Spiele, die AVP Play baut ("branding is text
    /// only: no game art is part of this project").
    private static let startbild: UIImage? = Bundle.main.resourceURL
        .map { $0.appendingPathComponent("Generated/StartHero.png") }
        .flatMap { UIImage(contentsOfFile: $0.path) }

    private static let versionsstempel: String? = {
        let info = Bundle.main.infoDictionary
        guard let kurz = info?["CFBundleShortVersionString"] as? String, !kurz.isEmpty else { return nil }
        let bau = (info?["CFBundleVersion"] as? String) ?? ""
        return bau.isEmpty || bau == kurz ? kurz : "\(kurz) (\(bau))"
    }()

    /// Die Startkarte, nach dem Vorbild aller Spiele, die AVP Play baut.
    ///
    /// Aufbau und Masse folgen Kleptons Startfenster (MIT, Max Thomas;
    /// visionos/Sources/KleptonApp.swift, BootView.startFront), wie es auch der
    /// Skyrim-VR-Port uebernimmt: Bild fuellend, darunter ein Verlauf nach
    /// Schwarz, der Titel gross, eine Zeile, ein weisser Startknopf und
    /// daneben die Einstellungen, der Versionsstempel klein in der Ecke.
    private var startkarte: some View {
        ZStack(alignment: .bottom) {
            if let bild = Self.startbild {
                Image(uiImage: bild).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                            startPoint: .center, endPoint: .bottom))
                    .accessibilityHidden(true)
            }
            startinhalt
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let stempel = Self.versionsstempel {
                Text(stempel).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .padding(.trailing, 48).padding(.bottom, 20)
            }
        }
    }

    /// Mit Bild sitzt der Text unten, auf dem dunklen Ende des Verlaufs; ohne
    /// Bild steht er in der Mitte.
    private var startinhalt: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(Spiel.fest?.name ?? "JKXR")
                .font(.extraLargeTitle.bold())
                .shadow(radius: Self.startbild == nil ? 0 : 10)
            Text(untertitel)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hinweis = starthinweis {
                Label(hinweis, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 18) {
                ForEach(Spiel.fest.map { [$0] } ?? Spiel.allCases) { s in
                    startknopf(s)
                }
                Button { zeigeEinstellungen = true } label: {
                    Label(Sprache.t("Settings", "Einstellungen"), systemImage: "gearshape")
                }
                .controlSize(.extraLarge)
            }
            if Self.startbild == nil { Spacer() }
        }
        .padding(40)
        .padding(.bottom, Self.startbild == nil ? 0 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ein Startknopf: „Start“, wenn die App ein Spiel traegt, sonst der Name
    /// des Spiels. Gesperrt, solange dessen Dateien fehlen -- welche, steht in
    /// den Einstellungen. Liegt die Pruefdatei fuers App-Review da, startet er
    /// die Demo-Welt; das ist der Weg, den ein Pruefer geht.
    private func startknopf(_ s: Spiel) -> some View {
        let st = stand[s] ?? .missing
        return Button {
            spiel = s
            Task { await startGame(demo: st.istDemo) }
        } label: {
            Label(Spiel.fest != nil ? Sprache.t("Start", "Start") : s.name,
                  systemImage: "play.fill")
                .frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent).tint(.white).controlSize(.extraLarge)
        .foregroundStyle(st.startbereit ? Color.black : Color.secondary)
        .disabled(!st.startbereit)
    }

    private var untertitel: String {
        if let fest = Spiel.fest {
            return Sprache.t("\(fest.name) on Apple Vision Pro, running natively with Sense controllers or a game controller.",
                             "\(fest.name) auf der Apple Vision Pro, nativ, mit Sense-Controllern oder Gamepad.")
        }
        return Sprache.t("Two first-person classics of the early 2000s on Apple Vision Pro, running natively with Sense controllers or a game controller.",
                         "Zwei Ego-Klassiker der frühen 2000er auf der Apple Vision Pro, nativ, mit Sense-Controllern oder Gamepad.")
    }

    /// Was unter dem Titel stehen muss, damit niemand vor einem grauen Knopf
    /// raetselt: ein gescheiterter Start, die Demo, oder dass Dateien fehlen.
    private var starthinweis: String? {
        if let progress { return progress }
        let spiele = Spiel.fest.map { [$0] } ?? Spiel.allCases
        if spiele.contains(where: { (stand[$0] ?? .missing).istDemo }) {
            return Sprache.t("Demo file recognised: Start opens the demo world.",
                             "Demo-Datei erkannt: Start öffnet die Demo-Welt.")
        }
        guard !stand.isEmpty, !spiele.contains(where: { (stand[$0] ?? .missing).startbereit }) else { return nil }
        return Sprache.t("The game files are missing. Settings shows which ones and where they go.",
                         "Die Spieldateien fehlen. Unter Einstellungen steht, welche und wohin.")
    }

    private func aktualisiereStand() {
        for s in Spiel.allCases { stand[s] = AssetStore.status(s) }
    }

    // MARK: - Einstellungen

    /// Die Einstellungen: alles, was das Fenster bisher war.
    ///
    /// Dateien, Texturen und Controller-Stand stehen hier unveraendert; nur der
    /// Startknopf ist auf die Karte davor gewandert. Aufgebaut wie die Seite
    /// jedes Spiels, das AVP Play baut: NavigationStack, oben rechts „Fertig“.
    private var einstellungen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Die Auswahl steht ganz oben: sie entscheidet, worauf sich alles
                    // darunter bezieht -- Dateiliste, Pfad und Anleitung. Eine App, die
                    // fest ein Spiel traegt (AVP Play), hat nichts zu waehlen.
                    if Spiel.fest == nil {
                        Picker(Sprache.t("Game", "Spiel"), selection: $spiel) {
                            ForEach(Spiel.allCases) { s in
                                Text(s.name).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 460)
                    }

                    switch assets {
                    case .ready(let names):
                        Label(Sprache.t("\(names.count) pk3 files in \(spiel.ordner)/base/",
                                        "\(names.count) pk3-Dateien in \(spiel.ordner)/base/"),
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text(names.sorted().joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .demo:
                        Label(Sprache.t("Demo file recognised — review mode",
                                        "Demo-Datei erkannt — Prüfmodus"),
                              systemImage: "checkmark.seal")
                            .foregroundStyle(.blue)
                        Text(Sprache.t(
                                "\"Start\" opens the small demo world built into the app. "
                                    + "It takes precedence over any game data present — "
                                    + "delete \(DemoDatei.dateiname) from the folder below "
                                    + "to play normally again.",
                                "„Start“ öffnet die kleine Welt, die die App "
                                    + "selbst mitbringt. Sie hat Vorrang vor vorhandenen "
                                    + "Spieldateien — zum normalen Spielen \(DemoDatei.dateiname) "
                                    + "im Ordner unten löschen."))
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)

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

                    // Der Abschnitt steht immer, sobald es fuer dieses Spiel ueberhaupt
                    // ein Angebot gibt -- die Auswahl soll auffindbar sein, bevor
                    // irgendetwas geladen wurde.
                    if !zusaetze.isEmpty || Zusatzkatalog.alle.contains(where: { $0.spiel == spiel }) {
                        Divider().frame(maxWidth: 460)

                        Text(Sprache.t("Textures", "Texturen"))
                            .font(.headline)

                        ForEach(zusaetze) { z in
                            HStack(spacing: 12) {
                                Toggle(isOn: Binding(
                                    get: { z.aktiv },
                                    set: { an in
                                        AssetStore.setzeAktiv(z, an)
                                        zusaetze = AssetStore.zusatzDateien(spiel)
                                    })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(z.name)
                                        Text(groesse(z.groesse))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Button(role: .destructive) {
                                    loeschKandidat = z
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .frame(maxWidth: 460)
                        }

                        Picker(Sprache.t("Texture resolution", "Texturauflösung"),
                               selection: Binding(get: { stufe },
                                                  set: { neu in waehleStufe(neu) })) {
                            ForEach(Texturstufe.allCases) { s in
                                Text(s.name).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 460)

                        Text(stufe.erklaerung)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)

                        if let angebot = Zusatzkatalog.fuer(spiel, stufe) {
                            let da = AssetStore.paketVorhanden(angebot)
                            // Drei Zustaende, nicht zwei: bekannt-und-aktuell,
                            // bekannt-und-aelter, und UNBEKANNT.
                            //
                            // Unbekannt ist der Normalfall fuer alles, was nicht ueber
                            // den Lader kam -- ueber die Dateien-App eingespielt oder
                            // von aussen in den Container geschoben. Frueher wurde
                            // dafuer beim Fensteraufbau ungefragt nachgerechnet. Das
                            // hat die App abgeschossen (JetsamEvent): eine Datei von
                            // fuenf Gigabyte zu lesen ist keine Nebensache, und beim
                            // Academy-4x-Paket waeren es zwoelf.
                            //
                            // Also fragt es jetzt. Wer die Fassung wissen will, drueckt
                            // darauf; wer nur spielen will, wartet auf nichts.
                            let bekannt = AssetStore.pruefsummeBekannt(angebot)
                            let aktuell = AssetStore.paketAktuell(angebot)
                            let laeuft = pruefen.contains(angebot.id)
                            HStack(spacing: 12) {
                                Text(!da ? angebot.ungefaehr
                                         : laeuft ? Sprache.t("Checking…", "wird geprüft…")
                                         : !bekannt ? Sprache.t("Version unknown", "Fassung unbekannt")
                                         : aktuell ? Sprache.t("Package present", "Paket vorhanden")
                                                   : Sprache.t("Older version present",
                                                               "Ältere Fassung vorhanden"))
                                    .font(.caption)
                                    .foregroundStyle(da && bekannt && !aktuell && !laeuft
                                                     ? Color.orange : Color.secondary)
                                Spacer()
                                if laedt == angebot.id {
                                    Text(ladeText).font(.caption).foregroundStyle(.secondary)
                                    ProgressView()
                                } else if laeuft {
                                    ProgressView()
                                } else {
                                    if da {
                                        Button(Sprache.t("Delete", "Löschen"), role: .destructive) {
                                            AssetStore.loeschePaket(angebot)
                                            zusaetze = AssetStore.zusatzDateien(spiel)
                                        }
                                    }
                                    if da && !bekannt {
                                        Button(Sprache.t("Verify", "Prüfen")) {
                                            Task { await pruefe(angebot) }
                                        }
                                        .disabled(laedt != nil)
                                    }
                                    if !da || (bekannt && !aktuell) {
                                        // Bei vorhandener älterer Fassung heisst der Knopf
                                        // "Erneuern": der Lader legt die Datei ohnehin neu an.
                                        Button(da ? Sprache.t("Update", "Erneuern")
                                                  : Sprache.t("Download", "Laden")) {
                                            Task { await hole(angebot) }
                                        }
                                        .disabled(laedt != nil)
                                    }
                                }
                            }
                            .frame(maxWidth: 460)
                        }

                        // Die Reihenfolge ist keine Kleinigkeit, sondern der haeufigste
                        // Grund, warum eine Mod "nicht wirkt": bei Gleichstand gewinnt
                        // der alphabetisch letzte Dateiname. Deshalb heissen unsere
                        // eigenen Zusaetze z_vr_...
                        Text(Sprache.t(
                                "On conflict the alphabetically last file wins. A name after "
                                    + "\"z_vr_…\" also overrides the VR add-ons of the port.",
                                "Bei Gleichstand gewinnt der alphabetisch letzte Dateiname. "
                                    + "Ein Name nach „z_vr_…“ überschreibt auch die "
                                    + "VR-Zusätze des Ports."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)

                        ControllerStand()
                    }

                    Divider().frame(maxWidth: 460)

                    // Die Leistungsanzeige (Sources/Leistung): wie in jedem Spiel,
                    // das AVP Play baut, auf Create + Options; hier nur, ob sie
                    // schon beim Start steht.
                    Toggle(isOn: $leistungsanzeige) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Sprache.t("Performance overlay from the start",
                                           "Leistungsanzeige schon beim Start"))
                            Text(Sprache.t("In the game, hold Create and Options together for a second to show or hide it.",
                                           "Im Spiel blendet sie sich ein und aus, wenn man Create und Options eine Sekunde zusammen hält."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 460)

                    Divider().frame(maxWidth: 460)

                    HStack(spacing: 12) {
                        Button(Sprache.t("Choose files…", "Dateien auswählen…")) { importing = true }
                        Button(Sprache.t("Open in Files", "In Dateien öffnen")) { AssetStore.revealInFiles(spiel) }
                        Button(Sprache.t("Check again", "Erneut prüfen")) {
                            assets = AssetStore.status(spiel)
                            zusaetze = AssetStore.zusatzDateien(spiel)
                        }
                    }
                    .font(.callout)

                    Text(AssetStore.baseDirectory(spiel).path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Sprache.t("Settings", "Einstellungen"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Sprache.t("Done", "Fertig")) {
                        zeigeEinstellungen = false
                        aktualisiereStand()
                    }
                }
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
    private func startGame(demo: Bool = false) async {
        // Vor dem Oeffnen setzen, wie die Spielwahl auch: der CompositorLayer
        // wird beim Oeffnen aufgebaut und entscheidet dort sofort, welcher der
        // beiden Wege laeuft.
        Laufmodus.demo = demo

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
        zusaetze = AssetStore.zusatzDateien(spiel)
        aktualisiereStand()
    }

    /// Die Texturstufe wechseln.
    ///
    /// Setzt in einem Zug alles, was zusammengehört: das Paket der gewählten
    /// Stufe wird eingeschaltet, das der anderen ausgeschaltet, und die
    /// Halbierung folgt der Stufe. Einzeln bedienbar waren die drei Dinge nur
    /// eine Quelle widersprüchlicher Zustände.
    private func waehleStufe(_ neu: Texturstufe) {
        stufeRoh = neu.rawValue
        picmip = neu.halbieren

        for angebot in Zusatzkatalog.alle where angebot.spiel == spiel {
            AssetStore.setzePaketAktiv(angebot, angebot.stufe == neu)
        }
        zusaetze = AssetStore.zusatzDateien(spiel)
        assets = AssetStore.status(spiel)
    }

    /// Ein Angebot holen und ablegen.
    ///
    /// Der Fortschritt steht in der Zeile des Angebots, nicht in der allgemeinen
    /// Meldung: bei einem Paket dieser Groesse laeuft das minutenlang, und man
    /// soll sehen, WORAN es laeuft.
    /// Die Pruefsumme eines vorhandenen Pakets nachrechnen -- auf Wunsch.
    ///
    /// Bewusst NICHT automatisch: das Lesen einer mehrere Gigabyte grossen
    /// Datei ist teuer genug, dass es eine Entscheidung sein sollte. Der
    /// Vermerk haengt danach an Aenderungszeit und Groesse, ein spaeterer
    /// Tausch von aussen wird also bemerkt und faellt wieder auf "unbekannt".
    private func pruefe(_ angebot: Zusatzangebot) async {
        guard AssetStore.paketVorhanden(angebot), !pruefen.contains(angebot.id) else { return }
        pruefen.insert(angebot.id)
        await Task.detached(priority: .utility) {
            AssetStore.rechnePruefsummeNach(angebot)
        }.value
        pruefen.remove(angebot.id)
    }

    private func hole(_ angebot: Zusatzangebot) async {
        laedt = angebot.id
        ladeText = Sprache.t("starting…", "beginnt…")
        let ziel = AssetStore.baseDirectory(angebot.spiel)
            .appendingPathComponent(angebot.dateiname)

        do {
            _ = try await lader.lade(angebot, nach: ziel) { anteil, geladen, gesamt in
                ladeText = gesamt > 0
                    ? String(format: "%.0f %% · %@ / %@", anteil * 100,
                             groesse(Int(geladen)), groesse(Int(gesamt)))
                    : groesse(Int(geladen))
            }
            AssetStore.merkePruefsumme(angebot)
            progress = nil
        } catch {
            progress = Sprache.t("Download failed: \(error.localizedDescription)",
                                 "Laden fehlgeschlagen: \(error.localizedDescription)")
        }
        laedt = nil
        ladeText = ""
        // Frisch geladen heißt eingeschaltet -- und das andere Paket aus.
        waehleStufe(stufe)
    }

    /// Dateigroesse in einer Zeile, die im Fenster Platz hat.
    private func groesse(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024)
                          : String(format: "%.0f MB", mb)
    }
}

/// Eine zusätzliche pk3 im base-Ordner, die weder zum gekauften Spiel noch zum
/// Port gehört — also eine Mod.
struct ZusatzDatei: Identifiable {
    let id = UUID()
    /// Der Name MIT .pk3, aber ohne die Abschaltendung.
    let name: String
    let aktiv: Bool
    let groesse: Int
    /// Wie die Datei gerade wirklich heißt.
    let pfad: URL
}

enum AssetStatus {
    case ready(names: [String])
    /// Die Pruefdatei fuers App-Review liegt da, echte Spieldateien nicht.
    case demo
    case missing
}

extension AssetStatus {
    /// Ob „Start“ etwas zu starten hat: das Spiel oder die Demo-Welt.
    var startbereit: Bool {
        if case .missing = self { return false }
        return true
    }

    var istDemo: Bool {
        if case .demo = self { return true }
        return false
    }
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
                JKXR — game files for \(spiel.name)

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

    /// Angehängt, um eine pk3 stillzulegen.
    ///
    /// Abschalten heißt UMBENENNEN, nicht verschieben. Die Engine listet
    /// ausschließlich Dateien auf ".pk3" (FS_AddGameDirectory), eine
    /// "…pk3.aus" ist für sie also gar nicht vorhanden. Verschieben wäre die
    /// naheliegende Alternative und die schlechtere: ein Upscale-Paket wiegt
    /// Gigabyte, und die hin- und herzuschaufeln dauert Minuten, das Umbenennen
    /// einen Augenblick.
    static let ausEndung = ".aus"

    /// Alle Mods im base-Ordner, an wie aus.
    ///
    /// Alles, was weder zum gekauften Spiel gehört (assets*.pk3) noch vom Port
    /// mitgeliefert wird (z_vr_assets_*), gilt als Mod. Die Prüfdatei fürs
    /// App-Review bleibt ebenfalls außen vor — sie ist keine.
    static func zusatzDateien(_ spiel: Spiel) -> [ZusatzDatei] {
        let fm = FileManager.default
        let base = baseDirectory(spiel)
        let eigene = Set(spiel.mitgelieferteDateien.map { "\($0).pk3" })

        // Nach Basisnamen zusammenfassen, nicht je Datei auflisten.
        //
        // Beide Formen koennen nebeneinander liegen -- etwa wenn ein Umbenennen
        // auf halbem Weg steckenblieb oder jemand von Hand kopiert hat. Ohne
        // diese Zusammenfassung erschien derselbe Zusatz ZWEIMAL im Fenster,
        // einmal an und einmal aus, und beim Umschalten passierte nichts:
        // moveItem trifft dann auf eine vorhandene Zieldatei und scheitert.
        //
        // Die aktive Form gewinnt, denn sie ist die, welche die Engine sieht.
        var gefunden: [String: ZusatzDatei] = [:]
        for datei in ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted() {
            let klein = datei.lowercased()
            let aktiv = klein.hasSuffix(".pk3")
            let abgeschaltet = klein.hasSuffix(".pk3" + ausEndung)
            guard aktiv || abgeschaltet else { continue }

            let name = aktiv ? datei : String(datei.dropLast(ausEndung.count))
            let k = name.lowercased()
            if spiel.spieleigeneDateien.contains(k) { continue }
            // Was die Texturauswahl verwaltet, taucht nicht zusaetzlich als
            // freier Schalter auf -- sonst liessen sich widersprechende
            // Zustaende einstellen.
            if Zusatzkatalog.verwalteteNamen.contains(k) { continue }
            if eigene.contains(k) { continue }
            if k == DemoDatei.dateiname { continue }

            let pfad = base.appendingPathComponent(datei)
            let groesse = (try? pfad.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let eintrag = ZusatzDatei(name: name, aktiv: aktiv, groesse: groesse, pfad: pfad)

            if let bisher = gefunden[k], bisher.aktiv, !aktiv { continue }
            gefunden[k] = eintrag
        }
        return gefunden.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Liegt das Paket eines Angebots da, an oder aus?
    static func paketVorhanden(_ angebot: Zusatzangebot) -> Bool {
        let base = baseDirectory(angebot.spiel)
        let fm = FileManager.default
        return fm.fileExists(atPath: base.appendingPathComponent(angebot.dateiname).path)
            || fm.fileExists(atPath: base.appendingPathComponent(angebot.dateiname + ausEndung).path)
    }

    /// Das Paket eines Angebots ein- oder ausschalten.
    ///
    /// Tut nichts, wenn es gar nicht da ist -- eine Stufe zu waehlen, deren
    /// Paket noch fehlt, ist ein zulaessiger Zwischenzustand: erst waehlen,
    /// dann laden.
    static func setzePaketAktiv(_ angebot: Zusatzangebot, _ an: Bool) {
        let base = baseDirectory(angebot.spiel)
        let fm = FileManager.default
        let ein = base.appendingPathComponent(angebot.dateiname)
        let aus = base.appendingPathComponent(angebot.dateiname + ausEndung)

        let quelle = an ? aus : ein
        let ziel   = an ? ein : aus
        guard fm.fileExists(atPath: quelle.path) else { return }
        try? fm.removeItem(at: ziel)
        try? fm.moveItem(at: quelle, to: ziel)
    }

    static func loeschePaket(_ angebot: Zusatzangebot) {
        let base = baseDirectory(angebot.spiel)
        for name in [angebot.dateiname, angebot.dateiname + ausEndung] {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
        UserDefaults.standard.removeObject(forKey: pruefschluessel(angebot))
    }

    static func pruefschluessel(_ angebot: Zusatzangebot) -> String {
        "jkxr.paket." + angebot.id
    }

    /// Die Datei eines Angebots -- eingeschaltet oder mit ".aus" daneben.
    static func paketPfad(_ angebot: Zusatzangebot) -> URL? {
        let base = baseDirectory(angebot.spiel)
        let fm = FileManager.default
        for name in [angebot.dateiname, angebot.dateiname + ausEndung] {
            let p = base.appendingPathComponent(name)
            if fm.fileExists(atPath: p.path) { return p }
        }
        return nil
    }

    /// Der Fingerabdruck der DATEI, nicht ihres Inhalts: Änderungszeit und Größe.
    ///
    /// Er entscheidet, ob ein Vermerk noch zur Datei gehört. Ohne ihn bliebe
    /// ein Paket, das von außen getauscht wurde -- über die Dateien-App oder
    /// per devicectl -- für immer als "ältere Fassung" stehen, obwohl längst
    /// die neue dort liegt.
    private static func merkmale(_ pfad: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: pfad.path),
              let d = a[.modificationDate] as? Date,
              let g = a[.size] as? Int else { return nil }
        return "\(Int(d.timeIntervalSince1970)):\(g)"
    }

    /// Der gespeicherte Vermerk, aber nur wenn er noch zu der Datei passt,
    /// die gerade dort liegt. Sonst nil -- dann muss nachgerechnet werden.
    private static func vermerk(_ angebot: Zusatzangebot) -> String? {
        guard let pfad = paketPfad(angebot),
              let jetzt = merkmale(pfad),
              let roh = UserDefaults.standard.string(forKey: pruefschluessel(angebot))
        else { return nil }
        let teile = roh.split(separator: "|", maxSplits: 1)
        guard teile.count == 2, String(teile[1]) == jetzt else { return nil }
        return String(teile[0])
    }

    static func pruefsummeBekannt(_ angebot: Zusatzangebot) -> Bool {
        vermerk(angebot) != nil
    }

    /// Ist das vorhandene Paket die Fassung, die der Katalog erwartet?
    ///
    /// Nicht bei jedem Start nachgerechnet: die Prüfsumme über fünf Gigabyte
    /// zu bilden dauert zu lange. Stattdessen wird vermerkt, WELCHE Prüfsumme
    /// zu welcher Datei gehört; gerechnet wird nur, wenn der Vermerk fehlt
    /// oder die Datei sich seither geändert hat.
    ///
    /// Über die Größe allein ginge es nicht: ASTC hat eine feste Rate, altes
    /// und neues 4×-Paket sind auf das Byte gleich groß.
    static func paketAktuell(_ angebot: Zusatzangebot) -> Bool {
        guard paketVorhanden(angebot) else { return false }
        guard let erwartet = angebot.sha256 else { return true }
        return vermerk(angebot)?.caseInsensitiveCompare(erwartet) == .orderedSame
    }

    /// Die Prüfsumme einer vorhandenen Datei nachrechnen und vermerken.
    ///
    /// Blockweise, nicht am Stück: eine Datei dieser Größe vollständig in den
    /// Speicher zu holen beendet die App -- derselbe Grund wie im Lader.
    ///
    /// Vermerkt wird das GERECHNETE Ergebnis, nicht das erwartete. Sonst würde
    /// die Prüfung sich selbst bestätigen, wie es eine frühere Probe in diesem
    /// Projekt schon getan hat.
    ///
    /// Die Merkmale werden VOR dem Lesen genommen: ändert sich die Datei
    /// währenddessen, passt der Vermerk hinterher nicht mehr und es wird beim
    /// nächsten Mal erneut gerechnet. Andersherum würde ein halb geschriebener
    /// Stand als geprüft gelten.
    static func rechnePruefsummeNach(_ angebot: Zusatzangebot) {
        guard let pfad = paketPfad(angebot),
              let vorher = merkmale(pfad),
              let ist = pruefsummeVonDatei(pfad) else { return }
        UserDefaults.standard.set(ist + "|" + vorher, forKey: pruefschluessel(angebot))
    }

    /// Nach dem Laden: der Lader hat die Prüfsumme bereits geprüft, hier wird
    /// sie nur der frisch abgelegten Datei zugeordnet.
    static func merkePruefsumme(_ angebot: Zusatzangebot) {
        guard let s = angebot.sha256, let pfad = paketPfad(angebot),
              let m = merkmale(pfad) else { return }
        UserDefaults.standard.set(s + "|" + m, forKey: pruefschluessel(angebot))
    }

    /// Einen Zusatz vollstaendig entfernen -- beide Formen.
    ///
    /// Ueber die Dateien-App ginge das auch, aber ein Paket dieser Groesse dort
    /// zu suchen ist umstaendlich, und nach einem missglueckten Umschalten
    /// koennen zwei Dateien herumliegen, von denen man nur eine sieht.
    static func loesche(_ eintrag: ZusatzDatei) {
        let base = eintrag.pfad.deletingLastPathComponent()
        for name in [eintrag.name, eintrag.name + ausEndung] {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    static func setzeAktiv(_ eintrag: ZusatzDatei, _ an: Bool) {
        guard an != eintrag.aktiv else { return }
        let base = eintrag.pfad.deletingLastPathComponent()
        let ziel = base.appendingPathComponent(an ? eintrag.name : eintrag.name + ausEndung)
        do {
            // Liegt die andere Form schon da, ist sie ein Ueberbleibsel: die
            // Datei, die wir gerade verschieben, ist die massgebliche.
            try? FileManager.default.removeItem(at: ziel)
            try FileManager.default.moveItem(at: eintrag.pfad, to: ziel)
        } catch {
            print("[JKXR] \(eintrag.name) ließ sich nicht umschalten: "
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
        // Die Pruefdatei gewinnt, auch wenn echte Spieldateien danebenliegen.
        //
        // Sie kommt nicht aus Versehen dorthin: man muss sie herunterladen und
        // ausdruecklich einspielen. Wer das tut, will die Demo sehen -- und ein
        // Pruefer, der ein Geraet mit installiertem Spiel in die Hand bekommt,
        // saehe sonst nicht das, wofuer wir ihm die Datei gegeben haben.
        //
        // Der Weg zurueck ist die Datei zu loeschen, und der steht auch im
        // Fenster.
        if DemoDatei.vorhanden(in: baseDirectory(spiel)) { return .demo }

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

        // Die Pruefdatei bekommt IMMER ihren kanonischen Namen.
        //
        // Sie wird heruntergeladen, und ein Browser haengt beim zweiten Versuch
        // gern eine Zahl an ("jkxr-demo-1.pk3"). Erkannt wird sie am Hash, also
        // ist der Name frei -- aber die spaetere Pruefung sucht sie unter einem
        // festen Namen, und zwei Kopien nebeneinander waeren nur Verwirrung.
        let name = DemoDatei.istDemodatei(source) ? DemoDatei.dateiname
                                                  : source.lastPathComponent
        let destination = baseDirectory(spiel).appendingPathComponent(name)
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
