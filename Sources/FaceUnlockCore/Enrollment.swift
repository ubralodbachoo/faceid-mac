import Foundation

public enum EnrollmentError: Error, LocalizedError {
    case quality, pose, lighting, incomplete, incompatible, expired, corrupt, busy, faceLimit, noEnabledFaces, invalidName
    public var errorDescription: String? {
        switch self {
        case .quality: "Use even light, hold still, and keep one unobstructed face closer to the camera."
        case .pose: "Follow the current pose instruction with a small movement; keep your head level."
        case .lighting: "Change the light on your face a little more, then look straight at the camera."
        case .incomplete: "Complete the guided face scan before saving. The saved enrollment was not changed."
        case .incompatible: "This saved face uses a different model or capture format. Register again before verification."
        case .expired: "The biometric session expired or was canceled. Authorize again."
        case .corrupt: "The encrypted enrollment could not be validated. No template was made available."
        case .busy: "An enrollment operation is already running."
        case .noEnabledFaces: "Enable at least one face in Settings → Faces."
        case .invalidName: "Use a face name of 1–40 characters, without control characters."
        case .faceLimit: "You can save up to three faces. Register again to replace your saved faces."
        }
    }
}

public enum EnrollmentStep: String, Codable, CaseIterable, Sendable {
    case center, turnOneSide, turnOtherSide, tiltUp, tiltDown, brighter, dimmer
    public var title: String {
        switch self {
        case .center: "Look straight ahead"
        case .turnOneSide: "Turn a little to one side"
        case .turnOtherSide: "Now turn the other way"
        case .tiltUp: "Lift your chin slightly"
        case .tiltDown: "Now lower your chin slightly"
        case .brighter: "Add a little light"
        case .dimmer: "Try slightly softer light"
        }
    }
    public var help: String {
        switch self {
        case .center: "Place your face inside the oval and hold still."
        case .turnOneSide: "Turn toward either shoulder, keeping your eyes near the camera."
        case .turnOtherSide: "Turn toward your other shoulder. A small movement is enough."
        case .tiltUp: "Keep facing the camera and gently tilt your head upward."
        case .tiltDown: "Tilt in the opposite direction without turning sideways."
        case .brighter: "Face a nearby lamp or add light in front of you. Look straight ahead."
        case .dimmer: "Reduce that light a little, keeping your face visible and facing forward."
        }
    }
    public var symbol: String {
        switch self {
        case .center: "person.crop.rectangle"
        case .turnOneSide, .turnOtherSide: "arrow.left.and.right"
        case .tiltUp: "arrow.up"
        case .tiltDown: "arrow.down"
        case .brighter: "sun.max"
        case .dimmer: "sun.min"
        }
    }
    public var instruction: String {
        switch self {
        case .center: "Look straight at the camera in normal light."
        case .turnOneSide: "Turn slightly to one side."
        case .turnOtherSide: "Turn slightly to the opposite side."
        case .tiltUp: "Look slightly upward."
        case .tiltDown: "Look slightly downward."
        case .brighter: "Look straight ahead and add a little light on your face."
        case .dimmer: "Look straight ahead and reduce the light a little; keep your face visible."
        }
    }
}

/// Capture heuristics, not an identity threshold or liveness test. Never logged or persisted.
public struct EnrollmentMetrics: Codable, Sendable {
    public let quality: Double
    public let yaw: Double
    public let pitch: Double
    public let roll: Double
    public let faceWidthPixels: Double
    public let faceHeightPixels: Double
    public let centered: Bool
    public let luminance: Double
    public let faceBounds: FaceBounds?

    public init(quality: Double, yaw: Double, pitch: Double, roll: Double,
                faceWidthPixels: Double, faceHeightPixels: Double, centered: Bool, luminance: Double,
                faceBounds: FaceBounds? = nil) {
        self.quality = quality; self.yaw = yaw; self.pitch = pitch; self.roll = roll
        self.faceWidthPixels = faceWidthPixels; self.faceHeightPixels = faceHeightPixels
        self.centered = centered; self.luminance = luminance
        self.faceBounds = faceBounds
    }

    public var adjustment: String? {
        guard [quality, yaw, pitch, roll, faceWidthPixels, faceHeightPixels, luminance].allSatisfy(\.isFinite) else {
            return "Face the camera so it can read your position."
        }
        if faceBounds?.isClipped == true { return "Move a little farther back so your whole face is visible." }
        if !centered { return "Move the detected face box toward the middle of the oval." }
        if faceWidthPixels < 120 || faceHeightPixels < 120 { return "Move a little closer to the camera." }
        if luminance < 45 { return "Add some light in front of your face." }
        if luminance > 220 { return "Reduce the bright light on your face." }
        if abs(roll) > 0.20 { return "Keep your head level, without leaning sideways." }
        if abs(yaw) > 0.50 || abs(pitch) > 0.40 { return "Turn back a little so the camera can see your face." }
        if !(0.35...1).contains(quality) { return "Hold still in even light, with your face unobstructed." }
        return nil
    }

