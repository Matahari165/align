import SwiftUI

struct ContentView: View {
    let appModel: AppModel
    private var history: PostureHistoryController { appModel.history }
    @Environment(\.openWindow) private var openWindow
    @State private var showsDiagnostics = false
    @State private var showsStatistics = false
    @StateObject private var resourceMonitor = SystemResourceMonitor()
    @State private var isPreviewVisible = true

    var body: some View {
        LiveCameraPane(
            camera: appModel.camera,
            resourceMonitor: resourceMonitor,
            isPreviewVisible: isPreviewVisible
        )
            .frame(minWidth: 560, minHeight: 430)
            .background(AlignTheme.canvas)
            .onAppear {
                appModel.attemptAutomaticCameraStart()
                resourceMonitor.start()
            }
            .onDisappear {
                resourceMonitor.stop()
            }
            .toolbar {
                ToolbarItem {
                    CameraToolbarAction(camera: appModel.camera)
                }
                ToolbarItem {
                    Button {
                        showsStatistics = true
                    } label: {
                        Label("Statistiques…", systemImage: "chart.xyaxis.line")
                            .labelStyle(.iconOnly)
                    }
                    .help("Statistiques…")
                    .accessibilityLabel("Statistiques…")
                }
                ToolbarItem {
                    Button {
                        openWindow(id: "settings")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Réglages…", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                    .help("Réglages…")
                    .accessibilityLabel("Réglages…")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsDiagnostics = true
                    } label: {
                        Label("Diagnostics…", systemImage: "waveform.path.ecg")
                            .labelStyle(.iconOnly)
                    }
                    .help("Diagnostics…")
                    .accessibilityLabel("Diagnostics…")
                }
            }
            .sheet(isPresented: $showsDiagnostics) {
                DiagnosticsView(camera: appModel.camera) {
                    showsDiagnostics = false
                }
            }
            .sheet(isPresented: $showsStatistics) {
                StatisticsView(history: history) { showsStatistics = false }
            }
            .background {
                WindowPresentationReader { presentation in
                    appModel.camera.updatePresentation(
                        isApplicationActive: presentation.usesForegroundCadence,
                        isWindowMiniaturized: presentation.isMiniaturized
                    )
                    resourceMonitor.setPresentationActive(presentation.usesForegroundCadence)
                    isPreviewVisible = presentation.usesForegroundCadence
                }
            }
    }
}

/// Keep high-frequency camera publications inside this subtree. Changes to
/// the app command model and sheet state must not rebuild the live preview.
private struct LiveCameraPane: View {
    @ObservedObject var camera: CameraCaptureService
    let resourceMonitor: SystemResourceMonitor
    let isPreviewVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            SystemResourceUsageBar(monitor: resourceMonitor)

            ZStack {
                CameraPreviewView(
                    session: camera.session,
                    overlay: camera.overlay,
                    diagnosticsEnabled: camera.upperBodyDevelopmentVisualizationEnabled,
                    upperBodyDevelopmentOptions: camera.upperBodyDevelopmentOptions,
                    isPreviewEnabled: isPreviewVisible
                )

                if camera.state != .running {
                    Rectangle()
                        .fill(AlignTheme.canvas.opacity(0.92))
                    Image(systemName: CameraStatusPresentation.make(for: camera).symbolName)
                        .font(.system(size: 30))
                        .foregroundStyle(AlignTheme.accentSoft.opacity(0.86))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aperçu de la caméra")
            .accessibilityValue(accessibilitySummary)

            PostureValidationLivePanel(camera: camera)

            PostureIndicatorsView(
                snapshot: camera.postureIndicators,
                cameraIsRunning: camera.state == .running,
                notificationAuthorization: camera.proximityNotificationAuthorization,
                onRequestNotifications: camera.requestProximityNotificationAuthorization,
                onCalibrate: camera.calibratePosture
            )
        }
    }

    private var accessibilitySummary: String {
        CameraStatusPresentation.make(for: camera).explanation
    }
}

private struct PostureValidationLivePanel: View {
    @ObservedObject var camera: CameraCaptureService

    var body: some View {
        Group {
            switch camera.postureValidationState {
            case .idle:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test caméra des postures")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AlignTheme.ivory)
                        Text("Suis les consignes tout en contrôlant ton cadrage.")
                            .font(.caption2)
                            .foregroundStyle(AlignTheme.quiet)
                    }
                    Spacer(minLength: 8)
                    Button("Tester les postures") {
                        camera.startPostureValidation(mode: .comprehensive20s)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(camera.state != .running)
                }

            case .running(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Étape \(progress.phaseIndex + 1)/\(progress.phaseCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AlignTheme.accentSoft)
                        Text(progress.instruction)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AlignTheme.ivory)
                        Spacer(minLength: 8)
                        Text("\(progress.phaseSecondsRemaining) s")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(AlignTheme.attention)
                        Button("Annuler") {
                            camera.cancelPostureValidation()
                        }
                        .controlSize(.small)
                    }
                    ProgressView(value: progress.phaseProgress)
                        .tint(AlignTheme.accent)
                        .accessibilityLabel("Progression de l'étape")
                        .accessibilityValue("\(progress.phaseSecondsRemaining) secondes restantes")
                }

            case .completed:
                HStack(spacing: 10) {
                    Label("Test terminé", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AlignTheme.accentSoft)
                    Text("Le rapport détaillé reste disponible dans Diagnostics.")
                        .font(.caption2)
                        .foregroundStyle(AlignTheme.quiet)
                    Spacer(minLength: 8)
                    Button("Recommencer") {
                        camera.startPostureValidation(mode: .comprehensive20s)
                    }
                    .controlSize(.small)
                    Button("Fermer") {
                        camera.cancelPostureValidation()
                    }
                    .controlSize(.small)
                }

            case .invalidated(let reason):
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AlignTheme.attention)
                        .accessibilityHidden(true)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(AlignTheme.ivory)
                    Spacer(minLength: 8)
                    Button("Fermer") {
                        camera.cancelPostureValidation()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AlignTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Test guidé des postures")
    }
}

private struct CameraToolbarAction: View {
    @ObservedObject var camera: CameraCaptureService

    @ViewBuilder
    var body: some View {
        switch camera.state {
        case .denied:
            Link(destination: cameraPrivacySettingsURL) {
                Label("Autoriser la caméra", systemImage: "video.slash")
                    .labelStyle(.iconOnly)
            }
            .help("Autoriser la caméra dans les Réglages Système")
            .accessibilityLabel("Autoriser la caméra")
        case .running, .interrupted:
            Button {
                camera.stop()
            } label: {
                Label("Arrêter la caméra", systemImage: "stop.circle")
                    .labelStyle(.iconOnly)
            }
            .help("Arrêter la caméra")
            .accessibilityLabel("Arrêter la caméra")
        case .requestingPermission, .configuring:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Démarrage de la caméra en cours")
        case .idle:
            Button {
                camera.start()
            } label: {
                Label(CameraStatusPresentation.startTitle(), systemImage: "video.fill")
                    .labelStyle(.iconOnly)
            }
            .help(CameraStatusPresentation.startTitle())
            .accessibilityLabel(CameraStatusPresentation.startTitle())
            .keyboardShortcut(.defaultAction)
        case .unavailable, .failed:
            Button {
                camera.start()
            } label: {
                Label("Réessayer la caméra", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Réessayer la caméra")
            .accessibilityLabel("Réessayer la caméra")
        }
    }

    private var cameraPrivacySettingsURL: URL {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            preconditionFailure("The camera privacy settings URL must be valid")
        }
        return url
    }
}
