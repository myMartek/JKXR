import CryptoKit
import Foundation

/// Ein Zusatz, den die App selbst holen kann.
///
/// Der Katalog steht im Code und nicht auf dem Server: die App soll nicht von
/// einer Liste abhängen, die jemand anders ändern kann, und ein Zusatz, den es
/// noch nicht gibt, ist auch kein Eintrag im Fenster wert.
struct Zusatzangebot: Identifiable, Sendable {
    let id: String
    /// Was im Fenster steht.
    let anzeige: String
    let anzeigeEnglisch: String
    /// Für welches Spiel, denn die base-Ordner sind getrennt.
    let spiel: Spiel

    /// Unter welchem Namen die Datei abgelegt wird — und das ist keine
    /// Nebensache, sondern bestimmt die LADEREIHENFOLGE.
    ///
    /// Bei Gleichstand gewinnt der alphabetisch letzte Name (files.cpp:
    /// aufsteigend hinzugefügt, jeder Suchpfad vorangestellt). "upscale_…"
    /// liegt hinter "assets3.pk3" und vor "z_vr_assets_…": das Paket schlägt
    /// damit die Originaltexturen, lässt die VR-Zusätze des Ports aber in Ruhe.
    /// Hieße es "zz_…", überschriebe es auch die Waffenmodelle.
    let dateiname: String

    let url: URL
    /// Nur für die Anzeige, bevor der Server die echte Größe nennt.
    let ungefaehr: String

    /// Optional: erwarteter SHA-256. Ist er gesetzt, wird nach dem Laden
    /// geprüft und bei Abweichung verworfen.
    let sha256: String?
}

enum Zusatzkatalog {
    // Die Datei liegt auf Marcels Server. Angeboten wird die ENTPACKTE .pk3,
    // nicht das 7z-Archiv des Autors: eine .pk3 ist bereits ein Deflate-ZIP,
    // LZMA holt daraus noch ein Prozent heraus (1756 statt 1774 MB), und dafür
    // einen 7z-Entpacker mitzuschleppen, der auf dem Gerät nochmals 1,7 GB
    // Zwischenraum bräuchte, wäre ein schlechter Handel.
    static let alle: [Zusatzangebot] = [
        Zusatzangebot(
            id: "jko-upscale-4x",
            anzeige: "Texturen in vierfacher Auflösung (KI-Hochrechnung)",
            anzeigeEnglisch: "Textures at four times the resolution (AI upscale)",
            spiel: .outcast,
            // Der Name stammt vom Autor und ist gut gewählt: "assets8" sortiert
            // hinter assets0-5 und vor z_vr_assets_ -- das Paket schlägt die
            // Originaltexturen, die VR-Zusätze des Ports bleiben unangetastet.
            dateiname: "assets8_4x_upscale.pk3",
            url: URL(string: "https://www.martek.de/downloads/assets8_4x_upscale.pk3")!,
            ungefaehr: "1,7 GB",
            sha256: "e00ae28ae11c96646795c07ce299d7641c8c133b5be7f7631a3ff9dfbbedccae"),
    ]

    static func fuer(_ spiel: Spiel) -> [Zusatzangebot] {
        alle.filter { $0.spiel == spiel }
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
