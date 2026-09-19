import CoreML
import Foundation

@main
enum RTMPoseCoreMLSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: RTMPoseCoreMLSmoke /path/to/Align.app")
        }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        for variant in ["fp32", "int8"] {
            let url = resources.appendingPathComponent(
                "rtmpose-m-halpe26-native-\(variant).mlmodelc", isDirectory: true
            )
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let input = try MLMultiArray(shape: [1, 3, 256, 192], dataType: .float32)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input": input])
            let output = try model.prediction(from: provider)
            guard output.featureValue(for: "simcc_x")?.multiArrayValue?.shape.map(\.intValue) == [1, 26, 384],
                  output.featureValue(for: "simcc_y")?.multiArrayValue?.shape.map(\.intValue) == [1, 26, 512] else {
                fatalError("Unexpected Core ML output shape: \(variant)")
            }
            print("Core ML \(variant): compiled bundle model loaded and predicted")
        }
    }
}
