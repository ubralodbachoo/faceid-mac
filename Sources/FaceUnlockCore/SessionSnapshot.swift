public enum ScreenLockState: String, Sendable {
    case locked = "Locked (reported)"
    case unlocked = "Unlocked (reported)"
    case unknown = "Unknown / not reported"
}

public enum SessionAssessment: String, Sendable {
    case unknown = "Account or session information unavailable"
    case stale = "Observation expired or timestamp invalid"
    case wrongAccount = "Console and process accounts do not match"
    case inactive = "Session is not on the console"
    case loginIncomplete = "Login is incomplete or unknown"
    case lockUnknown = "Screen lock state is unknown"
    case unlocked = "Screen is reported unlocked"
    case observedLocked = "Current account is reported locked — diagnostic only"
}

/// A point-in-time observation, never a credential-access or password-entry authorization.
public struct SessionSnapshot: Sendable {
    public let processUserID: UInt32
    public let consoleUserID: UInt32?
    public let sessionUserID: UInt32?
    public let isOnConsole: Bool?
    public let loginComplete: Bool?
    public let screenLock: ScreenLockState
    public let sampledAtUptime: Double

    public init(
        processUserID: UInt32, consoleUserID: UInt32? = nil, sessionUserID: UInt32? = nil,
        isOnConsole: Bool? = nil, loginComplete: Bool? = nil,
        screenLock: ScreenLockState = .unknown, sampledAtUptime: Double
    ) {
        self.processUserID = processUserID
        self.consoleUserID = consoleUserID
        self.sessionUserID = sessionUserID
        self.isOnConsole = isOnConsole
        self.loginComplete = loginComplete
        self.screenLock = screenLock
        self.sampledAtUptime = sampledAtUptime
    }

    public func assessment(at uptime: Double, maximumAge: Double = 2) -> SessionAssessment {
        let age = uptime - sampledAtUptime
        guard uptime >= 0, sampledAtUptime >= 0, age.isFinite, age >= 0,
              maximumAge.isFinite, maximumAge > 0, age <= maximumAge else {
            return .stale
        }
        guard processUserID != 0, let consoleUserID, let sessionUserID else { return .unknown }
        guard consoleUserID == processUserID, sessionUserID == processUserID else { return .wrongAccount }
        guard let isOnConsole else { return .unknown }
        guard isOnConsole else { return .inactive }
        guard loginComplete == true else { return .loginIncomplete }
        switch screenLock {
        case .unknown: return .lockUnknown
        case .unlocked: return .unlocked
        case .locked: return .observedLocked
        }
    }
}

