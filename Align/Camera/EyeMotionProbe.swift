import CoreGraphics
import CoreVideo

/// Samples a tiny fixed grid from the two eye regions on every camera frame.
/// It does not decide whether an eye is open or count a blink; it only wakes
/// the proven Vision landmark pipeline when the appearance changes. Therefore
/// an uncertain probe costs more CPU but can never manufacture a blink.
nonisolated struct EyeMotionProbe: Sendable {
    private static let columns = 8
    private static let rows = 4
    // Deliberately sensitive: false wake-ups only cost a short CPU burst,
    // whereas a missed wake-up could lose a blink.
    private static let motionThreshold = 0.015
    private static let regionChangeThreshold: CGFloat = 0.02

    private var regions: [CGRect] = []
    private var referenceSamples: [UInt8]?

    mutating func updateRegions(
        from polylines: [PosePolyline]
    ) -> (isAvailable: Bool, referenceChanged: Bool) {
        let updated = ["leftEye", "rightEye"].compactMap { name -> CGRect? in
            guard let points = polylines.first(where: { $0.name == name })?.locations,
                  !points.isEmpty else { return nil }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return nil }
            let width = max(maxX - minX, 0.001)
            let height = max(maxY - minY, 0.001)
            return CGRect(
                x: max(0, minX - width * 0.35),
                y: max(0, minY - height * 0.8),
                width: min(1, maxX + width * 0.35) - max(0, minX - width * 0.35),
                height: min(1, maxY + height * 0.8) - max(0, minY - height * 0.8)
            )
        }
        guard updated.count == 2 else {
            reset()
            return (false, true)
        }
        let changed = regions.count != updated.count || zip(regions, updated).contains { pair in
            let previous = pair.0
            let next = pair.1
            return abs(previous.minX - next.minX) > Self.regionChangeThreshold ||
                abs(previous.minY - next.minY) > Self.regionChangeThreshold ||
                abs(previous.width - next.width) > Self.regionChangeThreshold ||
                abs(previous.height - next.height) > Self.regionChangeThreshold
        }
        regions = updated
        if changed { referenceSamples = nil }
        return (true, changed)
    }

    mutating func observe(_ pixelBuffer: CVPixelBuffer) -> (isReliable: Bool, detectedMotion: Bool) {
        guard regions.count == 2, let samples = samples(from: pixelBuffer) else {
            return (false, false)
        }
        guard let referenceSamples, referenceSamples.count == samples.count else {
            self.referenceSamples = samples
            return (true, false)
        }
        let difference = zip(referenceSamples, samples).reduce(0.0) {
            $0 + abs(Double($1.0) - Double($1.1)) / 255.0
        } / Double(samples.count)
        if difference >= Self.motionThreshold {
            return (true, true)
        }
        self.referenceSamples = zip(referenceSamples, samples).map {
            UInt8((3 * Int($0.0) + Int($0.1)) / 4)
        }
        return (true, false)
    }

    mutating func reset() {
        regions = []
        referenceSamples = nil
    }

    private func samples(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var result: [UInt8] = []
        result.reserveCapacity(regions.count * Self.columns * Self.rows)
        for region in regions {
            for row in 0..<Self.rows {
                for column in 0..<Self.columns {
                    let normalizedX = region.minX + region.width * CGFloat(2 * column + 1) /
                        CGFloat(2 * Self.columns)
                    let normalizedY = region.minY + region.height * CGFloat(2 * row + 1) /
                        CGFloat(2 * Self.rows)
                    let x = min(width - 1, max(0, Int(normalizedX * CGFloat(width))))
                    let y = min(height - 1, max(0, Int(normalizedY * CGFloat(height))))
                    if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                            return nil
                        }
                        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                        result.append(base.assumingMemoryBound(to: UInt8.self)[y * stride + x])
                    } else if format == kCVPixelFormatType_32BGRA {
                        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
                        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                        let pixel = base.assumingMemoryBound(to: UInt8.self) + y * stride + x * 4
                        let luma = (29 * Int(pixel[0]) + 150 * Int(pixel[1]) + 77 * Int(pixel[2])) >> 8
                        result.append(UInt8(clamping: luma))
                    } else {
                        return nil
                    }
                }
            }
        }
        return result
    }
}
