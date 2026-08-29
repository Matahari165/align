//
//  ContentView.swift
//  Align
//
//  Created by Jérémy Delloume on 28/08/2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraCaptureService()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreviewView(session: camera.session, overlay: camera.overlay)

                if camera.state != .running {
                    Rectangle()
                        .fill(.black.opacity(0.78))
                    VStack(spacing: 10) {
                        Image(systemName: stateIcon)
                            .font(.system(size: 28))
                        Text(stateTitle)
                            .font(.headline)
                        Text(stateExplanation)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aperçu de la caméra")
            .accessibilityValue(accessibilitySummary)

            HStack(spacing: 12) {
                Image(systemName: stateIcon)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stateTitle)
                        .font(.headline)
                    Text(stateExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if showsDiagnostics {
                        Text(camera.diagnostics.summary)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                if camera.state == .denied {
                    Link("Ouvrir Réglages Système", destination: cameraPrivacySettingsURL)
                        .buttonStyle(.borderedProminent)
                } else if camera.state == .running || camera.state == .interrupted {
                    Button("Arrêter") {
                        camera.stop()
                    }
                } else if camera.state != .requestingPermission && camera.state != .configuring {
                    Button("Autoriser la caméra") {
                        camera.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 560, minHeight: 430)
        .onDisappear {
            camera.stop()
        }
    }

    private var stateIcon: String {
        switch camera.state {
        case .running:
            "video.fill"
        case .denied, .failed, .unavailable, .interrupted:
            "exclamationmark.triangle.fill"
        case .requestingPermission, .configuring:
            "hourglass"
        case .idle:
            "video.slash.fill"
        }
    }

    private var showsDiagnostics: Bool {
        switch camera.state {
        case .running, .failed:
            true
        default:
            false
        }
    }

    private var accessibilitySummary: String {
        guard camera.state == .running else { return camera.state.message }
        switch camera.trackingMode {
        case .faceOnly:
            return "Analyse locale active. Visage suivi."
        case .bodyAvailable:
            return "Analyse locale active. Visage, cou et épaules suivis."
        case nil:
            return "Analyse locale active. Recherche de posture."
        }
    }

    private var stateTitle: String {
        switch camera.state {
        case .idle:
            "Autorise la caméra"
        case .requestingPermission:
            "Autorisation en attente"
        case .configuring:
            "Démarrage de la caméra"
        case .running where camera.trackingMode == nil:
            "Recherche de posture"
        case .running where camera.trackingMode == .faceOnly:
            "Visage suivi"
        case .running:
            "Pose détectée"
        case .denied:
            "Accès caméra refusé"
        case .unavailable:
            "Caméra indisponible"
        case .interrupted:
            "Analyse interrompue"
        case .failed:
            "Erreur caméra"
        }
    }

    private var stateExplanation: String {
        switch camera.state {
        case .idle:
            "L’image sera analysée uniquement sur ce Mac et ne sera jamais enregistrée."
        case .running where camera.trackingMode == nil:
            "Place-toi face à la caméra pour faire apparaître les points reconnus."
        case .running where camera.trackingMode == .faceOnly:
            "Le visage est suivi localement. Le cou et les épaules ne sont pas encore visibles."
        case .running:
            "\(camera.recognizedPointCount) points reconnus et analysés localement."
        default:
            camera.state.message
        }
    }

    private var cameraPrivacySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    }
}
