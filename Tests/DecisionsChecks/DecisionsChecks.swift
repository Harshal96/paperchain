import Decisions
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message: message) }
}

private func response(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, URLResponse) {
    let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), http)
}

private let examples = [
    DecisionWindow(id: "local-501", app: "Editor", title: "Invoice 42"),
    DecisionWindow(id: "local-705", app: "Browser", title: "Train to Rome"),
]
private let groups = ["Finance", "Travel"]

private func testRequestAndAssignments() async throws {
    let client = JevClient { request in
        try check(request.httpMethod == "POST", "Expected a POST")
        try check(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone", "Unexpected provider endpoint")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Missing bearer header")
        try check(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Wrong content type")
        let data = request.httpBody ?? Data()
        try check(!String(decoding: data, as: UTF8.self).contains("local-"), "Sent a local window identifier")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try check(json?["model"] as? String == "jev-latest", "Wrong model")
        guard let state = json?["state"] as? [String: [String: String]],
              let questions = json?["questions"] as? [String: [String: Any]] else {
            throw CheckFailure(message: "Expected keyed window state and questions")
        }
        try check(state.count == 2 && questions.count == 2, "Expected two windows and two questions")
        var answers: [String: Any] = [:]
        for (key, fields) in state {
            let isInvoice = fields == ["app": "Editor", "title": "Invoice 42"]
            try check(isInvoice || fields == ["app": "Browser", "title": "Train to Rome"], "Wrong window evidence")
            let question = questions[key]
            try check(question?["type"] as? String == "choice", "Expected a choice question")
            try check((question?["instructions"] as? String)?.contains(key) == true, "Window reference missing in question")
            guard let criteria = question?["criteria"] as? [String: Any] else {
                throw CheckFailure(message: "Expected a criteria map")
            }
            try check(Set(criteria.keys) == Set(groups), "Choices differ from supplied groups")
            answers[key] = ["type": "choice", "choice": isInvoice ? "Finance" : "Travel"]
        }
        let body = try JSONSerialization.data(withJSONObject: ["answers": answers])
        return response(request, String(decoding: body, as: UTF8.self))
    }
    let result = try await client.classify(windows: examples, categories: groups, apiKey: "test-token")
    try check(result == ["local-501": "Finance", "local-705": "Travel"], "Window assignments changed identity")
}

private func testRejectedAnswers() async throws {
    let badResponses = [
        (200, #"{"answers":{}}"#),
        (200, #"{"answers":{"w0":{"type":"choice","choice":"Invented"}}}"#),
        (200, #"{"answers":{"w0":{"type":"score","choice":"Travel"}}}"#),
        (200, #"{"answers":{"w0":{"type":"choice","choice":"Travel"},"extra":{"type":"choice","choice":"Travel"}}}"#),
        (200, "invalid JSON"),
        (401, "echoed-private-title"),
        (429, "echoed-private-title"),
    ]
    for (status, body) in badResponses {
        let client = JevClient { response($0, body, status: status) }
        do {
            _ = try await client.classify(windows: [examples[0]], categories: groups, apiKey: "test-token")
        } catch {
            try check(!error.localizedDescription.contains("echoed-private-title"), "Provider payload leaked into error")
            continue
        }
        throw CheckFailure(message: "Accepted invalid response (HTTP \(status))")
    }
}

private func testNoRequestCases() async throws {
    let client = JevClient { _ in throw CheckFailure(message: "Unexpected HTTP request") }
    let empty = try await client.classify(windows: [], categories: groups, apiKey: "")
    try check(empty.isEmpty, "Empty snapshot produced assignments")
    let single = try await client.classify(windows: examples, categories: ["One"], apiKey: "")
    try check(single == ["local-501": "One", "local-705": "One"], "Single-category assignment failed")
    for (windows, categories, token) in [
        (examples, [], "token"),
        (examples, ["  "], "token"),
        (examples, ["one", "one"], "token"),
        (examples, (0..<256).map { "Group \($0)" }, "token"),
        ([examples[0], examples[0]], groups, "token"),
        (examples, groups, "  "),
        (examples, groups, "key\nInjected"),
    ] {
        do {
            _ = try await client.classify(windows: windows, categories: categories, apiKey: token)
        } catch is CheckFailure {
            throw CheckFailure(message: "Invalid input reached HTTP transport")
        } catch { continue }
        throw CheckFailure(message: "Invalid input was accepted")
    }
}

private func testBatching() async throws {
    let windows = (0..<40).map {
        DecisionWindow(id: "window-\($0)", app: "Notes", title: String(repeating: "a", count: 1_000))
    }
    let client = JevClient { request in
        let data = request.httpBody ?? Data()
        try check(data.count <= 24 * 1_024, "Unbounded request body")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let questions = json?["questions"] as? [String: Any] else { throw CheckFailure(message: "Missing questions") }
        try check(!questions.isEmpty && questions.count < 40, "Expected multiple batches")
        let answers = questions.mapValues { _ in ["type": "choice", "choice": "Travel"] }
        let body = try JSONSerialization.data(withJSONObject: ["answers": answers])
        return response(request, String(decoding: body, as: UTF8.self))
    }
    let result = try await client.classify(windows: windows, categories: groups, apiKey: "token")
    try check(result.count == windows.count && windows.allSatisfy { result[$0.id] == "Travel" }, "Lost a window across batches")
}

private func testLocalDecisionRouting() async throws {
    let client = JevClient { request in
        try check(request.url?.host == "127.0.0.1" && request.url?.port == 11434, "Local classification left loopback")
        try check(request.value(forHTTPHeaderField: "Authorization") == nil, "Local request carried a credential")
        let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        if request.url?.path == "/api/show" {
            try check(payload?["model"] as? String == "my-clef:latest", "Ignored the selected model")
            return response(request, #"{"capabilities":["decision"]}"#)
        }
        try check(request.url?.path == "/v1/systemone", "Expected the local decision endpoint")
        try check(payload?["model"] as? String == "my-clef:latest:local", "Did not require local inference")
        return response(request, #"{"answers":{"w1":{"type":"choice","choice":"Travel"},"w0":{"type":"choice","choice":"Finance"}}}"#)
    }
    let result = try await client.classify(windows: examples, categories: groups, ollamaModel: "my-clef:latest")
    try check(result == ["local-501": "Finance", "local-705": "Travel"], "Local model lost window identities")
}

private func testLocalDecisionCategoryLimit() async throws {
    let client = JevClient { request in
        try check(request.url?.path == "/api/show", "Submitted too many categories to a local decision model")
        return response(request, #"{"capabilities":["decision"]}"#)
    }
    do {
        _ = try await client.classify(windows: examples, categories: (1...27).map(String.init), ollamaModel: "clef")
    } catch is CheckFailure {
        throw CheckFailure(message: "Did not validate the decision model's category limit before classification")
    } catch {
        try check(error.localizedDescription.contains("26"), "Decision model category limit was not explained")
        return
    }
    throw CheckFailure(message: "Accepted too many groups for the local decision model")
}

private func testLocalOfflineShortcuts() async throws {
    let client = JevClient { _ in throw CheckFailure(message: "Offline grouping tried to contact Ollama") }
    let empty = try await client.classify(windows: [], categories: groups, ollamaModel: "")
    let single = try await client.classify(windows: examples, categories: ["One"], ollamaModel: "")
    try check(empty.isEmpty && single == ["local-501": "One", "local-705": "One"], "Offline grouping failed")
}

@main
private enum DecisionsChecks {
    static func main() async {
        do {
            try await testRequestAndAssignments()
            try await testRejectedAnswers()
            try await testNoRequestCases()
            try await testBatching()
            try await testLocalDecisionRouting()
            try await testLocalDecisionCategoryLimit()
            try await testLocalOfflineShortcuts()
            try await checkOllamaModels()
            try await checkOllamaChat()
            try await checkRegroupSettings()
            try await checkGroupingScenario()
            print("Decisions checks passed")
        } catch {
            FileHandle.standardError.write(Data("Decisions checks failed. \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
