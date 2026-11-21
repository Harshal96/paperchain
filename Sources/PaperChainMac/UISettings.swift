import AppKit
import ChainCore
import Decisions
import SwiftUI

@MainActor
struct PaperMenu<A: PaperActions>: View {
    @ObservedObject var actions: A
    let openSettings: () -> Void

    var body: some View {
        if !actions.hasAccessibility {
            Button("Grant Accessibility Access…") { actions.requestAccessibility() }
            Divider()
        }
        Button("Rescan all windows") { actions.rescan() }
        if !actions.workspace.detached.isDisjoint(with: actions.availableWindowIDs) {
            Button("Reattach detached windows on enabled displays") { actions.reattachDetachedWindows() }
        }
        Button(actions.isRegrouping ? "Regrouping windows…" : "Regroup windows") {
            actions.regroup()
        }
        .disabled(!actions.canRegroup)
        if !actions.statusText.isEmpty { Text(actions.statusText) }
        Divider()
        Button("Settings…", action: openSettings).keyboardShortcut(",")
        Button("Quit Paper Chain") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
struct PaperSettings<A: PaperActions>: View {
    @ObservedObject var actions: A
    @State private var categoryText = ""
    @State private var keyEntry = ""
    @State private var confirmingRemoval = false

    private var screens: [ScreenState] {
        actions.workspace.screens.values.filter(\.isConnected).sorted {
            ($0.info.name, $0.info.id) < ($1.info.name, $1.info.id)
        }
    }

    private var categoryNames: [String] {
        categoryText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            Section("Displays") {
                if screens.isEmpty { Text("No connected displays").foregroundStyle(.secondary) }
                ForEach(screens, id: \.info.id) { screen in
                    Toggle(screen.info.name, isOn: Binding(get: {
                        actions.workspace.screens[screen.info.id]?.enabled ?? false
                    }, set: { actions.setEnabled($0, screen: screen.info.id) }))
                }
            }
            Section("Appearance") {
                Stepper(value: Binding(get: { actions.windowPadding }, set: { actions.setWindowPadding($0) }),
                        in: Strip.paddingRange) {
                    LabeledContent("Window padding") {
                        Text("\(actions.windowPadding) pt").monospacedDigit()
                    }
                }
                .accessibilityLabel("Window padding")
                .accessibilityValue("\(actions.windowPadding) points")
                Toggle("Dim side windows", isOn: Binding(get: { actions.dimSideWindows },
                                                         set: { actions.setDimSideWindows($0) }))
                    .help("Dim other windows when the focused window has a visible column on each side.")
            }
            Section("Window access") {
                if actions.hasAccessibility {
                    Label("Accessibility access granted", systemImage: "checkmark.circle")
                } else {
                    Button("Grant Accessibility Access…") { actions.requestAccessibility() }
                    Text("Allow Paper Chain in System Settings to discover and move windows.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Decisions API") {
                Picker("Provider", selection: Binding(get: { actions.decisionProvider },
                                                      set: { actions.setDecisionProvider($0) })) {
                    Text("TypeSafe").tag(DecisionProvider.typeSafe)
                    Text("Ollama (local)").tag(DecisionProvider.ollama)
                }
                .disabled(actions.isRegrouping)
                switch actions.decisionProvider {
                case .typeSafe:
                    typeSafeSettings
                case .ollama:
                    OllamaModelPicker(model: Binding(get: { actions.ollamaModel },
                                                     set: { actions.setOllamaModel($0) }))
                        .disabled(actions.isRegrouping)
                }
            }
            Section("Categories") {
                Text("Enter one category per line. Regroup windows from the menu bar to apply changes.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $categoryText)
                    .font(.body)
                    .frame(height: 76)
                    .accessibilityLabel("Category names")
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                HStack {
                    Button("Restore defaults") { actions.setCategories([]); syncCategories() }
                    Spacer()
                    Button("Save categories") { actions.setCategories(categoryNames); syncCategories() }
                        .disabled(categoryNames.isEmpty || categoryNames == actions.categories)
                }
            }
            if !actions.statusText.isEmpty {
                Text(actions.statusText).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 450, idealHeight: 620)
        .onAppear { syncCategories() }
        .onDisappear { keyEntry = "" }
        .onChange(of: actions.decisionProvider) { keyEntry = "" }
        .onChange(of: actions.categories) { syncCategories() }
        .alert("Remove the saved API key?", isPresented: $confirmingRemoval) {
            Button("Remove key", role: .destructive) { keyEntry = ""; actions.saveAPIKey("") }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var typeSafeSettings: some View {
        LabeledContent("TypeSafe API key", value: actions.hasAPIKey ? "Saved in Keychain" : "No key saved")
        HStack {
            SecureField(actions.hasAPIKey ? "Replacement API key" : "Enter API key", text: $keyEntry)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveKey() }
            Button("Save key") { saveKey() }
                .disabled(keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if actions.hasAPIKey {
                Button("Remove…", role: .destructive) { confirmingRemoval = true }
            }
        }
        Text("When you regroup, TypeSafe Jev uses app names and window titles to choose among your categories.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func syncCategories() { categoryText = actions.categories.joined(separator: "\n") }

    private func saveKey() {
        let trimmed = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actions.saveAPIKey(trimmed)
        keyEntry = ""
    }
}

@MainActor
private struct OllamaModelPicker: View {
    private enum ModelList {
        case loading
        case loaded([String])
        case failed(String)
    }

    @Binding var model: String
    @State private var list = ModelList.loading
    @State private var refreshID = 0

    private var models: [String] {
        if case let .loaded(names) = list { return names }
        return []
    }

    var body: some View {
        HStack {
            Picker("Model", selection: $model) {
                Text("Choose a model…").tag("")
                if !model.isEmpty && !models.contains(model) {
                    Text(model).tag(model)
                }
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .disabled(models.isEmpty && model.isEmpty)
            Button("Refresh") { refreshID += 1 }
        }
        .task(id: refreshID) { await loadModels() }
        Group {
            switch list {
            case .loading:
                Text("Looking for local models…")
            case .failed(let message):
                Text(message)
            case .loaded(let names):
                if names.isEmpty {
                    Text("Install a local model such as Clef or Llama in Ollama, then refresh.")
                } else if !model.isEmpty && !names.contains(model) {
                    Text("The selected model is no longer installed. Choose another model or reinstall it in Ollama.")
                }
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        Text("When you regroup, Ollama processes app names and window titles on this Mac.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func loadModels() async {
        list = .loading
        do {
            let installed = try await OllamaModels().installed()
            guard !Task.isCancelled else { return }
            list = .loaded(installed)
        } catch {
            guard !Task.isCancelled else { return }
            list = .failed(error.localizedDescription)
        }
    }
}
