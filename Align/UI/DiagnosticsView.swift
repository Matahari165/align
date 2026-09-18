import AppKit
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var camera: CameraCaptureService
    let onClose: () -> Void

    @FocusState private var closeButtonFocused: Bool
    @State private var postureValidationMode: PostureValidationMode = .measurement20s

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics")
                        .font(.title2.weight(.semibold))
                    Text("Benchmark local · validation géométrique")
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
            upperBodyVisualization
            Divider()
            technicalDiagnostics
            Divider()
            benchmarkControls
            Divider()
            postureValidationControls
        }
        .padding(20)
        .background(AlignTheme.canvas)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 220)
        .onAppear {
            closeButtonFocused = true
        }
    }

    private var upperBodyVisualization: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Visualisation du moteur",
                isOn: Binding(
                    get: { camera.upperBodyDevelopmentVisualizationEnabled },
                    set: camera.setUpperBodyDevelopmentVisualizationEnabled
                )
            )
            .font(.callout.weight(.medium))

            HStack(spacing: 12) {
                developmentOption("Points", \.showsLandmarks)
                developmentOption("Connexions", \.showsConnections)
                developmentOption("Axes", \.showsAxes)
                developmentOption("ROI", \.showsROI)
                developmentOption("Libellés", \.showsValues)
            }
            .controlSize(.small)
            .disabled(!camera.upperBodyDevelopmentVisualizationEnabled)

            Text(camera.upperBodyDevelopmentSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Mode développement, estimations 2D. \(camera.upperBodyDevelopmentSummary)"
                )
        }
    }

    private func developmentOption(
        _ title: String,
        _ keyPath: WritableKeyPath<UpperBodyDevelopmentOptions, Bool>
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { camera.upperBodyDevelopmentOptions[keyPath: keyPath] },
                set: { value in
                    camera.updateUpperBodyDevelopmentOptions { options in
                        options[keyPath: keyPath] = value
                    }
                }
            )
        )
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

    @ViewBuilder
    private var postureValidationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Validation guidée de la géométrie")
                .font(.callout.weight(.medium))
            Text("Angles, proximité apparente et torse · aucune image ni coordonnée enregistrée.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch camera.postureValidationState {
            case .idle:
                HStack(spacing: 12) {
                    Picker("Durée", selection: $postureValidationMode) {
                        Text("Mesure · 20 s/phase").tag(PostureValidationMode.measurement20s)
                        Text("Postures complètes · 20 s/phase")
                            .tag(PostureValidationMode.comprehensive20s)
                        Text("Notification · 60 s/phase").tag(PostureValidationMode.notification60s)
                    }
                    .pickerStyle(.menu)
                    .disabled(camera.state != .running)

                    Spacer()
                    Button("Démarrer validation") {
                        camera.startPostureValidation(mode: postureValidationMode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(camera.state != .running)
                }

            case .running(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Étape \(progress.phaseIndex + 1)/\(progress.phaseCount) · \(progress.instruction)")
                        .font(.callout.weight(.medium))
                    ProgressView(value: progress.totalProgress)
                        .accessibilityLabel("Progression de la validation posture")
                    Text(progress.mode == .measurement20s
                         ? "Mesure 20 secondes par phase"
                         : "Mesure 60 secondes par phase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Annuler") {
                    camera.cancelPostureValidation()
                }

            case .completed(let report):
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Validation terminée")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("Copier") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                        .accessibilityLabel("Copier le rapport de validation posture")
                        Button("Recommencer") {
                            camera.startPostureValidation(mode: postureValidationMode)
                        }
                        .disabled(camera.state != .running)
                    }
                    ScrollView {
                        Text(report)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityLabel("Rapport de validation posture")
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
                        camera.cancelPostureValidation()
                    }
                }
            }
        }
    }
}
