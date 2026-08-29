import AVFoundation

@MainActor
struct CameraStatusPresentation {
    let title: String
    let explanation: String
    let symbolName: String

    static func make(for camera: CameraCaptureService) -> Self {
        switch camera.state {
        case .idle:
            Self(
                title: "Caméra inactive",
                explanation: "L’analyse reste sur ce Mac et aucune image n’est enregistrée.",
                symbolName: "video.slash.fill"
            )
        case .requestingPermission:
            Self(
                title: "Autorisation en attente",
                explanation: "Align attend la réponse de macOS.",
                symbolName: "hourglass"
            )
        case .configuring:
            Self(
                title: "Démarrage de la caméra",
                explanation: "Préparation de l’analyse locale…",
                symbolName: "video.fill"
            )
        case .running where camera.trackingMode == nil:
            Self(
                title: "Recherche de posture",
                explanation: "Place-toi face à la caméra pour afficher les repères reconnus.",
                symbolName: "viewfinder"
            )
        case .running where camera.trackingMode == .faceOnly:
            Self(
                title: "Repères partiels",
                explanation: "Le visage est suivi ; le cou et les épaules restent à détecter.",
                symbolName: "face.dashed"
            )
        case .running:
            Self(
                title: "Repères détectés",
                explanation: "Le visage, le cou et les épaules sont suivis localement.",
                symbolName: "viewfinder.circle.fill"
            )
        case .denied:
            Self(
                title: "Accès caméra refusé",
                explanation: "Autorise Align dans Réglages Système › Confidentialité et sécurité › Caméra.",
                symbolName: "exclamationmark.triangle.fill"
            )
        case .unavailable:
            Self(
                title: "Caméra indisponible",
                explanation: "Aucune caméra compatible n’est disponible.",
                symbolName: "video.slash.fill"
            )
        case .interrupted:
            Self(
                title: "Analyse interrompue",
                explanation: "La caméra est momentanément indisponible.",
                symbolName: "pause.circle.fill"
            )
        case .failed:
            Self(
                title: "Erreur caméra",
                explanation: "L’analyse caméra s’est interrompue. Réessaie.",
                symbolName: "exclamationmark.triangle.fill"
            )
        }
    }

    static func startTitle() -> String {
        AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
            ? "Autoriser la caméra"
            : "Démarrer la caméra"
    }
}
