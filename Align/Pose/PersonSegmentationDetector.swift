import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Face geometry in the **mask contract**: normalized captured-image
/// coordinates with an origin at the top-left (`y = 0` is the top edge).
/// Existing face/overlay coordinates cross into this type through the explicit
/// mapper in `VisionCoordinateMapper`; the contour is converted back before it
/// is published as a `PoseOverlay`.
nonisolated struct PersonSegmentationFaceAnchor: Sendable {
    let jawPoint: CGPoint
    let bounds: CGRect

    init(jawPoint: CGPoint, bounds: CGRect) {
        self.jawPoint = jawPoint
        self.bounds = bounds
    }

    /// Derives the lower (top-left `y` maximum) face-contour side used as the
    /// jaw anchor. Keeping this in the mask contract makes the conversion
    /// testable without a camera or a Vision request.
    init?(faceContour locations: [CGPoint]) {
        guard locations.count >= 3 else { return nil }
        let xs = locations.map(\.x)
        let ys = locations.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              maxX > minX, maxY > minY else { return nil }
        let jawCandidates = locations.filter { $0.y >= maxY - 0.08 * (maxY - minY) }
        let jawX = jawCandidates.map(\.x).reduce(0, +) / CGFloat(max(1, jawCandidates.count))
        self.init(
            jawPoint: CGPoint(x: jawX, y: maxY),
            bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        )
    }

    /// Builds the mask-side anchor from the face contour as carried by the
    /// existing face/overlay contract. The named boundary is deliberately kept
    /// here so callers cannot accidentally feed raw Vision coordinates to the
    /// extractor.
    init?(faceOverlayContour locations: [CGPoint]) {
        self.init(faceContour: locations.map(
            VisionCoordinateMapper.segmentationTopLeftPoint(fromFaceOverlayPoint:)
        ))
    }
}

nonisolated enum PersonSegmentationSide: String, Sendable {
    case left
    case right
}

/// A compact, mask-free representation suitable for publishing to the diagnostic overlay.
nonisolated struct PersonSilhouettePolyline: Sendable {
    let side: PersonSegmentationSide
    let locations: [CGPoint]
}

nonisolated struct PersonSilhouetteContour: Sendable {
    let left: PersonSilhouettePolyline
    let right: PersonSilhouettePolyline
    let jawAnchor: CGPoint
    let roi: CGRect
    let coverage: Double
    let medianWidth: Double

    var polylines: [PersonSilhouettePolyline] { [left, right] }
}

nonisolated enum PersonSegmentationFailure: Sendable, Equatable {
    case inactive
    case missingTimestamp
    case missingFaceAnchor
    case unsupportedMaskFormat
    case maskLockFailed
    case maskBaseAddressUnavailable
    case maskStrideInvalid
    case noMaskObservation
    case insufficientContour
    case vision(String)
}

nonisolated struct PersonSegmentationMeasurement: Sendable {
    let duration: TimeInterval
    let result: ResultKind
    let performedVision: Bool

    nonisolated enum ResultKind: String, Sendable {
        case contour
        case insufficient
        case noObservation
        case error
    }
}

nonisolated enum PersonSegmentationResult: Sendable {
    case contour(PersonSilhouetteContour, measurement: PersonSegmentationMeasurement)
    case insufficient(PersonSegmentationFailure, measurement: PersonSegmentationMeasurement)
    case error(PersonSegmentationFailure, measurement: PersonSegmentationMeasurement)

    var measurement: PersonSegmentationMeasurement {
        switch self {
        case .contour(_, let measurement), .insufficient(_, let measurement), .error(_, let measurement):
            measurement
        }
    }
}

nonisolated enum PersonSegmentationAvailability: String, Sendable {
    case notRequested
    case insufficient
    case available
    case error

    var displayName: String {
        switch self {
        case .notRequested: "non demandée"
        case .insufficient: "indisponible"
        case .available: "disponible"
        case .error: "erreur"
        }
    }
}

