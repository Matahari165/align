import Foundation

private func source(_ relativePath: String) throws -> String {
    try String(contentsOfFile: relativePath, encoding: .utf8)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let content = try source("Align/ContentView.swift")
let indicators = try source("Align/UI/PostureIndicatorsView.swift")
let shoulders = try source("Align/UI/ShoulderStatusPresentation.swift")
let diagnostics = try source("Align/UI/DiagnosticsView.swift")
let settings = try source("Align/UI/SettingsView.swift")
let calibration = try source("Align/UI/CalibrationPresentation.swift")
let cameraCapture = try source("Align/Camera/CameraCaptureService.swift")
let appModel = try source("Align/AppModel.swift")
let appIcon = try source("Align/Assets.xcassets/AppIcon.appiconset/Contents.json")

require(content.contains("minWidth: 560, minHeight: 430"), "La taille minimale macOS doit rester 560 × 430.")
require(content.contains("layoutPriority(1)"), "La caméra doit rester la zone dominante.")
require(!content.contains("inactiveCameraMessage"), "Le statut caméra inactif ne doit pas être dupliqué dans l’aperçu.")
require(!content.contains("camera.proximityAlertBanner"), "Aucune troisième bannière ne doit recouvrir la caméra.")
require(!content.contains("blazePoseState.displayName"), "Aucun badge d’état redondant ne doit recouvrir la caméra.")

for id in [
    "apparentProximity", "torsoInclination", "raisedShoulders",
    "shoulderSlope", "closedShoulders", "estimatedBlinks"
] {
    require(indicators.contains("indicator(for: .\(id))"), "Signal absent du rail complet : \(id)")
}
require(indicators.contains("threeColumnGrid") && indicators.contains("twoColumnGrid"),
        "Le rail doit proposer les dispositions 3 × 2 et 2 × 3.")
require(indicators.contains("ViewThatFits"), "Le rail doit sélectionner une grille adaptée à la largeur.")
require(indicators.contains("Indicateurs de posture, six"), "Le groupe VoiceOver doit annoncer six indicateurs.")
require(indicators.contains("case .positive: AlignTheme.ivory") &&
        indicators.contains("case .negative: AlignTheme.copper"),
        "Le rail doit utiliser les rôles premium ivoire/cuivre issus du presenter fiabilisé.")
require(!indicators.contains(".green") && !indicators.contains(".red") &&
        !indicators.contains(".yellow") && !indicators.contains(".orange"),
        "Le rail ne doit pas dépendre des couleurs santé rouge/vert ni du jaune de géométrie.")

for title in ["Recherche des épaules", "Épaules détectées", "Épaules partiellement détectées", "Épaules non détectées", "Erreur d’analyse"] {
    require(shoulders.contains(title), "État épaules manquant : \(title)")
}
require(!shoulders.localizedCaseInsensitiveContains("LiteRT"), "Le moteur ne doit pas apparaître dans la microcopie normale.")
require(diagnostics.contains("developmentOption(\"ROI\", \\.showsROI)"),
        "Le contrôle ROI Diagnostics doit piloter l’option réelle du builder.")
for option in [
    "developmentOption(\"Points\", \\.showsLandmarks)",
    "developmentOption(\"Connexions\", \\.showsConnections)",
    "developmentOption(\"Axes\", \\.showsAxes)",
    "developmentOption(\"ROI\", \\.showsROI)",
    "developmentOption(\"Libellés\", \\.showsValues)"
] {
    require(diagnostics.contains(option), "Option de visualisation moteur absente : \(option)")
}
require(!diagnostics.contains("developmentOption(\"Silhouette\"") &&
        !diagnostics.contains("Trace 0,5 s"),
        "La surface principale du mode développement doit rester limitée aux cinq options utiles.")
require(!diagnostics.contains("Toggle(\"ROI\", isOn: .constant(false))"),
        "Le contrôle ROI ne doit plus être une option factice désactivée.")
require(settings.contains("Sensibilité des recommandations") && settings.contains("Sensible"),
        "Les réglages doivent exposer la sensibilité.")
require(settings.contains("if appModel.recommendationSensitivity == .sensitive"),
        "L'aide de rappel fréquent doit être réservée au mode Sensible.")
require(!cameraCapture.contains("posturePipeline") && !cameraCapture.contains("publishPosture"),
        "Le pipeline historique ne doit plus publier le rail produit.")
require(cameraCapture.contains("didStartRunningNotification") &&
        cameraCapture.contains("reconcileRunningSession") &&
        cameraCapture.contains("wantsCameraRunning") &&
        cameraCapture.contains("sessionReconciliationSuppressed"),
        "L’état publié doit se réconcilier avec la session caméra réelle.")
require(cameraCapture.contains("guard !sessionReconciliationSuppressed, session.isRunning else { return }"),
        "Une session active autorisée doit converger même si le callback initial est obsolète.")
require(cameraCapture.contains("onFrameLiveness") &&
        cameraCapture.contains("reconcileFrameLiveness(epoch: epoch)"),
        "Le premier échantillon vidéo doit pouvoir réconcilier l’état indépendamment des événements d’analyse.")
require(cameraCapture.contains("upperBodyLastRejectionReason") &&
        cameraCapture.contains("upperBodyEngineDurationP95") &&
        cameraCapture.contains("postInferenceExpired"),
        "Les rejets upper-body et la latence moteur doivent être exposés comme diagnostics scalaires.")
if let capture = cameraCapture.range(of: "func captureOutput"),
   let frame = cameraCapture[capture.lowerBound...].range(of: "onFrameLiveness(livenessEpoch)"),
   let activeGuard = cameraCapture[capture.lowerBound...].range(of: "guard isActive else { return }") {
    require(frame.lowerBound < activeGuard.lowerBound,
            "La preuve de trame doit être publiée avant la garde isActive.")
} else {
    require(false, "Le callback de liveness du flux vidéo est absent.")
}
require(cameraCapture.contains("livenessEpoch &+= 1") &&
        cameraCapture.contains("startIntentEpoch = nil"),
        "Un arrêt explicite doit invalider les trames tardives.")
require(cameraCapture.contains("explicitStopRequested = true") &&
        cameraCapture.contains("explicitStopRequested = false"),
        "Le blocage d’une frame tardive doit dépendre d’un arrêt explicite.")
if let liveness = cameraCapture.range(of: "private func reconcileFrameLiveness"),
   let endRange = cameraCapture[liveness.lowerBound...].range(of: "\n    private func setPoseProcessingActive") {
    let end = endRange.lowerBound
    let body = cameraCapture[liveness.lowerBound..<end]
    require(body.contains("guard !explicitStopRequested") &&
            !body.contains("startIntentEpoch ==") &&
            !body.contains("epoch == livenessEpoch"),
            "Une frame réelle ne doit pas être rejetée par l’epoch du callback de démarrage.")
} else {
    require(false, "La réconciliation de liveness est absente.")
}
require(appModel.contains("didAttemptAutomaticCameraStart") &&
        appModel.contains("attemptAutomaticCameraStart()") &&
        appModel.contains("AVCaptureDevice.authorizationStatus(for: .video)"),
        "Le démarrage automatique doit être unique et conditionné par l’autorisation.")
require(content.contains("appModel.attemptAutomaticCameraStart()"),
        "La fenêtre principale doit déclencher le démarrage automatique une seule fois.")
require(content.contains("@ObservedObject private var camera") &&
        content.contains("_camera = ObservedObject(wrappedValue: appModel.camera)"),
        "ContentView doit observer directement l’unique service caméra partagé.")
require(cameraCapture.contains("else if self.state == .configuring"),
        "didStopRunning ne doit pas écraser un état failed/interrupted déjà publié.")
require(cameraCapture.contains("requestAccess(for: .video)") &&
        cameraCapture.contains("case .requestingPermission") &&
        cameraCapture.contains("configureAndStart(operationID:"),
        "Le cycle permission → démarrage doit rester explicite et testable.")
for title in ["Proximité apparente", "Torse incliné", "Épaules relevées", "Clignements estimés — Expérimental"] {
    require(settings.contains(title), "Rappel absent des réglages : \(title)")
}
require(!settings.contains("Toggle(\"Inclinaison des épaules") &&
        !settings.contains("Toggle(\"Épaules refermées"),
        "La pente et l'ouverture ne doivent pas devenir des rappels.")
require(settings.contains("private let signals = PostureObservationSignalID.alertableCases"),
        "Les réglages de rappels doivent utiliser la liste canonique de quatre signaux.")
for choice in ["1 h", "Aujourd’hui", "Jusqu’à réactivation"] {
    require(settings.contains(choice), "Choix de suspension absent : \(choice)")
}
require(settings.contains("Progression de la définition") && calibration.contains("Définition de tes repères…") && calibration.contains("Calibration incomplète"),
        "La calibration doit publier une progression et un échec explicite.")

for size in [16, 32, 64, 128, 256, 512, 1024] {
    require(appIcon.contains("AlignIcon-\(size).png"), "Rendition AppIcon manquante : \(size) px")
}

print("UIReferenceLockHarness: OK")
