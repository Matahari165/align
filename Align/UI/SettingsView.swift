import SwiftUI

/// Réglages locaux : cette vue ne démarre jamais la caméra et ne possède
/// aucune logique d'évaluation. Elle appelle uniquement les APIs d'AppModel.
struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var camera: CameraCaptureService
    let onClose: () -> Void
    @FocusState private var closeFocused: Bool
    @State private var confirmsErase = false
    @State private var testingNotification = false
    @State private var notificationTestMessage: String?

    private let signals = PostureObservationSignalID.alertableCases

    var body: some View {
        Form {
            Section("Analyse du corps") {
                Picker("Modèle", selection: Binding(
                    get: { camera.upperBodyModelMode },
                    set: { camera.setUpperBodyModelMode($0) }
                )) {
                    ForEach(UpperBodyModelMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(camera.upperBodyModelMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Le visage et les clignements utilisent le même suivi dans les deux modes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    Text("Les rappels peuvent revenir fréquemment pendant un même épisode, uniquement quand le signal est fiable, disponible et récent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Rappels") {
                ForEach(signals, id: \.self) { id in
                    alertRow(id)
                }
            }

            Section("Pause visuelle 20-20-20") {
                Toggle("Pause visuelle", isOn: Binding(
                    get: { appModel.screenBreakSettings.isEnabled },
                    set: { appModel.setScreenBreakEnabled($0) }
                ))
                .accessibilityLabel("Activer la pause visuelle")
                Text("Après un temps d’écran continu, tout l’écran se floute doucement avec un rappel et un compte à rebours, puis s’efface seul.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(
                    "Écran continu : \(Int(appModel.screenBreakSettings.workMinutes)) min",
                    value: Binding(
                        get: { appModel.screenBreakSettings.workMinutes },
                        set: { appModel.setScreenBreakWorkMinutes($0) }
                    ),
                    in: 1...120, step: 1
                )
                .disabled(!appModel.screenBreakSettings.isEnabled)
                .accessibilityLabel("Intervalle avant pause, en minutes")
                Stepper(
                    "Durée de la pause : \(Int(appModel.screenBreakSettings.breakSeconds)) s",
                    value: Binding(
                        get: { appModel.screenBreakSettings.breakSeconds },
                        set: { appModel.setScreenBreakBreakSeconds($0) }
                    ),
                    in: 5...120, step: 5
                )
                .disabled(!appModel.screenBreakSettings.isEnabled)
                .accessibilityLabel("Durée de la pause, en secondes")
                Toggle("Écran flouté plein-écran", isOn: Binding(
                    get: { appModel.screenBreakSettings.usesFullscreenOverlay },
                    set: { appModel.setScreenBreakUsesFullscreenOverlay($0) }
                ))
                .disabled(!appModel.screenBreakSettings.isEnabled)
                Toggle("Notification en plus", isOn: Binding(
                    get: { appModel.screenBreakSettings.sendsNotification },
                    set: { appModel.setScreenBreakSendsNotification($0) }
                ))
                .disabled(!appModel.screenBreakSettings.isEnabled)
                Button("Tester la pause plein-écran") {
                    appModel.previewScreenBreakOverlay()
                }
                .disabled(!appModel.screenBreakSettings.isEnabled)
            }

            Section("Notifications") {
                switch camera.proximityNotificationAuthorization {
                case .authorized:
                    Label("Notifications activées", systemImage: "bell.badge")
                    Text("Le style d’affichage et le son des rappels se règlent dans macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Son et affichage dans macOS…", destination: notificationSettingsURL)
                    Button("Tester un rappel") {
                        testingNotification = true
                        notificationTestMessage = nil
                        Task { @MainActor in
                            let sent = await appModel.sendTestNotification()
                            testingNotification = false
                            notificationTestMessage = sent
                                ? "Rappel de test envoyé."
                                : "Le rappel de test n’a pas pu être envoyé."
                        }
                    }
                    .disabled(testingNotification)
                    if let notificationTestMessage {
                        Text(notificationTestMessage)
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                Text("La posture utilise une référence géométrique commune : les angles sont mesurés par rapport aux axes de l’image et la proximité par rapport à la taille apparente du visage. Seule l’ouverture habituelle de tes yeux est mesurée ici pour les clignements.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Initialiser la référence des yeux…") {
                    camera.calibratePosture()
                }
                if camera.calibrationPresentation.phase != .idle {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(camera.calibrationPresentation.title)
                            .font(.callout.weight(.semibold))
                        if case .collecting = appModel.camera.calibrationPresentation.phase {
                            ProgressView(value: camera.calibrationPresentation.progress)
                                .accessibilityLabel("Progression de la mesure de l’ouverture des yeux")
                        }
                        ForEach([PostureObservationSignalID.estimatedBlinks], id: \.self) { id in
                            calibrationOutcome(id)
                        }
                    }
                }
                Text("La mesure reste locale à ce Mac et ne conserve aucune image.")
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
        case .shoulderSlope: "Épaules inclinées"
        case .estimatedBlinks: "Clignements estimés"
        case .closedShoulders: "Tête–épaules"
        case .headTilt: "Tête inclinée"
        case .handOnFace: "Main sur le visage"
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
        case .ready: label = "Référence prête"; symbol = "checkmark.circle"
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
        case .closedShoulders: "Tête–épaules"
        case .headTilt: "Tête inclinée"
        case .handOnFace: "Main sur le visage"
        }
    }

    private var notificationSettingsURL: URL {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            preconditionFailure("The notification settings URL must be valid")
        }
        return url
    }
}
