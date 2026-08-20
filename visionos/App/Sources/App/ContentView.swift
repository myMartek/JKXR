import CryptoKit
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

    /// Wirkt über die Befehlszeile der Engine (EngineHost) und damit erst beim
    /// nächsten Start des Immersive Space -- r_picmip ist gelatcht. Gesetzt
    /// wird es nicht mehr von Hand, sondern aus der Texturstufe.
    @AppStorage("jkxr.picmip") private var picmip: Bool = false

    /// Die gewählte Texturauflösung.
    @AppStorage("jkxr.texturstufe") private var stufeRoh: Int = Texturstufe.standard.rawValue
    private var stufe: Texturstufe { Texturstufe(rawValue: stufeRoh) ?? .standard }

    var body: some View {
        ScrollView {
        VStack(spacing: 20) {
            Text("JKXR")
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

            case .demo:
                Label(Sprache.t("Demo file recognised — review mode",
                                "Demo-Datei erkannt — Prüfmodus"),
                      systemImage: "checkmark.seal")
                    .foregroundStyle(.blue)
                Text(Sprache.t(
                        "\"Play\" opens the small demo world built into the app. "
                            + "It takes precedence over any game data present — "
                            + "delete \(DemoDatei.dateiname) from the folder below "
                            + "to play normally again.",
                        "„Demo-Welt starten“ öffnet die kleine Welt, die die App "
                            + "selbst mitbringt. Sie hat Vorrang vor vorhandenen "
                            + "Spieldateien — zum normalen Spielen \(DemoDatei.dateiname) "
                            + "im Ordner unten löschen."))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button(Sprache.t("Play demo world", "Demo-Welt starten")) {
                    Task { await startGame(demo: true) }
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
                    let aktuell = AssetStore.paketAktuell(angebot)
                    HStack(spacing: 12) {
                        let wirdGeprueft = pruefen.contains(angebot.id)
                        Text(!da ? angebot.ungefaehr
                                 : wirdGeprueft ? Sprache.t("Checking…", "wird geprüft…")
                                 : aktuell ? Sprache.t("Package present", "Paket vorhanden")
                                           : Sprache.t("Older version present",
                                                       "Ältere Fassung vorhanden"))
                            .font(.caption)
                            .foregroundStyle(!da || wirdGeprueft || aktuell
                                             ? Color.secondary : Color.orange)
                        Spacer()
                        if laedt == angebot.id {
                            Text(ladeText).font(.caption).foregroundStyle(.secondary)
                            ProgressView()
                        } else {
                            if da {
                                Button(Sprache.t("Delete", "Löschen"), role: .destructive) {
                                    AssetStore.loeschePaket(angebot)
                                    zusaetze = AssetStore.zusatzDateien(spiel)
                                }
                            }
                            if !aktuell && !pruefen.contains(angebot.id) {
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
            }

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
        }
        .padding(40)
        // Rollbar, nicht nur hoeher.
        //
        // Die Hoehe haengt jetzt am Inhalt: je Zusatz eine Zeile, dazu der
        // Ladefortschritt und der Regler. Eine feste Fenstergroesse passt fuer
        // genau einen Zustand und schneidet beim naechsten wieder ab -- so wie
        // es die Mod-Auswahl gerade getan hat.
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
            if let gemerkt = Spiel(rawValue: Int32(letztesSpiel)) {
                spiel = gemerkt
            }

            // Muss vor allem anderen passieren: ein leeres Dokumentenverzeichnis
            // erscheint in der Dateien-App überhaupt nicht, egal was in der
            // Info.plist steht. Erst wenn etwas darin liegt, wird der Ordner
            // sichtbar und man kann hineinkopieren.
            AssetStore.prepare()

            // Pakete ohne Vermerk einmalig nachrechnen.
            //
            // Der Vermerk kam erst mit der Fassung vom 20.08.2026; alles,
            // was davor geladen wurde, hat keinen. Statt es pauschal für
            // veraltet zu erklären -- das hätte 1,7 GB 2×-Paket unnötig neu
            // geladen -- wird einmal wirklich gerechnet. Über die Größe ginge
            // es nicht: ASTC hat eine feste Rate, altes und neues 4×-Paket
            // sind auf das Byte gleich groß.
            for angebot in Zusatzkatalog.alle where AssetStore.paketVorhanden(angebot)
                && !AssetStore.pruefsummeBekannt(angebot) {
                pruefen.insert(angebot.id)
                Task.detached(priority: .utility) {
                    AssetStore.rechnePruefsummeNach(angebot)
                    await MainActor.run { pruefen.remove(angebot.id) }
                }
            }

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

    /// Ist das vorhandene Paket die Fassung, die der Katalog erwartet?
    ///
    /// Nicht durch Nachrechnen: die Prüfsumme über fünf Gigabyte zu bilden
    /// dauert bei jedem Start zu lange. Stattdessen wird beim Laden vermerkt,
    /// WELCHE Prüfsumme bestätigt wurde -- die Prüfung selbst hat der Lader
    /// ohnehin schon gemacht.
    ///
    /// Über die Dateigröße ginge es nicht: ASTC hat eine feste Rate, altes und
    /// neues Paket sind auf das Byte gleich groß.
    ///
    /// Ein Paket ohne Vermerk gilt als veraltet. Das trifft alles, was vor
    /// dieser Prüfung geladen wurde -- gewollt, denn genau darunter liegt die
    /// Fassung mit den ausgelöschten Mip-Farben.
    static func paketAktuell(_ angebot: Zusatzangebot) -> Bool {
        guard paketVorhanden(angebot) else { return false }
        guard let erwartet = angebot.sha256 else { return true }
        let gemerkt = UserDefaults.standard.string(forKey: pruefschluessel(angebot))
        return gemerkt?.caseInsensitiveCompare(erwartet) == .orderedSame
    }

    static func pruefsummeBekannt(_ angebot: Zusatzangebot) -> Bool {
        UserDefaults.standard.string(forKey: pruefschluessel(angebot)) != nil
    }

    /// Die Prüfsumme einer vorhandenen Datei einmalig nachrechnen und vermerken.
    ///
    /// Blockweise, nicht am Stück: eine Datei dieser Größe vollständig in den
    /// Speicher zu holen beendet die App -- derselbe Grund wie im Lader.
    ///
    /// Vermerkt wird das GERECHNETE Ergebnis, nicht das erwartete. Sonst würde
    /// die Prüfung sich selbst bestätigen, wie es eine frühere Probe in diesem
    /// Projekt schon getan hat.
    static func rechnePruefsummeNach(_ angebot: Zusatzangebot) {
        let datei = baseDirectory(angebot.spiel).appendingPathComponent(angebot.dateiname)
        let aus = baseDirectory(angebot.spiel)
            .appendingPathComponent(angebot.dateiname + ausEndung)
        let fm = FileManager.default
        let pfad = fm.fileExists(atPath: datei.path) ? datei : aus
        guard let hand = try? FileHandle(forReadingFrom: pfad) else { return }
        defer { try? hand.close() }
        var hasher = SHA256()
        while let block = try? hand.read(upToCount: 8 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        let ist = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(ist, forKey: pruefschluessel(angebot))
    }

    static func merkePruefsumme(_ angebot: Zusatzangebot) {
        guard let s = angebot.sha256 else { return }
        UserDefaults.standard.set(s, forKey: pruefschluessel(angebot))
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
