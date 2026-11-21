import Decisions
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct ChatCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private let model = "llama3.2:3b"
private let categories = ["Writing", "Work & Coding"]
private let windows = [
    DecisionWindow(id: "private-101", app: "Notes", title: "Draft \"April\""),
    DecisionWindow(id: "private-205", app: "Editor", title: "code.swift"),
]

private func mockChat(_ answer: @escaping @Sendable (URLRequest) throws -> Data) -> JevClient {
    JevClient { request in
        guard let url = request.url, url.host == "127.0.0.1", url.port == 11434,
              request.value(forHTTPHeaderField: "Authorization") == nil, request.httpMethod == "POST" else {
            throw ChatCheckFailure(message: "Expected an unauthenticated local Ollama POST")
        }
        let data: Data
        switch url.path {
        case "/api/show": data = Data(#"{"capabilities":["completion"]}"#.utf8)
        case "/api/chat": data = try answer(request)
        default: throw ChatCheckFailure(message: "Unexpected route for a chat model")
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func reply(_ content: String, done: Bool = true, reason: String = "stop") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "done": done, "done_reason": reason, "message": ["role": "assistant", "content": content],
    ])
}

func checkOllamaChat() async throws {
    let assignments = #"{"w1":"Work & Coding","w0":"Writing"}"#
    let client = mockChat { request in
        let body = request.httpBody ?? Data()
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["model"] as? String == "llama3.2:3b:local", json["stream"] as? Bool == false,
              json["truncate"] as? Bool == false,
              let schema = json["format"] as? [String: Any], schema["type"] as? String == "object",
              schema["additionalProperties"] as? Bool == false,
              let required = schema["required"] as? [String], Set(required) == ["w0", "w1"],
              let properties = schema["properties"] as? [String: [String: Any]],
              Set(properties.keys) == ["w0", "w1"],
              properties.values.allSatisfy({ $0["type"] as? String == "string" && $0["enum"] as? [String] == categories })
        else { throw ChatCheckFailure(message: "Chat output schema lost the windows or category constraints") }
        guard let messages = json["messages"] as? [[String: String]],
              messages.map({ $0["role"] }) == ["system", "user"],
              let user = messages.last?["content"],
              let evidence = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any],
              evidence["windows"] as? [String: [String: String]] == [
                "w0": ["app": "Notes", "title": "Draft \"April\""], "w1": ["app": "Editor", "title": "code.swift"],
              ],
              evidence["categories"] as? [String] == categories,
              !String(decoding: body, as: UTF8.self).contains("private-")
        else { throw ChatCheckFailure(message: "Chat prompt lost evidence or exposed a local window ID") }
        return try reply(assignments)
    }
    let result = try await client.classify(windows: windows, categories: categories, ollamaModel: model)
    guard result == ["private-101": "Writing", "private-205": "Work & Coding"] else {
        throw ChatCheckFailure(message: "Chat answer was mapped to the wrong window")
    }

    let invalid = try [
        reply(#"{"w0":"Writing"}"#), reply(#"{"w0":"Writing","other":"Writing"}"#),
        reply(#"{"w0":"Writing","w1":"Writing","extra":"Writing"}"#),
        reply(#"{"w0":"unknown","w1":"Writing"}"#), reply("unreadable"),
        reply(assignments, done: false), reply(assignments, reason: "length"),
        JSONSerialization.data(withJSONObject: ["error": "private-window-title"]),
    ]
    for data in invalid {
        do {
            _ = try await mockChat { _ in data }.classify(windows: windows, categories: categories, ollamaModel: model)
        } catch let failure as ChatCheckFailure {
            throw failure
        } catch {
            guard !error.localizedDescription.contains("private-window-title") else {
                throw ChatCheckFailure(message: "Model response leaked into a user-facing error")
            }
            continue
        }
        throw ChatCheckFailure(message: "Accepted an invalid Ollama chat result")
    }
}
