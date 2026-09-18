import CoreGraphics
import CoreVideo
import Foundation

nonisolated enum UpperBodyEngineState: String, Equatable, Sendable {
    case detected
    case partial
    case noPerson
    case stale
    case expired
    case technicalError
}

nonisolated enum UpperBodyLandmarkID: String, CaseIterable, Hashable, Sendable {
    case nose
    case leftEar
    case rightEar
    /// Halpe26's explicit base-of-neck landmark (index 18). This is an
    /// observed point only; no anatomical neck is inferred from shoulders.
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftHip
    case rightHip

    var debugName: String {
        switch self {
        case .nose: "Nez"
        case .leftEar: "Oreille gauche"
        case .rightEar: "Oreille droite"
        case .neck: "Base du cou"
        case .leftShoulder: "Épaule gauche"
        case .rightShoulder: "Épaule droite"
        case .leftElbow: "Coude gauche"
        case .rightElbow: "Coude droit"
        case .leftHip: "Hanche gauche"
        case .rightHip: "Hanche droite"
        }
    }

    /// Stable Halpe26 indices used by the RTMPose adapter. Keeping this
    /// mapping beside the typed IDs prevents a second, divergent string/index
    /// contract in the inference bridge.
    var halpe26Index: Int {
        switch self {
        case .nose: 0
        case .leftEar: 3
        case .rightEar: 4
        case .leftShoulder: 5
        case .rightShoulder: 6
        case .leftElbow: 7
        case .rightElbow: 8
        case .leftHip: 11
        case .rightHip: 12
        case .neck: 18
        }
    }

    static let rtmposeMapping: [(index: Int, id: Self)] = [
        (UpperBodyLandmarkID.nose.halpe26Index, .nose),
        (UpperBodyLandmarkID.leftEar.halpe26Index, .leftEar),
        (UpperBodyLandmarkID.rightEar.halpe26Index, .rightEar),
        (UpperBodyLandmarkID.leftShoulder.halpe26Index, .leftShoulder),
        (UpperBodyLandmarkID.rightShoulder.halpe26Index, .rightShoulder),
        (UpperBodyLandmarkID.leftElbow.halpe26Index, .leftElbow),
        (UpperBodyLandmarkID.rightElbow.halpe26Index, .rightElbow),
        (UpperBodyLandmarkID.leftHip.halpe26Index, .leftHip),
        (UpperBodyLandmarkID.rightHip.halpe26Index, .rightHip),
        (UpperBodyLandmarkID.neck.halpe26Index, .neck)
    ]
}

nonisolated enum UpperBodyPointQuality: String, Equatable, Sendable {
    case good
    case limited
}

nonisolated enum UpperBodyPointProvenance: String, Equatable, Sendable {
    case observed
    case derived
}

nonisolated struct UpperBodyPoint: Equatable, Sendable {
    let id: UpperBodyLandmarkID
    let location: CGPoint
    let confidence: Float
    let quality: UpperBodyPointQuality
    let provenance: UpperBodyPointProvenance

    var isValid: Bool {
        location.x.isFinite && location.y.isFinite && confidence.isFinite &&
            (0...1).contains(location.x) && (0...1).contains(location.y) &&
            (0...1).contains(confidence)
    }
}

nonisolated struct UpperBodyContour: Equatable, Sendable {
    let name: String
    let locations: [CGPoint]
    let isClosed: Bool

    var isValid: Bool {
        locations.count >= 2 && locations.allSatisfy {
            $0.x.isFinite && $0.y.isFinite &&
                (0...1).contains($0.x) && (0...1).contains($0.y)
        }
    }
}

nonisolated struct UpperBodyEngineDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let runtime: String
}

/// Rectangle source for a top-down upper-body model. Coordinates are the
/// canonical camera-buffer contract: normalized, top-left, non-mirrored and
/// axis-aligned. The roll of the face is deliberately not represented.
nonisolated enum UpperBodyRegionOfInterestSource: String, Equatable, Sendable {
    case sameFrameFace
    case recentFace
    /// A bounded, center-biased crop used only when Vision has no face anchor
    /// for the current frame. The model still has to return confident points;
    /// this source is never itself evidence that a person was detected.
    case fullFrameFallback
}

nonisolated struct UpperBodyRegionOfInterest: Equatable, Sendable {
    static let maximumAnchorSkew: TimeInterval = 0.75
    /// Keep a small border out of the crop so edge padding cannot be mistaken
    /// for an anatomical point. This is deliberately a broad fallback, not a
    /// calibration rectangle.
    static let fullFrameFallbackRect = CGRect(x: 0.05, y: 0.02, width: 0.90, height: 0.96)

    let rect: CGRect
    let capturedAt: TimeInterval
    let anchorCapturedAt: TimeInterval
    let anchorSampleID: UInt64
    let generation: UInt64
    let source: UpperBodyRegionOfInterestSource

    static func fullFrameFallback(
        capturedAt: TimeInterval,
        sampleID: UInt64,
        generation: UInt64
    ) -> Self? {
        let roi = Self(
            rect: Self.fullFrameFallbackRect,
            capturedAt: capturedAt,
            anchorCapturedAt: capturedAt,
            anchorSampleID: sampleID,
            generation: generation,
            source: .fullFrameFallback
        )
        return roi.isValid ? roi : nil
    }

    var isValid: Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0 &&
            rect.minX >= 0 && rect.minY >= 0 &&
            rect.maxX <= 1 && rect.maxY <= 1 &&
            capturedAt.isFinite && anchorCapturedAt.isFinite &&
            anchorCapturedAt <= capturedAt && anchorSampleID > 0 && generation > 0
    }

    func isAdmissible(
        forFrameCapturedAt frameCapturedAt: TimeInterval,
        generation frameGeneration: UInt64,
        maximumSkew: TimeInterval = Self.maximumAnchorSkew
    ) -> Bool {
        guard isValid,
              frameCapturedAt.isFinite,
              maximumSkew.isFinite,
              maximumSkew >= 0,
              capturedAt == frameCapturedAt,
              generation == frameGeneration else { return false }
        let skew = frameCapturedAt - anchorCapturedAt
        guard skew >= 0, skew <= maximumSkew else { return false }
        switch source {
        case .sameFrameFace: return skew == 0
        case .recentFace: return skew > 0
        case .fullFrameFallback: return skew == 0
        }
    }
}

