import CoreML
import CoreVideo
import Foundation

/// Native Core ML experiment. No ONNX Runtime session is created in this mode.
nonisolated final class RTMPoseCoreMLAdapter: UpperBodyPoseEngine, @unchecked Sendable {
    enum Precision: Sendable { case fp32, int8 }

    let descriptor: UpperBodyEngineDescriptor
    private let precision: Precision
    private var model: MLModel?
    private var generation: UInt64?
    private var shoulderStabilizer = UpperBodyShoulderStabilizer()

    init(precision: Precision) {
        self.precision = precision
        descriptor = .init(
            id: precision == .int8 ? "rtmpose-coreml-int8" : "rtmpose-coreml-fp32",
            displayName: precision == .int8 ? "RTMPose Core ML INT8" : "RTMPose Core ML FP32",
            version: "20230605-4d3e73dd", runtime: "Core ML natif"
        )
    }

    func activate(generation: UInt64) {
        deactivate()
        self.generation = generation
        guard let url = Self.modelURL(for: precision) else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: url, configuration: configuration)
    }

    func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
        guard generation == frame.generation else {
            return .init(state: .stale, points: [], contours: [])
        }
        guard let model,
              CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA,
              let roi = frame.regionOfInterest,
              roi.isAdmissible(forFrameCapturedAt: frame.capturedAt, generation: frame.generation,
                               maximumSkew: RTMPoseUpperBodyCropPolicy.maximumFaceAnchorSkew)
        else {
            shoulderStabilizer.reset()
            return .init(state: model == nil ? .technicalError : .partial,
                         points: [], contours: [])
        }
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let crop = AlignRTMPoseNormalizedCrop(
            x: Float(roi.rect.minX), y: Float(roi.rect.minY),
            width: Float(roi.rect.width), height: Float(roi.rect.height)
        )
        do {
            let input = try MLMultiArray(shape: [1, 3, 256, 192], dataType: .float32)
            CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
            let built: Int32
            if let base = CVPixelBufferGetBaseAddress(frame.pixelBuffer) {
                built = AlignRTMPoseBuildTensor(
                    base.assumingMemoryBound(to: UInt8.self), width, height,
                    CVPixelBufferGetBytesPerRow(frame.pixelBuffer), crop,
                    input.dataPointer.assumingMemoryBound(to: Float.self)
                )
            } else {
                built = 0
            }
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly)
            guard built != 0 else { throw CoreMLEngineError.invalidInput }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input": input])
            let prediction = try model.prediction(from: provider)
            guard let x = prediction.featureValue(for: "simcc_x")?.multiArrayValue,
                  let y = prediction.featureValue(for: "simcc_y")?.multiArrayValue,
                  x.shape.map(\.intValue) == [1, 26, 384],
                  y.shape.map(\.intValue) == [1, 26, 512],
                  x.dataType == .float32, y.dataType == .float32 else {
                throw CoreMLEngineError.invalidOutput
            }
            let content = AlignRTMPoseModelContentRectForCrop(crop, width, height)
            var mapped: [UpperBodyPoint] = []
            var scores: [UpperBodyLandmarkID: Float] = [:]
            for (index, id) in UpperBodyLandmarkID.rtmposeMapping {
                let xPeak = Self.peak(x, point: index, bins: 384)
                let yPeak = Self.peak(y, point: index, bins: 512)
                let score = min(xPeak.value, yPeak.value)
                scores[id] = score
                var projectedX: Float = 0
                var projectedY: Float = 0
                let inside = AlignRTMPoseProjectPointWithContent(
                    crop, content, Float(xPeak.index) / 384,
                    Float(yPeak.index) / 512, &projectedX, &projectedY
                )
                guard inside != 0, score.isFinite, (0.20...1).contains(score),
                      projectedX.isFinite, projectedY.isFinite,
                      (0...1).contains(projectedX), (0...1).contains(projectedY) else { continue }
                mapped.append(.init(
                    id: id, location: CGPoint(x: CGFloat(projectedX), y: CGFloat(projectedY)),
                    confidence: score, quality: score >= 0.5 ? .good : .limited,
                    provenance: .observed
                ))
            }
            let points = shoulderStabilizer.stabilize(
                points: mapped, generation: frame.generation,
                sampleID: frame.sampleID, capturedAt: frame.capturedAt,
                regionSource: roi.source
            )
            return .init(
                state: points.isEmpty ? .noPerson : .detected,
                points: points, contours: [], regionOfInterest: roi,
                diagnostics: .init(
                    usedCoreML: true, validLandmarkCount: points.count,
                    simCCMinimum: nil, simCCMaximum: nil,
                    scoreMinimum: scores.values.min(), scoreMaximum: scores.values.max(),
                    leftShoulderScore: scores[.leftShoulder],
                    rightShoulderScore: scores[.rightShoulder]
                )
            )
        } catch {
            shoulderStabilizer.reset()
            return .init(state: .technicalError, points: [], contours: [])
        }
    }

    func deactivate() {
        generation = nil
        model = nil
        shoulderStabilizer.reset()
    }

    private static func peak(_ values: MLMultiArray, point: Int, bins: Int) -> (index: Int, value: Float) {
        var peak: Float = -.infinity
        var best = 0
        let base = values.dataPointer.assumingMemoryBound(to: Float.self)
        let pointOffset = point * values.strides[1].intValue
        let binStride = values.strides[2].intValue
        for bin in 0..<bins {
            let value = base[pointOffset + bin * binStride]
            if value.isFinite && value > peak {
                peak = value
                best = bin
            }
        }
        return (best, peak.isFinite ? peak : 0)
    }

    private static func modelURL(for precision: Precision) -> URL? {
        let name = precision == .int8
            ? "rtmpose-m-halpe26-native-int8" : "rtmpose-m-halpe26-native-fp32"
        for folder in ["Pose/RTMPose/Models", "RTMPose/Models", nil] {
            if let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: folder) {
                return compiled
            }
            if let package = Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: folder) {
                return try? MLModel.compileModel(at: package)
            }
        }
        return nil
    }

    private enum CoreMLEngineError: Error { case invalidInput, invalidOutput }
}
