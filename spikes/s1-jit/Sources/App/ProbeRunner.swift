import Foundation

/// Swift-Sicht auf eine Probe.
struct ProbeOutcome: Identifiable, Codable {
    enum Stage: Int, Codable {
        case none = 0
        case allocated = 1
        case written = 2
        case executable = 3
        case executed = 4

        var label: String {
            switch self {
            case .none:       return "kein Speicher"
            case .allocated:  return "Speicher belegt"
            case .written:    return "Code geschrieben"
            case .executable: return "ausführbar gemacht"
            case .executed:   return "ausgeführt"
            }
        }
    }

    var id: Int { index }

    let index: Int
    let name: String
    let detail: String
    let stage: Stage
    let faulted: Bool
    let returned: Int32

    /// Der Prozess wurde bei dieser Probe hart beendet — kein abfangbares
    /// Signal, sondern Abschuss durch den Kernel oder das OS. Das ist die
    /// härteste Form von "geht nicht" und nur über einen Neustart feststellbar.
    let fatal: Bool

    var succeeded: Bool {
        !fatal && stage == .executed && returned == JITPROBE_MAGIC
    }
}

/// Persistenter Zustand über App-Starts hinweg.
private struct RunState: Codable {
    var results: [ProbeOutcome] = []
    /// Index der Probe, die gerade läuft. Steht hier beim Start noch ein Wert,
    /// hat genau diese Probe den letzten Prozess umgebracht.
    var inFlight: Int?
    /// Zustand der laufenden Probe unmittelbar vor dem Sprung in den
    /// vorbereiteten Speicher. Damit lässt sich ein Prozessabschuss einordnen:
    /// mit Checkpoint gelang das Mappen und nur die Ausführung wurde verweigert,
    /// ohne Checkpoint starb die Probe schon vorher.
    var checkpoint: ProbeOutcome?
    var launches: Int = 0
}

/// Führt die Proben aus und überlebt es, wenn eine davon den Prozess killt.
///
/// Auf visionOS hat sich gezeigt, dass eine Probe den Prozess hart beenden kann
/// — ohne abfangbares Signal, der Handler in `call_guarded` greift dann nicht.
/// Deshalb ist der Lauf über App-Starts hinweg fortsetzbar: vor jeder Probe
/// wird ihr Index festgeschrieben, nach jeder das Ergebnis. Findet der nächste
/// Start noch einen festgeschriebenen Index vor, wird diese Probe als *fatal*
/// vermerkt und übersprungen. Ein paar Neustarts liefern so das vollständige
/// Bild, statt immer wieder an derselben Stelle abzubrechen.
@MainActor
final class ProbeRunner: ObservableObject {
    @Published private(set) var outcomes: [ProbeOutcome] = []
    @Published private(set) var environment: String = ""
    @Published private(set) var finished = false
    @Published private(set) var launches = 0

    static let shared = ProbeRunner()
    private init() {}

    private var state = RunState()

    static var reportURL: URL { documents.appendingPathComponent("s1-jit-report.txt") }
    private static var stateURL: URL { documents.appendingPathComponent("s1-jit-state.json") }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Läuft direkt beim App-Start, nicht erst wenn ein Fenster erscheint —
    /// auf visionOS ist nicht garantiert, dass eine Szene sichtbar wird.
    func runPendingProbes() {
        environment = Self.readEnvironment()
        state = Self.loadState()
        state.launches += 1
        launches = state.launches

        // Eine beim letzten Start festgeschriebene Probe, die kein Ergebnis
        // hinterlassen hat, hat den Prozess mitgenommen.
        if let killer = state.inFlight {
            state.results.append(Self.fatalOutcome(index: killer,
                                                   checkpoint: state.checkpoint))
            state.inFlight = nil
            state.checkpoint = nil
            save()
        }

        jitprobe_set_checkpoint { partial in
            guard let partial else { return }
            MainActor.assumeIsolated {
                ProbeRunner.shared.recordCheckpoint(partial.pointee)
            }
        }

        let done = Set(state.results.map(\.index))
        for index in 0..<jitprobe_count() where !done.contains(index) {
            state.inFlight = index
            state.checkpoint = nil
            save()

            var raw = JitProbeResult()
            jitprobe_run_one(index, &raw)

            state.results.append(Self.convert(raw, index: index))
            state.inFlight = nil
            state.checkpoint = nil
            save()
        }

        publish()
    }

    /// Wird aus C heraus unmittelbar vor dem Sprung in den vorbereiteten
    /// Speicher gerufen. Ab hier kann der Prozess jederzeit verschwinden, also
    /// muss der Stand sofort auf Platte.
    fileprivate func recordCheckpoint(_ raw: JitProbeResult) {
        guard let index = state.inFlight else { return }
        state.checkpoint = Self.convert(raw, index: index)
        save()
    }

