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
    /// Ouverture verticale normalisée par la largeur de chaque œil.
    let leftEyeOpeningRatio: Double?
    let rightEyeOpeningRatio: Double?
    /// Distance minimale entre sourcils, normalisée par la distance interoculaire.
    let innerBrowDistanceRatio: Double?
    /// Centre géométrique du visage dans le repère capture normalisé.
    let faceCenter: CGPoint?

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
        faceLength: Double?,
        leftEyeOpeningRatio: Double? = nil,
        rightEyeOpeningRatio: Double? = nil,
        innerBrowDistanceRatio: Double? = nil,
        faceCenter: CGPoint? = nil
    ) {
        self.eyeLineRollDegrees = Self.finite(eyeLineRollDegrees)
        self.yawProxy = Self.finite(yawProxy)
        self.pitchProxy = Self.finite(pitchProxy)
        self.interocularDistance = Self.finite(interocularDistance)
        self.faceLength = Self.finite(faceLength)
        self.leftEyeOpeningRatio = Self.nonnegativeFinite(leftEyeOpeningRatio)
        self.rightEyeOpeningRatio = Self.nonnegativeFinite(rightEyeOpeningRatio)
        self.innerBrowDistanceRatio = Self.nonnegativeFinite(innerBrowDistanceRatio)
        self.faceCenter = Self.finitePoint(faceCenter)
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
        let leftEyeLocations = regions["leftEye"] ?? []
        let rightEyeLocations = regions["rightEye"] ?? []
        let leftEyebrow = regions["leftEyebrow"] ?? []
        let rightEyebrow = regions["rightEyebrow"] ?? []

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
        let faceCenter = medianPoint(in: regions["faceContour"] ?? []) ?? eyeMidpoint

        let signal = FaceGeometrySignal(
            eyeLineRollDegrees: eyeLineRollDegrees,
            yawProxy: yawProxy,
            pitchProxy: pitchProxy,
            interocularDistance: interocularDistance,
            faceLength: faceLength,
            leftEyeOpeningRatio: openingRatio(leftEyeLocations),
            rightEyeOpeningRatio: openingRatio(rightEyeLocations),
            innerBrowDistanceRatio: interocularDistance.flatMap {
                normalizedMinimumDistance(leftEyebrow, rightEyebrow, scale: $0)
            },
            faceCenter: faceCenter
        )
        return signal.hasValue ? signal : nil
    }

    var hasValue: Bool {
        eyeLineRollDegrees != nil
            || yawProxy != nil
            || pitchProxy != nil
            || interocularDistance != nil
            || faceLength != nil
            || leftEyeOpeningRatio != nil
            || rightEyeOpeningRatio != nil
            || innerBrowDistanceRatio != nil
            || faceCenter != nil
    }

    var summary: String {
        "roll \(formatted(eyeLineRollDegrees, suffix: "°")) · "
            + "yaw \(formatted(yawProxy)) · "
            + "pitch \(formatted(pitchProxy)) · "
            + "interoculaire \(formatted(interocularDistance)) · "
            + "longueur \(formatted(faceLength)) · "
            + "yeux \(formatted(leftEyeOpeningRatio))/\(formatted(rightEyeOpeningRatio)) · "
            + "sourcils \(formatted(innerBrowDistanceRatio))"
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

    private static func openingRatio(_ locations: [CGPoint]) -> Double? {
        let finiteLocations = locations.filter { $0.x.isFinite && $0.y.isFinite }
        guard finiteLocations.count >= 4 else { return nil }
        // Le segment le plus long définit l'axe local de l'œil. L'ouverture est
        // ensuite mesurée perpendiculairement : incliner la tête ne simule donc
        // pas une fermeture.
        var endpoints: (CGPoint, CGPoint)?
        var width = 0.0
        for index in finiteLocations.indices {
            for otherIndex in finiteLocations.indices where otherIndex > index {
                let first = finiteLocations[index]
                let second = finiteLocations[otherIndex]
                let distance = hypot(Double(second.x - first.x), Double(second.y - first.y))
                if distance > width { width = distance; endpoints = (first, second) }
            }
        }
        guard let endpoints, width >= minimumDistance, width.isFinite else { return nil }
        let axisX = Double(endpoints.1.x - endpoints.0.x) / width
        let axisY = Double(endpoints.1.y - endpoints.0.y) / width
        let perpendicular = finiteLocations.map { point in
            -Double(point.x) * axisY + Double(point.y) * axisX
        }
        guard let minimum = perpendicular.min(), let maximum = perpendicular.max() else { return nil }
        let height = maximum - minimum
        guard height >= 0, height.isFinite else { return nil }
        return nonnegativeFinite(height / width)
    }

    private static func normalizedMinimumDistance(
        _ first: [CGPoint],
        _ second: [CGPoint],
        scale: Double
    ) -> Double? {
        let lhs = first.filter { $0.x.isFinite && $0.y.isFinite }
        let rhs = second.filter { $0.x.isFinite && $0.y.isFinite }
        guard !lhs.isEmpty, !rhs.isEmpty, scale.isFinite, scale >= minimumDistance else {
            return nil
        }
        var minimum = Double.greatestFiniteMagnitude
        for left in lhs {
            for right in rhs {
                minimum = min(minimum, hypot(Double(right.x - left.x), Double(right.y - left.y)))
            }
        }
        return nonnegativeFinite(minimum / scale)
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

    private static func nonnegativeFinite(_ value: Double?) -> Double? {
        guard let value = finite(value), value >= 0 else { return nil }
        return value
    }

    private static func finitePoint(_ point: CGPoint?) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private func formatted(_ value: Double?, suffix: String = "") -> String {
        value.map { String(format: "%+.3f\(suffix)", $0) } ?? "—"
    }
}
