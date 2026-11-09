import Foundation
import FaceUnlockRecognition

@main
struct RecognitionDiagnostics {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            print("Usage: FaceRecognitionDiagnostics <ArcFace.mlmodelc> <ArcFaceReference.json>")
            Foundation.exit(2)
        }
        do {
            let recognizer = ArcFaceRecognizer(modelURL: URL(fileURLWithPath: arguments[0]))
            let report = try await recognizer.validateAndBenchmark(referenceURL: URL(fileURLWithPath: arguments[1]))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } catch {
            print("Recognition disabled: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }
}
