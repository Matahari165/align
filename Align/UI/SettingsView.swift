import SwiftUI

/// Réglages locaux : cette vue ne démarre jamais la caméra et ne possède
/// aucune logique d'évaluation. Elle appelle uniquement les APIs d'AppModel.
struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var camera: CameraCaptureService
    let onClose: () -> Void
    @FocusState private var closeFocused: Bool
    @State private var confirmsErase = false

    private let signals = PostureObservationSignalID.alertableCases

    var body: some View {
        Form {
            Section("Sensibilité des recommandations") {
                Picker("Sensibilité", selection: Binding(
                    get: { appModel.recommendationSensitivity },
                    set: { appModel.setRecommendationSensitivity($0) }
                )) {
                    Text("Discrète").tag(PostureRecommendationSensitivity.discreet)
                    Text("Équilibrée").tag(PostureRecommendationSensitivity.balanced)
                    Text("Sensible").tag(PostureRecommendationSensitivity.sensitive)
                }
                Text(sensitivityDescription(appModel.recommendationSensitivity))
                    .font(.caption).foregroundStyle(.secondary)
                if appModel.recommendationSensitivity == .sensitive {
                    Text("Ce mode peut rappeler plus souvent afin de limiter les variations manquées.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Rappels") {
                ForEach(signals, id: \.self) { id in
                    alertRow(id)
                }
            }

            Section("Notifications") {
                switch camera.proximityNotificationAuthorization {
                case .authorized:
                    Label("Notifications activées", systemImage: "bell.badge")
                case .denied:
                    Label("Notifications désactivées dans macOS", systemImage: "bell.slash")
                    Link("Ouvrir Réglages Système…", destination: notificationSettingsURL)
                case .unknown:
                    Button("Autoriser les notifications…") {
                        camera.requestProximityNotificationAuthorization()
                    }
                }
            }

            Section("Repères") {
                Text("Définis un repère personnel dans une position confortable. Chaque signal est validé séparément.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Définir mes repères…") {
                    camera.calibratePosture()
                }
                if camera.calibrationPresentation.phase != .idle {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(camera.calibrationPresentation.title)
                            .font(.callout.weight(.semibold))
                        if case .collecting = appModel.camera.calibrationPresentation.phase {
                            ProgressView(value: camera.calibrationPresentation.progress)
                                .accessibilityLabel("Progression de la définition des repères")
                        }
                        ForEach(PostureObservationSignalID.allCases, id: \.self) { id in
                            calibrationOutcome(id)
                        }
                    }
                }
                Text("La calibration reste locale à ce Mac et ne conserve aucune image.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Données") {
                Text("Les statistiques sont conservées uniquement sur ce Mac pendant 90 jours.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Effacer l’historique local…") {
                    confirmsErase = true
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AlignTheme.canvas)
        .navigationTitle("Réglages")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fermer", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .focused($closeFocused)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 430, idealHeight: 560)
        .onAppear { closeFocused = true }
        .confirmationDialog("Effacer l’historique local ?", isPresented: $confirmsErase, titleVisibility: .visible) {
            Button("Effacer l’historique", role: .destructive) {
                Task { await appModel.history.erase() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action supprime les statistiques enregistrées sur ce Mac.")
        }
    }

    @ViewBuilder
    private func alertRow(_ id: PostureObservationSignalID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(signalTitle(id), isOn: Binding(
                get: { appModel.isAlertEnabled(id) },
                set: { appModel.setAlertEnabled($0, for: id) }
            ))
            let control = appModel.alertControl(id)
            if control.isEnabled {
                HStack {
                    Menu("Me le rappeler plus tard") {
                        Button("1 h") { appModel.snoozeAlert(id, choice: .oneHour) }
                        Button("Aujourd’hui") { appModel.snoozeAlert(id, choice: .today) }
                        Button("Jusqu’à réactivation") { appModel.snoozeAlert(id, choice: .untilReactivation) }
                    }
                    .menuStyle(.borderlessButton)
                    if let until = control.snoozedUntil, until > Date().timeIntervalSince1970 {
                        Text("Suspendu jusqu’à \(Date(timeIntervalSince1970: until), style: .time)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Réactiver maintenant") { appModel.reactivateAlert(id) }
                            .buttonStyle(.link).font(.caption)
                    } else if control.isSnoozedUntilReactivation {
                        Text("Suspendu jusqu’à réactivation")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Réactiver maintenant") { appModel.reactivateAlert(id) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            } else {
                Text("Rappel désactivé")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func signalTitle(_ id: PostureObservationSignalID) -> String {
        switch id {
        case .proximity: "Proximité apparente"
        case .torsoInclination: "Torse incliné"
        case .raisedShoulders: "Épaules relevées"
        case .shoulderSlope: "Inclinaison des épaules — Observation sans rappel"
        case .estimatedBlinks: "Clignements estimés — Expérimental"
        case .closedShoulders: "Épaules refermées — Expérimental, sans rappel"
        }
    }

    private func sensitivityDescription(_ value: PostureRecommendationSensitivity) -> String {
        switch value {
        case .discreet: "Signale seulement les variations nettes et durables."
        case .balanced: "Signale les variations modérées qui persistent."
        case .sensitive: "Privilégie les rappels, y compris pour les légères variations qui durent."
        }
    }

    private func calibrationOutcome(_ id: PostureObservationSignalID) -> some View {
        let outcome = camera.calibrationPresentation.outcomes[id] ?? .pending
        let label: String
        let symbol: String
        switch outcome {
        case .pending: label = "En attente"; symbol = "ellipsis.circle"
        case .ready: label = "Repère prêt"; symbol = "checkmark.circle"
        case .unavailable(let reason): label = "Données insuffisantes — \(reason)"; symbol = "minus.circle"
        }
        return Label("\(signalShortTitle(id)) · \(label)", systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(signalShortTitle(id)), \(label)")
    }

    private func signalShortTitle(_ id: PostureObservationSignalID) -> String {
        switch id {
        case .proximity: "Distance"
        case .torsoInclination: "Torse"
        case .raisedShoulders: "Épaules"
        case .shoulderSlope: "Inclinaison des épaules"
        case .estimatedBlinks: "Clignements estimés"
        case .closedShoulders: "Épaules refermées"
        }
    }

    private var notificationSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    }
}
