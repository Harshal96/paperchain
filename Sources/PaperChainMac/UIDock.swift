import AppKit
import ChainCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DockAppearance: ObservableObject {
    @Published var expanded = false
    @Published var vertical: Bool

    init(vertical: Bool) { self.vertical = vertical }
}

enum DockSizing {
    static let groupDiameter: CGFloat = 32
    static let groupSpacing: CGFloat = 4
    static let groupInset: CGFloat = 2
    static let addButtonSize: CGFloat = 26
    static let overflowSize: CGFloat = 22
    static let windowSpacing: CGFloat = 3
    static let windowInset: CGFloat = 2
    static let endDropLength: CGFloat = 12

    static func windowButtonSize(vertical: Bool) -> CGFloat { vertical ? 40 : 36 }

    static func groupWidth(for name: String, vertical: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
        return min(vertical ? 104 : 156, ceil(textWidth) + 43)
    }

    static func groupContentLength(_ screen: ScreenState, vertical: Bool, limit: Int? = nil) -> CGFloat {
        let count = min(screen.groups.count, limit ?? screen.groups.count)
        guard count > 0 else { return 0 }
        let selectedWidth = vertical ? groupDiameter : groupWidth(for: screen.activeGroup?.name ?? "", vertical: false)
        return 2 * groupInset + selectedWidth + CGFloat(count - 1) * (groupDiameter + groupSpacing)
    }

    static func groupListLength(_ screen: ScreenState, vertical: Bool) -> CGFloat {
        let visible = 7
        let overflow = screen.groups.count > visible ? overflowSize + groupSpacing : 0
        return groupContentLength(screen, vertical: vertical, limit: visible) + overflow
    }

    static func windowListLength(_ count: Int, vertical: Bool) -> CGFloat {
        guard count > 0 else { return vertical ? 52 : 120 }
        return 2 * windowInset + CGFloat(min(count, 7)) * (windowButtonSize(vertical: vertical) + windowSpacing) + endDropLength
    }

    static func controlsLength(vertical: Bool) -> CGFloat {
        (vertical ? 85 : 88) + addButtonSize + 5
    }

    static func expandedSize(for screen: ScreenState, windowCount: Int, vertical: Bool, available: CGSize) -> CGSize {
        let length = controlsLength(vertical: vertical) + groupListLength(screen, vertical: vertical)
            + windowListLength(windowCount, vertical: vertical)
        return vertical ? CGSize(width: min(120, available.width), height: min(length, available.height))
                        : CGSize(width: min(length, available.width), height: min(52, available.height))
    }
}

private struct WindowTransfer: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.paperchain.window"))
            .visibility(.ownProcess)
    }
}

private struct WindowDrop: ViewModifier {
    var cornerRadius: CGFloat = 7
    let receive: (String) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: WindowTransfer.self) { items, _ in
                guard let item = items.first else { return false }
                return receive(item.id)
            } isTargeted: { targeted = $0 }
    }
}

private struct DockItems<Content: View>: View {
    let vertical: Bool
    let spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if vertical { LazyVStack(spacing: spacing) { content } }
        else { LazyHStack(spacing: spacing) { content } }
    }
}

@MainActor
struct DockContent<A: PaperActions>: View {
    @ObservedObject var actions: A
    @ObservedObject var state: DockAppearance
    let screenID: String
    let toggle: () -> Void
    let drag: (CGPoint) -> Void
    let endDrag: () -> Void
    let position: (DockEdge) -> Void

