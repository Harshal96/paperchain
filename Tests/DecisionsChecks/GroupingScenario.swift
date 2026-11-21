import ChainCore
import Decisions
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct ScenarioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class GroupingSession {
    var workspace = Workspace()

    func editWhileRequestIsInFlight() {
        let manual = workspace.createGroup(named: "Manual", on: "portrait")
        workspace.move("transfer", to: "portrait", group: manual)
        workspace.detach("float")
    }
}

/// The transport supplies predetermined choices. This checks response routing and
/// preservation of user edits across an asynchronous request.
@MainActor
func checkGroupingScenario() async throws {
    let session = GroupingSession()
    let categories = ["Social Media", "Writing", "Work & Coding"]
    let screens = [
        ScreenInfo(id: "desk", name: "Desk", bounds: Box(x: -1400, y: 0, width: 1400, height: 900)),
        ScreenInfo(id: "portrait", name: "Portrait", bounds: Box(x: 0, y: -200, width: 900, height: 1400))
    ]
    let examples: [(id: String, app: String, title: String, display: String, choice: String)] = [
        ("news", "Browser", "Community feed", "desk", "Social Media"),
        ("draft-z", "Pages", "Introduction", "desk", "Writing"),
        ("draft-a", "Pages", "Conclusion", "desk", "Writing"),
        ("branch", "Editor", "Feature branch", "desk", "Work & Coding"),
        ("transfer", "Terminal", "Deployment", "desk", "Work & Coding"),
        ("float", "Notes", "Field journal", "desk", "Writing"),
        ("chat", "Browser", "Community chat", "portrait", "Social Media"),
        ("notes", "Notes", "Publication outline", "portrait", "Writing"),
        ("diff", "Editor", "Review changes", "portrait", "Work & Coding")
    ]
    session.workspace.syncScreens(screens)
    for example in examples {
        let window = WindowInfo(id: example.id, app: example.app, title: example.title)
        session.workspace.discover(window, on: example.display)
        session.workspace.select(window.id)
    }
    let available = Set(examples.map(\.id))
    let request = RegroupRequest(workspace: session.workspace, available: available, categories: categories)
    let choicesByTitle = Dictionary(uniqueKeysWithValues: examples.map { ($0.title, $0.choice) })
    let client = JevClient { httpRequest in
        let payload = try JSONSerialization.jsonObject(with: httpRequest.httpBody ?? Data()) as? [String: Any]
        guard let state = payload?["state"] as? [String: [String: String]], let url = httpRequest.url else {
            throw ScenarioFailure(message: "Expected a window classification request")
        }
        var answers: [String: [String: String]] = [:]
        for (key, evidence) in state {
            guard let title = evidence["title"], let choice = choicesByTitle[title] else {
                throw ScenarioFailure(message: "Unexpected window in classification request")
            }
            answers[key] = ["type": "choice", "choice": choice]
        }
        await session.editWhileRequestIsInFlight()
        let body = try JSONSerialization.data(withJSONObject: ["answers": answers])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    let windows = request.windows.map { DecisionWindow(id: $0.id, app: $0.app, title: $0.title) }
    let labels = try await client.classify(windows: windows, categories: categories, apiKey: "mock-key")
    let expected = Dictionary(uniqueKeysWithValues: examples.map { ($0.id, $0.choice) })
    guard labels == expected else { throw ScenarioFailure(message: "Mock choices lost their window identities") }
    let valid = request.applicable(labels, in: session.workspace, available: available, categories: categories)
    guard valid == expected.filter({ $0.key != "transfer" && $0.key != "float" }) else {
        throw ScenarioFailure(message: "Late response did not preserve the manual edits")
    }
    session.workspace.applyClassification(valid)
    // A stale monitor observation after layout must preserve the new groups on both displays.
    session.workspace.rescan(examples.map { example in
        (WindowInfo(id: example.id, app: example.app, title: example.title), example.display == "desk" ? "portrait" : "desk")
    })
    let expectedGroups: [String: [String: [String]]] = [
        "desk": ["Inbox": [], "Social Media": ["news"], "Writing": ["draft-z", "draft-a"], "Work & Coding": ["branch"]],
        "portrait": ["Inbox": [], "Social Media": ["chat"], "Writing": ["notes"], "Work & Coding": ["diff"], "Manual": ["transfer"]]
    ]
    for (id, expected) in expectedGroups {
        let actual = session.workspace.screens[id]?.groups.map { ($0.name, $0.orderedIDs) } ?? []
        guard actual.count == expected.count && actual.allSatisfy({ expected[$0.0] == $0.1 }) else {
            throw ScenarioFailure(message: "Regrouping changed monitor ownership, membership, or order on \(id)")
        }
    }
    guard session.workspace.detached.contains("float"), session.workspace.location(of: "float") == nil else {
        throw ScenarioFailure(message: "Rescan reattached the manually detached window")
    }
}