    public func validate() throws {
        guard adjustment == nil else { throw EnrollmentError.quality }
    }
}

/// A complete, validated template. Printable forms deliberately exclude all descriptors.
public struct EnrollmentTemplate: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Format: Int, Sendable { case legacySevenViews = 1, continuousVideo = 2, multipleFaces = 3, managedFaces = 4 }
    public let format: Format
    public let modelIdentifier: String
    public let embeddings: [FaceEmbedding]
    public let additionalFaces: [[FaceEmbedding]]
    public let faceNames: [String]
    public let faceEnabled: [Bool]
    public static let maximumFaces = 3
    public var faces: [[FaceEmbedding]] { [embeddings] + additionalFaces }
    public var supportsComparison: Bool { format != .legacySevenViews }
    public var hasEnabledFaces: Bool { faceEnabled.contains(true) }
    public var description: String { "EnrollmentTemplate(biometric data and names: redacted)" }
    public var debugDescription: String { description }

    public init(embeddings: [FaceEmbedding], modelIdentifier: String, format: Format = .continuousVideo,
                additionalFaces: [[FaceEmbedding]] = [], faceNames: [String]? = nil, faceEnabled: [Bool]? = nil) throws {
        let requiredCount = format == .legacySevenViews ? 7 : VideoEnrollmentCollector.requiredSamples
        guard additionalFaces.count < Self.maximumFaces else { throw EnrollmentError.faceLimit }
        if format != .managedFaces {
            guard faceNames == nil, faceEnabled == nil else { throw EnrollmentError.incompatible }
            guard (format == .multipleFaces) == !additionalFaces.isEmpty else { throw EnrollmentError.incompatible }
        }
        guard additionalFaces.allSatisfy({ $0.count == requiredCount }), embeddings.count == requiredCount else { throw EnrollmentError.incomplete }
        guard !modelIdentifier.isEmpty, ([embeddings] + additionalFaces).joined().allSatisfy({ $0.modelIdentifier == modelIdentifier }) else {
            throw EnrollmentError.incompatible
        }
        let count = 1 + additionalFaces.count
        let names = faceNames ?? (0..<count).map { $0 == 0 ? "My face" : "Face \($0 + 1)" }
        let enabled = faceEnabled ?? Array(repeating: true, count: count)
        guard names.count == count, enabled.count == count else { throw EnrollmentError.corrupt }
        self.faceNames = try names.map(Self.validateName)
        self.faceEnabled = enabled
        self.embeddings = embeddings; self.modelIdentifier = modelIdentifier
        self.format = format; self.additionalFaces = additionalFaces
    }

    public static func validateName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, name.utf8.count <= 320,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw EnrollmentError.invalidName }
        return name
    }

    public func adding(_ face: EnrollmentTemplate) throws -> EnrollmentTemplate {
        guard supportsComparison, face.supportsComparison, face.faces.count == 1,
              face.modelIdentifier == modelIdentifier else { throw EnrollmentError.incompatible }
        guard faces.count < Self.maximumFaces else { throw EnrollmentError.faceLimit }
        return try rebuilt(faces: faces + [face.embeddings], names: faceNames + face.faceNames, enabled: faceEnabled + face.faceEnabled)
    }

    public func editingFace(at index: Int, name: String? = nil, enabled: Bool? = nil) throws -> EnrollmentTemplate {
        guard supportsComparison, faces.indices.contains(index) else { throw EnrollmentError.incompatible }
        var names = faceNames, states = faceEnabled
        if let name { names[index] = try Self.validateName(name) }
        if let enabled { states[index] = enabled }
        return try rebuilt(faces: faces, names: names, enabled: states)
    }

    public func replacingFace(at index: Int, with face: EnrollmentTemplate) throws -> EnrollmentTemplate {
        guard supportsComparison, faces.indices.contains(index), face.faces.count == 1,
              face.supportsComparison, face.modelIdentifier == modelIdentifier else { throw EnrollmentError.incompatible }
        var updated = faces, names = faceNames
        updated[index] = face.embeddings; names[index] = face.faceNames[0]
        return try rebuilt(faces: updated, names: names, enabled: faceEnabled)
    }

    public func removingFace(at index: Int) throws -> EnrollmentTemplate {
        guard supportsComparison, faces.indices.contains(index), faces.count > 1 else { throw EnrollmentError.incomplete }
        var updated = faces, names = faceNames, states = faceEnabled
        updated.remove(at: index); names.remove(at: index); states.remove(at: index)
        return try rebuilt(faces: updated, names: names, enabled: states)
    }

    private func rebuilt(faces: [[FaceEmbedding]], names: [String], enabled: [Bool]) throws -> EnrollmentTemplate {
        try EnrollmentTemplate(embeddings: faces[0], modelIdentifier: modelIdentifier, format: .managedFaces,
                               additionalFaces: Array(faces.dropFirst()), faceNames: names, faceEnabled: enabled)
    }
}

