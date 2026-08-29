@preconcurrency import Vision
import CoreGraphics
import CoreVideo
import Foundation

nonisolated struct HumanRectangleDetection: Sendable, Equatable {
    let resultCount: Int
    let confidence: Float?
    let regionOfInterest: CGRect?
    let duration: TimeInterval

    var isAccepted: Bool { regionOfInterest != nil }
}

nonisolated struct UpperBodyROISpikeDiagnostics: Sendable, Equatable {
    static let empty = UpperBodyROISpikeDiagnostics()
    var rectangleAttempts = 0
    var rectangleResults = 0
    var rectangleAccepted = 0
    var rectangleErrors = 0
    var rectangleConfidence: Float?
    var rectangleDuration: TimeInterval?
    var fullFrameAttempts = 0
    var fullFrameCoverage: Int?
    var fullFrameDuration: TimeInterval?
    var regionAttempts = 0
    var regionCoverage: Int?
    var regionDuration: TimeInterval?

    mutating func clearBodyComparison() {
        fullFrameCoverage = nil
        fullFrameDuration = nil
        regionCoverage = nil
        regionDuration = nil
    }

    mutating func clearRegionComparison() {
        regionCoverage = nil
        regionDuration = nil
    }

    var summary: String {
        let confidence = rectangleConfidence.map { String(format: "%.0f", $0 * 100) } ?? "—"
        let rectangleMS = rectangleDuration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
        let fullMS = fullFrameDuration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
        let roiMS = regionDuration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
        return "rectangle brut/accepté \(rectangleResults)/\(rectangleAccepted) sur \(rectangleAttempts), confiance \(confidence), \(rectangleMS) · corps plein \(fullFrameCoverage.map(String.init) ?? "—")/3, \(fullMS) · ROI \(regionCoverage.map(String.init) ?? "—")/3, \(roiMS)"
    }
}

nonisolated enum UpperBodyROISpikeMeasurement: Sendable {
    case rectangle(resultCount: Int, accepted: Bool, confidence: Float?, duration: TimeInterval, error: Bool)
    case fullFrame(coverage: Int?, duration: TimeInterval, error: Bool)
    case region(coverage: Int?, duration: TimeInterval, error: Bool)
}

nonisolated enum UpperBodyROIMapper {
    static func expandedRegion(from rectangle: CGRect, margin: CGFloat = 0.18) -> CGRect? {
        guard rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite,
              rectangle.width > 0, rectangle.height > 0 else { return nil }
        let expanded = rectangle.insetBy(dx: -rectangle.width * margin, dy: -rectangle.height * margin)
        let clamped = expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }
}

nonisolated final class HumanRectangleDetector: @unchecked Sendable {
    static let minimumConfidence: Float = 0.5
    private let request: VNDetectHumanRectanglesRequest

    init() {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        self.request = request
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> HumanRectangleDetection {
        let start = ProcessInfo.processInfo.systemUptime
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let duration = ProcessInfo.processInfo.systemUptime - start
        let results = request.results ?? []
        let primary = results.max { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }
        let accepted = primary.flatMap { $0.confidence >= Self.minimumConfidence ? $0 : nil }
        return HumanRectangleDetection(
            resultCount: results.count,
            confidence: primary?.confidence,
            regionOfInterest: accepted.flatMap { UpperBodyROIMapper.expandedRegion(from: $0.boundingBox) },
            duration: duration
        )
    }
}
