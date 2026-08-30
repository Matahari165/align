import SwiftUI

struct ContentView: View {
    @ObservedObject var camera: CameraCaptureService
    @State private var showsDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreviewView(session: camera.session, overlay: camera.overlay)

                if camera.state == .running {
                    VStack {
                        HStack {
                            Text(camera.blazePoseState.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.68), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }

                if camera.state != .running {
                    Rectangle()
                        .fill(.black.opacity(0.78))
                    inactiveCameraMessage
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aperçu de la caméra")
            .accessibilityValue(accessibilitySummary)

            statusBand
        }
        .frame(minWidth: 560, minHeight: 430)
        .toolbar {
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
        .background {
            WindowPresentationReader { presentation in
                camera.updatePresentation(
                    isApplicationActive: presentation.usesForegroundCadence,
                    isWindowMiniaturized: presentation.isMiniaturized
                )
            }
        }
    }

    private var inactiveCameraMessage: some View {
        let presentation = CameraStatusPresentation.make(for: camera)
        return VStack(spacing: 10) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 28))
            Text(presentation.title)
                .font(.headline)
            Text(presentation.explanation)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    private var statusBand: some View {
        let presentation = CameraStatusPresentation.make(for: camera)
        return HStack(spacing: 12) {
            Image(systemName: presentation.symbolName)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
            windowCameraAction
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
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
        CameraStatusPresentation.make(for: camera).explanation
    }

    private var cameraPrivacySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    }
}