/// Legacy v1 collection, retained for compatibility tests only. Production uses VideoEnrollmentCollector.
public struct EnrollmentDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let modelIdentifier: String
    private var embeddings: [FaceEmbedding] = []
    private var baselineLuminance: Double?
    private var firstYaw: Double?
    private var firstPitch: Double?
    public var count: Int { embeddings.count }
    public var nextStep: EnrollmentStep? { count < EnrollmentStep.allCases.count ? EnrollmentStep.allCases[count] : nil }
    public var description: String { "EnrollmentDraft(samples: \(count), biometric data: redacted)" }
    public var debugDescription: String { description }

    public init(modelIdentifier: String) { self.modelIdentifier = modelIdentifier }

    public func poseAdjustment(for metrics: EnrollmentMetrics) -> String {
        switch nextStep {
        case .center, .brighter, .dimmer:
            if metrics.pitch > 0.10 { return "Lift your chin a little and look toward the camera lens." }
            if metrics.pitch < -0.10 { return "Lower your chin a little and look toward the camera lens." }
            return "Turn your nose toward the camera lens, without turning to either side."
        case .turnOneSide, .turnOtherSide:
            if metrics.pitch > 0.12 { return "Lift your chin a little while keeping the small sideways turn." }
            if metrics.pitch < -0.12 { return "Lower your chin a little while keeping the small sideways turn." }
            return nextStep == .turnOtherSide
                ? "Turn toward your other shoulder, past the straight-ahead position."
                : "Turn a little farther toward either shoulder."
        case .tiltUp, .tiltDown:
            if abs(metrics.yaw) > 0.10 { return "Keep your nose facing the camera while you move your chin." }
            return nextStep == .tiltDown
                ? "Move your chin in the opposite direction, past the straight-ahead position."
                : "Lift your chin a little more, without turning sideways."
        case nil: return "All seven views have been captured."
        }
    }

    public mutating func accept(_ embedding: FaceEmbedding, metrics: EnrollmentMetrics) throws {
        guard let step = nextStep else { throw EnrollmentError.incomplete }
        guard embedding.modelIdentifier == modelIdentifier else { throw EnrollmentError.incompatible }
        try metrics.validate()
        let frontal = abs(metrics.yaw) <= 0.10 && abs(metrics.pitch) <= 0.10
        switch step {
        case .center:
            guard frontal else { throw EnrollmentError.pose }
            baselineLuminance = metrics.luminance
        case .turnOneSide:
            guard abs(metrics.yaw) >= 0.16, abs(metrics.pitch) <= 0.12 else { throw EnrollmentError.pose }
            firstYaw = metrics.yaw
        case .turnOtherSide:
            guard abs(metrics.yaw) >= 0.16, abs(metrics.pitch) <= 0.12,
                  let firstYaw, firstYaw * metrics.yaw < 0 else { throw EnrollmentError.pose }
        case .tiltUp:
            // Vision/camera pitch conventions can vary. Require two opposite small tilts.
            guard abs(metrics.pitch) >= 0.12, abs(metrics.yaw) <= 0.10 else { throw EnrollmentError.pose }
            firstPitch = metrics.pitch
        case .tiltDown:
            guard abs(metrics.pitch) >= 0.12, abs(metrics.yaw) <= 0.10,
                  let firstPitch, firstPitch * metrics.pitch < 0 else { throw EnrollmentError.pose }
        case .brighter:
            guard frontal else { throw EnrollmentError.pose }
            guard let baselineLuminance, metrics.luminance >= baselineLuminance + 12 else { throw EnrollmentError.lighting }
        case .dimmer:
            guard frontal else { throw EnrollmentError.pose }
            guard let baselineLuminance, metrics.luminance <= baselineLuminance - 12 else { throw EnrollmentError.lighting }
        }
        embeddings.append(embedding)
    }

    public func finish() throws -> EnrollmentTemplate {
        try EnrollmentTemplate(embeddings: embeddings, modelIdentifier: modelIdentifier, format: .legacySevenViews)
    }
}
