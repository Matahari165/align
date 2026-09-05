import AppKit
import SwiftUI

struct StatusMenuLabel: View {
    @ObservedObject var camera: CameraCaptureService

    var body: some View {
        let presentation = CameraStatusPresentation.make(for: camera)
        Image(systemName: presentation.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(AlignTheme.accent)
            .accessibilityLabel("Align — \(presentation.title)")
    }
}

struct StatusMenuView: View {
    @ObservedObject var camera: CameraCaptureService
    let onQuit: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = CameraStatusPresentation.make(for: camera)

        Text(presentation.title)
        Divider()
        Button("Ouvrir Align…") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Statistiques…") {
            openWindow(id: "statistics")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Réglages…") {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        menuCameraAction
        if camera.state == .denied {
            Link("Ouvrir Réglages Système…", destination: cameraPrivacySettingsURL)
        }
        Divider()
        Button("Quitter Align") {
            onQuit()
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var menuCameraAction: some View {
        switch camera.state {
        case .running, .interrupted:
            Button("Arrêter la caméra") {
                camera.stop()
            }
        case .requestingPermission, .configuring:
            Button("Démarrage en cours…") {}
                .disabled(true)
        case .denied:
            EmptyView()
        case .idle, .unavailable, .failed:
            Button(CameraStatusPresentation.startTitle()) {
                camera.start()
            }
        }
    }

    private var cameraPrivacySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    }
}
