import Combine
import Foundation
import SwiftUI

enum AppEdition {
    #if FACEUNLOCK_CUSTOMER
    static let isAdmin = false
    #else
    static let isAdmin = true
    #endif
}

enum FaceIDAccent: String, CaseIterable, Identifiable {
    case green, blue, violet, orange, white
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .green: Color(red: 0.55, green: 0.96, blue: 0.48)
        case .blue: Color(red: 0.38, green: 0.73, blue: 1)
        case .violet: Color(red: 0.76, green: 0.61, blue: 1)
        case .orange: Color(red: 1, green: 0.69, blue: 0.36)
        case .white: .white
        }
    }
}

/// Installation preferences never restore credential authorization or enable scanning.
@MainActor
final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var accent: FaceIDAccent {
        didSet { defaults.set(accent.rawValue, forKey: "faceIDAccent") }
    }
    @Published private(set) var setupCompleted: Bool
    var shouldPresentSetupAtLaunch: Bool { shouldPresentSetupAtLaunch(isAdmin: AppEdition.isAdmin) }
    func shouldPresentSetupAtLaunch(isAdmin: Bool) -> Bool { isAdmin || !setupCompleted }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = FaceIDAccent(rawValue: defaults.string(forKey: "faceIDAccent") ?? "") ?? .green
        setupCompleted = defaults.bool(forKey: "setupCompleted.v1")
    }

    func recordCompletedSetup() {
        setupCompleted = true
        defaults.set(true, forKey: "setupCompleted.v1")
    }
}
