import SwiftUI

enum GroupIcon {
    static func symbol(for name: String) -> String {
        appearance(for: name).symbol ?? "folder"
    }

    static func appearance(for name: String) -> (symbol: String?, tint: Color) {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inbox":
            ("tray.fill", Color(red: 0.28, green: 0.35, blue: 0.46))
        case "writing", "notes":
            ("pencil.line", Color(red: 0.61, green: 0.34, blue: 0.04))
        case "building":
            ("hammer.fill", Color(red: 0.16, green: 0.39, blue: 0.64))
        case "work & coding", "coding", "development":
            ("chevron.left.forwardslash.chevron.right", Color(red: 0.16, green: 0.39, blue: 0.64))
        case "social media", "social", "chat":
            ("bubble.left.and.bubble.right.fill", Color(red: 0.62, green: 0.24, blue: 0.37))
        case "work":
            ("briefcase.fill", Color(red: 0.21, green: 0.39, blue: 0.54))
        case "personal":
            ("person.fill", Color(red: 0.45, green: 0.31, blue: 0.64))
        case "research":
            ("magnifyingglass", Color(red: 0.14, green: 0.42, blue: 0.42))
        default:
            (nil, Color(red: 0.36, green: 0.33, blue: 0.60))
        }
    }

    static func initials(for name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let initials = String(words.prefix(2).compactMap(\.first))
        return initials.isEmpty ? String(name.prefix(1)) : String(initials.uppercased().prefix(2))
    }
}

struct DockGroupLabel: View {
    let name: String
    let selected: Bool
    let vertical: Bool
    let availableWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let appearance = GroupIcon.appearance(for: name)
        let idealWidth = selected ? DockSizing.groupWidth(for: name, vertical: vertical) : DockSizing.groupDiameter
        let width = min(availableWidth, idealWidth)
        let showsName = selected && width >= min(60, idealWidth)
        HStack(spacing: 5) {
            Group {
                if let symbol = appearance.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(GroupIcon.initials(for: name))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .frame(width: 17)
            .accessibilityHidden(true)
            if showsName {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, showsName ? 9 : 0)
        .frame(width: width, height: DockSizing.groupDiameter)
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(hovered ? 0.92 : 0.70))
        .background(selected ? appearance.tint : Color.primary.opacity(hovered ? 0.13 : 0.065), in: Capsule())
        .overlay {
            Capsule().strokeBorder(selected ? .white.opacity(hovered ? 0.38 : 0.16)
                                            : .primary.opacity(hovered ? 0.14 : 0.05))
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
    }
}
