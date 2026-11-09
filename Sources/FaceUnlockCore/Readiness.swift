/// Setup requirements, not authentication decisions. Availability must never grant an unlock.
public enum Component: String, CaseIterable, Sendable {
    case cameraPermission
    case accessibilityPermission
    case credentialVault
    case lockSession
    case faceRecognition
    case liveness
    case passwordEntry

    public var title: String {
        switch self {
        case .cameraPermission: "Camera permission"
        case .accessibilityPermission: "Accessibility permission"
        case .credentialVault: "Encrypted credential storage"
        case .lockSession: "Lock and account verification"
        case .faceRecognition: "Face recognition"
        case .liveness: "Liveness verification"
        case .passwordEntry: "Lock-screen password entry"
        }
    }
}

public enum ComponentStatus: String, Sendable {
    case available = "Available"
    case permissionRequired = "Permission required"
    case unavailable = "Unavailable"
    case notImplemented = "Not implemented"
}

public struct ReadinessReport: Sendable {
    private let statuses: [Component: ComponentStatus]

    public init(statuses: [Component: ComponentStatus]) {
        self.statuses = statuses
    }

    /// Missing entries stay blocked, including requirements added in future versions.
    public func status(for component: Component) -> ComponentStatus {
        statuses[component] ?? .notImplemented
    }

    public var blockers: [Component] {
        Component.allCases.filter { status(for: $0) != .available }
    }

    /// Only describes setup. Identity, liveness, session and focus still need per-attempt checks.
    public var isSetupComplete: Bool { blockers.isEmpty }
}

@MainActor
public protocol ReadinessProviding {
    /// Read-only: must not request permissions, capture video or retrieve credentials.
    func inspect() -> ReadinessReport
}
