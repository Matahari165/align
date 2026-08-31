import CoreGraphics
import Foundation

/// Crop top-down RTMPose en coordonnées image top-left non miroir.
/// La rotation faciale n'entre jamais dans le calcul : elle reste un signal
/// séparé, jamais une transformation du torse.
nonisolated enum RTMPoseUpperBodyCropPolicy {
    /// Maximum age accepted for a face anchor on a later upper-body frame.
    /// This is a temporal admission bound, not a personal calibration.
    static let maximumFaceAnchorSkew = UpperBodyRegionOfInterest.maximumAnchorSkew

    static func faceAnchored(
        center: CGPoint,
        faceSize: CGSize,
        imageSize: CGSize
    ) -> AlignRTMPoseNormalizedCrop {
        AlignRTMPoseFaceAnchoredCrop(
            Float(center.x), Float(center.y), Float(faceSize.width),
            Float(faceSize.height), Int(imageSize.width), Int(imageSize.height)
        )
    }

    /// Builds the canonical ROI from the already-converted face contour.
    /// `faceContour` is normalized top-left/non-mirrored output from Vision;
    /// no roll or mirror transformation is applied here.
    static func faceAnchored(
        faceContour: [CGPoint],
        imageSize: CGSize,
        capturedAt: TimeInterval,
        sampleID: UInt64,
        generation: UInt64
    ) -> UpperBodyRegionOfInterest? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              capturedAt.isFinite, generation > 0,
              let bounds = finiteBounds(of: faceContour) else { return nil }
        let crop = faceAnchored(
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            faceSize: bounds.size,
            imageSize: imageSize
        )
        let rect = CGRect(
            x: CGFloat(crop.x), y: CGFloat(crop.y),
            width: CGFloat(crop.width), height: CGFloat(crop.height)
        )
        let roi = UpperBodyRegionOfInterest(
            rect: rect,
            capturedAt: capturedAt,
            anchorCapturedAt: capturedAt,
            anchorSampleID: sampleID,
            generation: generation,
            source: .sameFrameFace
        )
        return roi.isValid ? roi : nil
    }

    /// Legacy diagnostic helper only. Production analysis must provide a
    /// fresh face ROI; this full-frame-shaped rectangle is never selected by
    /// `RTMPoseUpperBodyAdapter` as a silent fallback.
    static func fixed(imageSize: CGSize) -> AlignRTMPoseNormalizedCrop {
        _ = imageSize
        return AlignRTMPoseNormalizedCrop(x: 0.05, y: 0.02, width: 0.90, height: 0.96)
    }

    private static func finiteBounds(of points: [CGPoint]) -> CGRect? {
        let finite = points.filter { point in
            point.x.isFinite && point.y.isFinite &&
                (0...1).contains(point.x) && (0...1).contains(point.y)
        }
        guard let first = finite.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in finite.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
