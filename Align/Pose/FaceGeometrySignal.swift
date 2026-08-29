import CoreGraphics
import Foundation

/// Mesures géométriques dérivées des polylines faciales déjà produites par Vision.
///
/// Le signal ne contient ni image ni coordonnée brute. Les coordonnées ne vivent
/// que pendant le calcul de l'échantillon puis sont remplacées par ces valeurs
/// normalisées avant leur transport vers le benchmark.
nonisolated struct FaceGeometrySignal: Equatable, Sendable {
    /// Inclinaison de la ligne joignant les centres des yeux, dans le repère
    /// capture actuel (x vers la droite, y vers le bas).
    let eyeLineRollDegrees: Double?
    /// Déplacement horizontal du nez par rapport au milieu des yeux,
    /// normalisé par la distance interoculaire. Positif = vers la droite.
    let yawProxy: Double?
    /// Déplacement vertical du nez par rapport au milieu des yeux,
    /// normalisé par une longueur faciale robuste. Positif = vers le bas.
    let pitchProxy: Double?
    let interocularDistance: Double?
    let faceLength: Double?

    /// Seuil en coordonnées normalisées Vision : évite les divisions par une
    /// distance nulle ou par un visage dégénéré.
    static let minimumDistance = 0.0001

    init?(polylines: [PosePolyline]) {
        guard let signal = Self.from(polylines: polylines) else { return nil }
        self = signal
    }

    init(
        eyeLineRollDegrees: Double?,
        yawProxy: Double?,
        pitchProxy: Double?,
        interocularDistance: Double?,
        faceLength: Double?
    ) {
        self.eyeLineRollDegrees = Self.finite(eyeLineRollDegrees)
        self.yawProxy = Self.finite(yawProxy)
        self.pitchProxy = Self.finite(pitchProxy)
        self.interocularDistance = Self.finite(interocularDistance)
        self.faceLength = Self.finite(faceLength)
    }

    /// Construit un signal à partir des polylines nommées par `PoseDetector`.
    /// Les régions partielles restent utiles : chaque métrique est optionnelle.
    static func from(polylines: [PosePolyline]) -> FaceGeometrySignal? {
        var regions: [String: [CGPoint]] = [:]
        for polyline in polylines where regions[polyline.name] == nil {
            regions[polyline.name] = polyline.locations
        }
        let leftEye = medianPoint(in: regions["leftEye"] ?? [])
        let rightEye = medianPoint(in: regions["rightEye"] ?? [])
        let nose = medianPoint(in: regions["nose"] ?? [])

        let interocularDistance: Double?
        let eyeLineRollDegrees: Double?
        let eyeMidpoint: CGPoint?
        if let leftEye, let rightEye {
            let delta = CGPoint(x: rightEye.x - leftEye.x, y: rightEye.y - leftEye.y)
            let distance = hypot(delta.x, delta.y)
            if distance >= minimumDistance, distance.isFinite {
                interocularDistance = distance
                eyeLineRollDegrees = axialAngleDegrees(
                    atan2(delta.y, delta.x) * 180 / .pi
                )
                eyeMidpoint = CGPoint(
                    x: (leftEye.x + rightEye.x) / 2,
                    y: (leftEye.y + rightEye.y) / 2
                )
            } else {
                interocularDistance = nil
                eyeLineRollDegrees = nil
                eyeMidpoint = nil
            }
        } else {
            interocularDistance = nil
            eyeLineRollDegrees = nil
            eyeMidpoint = nil
        }

        let faceLength = robustFaceLength(
            medianLine: regions["medianLine"] ?? [],
            contour: regions["faceContour"] ?? []
        )
        let yawProxy: Double?
        let pitchProxy: Double?
        if let nose, let eyeMidpoint {
            yawProxy = interocularDistance.map {
                finite((nose.x - eyeMidpoint.x) / $0)
            } ?? nil
            pitchProxy = faceLength.map {
                finite((nose.y - eyeMidpoint.y) / $0)
            } ?? nil
        } else {
            yawProxy = nil
            pitchProxy = nil
        }

        let signal = FaceGeometrySignal(
            eyeLineRollDegrees: eyeLineRollDegrees,
            yawProxy: yawProxy,
            pitchProxy: pitchProxy,
            interocularDistance: interocularDistance,
            faceLength: faceLength
        )
        return signal.hasValue ? signal : nil
    }

    var hasValue: Bool {
        eyeLineRollDegrees != nil
            || yawProxy != nil
            || pitchProxy != nil
            || interocularDistance != nil
            || faceLength != nil
    }

    var summary: String {
        "roll \(formatted(eyeLineRollDegrees, suffix: "°")) · "
            + "yaw \(formatted(yawProxy)) · "
            + "pitch \(formatted(pitchProxy)) · "
            + "interoculaire \(formatted(interocularDistance)) · "
            + "longueur \(formatted(faceLength))"
    }

    private static func medianPoint(in locations: [CGPoint]) -> CGPoint? {
        let finiteLocations = locations.filter { $0.x.isFinite && $0.y.isFinite }
        guard !finiteLocations.isEmpty else { return nil }
        let xs = finiteLocations.map(\.x).sorted()
        let ys = finiteLocations.map(\.y).sorted()
        return CGPoint(x: median(xs), y: median(ys))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private static func robustFaceLength(
        medianLine: [CGPoint],
        contour: [CGPoint]
    ) -> Double? {
        // La medianLine est plus directement liée à l'axe facial et son chemin
        // central fournit une longueur stable, indépendante de la translation.
        // Le contour reste un fallback : son étendue verticale robuste évite que
        // la longueur d'arc varie avec le nombre de points ou la courbure.
        if let length = polylineLength(medianLine) { return length }
        return robustVerticalExtent(contour)
    }

    private static func polylineLength(_ locations: [CGPoint]) -> Double? {
        let finiteLocations = locations.filter { $0.x.isFinite && $0.y.isFinite }
        guard finiteLocations.count >= 2 else { return nil }
        var length: Double = 0
        for pair in zip(finiteLocations, finiteLocations.dropFirst()) {
            let dx = Double(pair.1.x - pair.0.x)
            let dy = Double(pair.1.y - pair.0.y)
            let segment = hypot(dx, dy)
            guard segment.isFinite else { return nil }
            length += segment
        }
        guard length >= minimumDistance, length.isFinite else { return nil }
        return length
    }

    private static func robustVerticalExtent(_ locations: [CGPoint]) -> Double? {
        let ys = locations
            .filter { $0.x.isFinite && $0.y.isFinite }
            .map(\.y)
            .sorted()
        guard ys.count >= 2 else { return nil }

        // Les petits jeux synthétiques et les contours courts conservent leurs
        // bornes. Pour un contour dense, les quantiles 10–90 % ignorent les
        // quelques points aberrants sans dépendre de la longueur d'arc.
        let lower: CGFloat
        let upper: CGFloat
        if ys.count < 5 {
            lower = ys[0]
            upper = ys[ys.count - 1]
        } else {
            lower = interpolatedQuantile(ys, fraction: 0.10)
            upper = interpolatedQuantile(ys, fraction: 0.90)
        }
        let extent = Double(upper - lower)
        guard extent >= minimumDistance, extent.isFinite else { return nil }
        return extent
    }

    private static func interpolatedQuantile(
        _ values: [CGFloat],
        fraction: Double
    ) -> CGFloat {
        let position = Double(values.count - 1) * fraction
        let lowerIndex = Int(position.rounded(.towardZero))
        let upperIndex = min(values.count - 1, lowerIndex + 1)
        let weight = CGFloat(position - Double(lowerIndex))
        return values[lowerIndex] + (values[upperIndex] - values[lowerIndex]) * weight
    }

    private static func axialAngleDegrees(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        var axial = degrees.truncatingRemainder(dividingBy: 180)
        if axial >= 90 { axial -= 180 }
        if axial < -90 { axial += 180 }
        return finite(axial)
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private func formatted(_ value: Double?, suffix: String = "") -> String {
        value.map { String(format: "%+.3f\(suffix)", $0) } ?? "—"
    }
}
