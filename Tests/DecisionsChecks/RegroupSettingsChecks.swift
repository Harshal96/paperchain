import Decisions
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct SettingsFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func checkRegroupSettings() async throws {
    let suite = "app.paperchain.checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = RegroupSettings(defaults: defaults)
    guard settings.provider == .typeSafe,
          !settings.isReady(categoryCount: 2, hasTypeSafeKey: false),
          settings.isReady(categoryCount: 2, hasTypeSafeKey: true) else {
        throw SettingsFailure("Existing installations must open with the hosted provider and use their saved key.")
    }

    let windows = [DecisionWindow(id: "stable-id", app: "Notes", title: "Book outline")]
    let offline = JevClient { _ in throw SettingsFailure("Single-category regroup contacted a server.") }
    for provider in [DecisionProvider.typeSafe, .ollama] {
        settings.provider = provider
        let labels = try await settings.classify(windows: windows, categories: ["Writing"], client: offline) {
            throw SettingsFailure("Single-category regroup read Keychain.")
        }
        guard settings.isReady(categoryCount: 1, hasTypeSafeKey: false), labels == ["stable-id": "Writing"] else {
            throw SettingsFailure("Single-category regroup must work offline, even with no model or key.")
        }
    }

    guard !settings.isReady(categoryCount: 2, hasTypeSafeKey: true) else {
        throw SettingsFailure("A saved hosted key enabled local regroup without a model.")
    }
    settings.ollamaModel = "clef-flash:latest"
    settings.save(to: defaults)
    guard RegroupSettings(defaults: defaults) == settings, settings.isReady(categoryCount: 2, hasTypeSafeKey: false) else {
        throw SettingsFailure("The local model selection did not survive relaunch or required a key.")
    }
    let local = JevClient { request in
        guard let url = request.url, url.host == "127.0.0.1",
              request.value(forHTTPHeaderField: "Authorization") == nil else {
            throw SettingsFailure("Local regroup used a hosted endpoint or credential.")
        }
        let json: String
        switch url.path {
        case "/api/show": json = #"{"capabilities":["decision"]}"#
        case "/v1/systemone": json = #"{"answers":{"w0":{"type":"choice","choice":"Writing"}}}"#
        default: throw SettingsFailure("Regroup sent the local decision model to an unexpected endpoint.")
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
    let labels = try await settings.classify(windows: windows, categories: ["Writing", "Mail"], client: local) {
        throw SettingsFailure("Local regroup tried to read the TypeSafe credential.")
    }
    guard labels == ["stable-id": "Writing"] else { throw SettingsFailure("Local regroup lost its assignment.") }
    settings.provider = .typeSafe
    settings.save(to: defaults)
    guard RegroupSettings(defaults: defaults).ollamaModel == "clef-flash:latest" else {
        throw SettingsFailure("Switching to TypeSafe cleared the saved local model.")
    }
}
