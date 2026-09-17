import SwiftUI

struct ContentView: View {
    let appModel: AppModel
    private var history: PostureHistoryController { appModel.history }
    @Environment(\.openWindow) private var openWindow
    @State private var showsDiagnostics = false
    @State private var showsStatistics = false
    @StateObject private var resourceMonitor = SystemResourceMonitor()

    var body: some View {
        LiveCameraPane(camera: appModel.camera, resourceMonitor: resourceMonitor)
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
                }
            }
    }
}

/// Keep high-frequency camera publications inside this subtree. Changes to
/// the app command model and sheet state must not rebuild the live preview.
private struct LiveCameraPane: View {
    @ObservedObject var camera: CameraCaptureService
    let resourceMonitor: SystemResourceMonitor

    var body: some View {
        VStack(spacing: 0) {
            SystemResourceUsageBar(monitor: resourceMonitor)

            ZStack {
                CameraPreviewView(
                    session: camera.session,
                    overlay: camera.overlay,
                    diagnosticsEnabled: camera.upperBodyDevelopmentVisualizationEnabled,
                    upperBodyDevelopmentOptions: camera.upperBodyDevelopmentOptions
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