nonisolated struct UpperBodyFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let capturedAt: TimeInterval
    let sampleID: UInt64
    let generation: UInt64
    let regionOfInterest: UpperBodyRegionOfInterest?

    init(
        pixelBuffer: CVPixelBuffer,
        capturedAt: TimeInterval,
        sampleID: UInt64,
        generation: UInt64,
        regionOfInterest: UpperBodyRegionOfInterest? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.capturedAt = capturedAt
        self.sampleID = sampleID
        self.generation = generation
        self.regionOfInterest = regionOfInterest
    }
}

nonisolated struct UpperBodyEngineOutput: Equatable, Sendable {
    let state: UpperBodyEngineState
    let points: [UpperBodyPoint]
    let contours: [UpperBodyContour]
    let regionOfInterest: UpperBodyRegionOfInterest?
    let diagnostics: UpperBodyEngineDiagnostics?

    init(
        state: UpperBodyEngineState,
        points: [UpperBodyPoint],
        contours: [UpperBodyContour],
        regionOfInterest: UpperBodyRegionOfInterest? = nil,
        diagnostics: UpperBodyEngineDiagnostics? = nil
    ) {
        self.state = state
        self.points = points
        self.contours = contours
        self.regionOfInterest = regionOfInterest
        self.diagnostics = diagnostics
    }
}

/// Scalar-only engine evidence for Diagnostics. It never changes point
/// validity and never retains an image, tensor or coordinate array.
nonisolated struct UpperBodyEngineDiagnostics: Equatable, Sendable {
    let usedCoreML: Bool
    let validLandmarkCount: Int
    let simCCMinimum: Float?
    let simCCMaximum: Float?
    let scoreMinimum: Float?
    let scoreMaximum: Float?
    let leftShoulderScore: Float?
    let rightShoulderScore: Float?
}

nonisolated struct UpperBodyResult: Equatable, Sendable {
    let descriptor: UpperBodyEngineDescriptor
    let state: UpperBodyEngineState
    let generation: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let producedAt: TimeInterval
    let points: [UpperBodyPoint]
    let contours: [UpperBodyContour]
    let regionOfInterest: UpperBodyRegionOfInterest?
    let diagnostics: UpperBodyEngineDiagnostics?

    init(
        descriptor: UpperBodyEngineDescriptor,
        state: UpperBodyEngineState,
        generation: UInt64,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        producedAt: TimeInterval,
        points: [UpperBodyPoint],
        contours: [UpperBodyContour],
        regionOfInterest: UpperBodyRegionOfInterest? = nil,
        diagnostics: UpperBodyEngineDiagnostics? = nil
    ) {
        self.descriptor = descriptor
        self.state = state
        self.generation = generation
        self.sampleID = sampleID
        self.capturedAt = capturedAt
        self.producedAt = producedAt
        self.points = points
        self.contours = contours
        self.regionOfInterest = regionOfInterest
        self.diagnostics = diagnostics
    }

    func point(_ id: UpperBodyLandmarkID) -> UpperBodyPoint? {
        points.first { $0.id == id }
    }

    var isFreshGeometry: Bool {
        state == .detected || state == .partial
    }

    func isRenderable(at uptime: TimeInterval, maximumAge: TimeInterval) -> Bool {
        guard isFreshGeometry, maximumAge.isFinite, maximumAge > 0,
              let age = age(at: uptime) else { return false }
        return age <= maximumAge
    }

    var hasCoherentShoulders: Bool {
        guard let left = point(.leftShoulder), let right = point(.rightShoulder) else {
            return false
        }
        return UpperBodyShoulderPairValidator.isCoherent(
            left: left.location,
            right: right.location
        )
    }

    func age(at uptime: TimeInterval) -> TimeInterval? {
        guard uptime.isFinite, capturedAt.isFinite, uptime >= capturedAt else { return nil }
        return uptime - capturedAt
    }

    /// Geometry derived exclusively from this immutable result. Every segment
    /// and axis carries this result's sample/generation; no cross-frame point
    /// or anatomical point is invented.
    var derivedGeometry: UpperBodyGeometrySnapshot {
        UpperBodyGeometryDeriver.make(from: self)
    }
}

nonisolated enum UpperBodyShoulderPairValidator {
    static let minimumSeparation: CGFloat = 0.08
    static let maximumSeparation: CGFloat = 0.90

    static func isCoherent(left: CGPoint?, right: CGPoint?) -> Bool {
        guard let left, let right,
              left.x.isFinite, left.y.isFinite,
              right.x.isFinite, right.y.isFinite,
              (0...1).contains(left.x), (0...1).contains(left.y),
              (0...1).contains(right.x), (0...1).contains(right.y) else { return false }
        let separation = hypot(right.x - left.x, right.y - left.y)
        return separation >= minimumSeparation && separation <= maximumSeparation
    }
}

nonisolated protocol UpperBodyPoseEngine: AnyObject, Sendable {
    var descriptor: UpperBodyEngineDescriptor { get }
    func activate(generation: UInt64)
    func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput
    func deactivate()
}
