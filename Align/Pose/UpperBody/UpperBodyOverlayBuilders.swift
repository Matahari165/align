import CoreGraphics
import Foundation

nonisolated struct UpperBodyDevelopmentOptions: Equatable, Sendable {
    var showsLandmarks = true
    var showsConnections = true
    var showsAxes = true
    var showsSilhouette = false
    var showsValues = false
    var showsTrace = false
    var showsROI = false

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: "UpperBodyDevelopmentShowsLandmarks") != nil else {
            return .init()
        }
        return Self(
            showsLandmarks: defaults.bool(forKey: "UpperBodyDevelopmentShowsLandmarks"),
            showsConnections: defaults.object(forKey: "UpperBodyDevelopmentShowsConnections")
                .map { _ in defaults.bool(forKey: "UpperBodyDevelopmentShowsConnections") }
                ?? true,
            showsAxes: defaults.bool(forKey: "UpperBodyDevelopmentShowsAxes"),
            showsSilhouette: defaults.bool(forKey: "UpperBodyDevelopmentShowsSilhouette"),
            showsValues: defaults.bool(forKey: "UpperBodyDevelopmentShowsValues"),
            showsTrace: defaults.bool(forKey: "UpperBodyDevelopmentShowsTrace"),
            showsROI: defaults.bool(forKey: "UpperBodyDevelopmentShowsROI")
        )
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(showsLandmarks, forKey: "UpperBodyDevelopmentShowsLandmarks")
        defaults.set(showsConnections, forKey: "UpperBodyDevelopmentShowsConnections")
        defaults.set(showsAxes, forKey: "UpperBodyDevelopmentShowsAxes")
        defaults.set(showsSilhouette, forKey: "UpperBodyDevelopmentShowsSilhouette")
        defaults.set(showsValues, forKey: "UpperBodyDevelopmentShowsValues")
        defaults.set(showsTrace, forKey: "UpperBodyDevelopmentShowsTrace")
        defaults.set(showsROI, forKey: "UpperBodyDevelopmentShowsROI")
    }
}

nonisolated enum ProductUpperBodyOverlayBuilder {
    static func make(
        from result: UpperBodyResult,
        at uptime: TimeInterval,
        maximumAge: TimeInterval = UpperBodyEngineSession.defaultMaximumAge
    ) -> PoseOverlay {
        guard result.isRenderable(at: uptime, maximumAge: maximumAge) else { return .empty }
        let left = posePoint(result.point(.leftShoulder), source: .upperBodyShoulders)
        let right = posePoint(result.point(.rightShoulder), source: .upperBodyShoulders)
        let points = [left, right].compactMap { $0 }
        let lines: [PosePolyline]
        if result.hasCoherentShoulders, let left, let right {
            lines = [line("ligne-épaules", left.location, right.location,
                          source: .upperBodyShoulders)]
        } else {
            lines = []
        }
        return PoseOverlay(points: points, polylines: lines)
    }
}

