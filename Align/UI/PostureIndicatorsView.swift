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
                    HStack(spacing: 6) {
                        Text("Indicateurs de posture")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AlignTheme.ivory)
                        Text("EN DIRECT")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(AlignTheme.canvas)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AlignTheme.accent, in: Capsule())
                    }
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
        .padding(.vertical, 8)
        .background(AlignTheme.elevated.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle().fill(AlignTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Indicateurs de posture, sept")
    }

    private var threeColumnGrid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                indicator(for: .shoulderSlope)
                indicator(for: .raisedShoulders)
                indicator(for: .headTilt)
            }
            GridRow {
                indicator(for: .closedShoulders)
                indicator(for: .apparentProximity)
                indicator(for: .torsoInclination)
            }
            GridRow {
                indicator(for: .estimatedBlinks).gridCellColumns(3)
            }
        }
        .frame(minWidth: 570)
    }

    private var twoColumnGrid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                indicator(for: .shoulderSlope)
                indicator(for: .raisedShoulders)
            }
            GridRow {
                indicator(for: .headTilt)
                indicator(for: .closedShoulders)
            }
            GridRow {
                indicator(for: .apparentProximity)
                indicator(for: .torsoInclination)
            }
            GridRow {
                indicator(for: .estimatedBlinks).gridCellColumns(2)
            }
        }
    }

    private func indicator(for id: PostureIndicatorID) -> some View {
        let presentation = PostureIndicatorPresentation.make(
            for: snapshot.result(for: id), producedAt: snapshot.producedAt
        )
        let toneColor = color(for: presentation.tone)
        return HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(toneColor.opacity(0.14))
                Image(systemName: presentation.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(toneColor)
            }
            .frame(width: 27, height: 27)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(presentation.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AlignTheme.ivory)
                    if presentation.isExperimental {
                        Text("ESTIMATION")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(AlignTheme.accent)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)

                Text(presentation.primaryValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(toneColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let secondaryValue = presentation.secondaryValue {
                    Text(secondaryValue)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(AlignTheme.quiet)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AlignTheme.surface.opacity(0.32))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(toneColor.opacity(0.72))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AlignTheme.hairline)
                .frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AlignTheme.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(accessibilityHint(for: id))
        .help(availabilityHelp(for: id))
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
        if snapshot.isCalibrating { return "Calibration en cours" }
        let available = PostureIndicatorPresentation.orderedIDs.filter {
            snapshot.result(for: $0).state != .unavailable
        }.count
        return "\(available)/7 signaux disponibles"
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
            "Proxy relatif à ton repère ; Align ne mesure pas une distance physique."
        case .closedShoulders:
            "Proportions tête–épaules comparées à ton repère. Un écart peut venir de la tête avancée ou des épaules refermées."
        case .headTilt:
            "Tête penchée sur le côté par rapport à la ligne des épaules et à ton repère personnel."
        case .shoulderSlope:
            "Différence de hauteur entre les deux épaules, vue de face. L’angle est comparé à ton repère ; il ne mesure pas des épaules avancées."
        case .torsoInclination:
            "Buste penché sur le côté, mesuré entre le milieu des épaules et celui des hanches, puis comparé à ton repère."
        case .raisedShoulders:
            "Hauteur des épaules par rapport à la base du cou et à ton repère personnel."
        case .estimatedBlinks:
            "Clignements par minute sur le temps où les deux yeux sont visibles. La référence s'apprend sur plusieurs minutes."
        }
    }

    private func availabilityHelp(for id: PostureIndicatorID) -> String {
        guard snapshot.result(for: id).state == .unavailable else {
            return accessibilityHint(for: id)
        }
        switch id {
        case .torsoInclination: return "Le torse nécessite des épaules et des hanches suffisamment visibles."
        case .headTilt, .closedShoulders: return "Le visage et les deux épaules doivent être visibles ensemble."
        case .estimatedBlinks: return "Les deux yeux doivent être visibles assez longtemps pour estimer les clignements."
        case .apparentProximity: return "Le visage doit être suffisamment visible et face à l'écran."
        case .raisedShoulders: return "Les épaules et la base du cou doivent être suffisamment visibles."
        case .shoulderSlope: return "Les deux épaules doivent être suffisamment visibles."
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
            Button(snapshot.isCalibrating ? "Calibration…" : "Calibrer") {
                onCalibrate()
            }
            .disabled(!cameraIsRunning || snapshot.isCalibrating)
            .accessibilityHint("Adoptez une posture confortable pendant huit secondes.")
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
    }

}
