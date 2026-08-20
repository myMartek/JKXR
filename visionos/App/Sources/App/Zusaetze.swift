import CryptoKit
import Foundation

/// Ein Zusatz, den die App selbst holen kann.
///
/// Der Katalog steht im Code und nicht auf dem Server: die App soll nicht von
/// einer Liste abhängen, die jemand anders ändern kann, und ein Zusatz, den es
/// noch nicht gibt, ist auch kein Eintrag im Fenster wert.
/// Wie fein die Texturen sein sollen.
///
/// Eine Auswahl statt zweier Schalter: die Stufe entscheidet BEIDES -- welches
/// Paket geladen wird und ob die Engine die Texturen beim Hochladen halbiert.
/// Getrennt bedienbar waren die zwei Dinge nur verwirrend, denn nur bestimmte
/// Paarungen ergeben Sinn.
enum Texturstufe: Int, CaseIterable, Identifiable {
    case standard = 0
    case zweifach = 1
    case vierfach = 2

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .standard: return Sprache.t("Default", "Standard")
        case .zweifach: return "2×"
        case .vierfach: return Sprache.t("4× (experimental)", "4× (experimentell)")
        }
    }

    var erklaerung: String {
        switch self {
        case .standard:
            return Sprache.t("The textures of the game you own.",
                             "Die Texturen des Spiels, das dir gehört.")
        case .zweifach:
            return Sprache.t("Upscaled pack, halved on upload — a quarter of the "
                                + "texture memory, still sharper than the original.",
                             "Hochgerechnetes Paket, beim Laden halbiert — ein Viertel "
                                + "des Texturspeichers, immer noch schärfer als das Original.")
        case .vierfach:
            // Der frühere Hinweis auf die falsch platzierte Textur ist raus:
            // die Ursache lag in der Mip-Erzeugung des Backwerkzeugs und ist
            // behoben, das Paket neu gebacken. "Experimentell" bleibt es
            // trotzdem -- es ist der jüngste der drei Wege.
            return Sprache.t("Full resolution, pre-baked as compressed GPU textures.",
                             "Volle Auflösung, vorgebacken als komprimierte "
                                + "GPU-Texturen.")
        }
    }

    /// Halbiert die Engine beim Hochladen? Nur bei 2× -- bei 4x ist das Paket
    /// bereits komprimiert und braucht es nicht.
    var halbieren: Bool { self == .zweifach }
}

/// Ein Zusatz, den die App selbst holen kann.
struct Zusatzangebot: Identifiable, Sendable {
    let id: String
    let spiel: Spiel
    let stufe: Texturstufe

    /// Unter welchem Namen die Datei abgelegt wird — und das ist keine
    /// Nebensache, sondern bestimmt die LADEREIHENFOLGE.
    ///
    /// Bei Gleichstand gewinnt der alphabetisch letzte Name (files.cpp:
    /// aufsteigend hinzugefügt, jeder Suchpfad vorangestellt). Beide Namen
    /// liegen hinter "assets0-5" und vor "z_vr_assets_": die Pakete schlagen
    /// damit die Originaltexturen, lassen die VR-Zusätze des Ports aber in Ruhe.
    let dateiname: String

    let url: URL
    let ungefaehr: String

    /// Optional: erwarteter SHA-256. Ist er gesetzt, wird nach dem Laden
    /// geprüft und bei Abweichung verworfen.
    let sha256: String?
}

