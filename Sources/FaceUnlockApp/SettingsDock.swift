import SwiftUI

enum SettingsPage: Int, CaseIterable, Identifiable {
    case general, faces, password
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .faces: "Faces"
        case .password: "Password"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .faces: "faceid"
        case .password: "key.horizontal"
        }
    }
}

/// Original icon-tile dock with proximity magnification and active dots.
struct SettingsDock: View {
    @Binding var selection: SettingsPage
    @State private var pointerX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appAnimationsEnabled) private var animations
    private var reduceMotion: Bool { systemReduceMotion || !animations }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(SettingsPage.allCases) { page in
                let influence = influence(for: page)
                Button { selection = page } label: {
                    VStack(spacing: 6) {
                        Image(systemName: page.symbol).font(.system(size: 21, weight: .light))
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(selection == page ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.14), lineWidth: 1))
                            .scaleEffect(reduceMotion ? 1 : 1 + influence * 0.22, anchor: .bottom)
                            .offset(y: reduceMotion ? 0 : -influence * 3)
                        Circle().fill(selection == page ? Color.white : .clear).frame(width: 4, height: 4)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(selection == page ? .white : .white.opacity(0.65))
                .overlay(alignment: .top) {
                    if influence > 0.85 {
                        Text(page.title).font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.black, in: Capsule()).fixedSize().offset(y: -35).allowsHitTesting(false)
                    }
                }
                .help(page.title).accessibilityLabel(page.title)
                .accessibilityAddTraits(selection == page ? .isSelected : [])
                .accessibilityIdentifier("settingsTab\(page.title)")
            }
        }
        .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 7)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.14), lineWidth: 1))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): pointerX = point.x
            case .ended: pointerX = nil
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76), value: pointerX)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain).accessibilityLabel("Settings pages")
    }

    private func influence(for page: SettingsPage) -> CGFloat {
        guard let pointerX else { return 0 }
        let distance = min(1, abs(pointerX - (CGFloat(page.rawValue) * 56 + 36)) / 90)
        return (1 + cos(distance * .pi)) / 2
    }
}
