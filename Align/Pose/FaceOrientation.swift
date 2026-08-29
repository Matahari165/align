import Foundation

/// Orientation estimée du visage, transportée uniquement en degrés.
///
/// Les valeurs sont optionnelles car Vision peut ne pas calculer un axe pour
/// une observation donnée. Cette valeur ne contient aucune image ni coordonnée.
nonisolated struct FaceOrientationSignal: Equatable, Sendable {
    let rollDegrees: Double?
    let yawDegrees: Double?
    let pitchDegrees: Double?

    init(
        rollRadians: Double?,
        yawRadians: Double?,
        pitchRadians: Double?
    ) {
        rollDegrees = Self.degrees(from: rollRadians)
        yawDegrees = Self.degrees(from: yawRadians)
        pitchDegrees = Self.degrees(from: pitchRadians)
    }

    static func degrees(from radians: Double?) -> Double? {
        guard let radians, radians.isFinite else { return nil }
        return radians * 180 / .pi
    }

    var isEmpty: Bool {
        rollDegrees == nil && yawDegrees == nil && pitchDegrees == nil
    }

    var summary: String {
        "roll \(formatted(rollDegrees)) · yaw \(formatted(yawDegrees)) · pitch \(formatted(pitchDegrees))"
    }

    private func formatted(_ value: Double?) -> String {
        value.map { String(format: "%+.1f°", $0) } ?? "—"
    }
}