    /// Alles verwerfen und von vorn beginnen.
    func reset() {
        state = RunState()
        try? FileManager.default.removeItem(at: Self.stateURL)
        save()
        runPendingProbes()
    }

    // MARK: - Bericht

    func reportText() -> String {
        var lines: [String] = []
        lines.append("S1 — JIT-Spike")
        lines.append("App-Starts für diesen Lauf: \(state.launches)")
        lines.append(ISO8601DateFormatter().string(from: Date()))
        lines.append("")
        lines.append(environment)
        lines.append(String(repeating: "-", count: 60))

        for o in outcomes.sorted(by: { $0.index < $1.index }) {
            lines.append("")
            let tag = o.fatal ? "TOT " : (o.succeeded ? "OK  " : "FEHL")
            lines.append("[\(tag)] \(o.name)")
            if o.fatal {
                lines.append("       \(o.detail)")
                continue
            }
            lines.append("       weit gekommen bis: \(o.stage.label)")
            if o.faulted {
                lines.append("       Signal beim Sprung in den Speicher (abgefangen)")
            }
            if o.stage == .executed {
                lines.append("       Rückgabewert: \(o.returned) (erwartet \(JITPROBE_MAGIC))")
            }
            lines.append("       \(o.detail)")
        }

        if let pending = state.inFlight {
            var name = [CChar](repeating: 0, count: 128)
            jitprobe_name(pending, &name, name.count)
            lines.append("")
            lines.append("[????] \(String(cString: name)) — läuft gerade. Steht das "
                       + "beim nächsten Start noch hier, hat diese Probe den "
                       + "Prozess beendet.")
        }

        lines.append("")
        lines.append(String(repeating: "-", count: 60))
        lines.append("Fazit: \(verdict)")
        return lines.joined(separator: "\n")
    }

    var verdict: String {
        guard finished else {
            return "Lauf unvollständig — \(outcomes.count) von \(jitprobe_count()) "
                 + "Proben erledigt. App erneut starten, um fortzusetzen."
        }
        let winners = outcomes.filter(\.succeeded)
        guard !winners.isEmpty else {
            let fatals = outcomes.filter(\.fatal).count
            return "KEIN ausführbarer Speicher auf diesem Weg."
                 + (fatals > 0 ? " \(fatals) Probe(n) beendeten den Prozess hart." : "")
                 + " Ein nativer Cemu-Port über den Recompiler ist auf dieser "
                 + "Konfiguration nicht möglich."
        }
        return "JIT möglich über: " + winners.map(\.name).joined(separator: ", ")
    }

    // MARK: - Zustand

    private func publish() {
        outcomes = state.results.sorted { $0.index < $1.index }
        finished = outcomes.count == jitprobe_count()
        try? reportText().write(to: Self.reportURL, atomically: true, encoding: .utf8)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
        publish()
    }

    private static func loadState() -> RunState {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(RunState.self, from: data)
        else { return RunState() }
        return decoded
    }

    private static func fatalOutcome(index: Int,
                                     checkpoint: ProbeOutcome?) -> ProbeOutcome {
        var name = [CChar](repeating: 0, count: 128)
        jitprobe_name(index, &name, name.count)

        // Der Checkpoint entscheidet, was der Abschuss bedeutet.
        let detail: String
        if let cp = checkpoint {
            detail = "Speicher ließ sich vorbereiten (\(cp.stage.label)) — "
                   + "erst der Sprung in den Speicher beendete den Prozess. "
                   + "Das Mappen ist also erlaubt, die Ausführung nicht. "
                   + "[\(cp.detail)]"
        } else {
            detail = "Prozess starb noch vor dem Sprung in den Speicher, also "
                   + "schon beim Vorbereiten. Kein abfangbares Signal, sondern "
                   + "Abschuss durch Kernel oder OS."
        }

        return ProbeOutcome(
            index: index,
            name: String(cString: name),
            detail: detail,
            stage: checkpoint?.stage ?? .none,
            faulted: false,
            returned: -1,
            fatal: true
        )
    }

    // MARK: - C-Brücke

    private static func convert(_ raw: JitProbeResult, index: Int) -> ProbeOutcome {
        ProbeOutcome(
            index: index,
            name: string(from: raw.name),
            detail: string(from: raw.detail),
            stage: ProbeOutcome.Stage(rawValue: Int(raw.stage)) ?? .none,
            faulted: raw.faulted != 0,
            returned: raw.returned,
            fatal: false
        )
    }

    /// Fixed-size C-Char-Arrays kommen als Swift-Tupel an; über den rohen
    /// Speicher gelesen bleibt das unabhängig von der Array-Länge.
    private static func string<T>(from tuple: T) -> String {
        var copy = tuple
        return withUnsafeBytes(of: &copy) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }

    private static func readEnvironment() -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        jitprobe_environment(&buffer, buffer.count)
        return String(cString: buffer)
    }
}