enum Zusatzkatalog {
    static let alle: [Zusatzangebot] = [
        Zusatzangebot(
            id: "jko-upscale-2x",
            spiel: .outcast,
            stufe: .zweifach,
            // Der Name stammt vom Autor des Pakets.
            dateiname: "assets8_4x_upscale.pk3",
            url: URL(string: "https://www.martek.de/downloads/outcast/assets8_4x_upscale.pk3")!,
            ungefaehr: "1,7 GB",
            sha256: "e00ae28ae11c96646795c07ce299d7641c8c133b5be7f7631a3ff9dfbbedccae"),

        Zusatzangebot(
            id: "jko-upscale-4x",
            spiel: .outcast,
            stufe: .vierfach,
            dateiname: "assets9_astc.pk3",
            url: URL(string: "https://www.martek.de/downloads/outcast/assets9_astc.pk3")!,
            ungefaehr: "4,7 GB",
            // Neu gebacken am 20.08.2026, nachdem die Mip-Erzeugung im
            // Backwerkzeug die Farbe aller Texturen mit Alphakanal ausgelöscht
            // hatte (siehe verkleinere() in bake-astc.py). Wer hier einen Wert
            // ändert, muss auch das Paket auf dem Server tauschen -- sonst
            // verwirft die App die Datei, die sie gerade geladen hat.
            sha256: "68fa3d2efcc78af95a9fabf6ac2d406c7cae6175502ac6894a46b1ce8a374e9b"),

        // Academy kam als ELF Dateien (z_JAx4_gfx, models_1..4, textures_1..6).
        // Zu einer zusammengefasst, weil ein Angebot genau eine Datei lädt --
        // mit erhaltener DEFLATE-Packung, sonst wären aus 5 GB rund 16 geworden.
        Zusatzangebot(
            id: "ja-upscale-2x",
            spiel: .academy,
            stufe: .zweifach,
            dateiname: "assets8_4x_upscale.pk3",
            url: URL(string: "https://www.martek.de/downloads/academy/assets8_4x_upscale.pk3")!,
            ungefaehr: "4,8 GB",
            sha256: "dcf4171db14303dc7919e75c1e34c348259808aa836c42963f208af9384c1604"),

        // 11,8 GB, zweieinhalbmal Outcast: Academy bringt 4500 Texturen mit
        // 20,9 Mrd. Bildpunkten mit, und ASTC hat eine feste Rate je Bildpunkt.
        // Block 6x6 wie bei Outcast -- 8x8 wäre halb so groß, aber auch halbe
        // Bitrate und damit ein sichtbarer Rückschritt.
        Zusatzangebot(
            id: "ja-upscale-4x",
            spiel: .academy,
            stufe: .vierfach,
            dateiname: "assets9_astc.pk3",
            url: URL(string: "https://www.martek.de/downloads/academy/assets9_astc.pk3")!,
            ungefaehr: "11,5 GB",
            sha256: "45bacc2245042b1e55307509d4082594a0024aac6c01c0ca3ad698e417a48a79"),
    ]

    static func fuer(_ spiel: Spiel, _ stufe: Texturstufe) -> Zusatzangebot? {
        alle.first { $0.spiel == spiel && $0.stufe == stufe }
    }

    /// Alle Dateinamen des Katalogs -- die verwaltet die Auswahl, nicht die
    /// allgemeine Zusatzliste.
    static var verwalteteNamen: Set<String> {
        Set(alle.map { $0.dateiname.lowercased() })
    }
}