/// Local, stateful person segmentation for the diagnostic neck/shoulder overlay.
///
/// The instance is intentionally not internally synchronized. The owner must call
/// every method from the camera sample queue. This keeps the Vision sequence handler
/// and its request confined to one serial execution context.
nonisolated final class PersonSegmentationDetector: @unchecked Sendable {
    nonisolated struct Configuration: Sendable {
        var quality: VNGeneratePersonSegmentationRequest.QualityLevel = .fast
        var maskThreshold: UInt8 = 128
        var minimumCoverage: Double = 0.60
        var maximumEdgeJump: Double = 0.08
        var minimumImageWidth: Double = 0.12
        var minimumFaceWidthMultiplier: Double = 1.5
        var maximumPolylinePoints = 48

        static let diagnosticDefault = Configuration()
    }

    private let configuration: Configuration
    private var request: VNGeneratePersonSegmentationRequest?
    private var sequenceHandler: VNSequenceRequestHandler?
    private(set) var isActive = false

    init(configuration: Configuration = .diagnosticDefault) {
        self.configuration = configuration
    }

    /// Creates a fresh stateful request and sequence handler for a camera activation.
    func activate() {
        request = makeRequest()
        sequenceHandler = VNSequenceRequestHandler()
        isActive = true
    }

    /// Drops Vision's temporal state and any in-flight activation state.
    func deactivate() {
        isActive = false
        request = nil
        sequenceHandler = nil
    }

    func reset() {
        let wasActive = isActive
        deactivate()
        if wasActive { activate() }
    }

    /// Runs segmentation on the complete timestamped sample buffer. The result is
    /// reduced synchronously to polylines/scalars before the mask is unlocked/released.
    func detect(
        in sampleBuffer: CMSampleBuffer,
        faceAnchor: PersonSegmentationFaceAnchor?
    ) -> PersonSegmentationResult {
        let start = ProcessInfo.processInfo.systemUptime

        guard isActive else {
            return .error(
                .inactive,
                measurement: measurement(from: start, result: .error, performedVision: false)
            )
        }
        guard let faceAnchor, faceAnchor.isValid else {
            return .insufficient(
                .missingFaceAnchor,
                measurement: measurement(from: start, result: .insufficient, performedVision: false)
            )
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, timestamp.isNumeric else {
            reset()
            return .error(
                .missingTimestamp,
                measurement: measurement(from: start, result: .error, performedVision: false)
            )
        }
        guard let request, let sequenceHandler else {
            return .error(
                .inactive,
                measurement: measurement(from: start, result: .error, performedVision: false)
            )
        }

        do {
            // This is deliberately the CMSampleBuffer overload. Stateful requests
            // require timestamps and must not be routed through a pixel-buffer handler.
            try sequenceHandler.perform(
                [request],
                on: sampleBuffer,
                orientation: .up
            )
            guard let observation = request.results?.first else {
                return .insufficient(
                    .noMaskObservation,
                    measurement: measurement(from: start, result: .noObservation, performedVision: true)
                )
            }

            let mask = observation.pixelBuffer
            guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else {
                reset()
                return .error(
                    .unsupportedMaskFormat,
                    measurement: measurement(from: start, result: .error, performedVision: true)
                )
            }

            guard CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else {
                return .error(
                    .maskLockFailed,
                    measurement: measurement(from: start, result: .error, performedVision: true)
                )
            }
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
            let width = CVPixelBufferGetWidth(mask)
            let height = CVPixelBufferGetHeight(mask)
            let baseAddress = CVPixelBufferIsPlanar(mask)
                ? CVPixelBufferGetBaseAddressOfPlane(mask, 0)
                : CVPixelBufferGetBaseAddress(mask)
            let bytesPerRow = CVPixelBufferIsPlanar(mask)
                ? CVPixelBufferGetBytesPerRowOfPlane(mask, 0)
                : CVPixelBufferGetBytesPerRow(mask)
            guard let baseAddress else {
                return .error(
                    .maskBaseAddressUnavailable,
                    measurement: measurement(from: start, result: .error, performedVision: true)
                )
            }
            guard width > 0, height > 0, bytesPerRow >= width else {
                return .error(
                    .maskStrideInvalid,
                    measurement: measurement(from: start, result: .error, performedVision: true)
                )
            }
            let contour = PersonSilhouetteExtractor.extract(
                baseAddress: UnsafeRawPointer(baseAddress),
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                faceAnchor: faceAnchor,
                configuration: configuration
            )

            guard let contour else {
                return .insufficient(
                    .insufficientContour,
                    measurement: measurement(from: start, result: .insufficient, performedVision: true)
                )
            }
            return .contour(
                contour,
                measurement: measurement(from: start, result: .contour, performedVision: true)
            )
        } catch {
            // A stateful request can retain temporal evidence. Recreate both objects
            // after an error so the next activation cannot inherit a broken sequence.
            reset()
            return .error(
                .vision(error.localizedDescription),
                measurement: measurement(from: start, result: .error, performedVision: true)
            )
        }
    }

    private func makeRequest() -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = configuration.quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    private func measurement(
        from start: TimeInterval,
        result: PersonSegmentationMeasurement.ResultKind,
        performedVision: Bool
    ) -> PersonSegmentationMeasurement {
        PersonSegmentationMeasurement(
            duration: max(0, ProcessInfo.processInfo.systemUptime - start),
            result: result,
            performedVision: performedVision
        )
    }
}

/// Pure extractor. It accepts only a transient read-only mask view and never stores it.
nonisolated enum PersonSilhouetteExtractor {
    static func extract(
        baseAddress: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        faceAnchor: PersonSegmentationFaceAnchor,
        configuration: PersonSegmentationDetector.Configuration = .diagnosticDefault
    ) -> PersonSilhouetteContour? {
        guard width > 0, height > 0, bytesPerRow >= width, faceAnchor.isValid else {
            return nil
        }

        let roi = roi(for: faceAnchor)
        let minX = max(0, min(width - 1, Int(floor(roi.minX * CGFloat(width)))))
        let maxX = max(minX + 1, min(width, Int(ceil(roi.maxX * CGFloat(width)))))
        let minY = max(0, min(height - 1, Int(floor(roi.minY * CGFloat(height)))))
        let maxY = max(minY + 1, min(height, Int(ceil(roi.maxY * CGFloat(height)))))
        guard maxX > minX, maxY > minY else { return nil }

        var runs: [(y: Int, left: Int, right: Int)] = []
        var previous: (left: Int, right: Int)?
        var encounteredEdgeJump = false
        let threshold = configuration.maskThreshold

        for y in minY..<maxY {
            let row = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            var candidates: [(left: Int, right: Int)] = []
            var runStart: Int?
            for x in minX..<maxX {
                if row[x] >= threshold {
                    runStart = runStart ?? x
                } else if let start = runStart {
                    candidates.append((start, x - 1))
                    runStart = nil
                }
            }
            if let start = runStart { candidates.append((start, maxX - 1)) }
            candidates = mergeNearbyRuns(candidates, maximumGap: max(1, Int(0.04 * CGFloat(width))))

            guard let selected = selectRun(
                candidates,
                previous: previous,
                faceCenterX: faceAnchor.bounds.midX * CGFloat(width)
            ) else {
                continue
            }
            if let previous,
               abs(selected.left - previous.left) > Int(configuration.maximumEdgeJump * CGFloat(width))
                || abs(selected.right - previous.right) > Int(configuration.maximumEdgeJump * CGFloat(width)) {
                encounteredEdgeJump = true
                continue
            }
            runs.append((y, selected.left, selected.right))
            previous = selected
        }

        let rowCount = maxY - minY
        let coverage = Double(runs.count) / Double(max(1, rowCount))
        guard !encounteredEdgeJump,
              coverage >= configuration.minimumCoverage,
              runs.count >= 3 else { return nil }

        let widths = runs.map { Double($0.right - $0.left + 1) / Double(width) }
        let medianWidth = median(widths)
        let minimumWidth = max(
            configuration.minimumImageWidth,
            configuration.minimumFaceWidthMultiplier * Double(faceAnchor.bounds.width)
        )
        guard medianWidth >= minimumWidth else { return nil }

        let compactRuns = compact(runs, maximumPoints: configuration.maximumPolylinePoints)
        guard compactRuns.count >= 2 else { return nil }
        let left = PersonSilhouettePolyline(
            side: .left,
            locations: compactRuns.map {
                CGPoint(x: CGFloat($0.left) / CGFloat(width), y: CGFloat($0.y) / CGFloat(height))
            }
        )
        let right = PersonSilhouettePolyline(
            side: .right,
            locations: compactRuns.map {
                CGPoint(x: CGFloat($0.right) / CGFloat(width), y: CGFloat($0.y) / CGFloat(height))
            }
        )
        return PersonSilhouetteContour(
            left: left,
            right: right,
            jawAnchor: faceAnchor.jawPoint,
            roi: roi,
            coverage: coverage,
            medianWidth: medianWidth
        )
    }

    private static func roi(for faceAnchor: PersonSegmentationFaceAnchor) -> CGRect {
        let faceWidth = max(faceAnchor.bounds.width, 0.0001)
        let faceHeight = max(faceAnchor.bounds.height, 0.0001)
        let minX = max(0, min(1, faceAnchor.bounds.minX - 0.75 * faceWidth))
        let maxX = max(minX, min(1, faceAnchor.bounds.maxX + 0.75 * faceWidth))
        let minY = max(0, min(1, faceAnchor.jawPoint.y + 0.02 * faceHeight))
        let maxY = max(minY, min(1, faceAnchor.jawPoint.y + 2.5 * faceHeight))
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func selectRun(
        _ candidates: [(left: Int, right: Int)],
        previous: (left: Int, right: Int)?,
        faceCenterX: CGFloat
    ) -> (left: Int, right: Int)? {
        guard !candidates.isEmpty else { return nil }
        if let previous {
            let best = candidates.max { lhs, rhs in
                overlap(lhs, previous) * 10 - distance(lhs, previous)
                    < overlap(rhs, previous) * 10 - distance(rhs, previous)
            }
            // A disconnected secondary component must be treated as a hole,
            // never as the continuation of the torso run.
            guard let best, overlap(best, previous) > 0 else { return nil }
            return best
        }
        return candidates.min {
            abs(CGFloat(($0.left + $0.right) / 2) - faceCenterX)
                < abs(CGFloat(($1.left + $1.right) / 2) - faceCenterX)
        }
    }

    private static func mergeNearbyRuns(
        _ candidates: [(left: Int, right: Int)],
        maximumGap: Int
    ) -> [(left: Int, right: Int)] {
        guard candidates.count > 1 else { return candidates }
        let sorted = candidates.sorted { $0.left < $1.left }
        var merged: [(left: Int, right: Int)] = []
        for candidate in sorted {
            guard let previous = merged.last else {
                merged.append(candidate)
                continue
            }
            if candidate.left - previous.right - 1 <= maximumGap {
                merged[merged.count - 1] = (previous.left, max(previous.right, candidate.right))
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }

    private static func overlap(
        _ lhs: (left: Int, right: Int),
        _ rhs: (left: Int, right: Int)
    ) -> Double {
        Double(max(0, min(lhs.right, rhs.right) - max(lhs.left, rhs.left) + 1))
    }

    private static func distance(
        _ lhs: (left: Int, right: Int),
        _ rhs: (left: Int, right: Int)
    ) -> Double {
        Double(abs(lhs.left - rhs.left) + abs(lhs.right - rhs.right))
    }

    private static func compact(
        _ runs: [(y: Int, left: Int, right: Int)],
        maximumPoints: Int
    ) -> [(y: Int, left: Int, right: Int)] {
        let count = min(maximumPoints, runs.count)
        guard count > 0, runs.count > count else { return runs }
        return (0..<count).map { index in
            let sourceIndex = Int(round(Double(index) * Double(runs.count - 1) / Double(count - 1)))
            return runs[sourceIndex]
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

nonisolated private extension PersonSegmentationFaceAnchor {
    var isValid: Bool {
        jawPoint.x.isFinite && jawPoint.y.isFinite
            && bounds.minX.isFinite && bounds.minY.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width > 0 && bounds.height > 0
            && (0...1).contains(jawPoint.x)
            && (0...1).contains(jawPoint.y)
    }
}