nonisolated enum DevelopmentUpperBodyOverlayBuilder {
    static func make(
        from result: UpperBodyResult,
        at uptime: TimeInterval,
        maximumAge: TimeInterval = UpperBodyEngineSession.defaultMaximumAge,
        options: UpperBodyDevelopmentOptions = .init()
    ) -> PoseOverlay {
        guard result.isRenderable(at: uptime, maximumAge: maximumAge) else { return .empty }
        var points: [PosePoint] = []
        var lines: [PosePolyline] = []
        let geometry = result.derivedGeometry
        let comparisonNeck = lightweightComparisonNeck(from: result)

        if options.showsLandmarks {
            for point in result.points {
                points.append(PosePoint(
                    name: developmentName(for: point.id),
                    location: point.location,
                    confidence: point.confidence,
                    source: source(for: point.id),
                    isLimited: point.quality == .limited
                ))
            }
            if let comparisonNeck {
                points.append(PosePoint(
                    name: developmentName(for: .neck),
                    location: comparisonNeck.location,
                    confidence: comparisonNeck.confidence,
                    source: .upperBodyHead,
                    isLimited: comparisonNeck.quality == .limited
                ))
            }
        }

        if options.showsConnections {
            for segment in geometry.segments where segment.family != .head {
                let source: PosePointSource = switch segment.family {
                case .shoulders, .neckShoulders, .arms: .upperBodyShoulders
                case .hips, .torso: .upperBodyTorso
                case .head: .upperBodyHead
                }
                lines.append(line(segment.name, segment.start, segment.end, source: source))
            }
            if let comparisonNeck,
               let leftShoulder = result.point(.leftShoulder),
               let rightShoulder = result.point(.rightShoulder) {
                lines.append(line(
                    "cou-épaule-gauche",
                    comparisonNeck.location,
                    leftShoulder.location,
                    source: .upperBodyShoulders
                ))
                lines.append(line(
                    "cou-épaule-droite",
                    comparisonNeck.location,
                    rightShoulder.location,
                    source: .upperBodyShoulders
                ))
            }
        }

        if options.showsAxes {
            if let ears = geometry.segment(named: "ligne-oreilles") {
                lines.append(line("Tête · ligne des oreilles", ears.start, ears.end,
                                  source: .upperBodyDerived))
            }
            if let torso = geometry.axis(named: "axe-torse") {
                lines.append(line("Torse · axe central (dérivé)", torso.start, torso.end,
                                  source: .upperBodyDerived))
            }
        }

        if options.showsROI, let roi = result.regionOfInterest, roi.isValid {
            let rect = roi.rect
            lines.append(PosePolyline(
                name: "RTMPose ROI",
                locations: [
                    CGPoint(x: rect.minX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.maxY)
                ],
                source: .upperBodyROI,
                isClosed: true
            ))
        }

        if options.showsSilhouette {
            for contour in result.contours {
                lines.append(PosePolyline(
                    name: contour.name,
                    locations: contour.locations,
                    source: .silhouette,
                    isClosed: contour.isClosed
                ))
            }
        }
        return PoseOverlay(points: points, polylines: lines)
    }

    static func summary(for result: UpperBodyResult, at uptime: TimeInterval) -> String {
        switch result.state {
        case .technicalError:
            return "Erreur technique · nouvelle tentative automatique"
        case .expired, .stale:
            return "Haut du corps · résultat expiré"
        case .noPerson:
            return "Haut du corps · perdu"
        case .detected, .partial:
            guard result.isRenderable(
                at: uptime,
                maximumAge: UpperBodyEngineSession.defaultMaximumAge
            ) else { return "Haut du corps · résultat expiré" }
            let left = result.point(.leftShoulder)
            let right = result.point(.rightShoulder)
            let base: String
            if let left, let right,
               UpperBodyShoulderPairValidator.isCoherent(
                   left: left.location, right: right.location
               ) {
                base = "Haut du corps · prêt"
            } else if left != nil {
                base = "Haut du corps · partiel · épaule droite absente"
            } else if right != nil {
                base = "Haut du corps · partiel · épaule gauche absente"
            } else {
                return "Haut du corps · perdu"
            }
            let edges = edgeQualifications(for: [left, right].compactMap { $0?.location })
            return edges.isEmpty ? base : "\(base) · \(edges.joined(separator: "/"))"
        }
    }

    /// Diagnostic de cadrage provisoire. La marge de 6 % doit être validée
    /// sur caméra réelle avant d'être considérée comme un seuil produit.
    static let provisionalEdgeMargin: CGFloat = 0.06

    private static func edgeQualifications(for locations: [CGPoint]) -> [String] {
        var labels: [String] = []
        if locations.contains(where: { $0.x <= provisionalEdgeMargin }) { labels.append("bord gauche") }
        if locations.contains(where: { $0.x >= 1 - provisionalEdgeMargin }) { labels.append("bord droit") }
        if locations.contains(where: { $0.y <= provisionalEdgeMargin }) { labels.append("bord haut") }
        if locations.contains(where: { $0.y >= 1 - provisionalEdgeMargin }) { labels.append("bord bas") }
        return labels
    }

    private static func source(for id: UpperBodyLandmarkID) -> PosePointSource {
        switch id {
        case .nose, .leftEar, .rightEar, .neck: .upperBodyHead
        case .leftShoulder, .rightShoulder, .leftElbow, .rightElbow: .upperBodyShoulders
        case .leftHip, .rightHip: .upperBodyTorso
        }
    }

    private static func developmentName(for id: UpperBodyLandmarkID) -> String {
        switch id {
        case .nose: "NEZ"
        case .leftEar: "OREILLE G."
        case .rightEar: "OREILLE D."
        case .neck: "BASE DU COU"
        case .leftShoulder: "ÉPAULE G."
        case .rightShoulder: "ÉPAULE D."
        case .leftElbow: "COUDE G."
        case .rightElbow: "COUDE D."
        case .leftHip: "HANCHE G."
        case .rightHip: "HANCHE D."
        }
    }

    /// BlazePose Lite has no explicit base-of-neck landmark. This point is
    /// presentation-only so both engines expose the same comparison shape;
    /// it never enters posture metrics or calibration.
    private static func lightweightComparisonNeck(
        from result: UpperBodyResult
    ) -> UpperBodyPoint? {
        guard result.descriptor.id.hasPrefix("blazepose."),
              result.point(.neck) == nil,
              let nose = result.point(.nose),
              let leftShoulder = result.point(.leftShoulder),
              let rightShoulder = result.point(.rightShoulder) else { return nil }
        let shoulderCenter = CGPoint(
            x: (leftShoulder.location.x + rightShoulder.location.x) * 0.5,
            y: (leftShoulder.location.y + rightShoulder.location.y) * 0.5
        )
        let location = CGPoint(
            x: shoulderCenter.x + (nose.location.x - shoulderCenter.x) * 0.28,
            y: shoulderCenter.y + (nose.location.y - shoulderCenter.y) * 0.28
        )
        let confidence = min(
            nose.confidence,
            min(leftShoulder.confidence, rightShoulder.confidence)
        )
        return UpperBodyPoint(
            id: .neck,
            location: location,
            confidence: confidence,
            quality: confidence >= 0.5 ? .good : .limited,
            provenance: .derived
        )
    }

}

private nonisolated func posePoint(_ point: UpperBodyPoint?, source: PosePointSource) -> PosePoint? {
    point.map {
        PosePoint(name: $0.id.debugName, location: $0.location,
                  confidence: $0.confidence, source: source)
    }
}

private nonisolated func line(
    _ name: String,
    _ first: CGPoint,
    _ second: CGPoint,
    source: PosePointSource
) -> PosePolyline {
    PosePolyline(name: name, locations: [first, second], source: source, isClosed: false)
}
