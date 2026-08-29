import AppKit
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var camera: CameraCaptureService
    let onClose: () -> Void

    @FocusState private var closeButtonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics")
                        .font(.title2.weight(.semibold))
                    Text("Benchmark local guidé · 60 s")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .focused($closeButtonFocused)
            }

            Divider()
            technicalDiagnostics
            Divider()
            benchmarkControls
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 220)
        .onAppear {
            closeButtonFocused = true
        }
    }

    @ViewBuilder
    private var technicalDiagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diagnostic technique")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(technicalReport, forType: .string)
                }
                .accessibilityLabel("Copier le diagnostic technique")
            }
            ScrollView {
                Text(technicalReport)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("Diagnostic technique")
            }
            .frame(minHeight: 54, maxHeight: 110)
        }
    }

    private var technicalReport: String {
        if case .failed(let message) = camera.state {
            return "\(camera.diagnostics.summary)\nErreur caméra : \(message)"
        }
        return camera.diagnostics.summary
    }

    @ViewBuilder
    private var benchmarkControls: some View {
        switch camera.benchmarkState {
        case .idle:
            HStack(spacing: 12) {
                Text(idleExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Démarrer benchmark") {
                    camera.startBenchmark(experiment: .upperBodyROI)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(camera.state != .running)
            }

        case .running(let progress):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Étape \(progress.phaseIndex + 1)/\(progress.phaseCount) · \(progress.instruction)")
                        .font(.callout.weight(.medium))
                    ProgressView(value: progress.totalProgress)
                        .accessibilityLabel("Progression du benchmark")
                }
                Button("Annuler") {
                    camera.cancelBenchmark()
                }
            }

        case .completed(let report):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Benchmark terminé")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Copier") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    .accessibilityLabel("Copier le rapport du benchmark")
                    Button("Recommencer") {
                        camera.startBenchmark(experiment: .upperBodyROI)
                    }
                    .disabled(camera.state != .running)
                }
                ScrollView {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel("Rapport du benchmark")
                }
                .frame(minHeight: 160, maxHeight: 280)
            }

        case .invalidated(let reason):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(reason)
                    .font(.callout)
                Spacer()
                Button("Fermer") {
                    camera.cancelBenchmark()
                }
            }
        }
    }

    private var idleExplanation: String {
        camera.state == .running
            ? "Suis les instructions affichées pour mesurer la stabilité du suivi."
            : "Démarre d’abord la caméra pour lancer le benchmark."
    }
}
