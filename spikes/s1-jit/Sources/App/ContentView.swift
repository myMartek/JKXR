import SwiftUI

struct ContentView: View {
    @ObservedObject private var runner = ProbeRunner.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                verdictBanner
                environmentBox

                ForEach(runner.outcomes) { outcome in
                    ProbeRow(outcome: outcome)
                }

                footer
            }
            .padding(28)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("S1 — JIT-Spike")
                .font(.largeTitle.weight(.semibold))
            Text("Kann ein dev-signierter Dritt-App-Prozess auf visionOS "
               + "ausführbaren Speicher bekommen?")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    /// Die eine Zeile, wegen der der Spike existiert.
    private var verdictBanner: some View {
        let ok = runner.outcomes.contains(where: \.succeeded)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: runner.finished
                  ? (ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                  : "hourglass")
                .font(.system(size: 34))
                .foregroundStyle(runner.finished ? (ok ? .green : .red) : .secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(runner.finished ? (ok ? "JIT möglich" : "Kein JIT") : "Läuft …")
                    .font(.title.weight(.bold))
                Text(runner.verdict)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var environmentBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Umgebung").font(.headline)
            Text(runner.environment)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    Clipboard.copy(runner.reportText())
                    copied = true
                } label: {
                    Label(copied ? "Kopiert" : "Bericht kopieren",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Button(role: .destructive) {
                    copied = false
                    runner.reset()
                } label: {
                    Label("Von vorn beginnen", systemImage: "arrow.clockwise")
                }
            }

            if !runner.finished {
                Label("App erneut starten, um fortzusetzen — eine Probe hat den "
                    + "Prozess beendet. Der Fortschritt bleibt erhalten.",
                      systemImage: "exclamationmark.arrow.circlepath")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("App-Starts für diesen Lauf: \(runner.launches). Der Bericht "
               + "liegt als s1-jit-report.txt im Documents-Verzeichnis der App. "
               + "Wichtig: einmal mit angehängtem Debugger und einmal ohne "
               + "laufen lassen; nur der Lauf ohne Debugger sagt etwas über den "
               + "Alltagsbetrieb aus.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}

private struct ProbeRow: View {
    let outcome: ProbeOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: outcome.fatal
                      ? "bolt.trianglebadge.exclamationmark.fill"
                      : (outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .foregroundStyle(outcome.fatal ? .orange
                                     : (outcome.succeeded ? .green : .red))
                Text(outcome.name).font(.headline)
                Spacer(minLength: 0)
                if outcome.fatal {
                    Text("Prozess beendet")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(.orange.opacity(0.25)))
                }
            }

            if !outcome.fatal {
                StageBar(stage: outcome.stage)
            }

            Text(outcome.detail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if outcome.stage == .executed && outcome.returned != JITPROBE_MAGIC {
                Text("Code lief, lieferte aber \(outcome.returned) statt \(JITPROBE_MAGIC)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Zeigt, wie weit eine Probe gekommen ist. Der Abbruchpunkt ist die
/// eigentliche Information: an "ausführbar gemacht" zu scheitern bedeutet etwas
/// anderes als schon beim Belegen zu scheitern.
private struct StageBar: View {
    let stage: ProbeOutcome.Stage

    private static let all: [ProbeOutcome.Stage] =
        [.allocated, .written, .executable, .executed]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.all, id: \.rawValue) { step in
                let reached = stage.rawValue >= step.rawValue
                Text(step.label)
                    .font(.caption2.weight(reached ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(reached
                            ? Color.accentColor.opacity(0.28)
                            : Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(reached ? .primary : .secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
