import SwiftUI

enum SettingsPage: Int, CaseIterable, Identifiable {
    case overview, permissions, faces, password, appearance
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .overview: "Home"
        case .permissions: "Permissions"
        case .faces: "Faces"
        case .password: "Password"
        case .appearance: "Appearance"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "house"
        case .permissions: "hand.raised"
        case .faces: "faceid"
        case .password: "key.horizontal"
        case .appearance: "paintpalette"
        }
    }
}

/// Native dock navigation: proximity magnification, labels and selection dots.
struct SettingsDock: View {
    @Binding var selection: SettingsPage
    @State private var pointerX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(SettingsPage.allCases) { page in
                let influence = influence(for: page)
                Button { selection = page } label: {
                    VStack(spacing: 7) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 23, weight: .light))
                            .frame(width: 52, height: 52)
                            .background(.primary.opacity(selection == page ? 0.11 : 0.045),
                                        in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.1), lineWidth: 1))
                            .scaleEffect(reduceMotion ? 1 : 1 + influence * 0.22, anchor: .bottom)
                            .offset(y: reduceMotion ? 0 : -influence * 3)
                        Circle().fill(selection == page ? Color.primary : .clear).frame(width: 4, height: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == page ? .primary : .secondary)
                .overlay(alignment: .top) {
                    if influence > 0.82 {
                        Text(page.title).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .fixedSize().offset(y: -40).allowsHitTesting(false)
                    }
                }
                .help(page.title)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(selection == page ? .isSelected : [])
                .accessibilityIdentifier("settingsTab\(page.title)")
            }
        }
        .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(.primary.opacity(0.12), lineWidth: 1))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): pointerX = point.x
            case .ended: pointerX = nil
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76), value: pointerX)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings pages")
    }

    private func influence(for page: SettingsPage) -> CGFloat {
        guard let pointerX else { return 0 }
        let center = CGFloat(page.rawValue) * 64 + 41
        let distance = min(1, abs(pointerX - center) / 105)
        return (1 + cos(distance * .pi)) / 2
    }
}
