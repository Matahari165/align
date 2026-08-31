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
                Text("Indicateurs de posture")
                    .font(.caption.weight(.semibold))
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
        .accessibilityLabel("Indicateurs de posture, six")
    }

    private var threeColumnGrid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                indicator(for: .apparentProximity)
                indicator(for: .torsoInclination)
                indicator(for: .raisedShoulders)
            }
            GridRow {
                indicator(for: .shoulderSlope)
                indicator(for: .closedShoulders)
                indicator(for: .estimatedBlinks)
            }
        }
        .frame(minWidth: 570)
    }

    private var twoColumnGrid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                indicator(for: .apparentProximity)
                indicator(for: .torsoInclination)
            }
            GridRow {
                indicator(for: .raisedShoulders)
                indicator(for: .shoulderSlope)
            }
            GridRow {
                indicator(for: .closedShoulders)
                indicator(for: .estimatedBlinks)
            }
        }
    }

    private func indicator(for id: PostureIndicatorID) -> some View {
        let presentation = PostureIndicatorPresentation.make(
            for: snapshot.result(for: id), producedAt: snapshot.producedAt
        )
        return HStack(spacing: 7) {
            Image(systemName: presentation.symbolName)
                .foregroundStyle(color(for: presentation.tone))
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(presentation.title)
                        .font(.caption.weight(.semibold))
                    if presentation.isExperimental {
                        Text("Expérimental")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Text(presentation.value)
                    .font(.caption2)
                    .foregroundStyle(color(for: presentation.tone))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
        .padding(.horizontal, 9)
        .overlay(alignment: .trailing) {
            Divider()
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(accessibilityHint(for: id))
    }

    private func color(for tone: PostureIndicatorTone) -> Color {
        switch tone {
        case .neutral: AlignTheme.quiet
        case .positive: AlignTheme.ivory
        case .negative: AlignTheme.copper
        }
    }

    private func accessibilityHint(for id: PostureIndicatorID) -> String {
        switch id {
        case .apparentProximity:
            "Proxy relatif à ton repère ; Align ne mesure pas une distance physique."
        case .shoulderSlope, .closedShoulders:
            "Observation expérimentale sans rappel."
        case .torsoInclination, .raisedShoulders, .estimatedBlinks:
            ""
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
                      : "Autoriser les alertes lorsque Align est en arrière-plan")
                .accessibilityLabel("Activer les alertes")
            }
            Button(snapshot.isCalibrating ? "Calibration…" : "Calibrer") {
                onCalibrate()
            }
            .disabled(!cameraIsRunning || snapshot.isCalibrating)
            .accessibilityHint("Adoptez une posture confortable pendant huit secondes.")
        }
        .controlSize(.small)
    }

}