    var body: some View {
        if state.expanded, let screen = actions.workspace.screens[screenID] {
            GeometryReader { proxy in
                let layout = state.vertical ? AnyLayout(VStackLayout(spacing: 5))
                                            : AnyLayout(HStackLayout(spacing: 5))
                let length = state.vertical ? proxy.size.height : proxy.size.width
                let listSpace = max(0, length - DockSizing.controlsLength(vertical: state.vertical)
                                    - DockSizing.windowListLength(1, vertical: state.vertical))
                let groupLength = max(DockSizing.overflowSize,
                                      min(DockSizing.groupListLength(screen, vertical: state.vertical), listSpace))
                layout {
                    grip
                        .frame(width: state.vertical ? nil : 14, height: state.vertical ? 14 : nil)
                    groupList(screen, length: groupLength)
                        .frame(width: state.vertical ? nil : groupLength,
                               height: state.vertical ? groupLength : nil)
                    addGroupButton
                    Divider()
                    if !actions.hasAccessibility {
                        Button(action: actions.requestAccessibility) {
                            Text("Grant Accessibility Access")
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.17), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Allow Paper Chain to discover and arrange windows.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let group = screen.activeGroup {
                        windowList(group)
                    }
                    optionsMenu(screen)
                }
                .padding(6)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.16))
                    .allowsHitTesting(false)
            }
        } else {
            grip
                .background(Color(white: 0.13), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.28)).allowsHitTesting(false) }
                .contextMenu { positionMenu }
        }
    }

    private var grip: some View {
        DockGrip(expanded: state.expanded, vertical: state.vertical, toggle: toggle,
                 drag: drag, endDrag: endDrag)
    }

    private var addGroupButton: some View {
        Button { nameGroup(nil) } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: DockSizing.addButtonSize, height: DockSizing.addButtonSize)
                .foregroundStyle(.secondary)
                .overlay { Circle().strokeBorder(.secondary.opacity(0.35)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("New group")
        .accessibilityLabel("New group")
    }

    private func groupList(_ screen: ScreenState, length: CGFloat) -> some View {
        let vertical = state.vertical
        let layout = vertical ? AnyLayout(VStackLayout(spacing: DockSizing.groupSpacing))
                              : AnyLayout(HStackLayout(spacing: DockSizing.groupSpacing))
        let overflows = DockSizing.groupContentLength(screen, vertical: vertical) > length + 0.5
        let scrollLength = overflows ? length - DockSizing.overflowSize - DockSizing.groupSpacing : length
        return layout {
            if scrollLength >= DockSizing.groupDiameter + 2 * DockSizing.groupInset {
                groupScroll(screen, length: scrollLength)
                    .frame(width: vertical ? nil : scrollLength, height: vertical ? scrollLength : nil)
            }
            if overflows {
                Menu {
                    Picker("Group", selection: Binding(get: { screen.activeGroupID },
                                                       set: { actions.selectGroup($0, screen: screenID) })) {
                        ForEach(screen.groups) { group in Text(group.name).tag(group.id) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: DockSizing.overflowSize, height: DockSizing.overflowSize)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: DockSizing.overflowSize, height: DockSizing.overflowSize)
                .help("Show all groups")
                .accessibilityLabel("Show all groups")
            }
        }
    }

    private func groupScroll(_ screen: ScreenState, length: CGFloat) -> some View {
        ScrollViewReader { scroll in
            ScrollView(state.vertical ? .vertical : .horizontal) {
                DockItems(vertical: state.vertical, spacing: DockSizing.groupSpacing) {
                    ForEach(screen.groups) { group in
                        let active = group.id == screen.activeGroupID
                        Button { actions.selectGroup(group.id, screen: screenID) } label: {
                            DockGroupLabel(name: group.name, selected: active, vertical: state.vertical,
                                           availableWidth: state.vertical ? .infinity : length - 2 * DockSizing.groupInset)
                        }
                        .buttonStyle(.plain)
                        .help("\(group.name) · Drop a window here to move it to this group.")
                        .accessibilityLabel(group.name)
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .contextMenu {
                            Button("Rename group…") { nameGroup(group) }
                            Button("New group…") { nameGroup(nil) }
                        }
                        .modifier(WindowDrop(cornerRadius: DockSizing.groupDiameter / 2) { id in move(id, to: group.id) })
                        .id(group.id)
                    }
                }
                .padding(DockSizing.groupInset)
            }
            .scrollIndicators(.never)
            .frame(height: state.vertical ? nil : DockSizing.groupDiameter + 2 * DockSizing.groupInset)
            .onChange(of: screen.activeGroupID, initial: true) { _, selected in
                scroll.scrollTo(selected, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func windowList(_ group: ChainGroup) -> some View {
        let visibleIDs = group.orderedIDs.filter(actions.availableWindowIDs.contains)
        if visibleIDs.isEmpty {
            Text(group.orderedIDs.isEmpty ? "No windows" : "No available windows")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(WindowDrop { id in move(id, to: group.id) })
        } else {
            let stackedIDs = Set(group.columns.filter { $0.count > 1 }.joined())
            let buttonSize = DockSizing.windowButtonSize(vertical: state.vertical)
            ScrollViewReader { scroll in
                ScrollView(state.vertical ? .vertical : .horizontal) {
                    DockItems(vertical: state.vertical, spacing: DockSizing.windowSpacing) {
                        ForEach(visibleIDs, id: \.self) { id in
                            if let window = actions.workspace.windows[id] {
                                windowButton(window, group: group, stacked: stackedIDs.contains(id)).id(id)
                            }
                        }
                        Color.clear
                            .frame(width: state.vertical ? buttonSize : DockSizing.endDropLength,
                                   height: state.vertical ? DockSizing.endDropLength : buttonSize)
                            .modifier(WindowDrop { id in move(id, to: group.id) })
                            .accessibilityHidden(true)
                    }
                    .padding(DockSizing.windowInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: group.selectedID, initial: true) { _, selected in
                    if let selected { scroll.scrollTo(selected, anchor: .center) }
                }
            }
        }
    }

    private func windowButton(_ window: WindowInfo, group: ChainGroup, stacked: Bool) -> some View {
        let active = window.id == group.selectedID
        let buttonSize = DockSizing.windowButtonSize(vertical: state.vertical)
        let iconSize: CGFloat = state.vertical ? 31 : 27
        return Button { actions.focus(window.id) } label: {
            Group {
                if let icon = actions.icon(for: window.id) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit().padding(3)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .overlay(alignment: .bottomTrailing) {
                if stacked {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 8)).padding(2)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .background(active ? Color.accentColor.opacity(0.17) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(actions.workspace.placementPaused.contains(window.id)
              ? "\(label(for: window)) is floating. Click to retry its place in the chain."
              : label(for: window))
        .accessibilityLabel(label(for: window))
        .accessibilityAddTraits(active ? .isSelected : [])
        .contextMenu { windowMenu(window, group: group, stacked: stacked) }
        .draggable(WindowTransfer(id: window.id)) {
            Text(label(for: window)).padding(6).background(.regularMaterial, in: Capsule())
        }
        .modifier(WindowDrop { id in
            guard id != window.id else { return false }
            return move(id, to: group.id, before: window.id)
        })
    }

    @ViewBuilder
    private func windowMenu(_ window: WindowInfo, group: ChainGroup, stacked: Bool) -> some View {
        Button("Focus window") { actions.focus(window.id) }
        Menu("Move to group") {
            ForEach(actions.workspace.screens.values.filter { $0.enabled && $0.isConnected }
                .sorted { ($0.info.name, $0.id) < ($1.info.name, $1.id) }) { screen in
                Section(screen.info.name) {
                    ForEach(screen.groups) { target in
                        Button {
                            actions.moveWindow(window.id, to: target.id, screen: screen.id, before: nil)
                        } label: {
                            Label(target.name, systemImage: GroupIcon.symbol(for: target.name))
                        }
                    }
                }
            }
        }
        Menu("Reorder") {
            ForEach(group.columns.compactMap { $0.first(where: actions.availableWindowIDs.contains) }
                .filter { $0 != window.id }, id: \.self) { id in
                if let other = actions.workspace.windows[id] {
                    Button("Before \(label(for: other))") { _ = move(window.id, to: group.id, before: id) }
                }
            }
            Button("Move to end") { _ = move(window.id, to: group.id) }
        }
        let partners = group.columns.filter { $0.count == 1 }.compactMap(\.first)
            .filter { $0 != window.id && actions.availableWindowIDs.contains($0) }
        if !partners.isEmpty {
            Menu("Stack with") {
                ForEach(partners, id: \.self) { id in
                    if let other = actions.workspace.windows[id] {
                        Button(label(for: other)) { actions.stack(window.id, with: id) }
                    }
                }
            }
        }
        if stacked { Button("Unstack window") { actions.unstack(window.id) } }
        Divider()
        Button("Detach window") { actions.detach(window.id) }
    }

    private func optionsMenu(_ screen: ScreenState) -> some View {
        Menu {
            Button("New group…") { nameGroup(nil) }
            if let active = screen.activeGroup {
                Button("Rename \(active.name)…") { nameGroup(active) }
                let detached = actions.workspace.detached.intersection(actions.availableWindowIDs)
                    .compactMap { actions.workspace.windows[$0] }
                    .sorted { (label(for: $0), $0.id) < (label(for: $1), $1.id) }
                if !detached.isEmpty {
                    Menu("Attach window") {
                        ForEach(detached) { window in
                            Button(label(for: window)) { _ = move(window.id, to: active.id) }
                        }
                    }
                }
            }
            Divider()
            positionMenu
            Button("Collapse dock", action: toggle)
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Group and dock options")
        .accessibilityLabel("Group and dock options")
    }

    private var positionMenu: some View {
        Menu("Dock position") {
            ForEach(DockEdge.allCases, id: \.self) { edge in
                Button { position(edge) } label: { Label(edge.rawValue.capitalized, systemImage: edge.symbol) }
            }
        }
    }

    private func label(for window: WindowInfo) -> String {
        window.title.isEmpty || window.title == window.app ? window.app : "\(window.app) — \(window.title)"
    }

    private func move(_ id: String, to group: String, before: String? = nil) -> Bool {
        guard actions.availableWindowIDs.contains(id), actions.workspace.windows[id] != nil else { return false }
        actions.moveWindow(id, to: group, screen: screenID, before: before)
        return true
    }

    private func nameGroup(_ group: ChainGroup?) {
        let alert = NSAlert()
        alert.messageText = group == nil ? "New group" : "Rename group"
        alert.addButton(withTitle: group == nil ? "Create group" : "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: group?.name ?? "")
        field.placeholderString = "Group name"
        field.setAccessibilityLabel("Group name")
        field.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let group { actions.renameGroup(group.id, screen: screenID, name: name) }
        else { actions.createGroup(screen: screenID, name: name) }
    }
}