/// SHA-256 einer Datei, ohne sie in den Speicher zu holen.
///
/// Zwei Dinge, die beide nötig sind und deren Fehlen die App abgeschossen hat
/// (JetsamEvent, gemessen am 20.08.2026 beim Prüfen eines 5-GB-Pakets):
///
/// 1. AUTORELEASEPOOL um jeden Block. `read(upToCount:)` liefert ein
///    autoreleastes Objekt; ohne eigenen Pool wird davon nichts freigegeben,
///    bis die Schleife fertig ist. Bei 5 GB in 8-MB-Blöcken sammeln sich so
///    5 GB an -- die Blockgröße hilft dagegen überhaupt nicht, sie bestimmt
///    nur, in wie vielen Stücken der Speicher vollläuft.
///
/// 2. F_NOCACHE. Sonst wandert die ganze Datei zusätzlich durch den
///    Seitencache, und das zählt auf diesem System gegen uns.
///
/// Gibt nil zurück, wenn die Datei nicht lesbar ist.
func pruefsummeVonDatei(_ pfad: URL, blockgroesse: Int = 4 * 1024 * 1024) -> String? {
    guard let hand = try? FileHandle(forReadingFrom: pfad) else { return nil }
    defer { try? hand.close() }
    fcntl(hand.fileDescriptor, F_NOCACHE, 1)

    var hasher = SHA256()
    while true {
        let weiter: Bool = autoreleasepool {
            guard let block = try? hand.read(upToCount: blockgroesse),
                  !block.isEmpty else { return false }
            hasher.update(data: block)
            return true
        }
        if !weiter { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Laden

/// Lädt eine Datei mit Fortschritt und legt sie in den base-Ordner.
///
/// Über einen Delegaten und nicht über `URLSession.bytes`: Letzteres liefert
/// eine Folge von EINZELNEN Bytes, und bei zwei Gigabyte sind das zwei
/// Milliarden Schleifendurchläufe. Der Download-Task schreibt dagegen selbst
/// gepuffert in eine temporäre Datei, und der Delegat meldet nebenbei, wie weit
/// er ist.
final class ZusatzLader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var fortschritt: ((Double, Int64, Int64) -> Void)?
    private var abschluss: ((Result<URL, Error>) -> Void)?
    private var ziel: URL?
    private var sitzung: URLSession?

    enum Fehler: LocalizedError {
        case status(Int)
        case hashPasstNicht
        case keinZiel

        var errorDescription: String? {
            switch self {
            case .status(let code): return "Server antwortete mit \(code)"
            case .hashPasstNicht:   return "Prüfsumme stimmt nicht"
            case .keinZiel:         return "Kein Ablageort"
            }
        }
    }

    private var erwarteterHash: String?

    /// Lädt und legt ab. Der Fortschritt kommt auf dem Hauptthread.
    func lade(_ angebot: Zusatzangebot,
              nach ziel: URL,
              fortschritt: @escaping (Double, Int64, Int64) -> Void) async throws -> URL {
        self.ziel = ziel
        self.fortschritt = fortschritt
        self.erwarteterHash = angebot.sha256

        // Eigene Sitzung, damit der Delegat greift. Kein Zwischenspeicher: die
        // Datei ist gigabytegroß und würde den Cache sprengen, den iOS uns
        // ohnehin jederzeit wieder wegräumen darf.
        let konfig = URLSessionConfiguration.default
        konfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        konfig.urlCache = nil
        konfig.timeoutIntervalForResource = 60 * 60
        let sitzung = URLSession(configuration: konfig, delegate: self, delegateQueue: nil)
        self.sitzung = sitzung

        return try await withCheckedThrowingContinuation { fortsetzung in
            self.abschluss = { ergebnis in
                fortsetzung.resume(with: ergebnis)
            }
            sitzung.downloadTask(with: angebot.url).resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let anteil = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let melde = fortschritt
        DispatchQueue.main.async {
            melde?(anteil, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // SOFORT verschieben. Die temporäre Datei wird gelöscht, sobald diese
        // Methode zurückkehrt — später darauf zuzugreifen findet nichts mehr.
        defer { session.finishTasksAndInvalidate() }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            abschluss?(.failure(Fehler.status(http.statusCode)))
            return
        }
        guard let ziel else {
            abschluss?(.failure(Fehler.keinZiel))
            return
        }

        do {
            if let erwartet = erwarteterHash {
                guard let ist = pruefsummeVonDatei(location) else {
                    throw Fehler.keinZiel
                }
                if ist.caseInsensitiveCompare(erwartet) != .orderedSame {
                    throw Fehler.hashPasstNicht
                }
            }

            try? FileManager.default.removeItem(at: ziel)
            try FileManager.default.moveItem(at: location, to: ziel)
            abschluss?(.success(ziel))
        } catch {
            abschluss?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Nur der Fehlerfall: der Erfolg ist oben schon gemeldet, und ein
        // zweiter Aufruf der Fortsetzung wäre ein Absturz.
        guard let error else { return }
        abschluss?(.failure(error))
        abschluss = nil
        session.finishTasksAndInvalidate()
    }
}
