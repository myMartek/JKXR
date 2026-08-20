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
            // Der Fehler ist BENANNT, nicht beschönigt -- und richtig benannt:
            // es rauscht nichts, sondern eine bestimmte animierte Textur landet
            // an der falschen Stelle und viel zu groß. Eine falsche Beschreibung
            // schickt den nächsten Sucher in die falsche Richtung, wie sie es
            // hier schon getan hat.
            return Sprache.t("Full resolution, pre-baked as compressed GPU textures. "
                                + "Known issue: one animated texture appears in the "
                                + "wrong place and far too large.",
                             "Volle Auflösung, vorgebacken als komprimierte "
                                + "GPU-Texturen. Bekannter Fehler: eine animierte "
                                + "Textur liegt an der falschen Stelle und ist viel "
                                + "zu groß.")
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
            // Gilt für das Paket, das derzeit auf dem Server liegt. Wird neu
            // gebacken, sobald der Platzierungsfehler behoben ist -- dann
            // gehört auch dieser Wert erneuert, sonst verwirft die App die
            // Datei, die sie gerade geladen hat.
            sha256: "9a4863001669d874f68b9496132eff77aa60afdfb6d2196f36c1bd6a1bc503ad"),
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
                // Blockweise gelesen, nicht am Stück: eine Datei dieser Größe
                // vollständig in den Speicher zu holen beendet die App.
                guard let hand = try? FileHandle(forReadingFrom: location) else {
                    throw Fehler.keinZiel
                }
                defer { try? hand.close() }
                var hasher = SHA256()
                while let block = try hand.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
                    hasher.update(data: block)
                }
                let ist = hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
