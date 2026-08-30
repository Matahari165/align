import SwiftUI

struct PostureIndicatorsView: View {
    let snapshot: PostureIndicatorsSnapshot
    let cameraIsRunning: Bool
    let onCalibrate: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Repères de posture")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(snapshot.isCalibrating ? "Calibration…" : "Calibrer (8 s)") {
                    onCalibrate()
                }
                .controlSize(.small)
                .disabled(!cameraIsRunning || snapshot.isCalibrating)
                .accessibilityHint("Adoptez une posture confortable pendant huit secondes, avec le haut de l’écran au niveau ou sous les yeux et une distance confortable.")
            }

            Text(snapshot.isCalibrating
                 ? "Restez confortablement installé jusqu’à la fin de la calibration."
                 : "Posture confortable · haut de l’écran au niveau ou sous les yeux · distance confortable")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                ForEach(PostureIndicatorID.allCases, id: \.self) { id in
                    indicator(snapshot.result(for: id))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    private func indicator(_ result: PostureIndicatorResult) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol(for: result.state))
                .foregroundStyle(color(for: result.state))
                .frame(width: 15)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(result.id.title)
                    .font(.caption)
                    .lineLimit(1)
                Text(value(for: result))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if result.isExperimental {
                Text("Bêta")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.id.title)
        .accessibilityValue(value(for: result))
    }

    private func value(for result: PostureIndicatorResult) -> String {
        let prefix = result.isExperimental ? "Expérimental, " : ""
        if let count = result.count { return "\(prefix)\(result.state.displayName), \(count)" }
        return prefix + result.state.displayName
    }

    private func symbol(for state: PostureIndicatorState) -> String {
        switch state {
        case .needsCalibration: "scope"
        case .calibrating: "hourglass"
        case .normal: "checkmark.circle.fill"
        case .pending: "ellipsis.circle"
        case .attention: "exclamationmark.triangle.fill"
        case .unavailable: "minus.circle"
        }
    }

    private func color(for state: PostureIndicatorState) -> Color {
        switch state {
        case .normal: .green
        case .attention: .orange
        case .pending: .blue
        case .needsCalibration, .calibrating, .unavailable: .secondary
        }
    }
}
