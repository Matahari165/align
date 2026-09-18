// Compilé avec le worker réel extrait par UpperBodyInferenceWorkerHarness.sh.
// Seul le moteur natif est remplacé par une inférence contrôlable.
import CoreVideo
nonisolated private final class WorkerProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let delivered = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var completions: [UpperBodyInferenceCompletion] = []
    func receive(_ c: UpperBodyInferenceCompletion) { lock.lock(); completions.append(c); lock.unlock(); delivered.signal() }
    func values() -> [UpperBodyInferenceCompletion] { lock.lock(); defer {lock.unlock()}; return completions }
}
nonisolated private let workerProbe = WorkerProbe()
nonisolated private final class RTMPoseUpperBodyAdapter: UpperBodyPoseEngine, @unchecked Sendable {
    let descriptor = UpperBodyEngineDescriptor(id: "fake", displayName: "Fake", version: "1", runtime: "test")
    func activate(generation: UInt64) {}
    func deactivate() {}
    func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
        workerProbe.started.signal()
        _ = workerProbe.resume.wait(timeout: .now() + 4)
        return .init(state: .detected, points: [], contours: [])
    }
}
nonisolated private enum BlazePoseModelVariant { case lite }
nonisolated private final class BlazePoseUpperBodyAdapter: UpperBodyPoseEngine, @unchecked Sendable {
    let descriptor = UpperBodyEngineDescriptor(id: "fake-lite", displayName: "Fake Lite", version: "1", runtime: "test")
    init(modelVariant: BlazePoseModelVariant) {}
    func activate(generation: UInt64) {}
    func deactivate() {}
    func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
        .init(state: .detected, points: [], contours: [])
    }
}
@main
private enum WorkerTest {
    static func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func request(_ generation: UInt64, _ sample: UInt64) -> UpperBodyInferenceRequest {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        return .init(frame: .init(pixelBuffer: buffer!, capturedAt: ProcessInfo.processInfo.systemUptime,
                                 sampleID: sample, generation: generation, regionOfInterest: nil),
                     poseGeneration: .init(operationID: Int(generation), activationID: Int(generation)),
                     contextKey: "camera", targetEpoch: 1, face: nil)
    }
    static func main() {
        let worker = UpperBodyInferenceWorker(modelMode: .precise) { workerProbe.receive($0) }
        worker.setActive(true, generation: 1)
        let sampleQueue = DispatchQueue(label: "test.capture")
        let accepted = DispatchSemaphore(value: 0)
        sampleQueue.async { expect(worker.submit(request(1, 1)), "first admission"); accepted.signal() }
        expect(accepted.wait(timeout: .now() + 1) == .success, "submit blocks sample queue")
        expect(workerProbe.started.wait(timeout: .now() + 1) == .success, "engine starts")
        expect(!worker.submit(request(1, 2)), "no backlog allowed")
        let faceTick = DispatchSemaphore(value: 0)
        sampleQueue.async { faceTick.signal() }
        expect(faceTick.wait(timeout: .now() + 0.15) == .success, "face queue must remain free during inference")
        Thread.sleep(forTimeInterval: 0.4)
        worker.setActive(false, generation: 1)
        workerProbe.resume.signal()
        expect(workerProbe.delivered.wait(timeout: .now() + 0.2) == .timedOut, "old activation must not publish")
        worker.setActive(true, generation: 2)
        expect(worker.submit(request(2, 1)), "new activation accepted")
        expect(workerProbe.started.wait(timeout: .now() + 1) == .success, "new engine starts")
        workerProbe.resume.signal()
        expect(workerProbe.delivered.wait(timeout: .now() + 1) == .success, "fresh result delivered")
        expect(workerProbe.values().last?.result?.generation == 2, "new generation result")
        expect(worker.submit(request(2, 2)), "slow result admitted")
        expect(workerProbe.started.wait(timeout: .now() + 1) == .success, "slow engine starts")
        Thread.sleep(forTimeInterval: 1.3)
        workerProbe.resume.signal()
        expect(workerProbe.delivered.wait(timeout: .now() + 1) == .success, "late completion delivered for rejection")
        expect(workerProbe.values().last?.result == nil && workerProbe.values().last?.rejectionReason == .postInferenceExpired, "expired inference never becomes a valid result")
        worker.setActive(false, generation: 2)
        print("UpperBodyInferenceWorkerHarness: OK (actual worker source, fake inference)")
    }
}
