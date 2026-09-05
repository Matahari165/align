import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var camera: CameraCaptureService
    private var history: PostureHistoryController { appModel.history }
    @Environment(\.openWindow) private var openWindow
    @State private var showsDiagnostics = false
    @State private var showsStatistics = false

    init(appModel: AppModel) {
        self.appModel = appModel
        _camera = ObservedObject(wrappedValue: appModel.camera)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreviewView(
                    session: camera.session,
                    overlay: camera.overlay,
                    diagnosticsEnabled: camera.upperBodyDevelopmentVisualizationEnabled,
                    upperBodyDevelopmentOptions: camera.upperBodyDevelopmentOptions
                )

                if camera.state == .running,
                   camera.upperBodyDevelopmentVisualizationEnabled {
                    VStack {
                        HStack {
                            Label("DÉVELOPPEMENT · estimations 2D", systemImage: "wrench.and.screwdriver")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(AlignTheme.canvas.opacity(0.94), in: Capsule())
                                .overlay(Capsule().stroke(AlignTheme.hairline, lineWidth: 1))
                                .foregroundStyle(AlignTheme.accentSoft)
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Text(camera.upperBodyDevelopmentSummary)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AlignTheme.elevated.opacity(0.92), in: Capsule())
                                .overlay(Capsule().stroke(AlignTheme.hairline, lineWidth: 1))
                                .foregroundStyle(AlignTheme.ivory)
                            Spacer()
                        }
                    }
                    .padding(10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Mode développement, estimations 2D. \(camera.upperBodyDevelopmentSummary)"
                    )
                }

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

            statusBand
        }
        .frame(minWidth: 560, minHeight: 430)
        .background(AlignTheme.canvas)
        .onAppear {
            appModel.attemptAutomaticCameraStart()
        }
        .toolbar {
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
            DiagnosticsView(camera: camera) {
                showsDiagnostics = false
            }
        }
        .sheet(isPresented: $showsStatistics) {
            StatisticsView(history: history) { showsStatistics = false }
        }
        .background {
            WindowPresentationReader { presentation in
                camera.updatePresentation(
                    isApplicationActive: presentation.usesForegroundCadence,
                    isWindowMiniaturized: presentation.isMiniaturized
                )
            }
        }
    }

    private var statusBand: some View {
        let presentation = activePresentation
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AlignTheme.accent.opacity(0.14))
                Image(systemName: presentation.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AlignTheme.accent)
            }
            .frame(width: 27, height: 27)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                    .foregroundStyle(AlignTheme.ivory)
                Text(presentation.explanation)
                    .font(.callout)
                    .foregroundStyle(AlignTheme.quiet)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
            windowCameraAction
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AlignTheme.elevated.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AlignTheme.hairline)
                .frame(height: 1)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var windowCameraAction: some View {
        switch camera.state {
        case .denied:
            Link("Ouvrir Réglages Système…", destination: cameraPrivacySettingsURL)
                .buttonStyle(.borderedProminent)
        case .running, .interrupted:
            Button("Arrêter") {
                camera.stop()
            }
            .buttonStyle(.bordered)
        case .requestingPermission, .configuring:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Démarrage de la caméra en cours")
        case .idle:
            Button(CameraStatusPresentation.startTitle()) {
                camera.start()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .unavailable, .failed:
            Button("Réessayer") {
                camera.start()
            }
            .buttonStyle(.bordered)
        }
    }

    private var accessibilitySummary: String {
        activePresentation.explanation
    }

    private var activePresentation: CameraStatusPresentation {
        guard camera.state == .running else {
            return CameraStatusPresentation.make(for: camera)
        }
        let shoulders = ShoulderStatusPresentation.make(for: camera.blazePoseState)
        return CameraStatusPresentation(
            title: shoulders.title,
            explanation: shoulders.explanation,
            symbolName: shoulders.symbolName
        )
    }

    private var cameraPrivacySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    }
}
