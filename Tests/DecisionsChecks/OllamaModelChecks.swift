import Decisions
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct ModelCheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func response(_ request: URLRequest, json: String, status: Int = 200) -> (Data, URLResponse) {
    let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(json.utf8), http)
}

func checkOllamaModels() async throws {
    try await checkInstalledModels()
    try await checkOfflineModelList()
    try await checkUnusableModels()
}

private func checkInstalledModels() async throws {
    let models = OllamaModels { request in
        guard request.url?.absoluteString == "http://127.0.0.1:11434/api/tags", request.httpMethod == "GET",
              request.httpBody == nil, request.value(forHTTPHeaderField: "Authorization") == nil else {
            throw ModelCheckFailure("Unexpected request for installed Ollama models")
        }
        return response(request, json: """
            {"models":[
              {"name":"llama3.2:latest","capabilities":["completion"]},
              {"name":"clef:cloud"},{"name":"clef:27b-cloud"},{"name":"alias","remote_host":"https://ollama.com"},
              {"name":"other","remote_model":"clef"},{"name":"embed","capabilities":["embedding"]},
              {"name":"clef:latest"},{"name":"llama3.2:latest"}
            ]}
            """)
    }
    guard try await models.installed() == ["clef:latest", "llama3.2:latest"] else {
        throw ModelCheckFailure("Expected a sorted, unique list of usable local Ollama models")
    }
}

private func checkOfflineModelList() async throws {
    let offline = OllamaModels { _ in throw URLError(.cannotConnectToHost) }
    do { _ = try await offline.installed() }
    catch where error.localizedDescription.contains("Open Ollama") { return }
    throw ModelCheckFailure("Missing guidance when Ollama is unavailable")
}

private func checkUnusableModels() async throws {
    let window = DecisionWindow(id: "id", app: "App", title: "Example")
    for (name, details, status) in [
        ("clef:cloud", "", 0), ("clef:27b-cloud", "", 0),
        ("alias", #"{"capabilities":["decision"],"remote_model":"clef"}"#, 200),
        ("chat-alias", #"{"capabilities":["completion"],"remote_host":"https://ollama.com"}"#, 200),
        ("embed", #"{"capabilities":["embedding"]}"#, 200),
        ("removed", #"{"error":"unknown"}"#, 404)
    ] {
        let client = JevClient { request in
            guard status != 0, request.url?.absoluteString == "http://127.0.0.1:11434/api/show",
                  request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == nil,
                  let body = request.httpBody, let fields = try JSONSerialization.jsonObject(with: body) as? [String: String],
                  fields == ["model": name] else {
                throw ModelCheckFailure("Unexpected lookup or inference for \(name)")
            }
            return response(request, json: details, status: status)
        }
        do { _ = try await client.classify(windows: [window], categories: ["A", "B"], ollamaModel: name) }
        catch let failure as ModelCheckFailure { throw failure }
        catch { continue }
        throw ModelCheckFailure("Accepted cloud, incompatible, or unavailable model \(name)")
    }
}
