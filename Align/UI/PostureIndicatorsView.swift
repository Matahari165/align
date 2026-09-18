import SwiftUI

struct PostureIndicatorsView: View {
    let snapshot: PostureIndicatorsSnapshot
    let cameraIsRunning: Bool
    let notificationAuthorization: LocalPostureNotificationService.Authorization
    let onRequestNotifications: () -> Void
    let onCalibrate: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Indicateurs de posture")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AlignTheme.ivory)
                    Label(railStatus, systemImage: railStatusSymbol)
                        .font(.caption2)
                        .foregroundStyle(railStatusColor)
                }
                Spacer(minLength: 8)
                controls
            }

            ViewThatFits(in: .horizontal) {
                threeColumnGrid
                twoColumnGrid
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AlignTheme.elevated.opacity(0.94))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Indicateurs de posture, sept")
    }

    private var threeColumnGrid: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                indicator(for: .shoulderSlope)
                indicator(for: .raisedShoulders)
                indicator(for: .headTilt)
            }
            GridRow {
                indicator(for: .apparentProximity)
                indicator(for: .torsoInclination)
                indicator(for: .estimatedBlinks)
            }
            GridRow {
                indicator(for: .handOnFace)
            }
        }
        .frame(minWidth: 570)
    }

    private var twoColumnGrid: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                indicator(for: .shoulderSlope)
                indicator(for: .raisedShoulders)
            }
            GridRow {
                indicator(for: .headTilt)
                indicator(for: .apparentProximity)
            }
            GridRow {
                indicator(for: .torsoInclination)
                indicator(for: .estimatedBlinks)
            }
            GridRow {
                indicator(for: .handOnFace)
            }
        }
    }

    private func indicator(for id: PostureIndicatorID) -> some View {
        let presentation = PostureIndicatorPresentation.make(
            for: snapshot.result(for: id), producedAt: snapshot.producedAt
        )
        let toneColor = color(for: presentation.tone)
        return HStack(alignment: .top, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(toneColor.opacity(0.16))
                Image(systemName: presentation.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(toneColor)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(presentation.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AlignTheme.ivory)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)

                HStack(spacing: 6) {
                    if showsPrimaryValue(for: presentation) {
                        Text(compactPrimaryValue(for: id, presentation: presentation))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(toneColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    if let secondaryValue = presentation.secondaryValue {
                        Text(secondaryValue)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(toneColor.opacity(0.86))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(minHeight: 17, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AlignTheme.surface.opacity(0.40), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(accessibilityHint(for: id))
        .help(availabilityHelp(for: id))
    }

    private func showsPrimaryValue(for presentation: PostureIndicatorPresentation) -> Bool {
        presentation.tone != .positive ||
            (presentation.secondaryValue == nil && presentation.isExperimental)
    }

    private func compactPrimaryValue(
        for id: PostureIndicatorID,
        presentation: PostureIndicatorPresentation
    ) -> String {
        guard presentation.tone == .negative else { return presentation.primaryValue }
        return switch id {
        case .apparentProximity: "À éloigner légèrement"
        case .torsoInclination: "À redresser"
        case .raisedShoulders: "À relâcher"
        case .shoulderSlope: "À corriger"
        case .headTilt: "À redresser"
        case .estimatedBlinks: "Cligne naturellement"
        case .closedShoulders: "À réajuster"
        case .handOnFace: "Éloigne ta main"
        }
    }

    private func color(for tone: PostureIndicatorTone) -> Color {
        switch tone {
        case .neutral: AlignTheme.quiet
        case .positive: AlignTheme.accentSoft
        case .negative: AlignTheme.attention
        }
    }

    private var railStatus: String {
        guard cameraIsRunning else { return "Caméra inactive" }
        if snapshot.isCalibrating { return "Mesure des yeux en cours" }
        let available = PostureIndicatorPresentation.orderedIDs.filter {
            snapshot.result(for: $0).state != .unavailable
        }.count
        return "\(available)/\(PostureIndicatorPresentation.orderedIDs.count) signaux disponibles"
    }

    private var railStatusSymbol: String {
        guard cameraIsRunning else { return "pause.circle" }
        return snapshot.isCalibrating ? "scope" : "waveform.path.ecg"
    }

    private var railStatusColor: Color {
        guard cameraIsRunning else { return AlignTheme.quiet }
        if snapshot.isCalibrating { return AlignTheme.attention }
        return AlignTheme.accentSoft
    }

    private func accessibilityHint(for id: PostureIndicatorID) -> String {
        switch id {
        case .apparentProximity:
            "Proxy géométrique 2D : Align mesure la taille apparente du visage dans l'image, pas une distance physique."
        case .closedShoulders:
            "Proportions tête–épaules comparées à ton repère. Un écart peut venir de la tête avancée ou des épaules refermées."
        case .headTilt:
            "Angle de la tête par rapport à la ligne des épaules et à l'axe horizontal de l'image."
        case .shoulderSlope:
            "Angle de la ligne entre les deux épaules, vu de face. Il est comparé à l'horizontale de l'image ; il ne mesure pas des épaules avancées."
        case .torsoInclination:
            "Angle entre le milieu des épaules et celui des hanches, comparé à l'axe vertical de l'image."
        case .raisedShoulders:
            "Ratio géométrique entre la hauteur du triangle base du cou–épaules et sa largeur. Plus il baisse, plus le triangle est aplati ; la pente de la base est contrôlée séparément."
        case .estimatedBlinks:
            "Clignements par minute sur le temps où les deux yeux sont visibles. La référence s'apprend sur plusieurs minutes."
        case .handOnFace:
            "Proximité 2D entre les repères de la main et la surface du visage. Une alerte demande un maintien continu de 2,5 secondes ; ce n'est pas une preuve de contact physique."
        }
    }

    private func availabilityHelp(for id: PostureIndicatorID) -> String {
        let result = snapshot.result(for: id)
        guard result.state == .unavailable else {
            return accessibilityHint(for: id)
        }
        if let reason = result.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            return "Mesure indisponible : \(reason)."
        }
        switch id {
        case .torsoInclination: return "Le torse nécessite des épaules et des hanches suffisamment visibles."
        case .headTilt, .closedShoulders: return "Le visage et les deux épaules doivent être visibles ensemble."
        case .estimatedBlinks: return "Les deux yeux doivent être visibles assez longtemps pour estimer les clignements."
        case .apparentProximity: return "Le visage doit être suffisamment visible et face à l'écran."
        case .raisedShoulders: return "Les épaules et la base du cou doivent être suffisamment visibles."
        case .shoulderSlope: return "Les deux épaules doivent être suffisamment visibles."
        case .handOnFace: return "Le visage et au moins une main doivent être suffisamment visibles."
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if notificationAuthorization != .authorized {
                Button(action: onRequestNotifications) {
                    Label("Activer les alertes", systemImage: "bell.badge")
                        .labelStyle(.iconOnly)
                }
                .help(notificationAuthorization == .denied
                      ? "Ouvrir les Réglages Système pour autoriser les alertes"
                      : "Autoriser les rappels de posture")
                .accessibilityLabel("Activer les alertes")
                .buttonStyle(.bordered)
            }
            Button(snapshot.isCalibrating ? "Mesure des yeux…" : "Initialiser les yeux") {
                onCalibrate()
            }
            .disabled(!cameraIsRunning || snapshot.isCalibrating)
            .accessibilityHint("Gardez simplement les deux yeux visibles pendant huit secondes.")
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
    }

}
