import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import FaceUnlockRecognition

@MainActor
final class RecognitionTestModel: ObservableObject {
    @Published private(set) var status = "Model not tested"
    @Published private(set) var isBusy = false
    @Published private(set) var isValidated = false
    @Published private(set) var report = ""
    private var recognizer: ArcFaceRecognizer?
    private var operation: Task<Void, Never>?

    func runSelfTest() {
        guard !isBusy else { return }
        guard let model = Bundle.main.url(forResource: "ArcFace", withExtension: "mlmodelc"),
              let reference = Bundle.main.url(forResource: "ArcFaceReference", withExtension: "json") else {
            status = RecognitionError.missingModel.localizedDescription
            isValidated = false
            return
        }
        isBusy = true
        isValidated = false
        report = ""
        status = "Loading ArcFace and checking synthetic reference outputs…"
        let recognizer = ArcFaceRecognizer(modelURL: model)
        self.recognizer = recognizer
        operation = Task {
            defer { isBusy = false }
            do {
                let result = try await recognizer.validateAndBenchmark(referenceURL: reference)
                try Task.checkCancellation()
                isValidated = true
                status = "Model loaded; 5 synthetic ONNX reference cases passed. Identity verification is not enabled."
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                report = String(decoding: try encoder.encode(result), as: UTF8.self)
            } catch {
                isValidated = false
                self.recognizer = nil
                status = error is CancellationError ? "Model test canceled" : error.localizedDescription
            }
        }
    }

    func chooseImage() {
        guard !isBusy, isValidated, let recognizer else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Analyze one local image. The image and face descriptor stay in memory and are not saved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        status = "Detecting, aligning and embedding one face…"
        operation = Task {
            defer { isBusy = false }
            do {
                let result = try await recognizer.analyzeImage(at: url)
                try Task.checkCancellation()
                let quality = result.quality.map { String(format: "%.2f", $0) } ?? "unavailable"
                // Do not publish the embedding, file name, or image. No enrolled identity exists yet.
                status = "One face aligned to 112×112; \(result.embedding.dimensions)-number descriptor generated. Capture quality: \(quality). Inference: \(String(format: "%.1f", result.inferenceMilliseconds)) ms. This does not identify you or prove liveness."
            } catch {
                status = error is CancellationError ? "Image analysis canceled" : error.localizedDescription
            }
        }
    }

    func cancel() { operation?.cancel() }
}
