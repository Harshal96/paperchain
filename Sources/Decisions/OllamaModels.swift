import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OllamaModels: Sendable {
    static let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let transport: JevClient.Transport

    public init() { transport = JevClient.transport(using: .shared) }
    public init(transport: @escaping JevClient.Transport) { self.transport = transport }

    enum Kind { case decision, chat }

    public func installed() async throws -> [String] {
        let request = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let list: ModelList = try await fetch(request)
        let names = list.models.compactMap { model -> String? in
            guard let name = model.name ?? model.model, Self.isLocalName(name), !model.isRemote else { return nil }
            // Older servers supply capabilities only in /api/show.
            if model.capabilities != nil && model.kind == nil { return nil }
            return name
        }
        return Set(names).sorted()
    }

    func kind(for model: String) async throws -> Kind {
        guard Self.isLocalName(model) else { throw ModelError("Choose an installed local Ollama model in Settings.") }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/show"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": model])
        let info: ModelInfo = try await fetch(request)
        guard !info.isRemote else { throw ModelError("This model runs in Ollama Cloud. Choose a local model in Settings.") }
        guard let kind = info.kind else {
            throw ModelError("Choose an Ollama model that supports decisions or chat.")
        }
        return kind
    }

    private static func isLocalName(_ name: String) -> Bool {
        guard !name.isEmpty, name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let lower = name.lowercased()
        return !lower.hasSuffix(":cloud") && !lower.hasSuffix("-cloud")
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                                              .timedOut].contains(error.code) {
            throw ModelError("Couldn’t reach Ollama. Open Ollama on this Mac and try again.")
        }
        guard let http = response as? HTTPURLResponse else { throw ModelError("Ollama returned an invalid response.") }
        if http.statusCode == 404 && request.httpMethod == "POST" {
            throw ModelError("The selected Ollama model is unavailable. Refresh the models in Settings.")
        }
        guard (200..<300).contains(http.statusCode) else { throw ModelError("Ollama returned HTTP \(http.statusCode).") }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw ModelError("Ollama returned unreadable model information.")
        }
        return decoded
    }
}

private struct ModelList: Decodable {
    let models: [ModelInfo]
}

private struct ModelInfo: Decodable {
    let name: String?
    let model: String?
    let capabilities: [String]?
    let remoteHost: String?
    let remoteModel: String?

    enum CodingKeys: String, CodingKey {
        case name, model, capabilities
        case remoteHost = "remote_host"
        case remoteModel = "remote_model"
    }

    var isRemote: Bool { !(remoteHost ?? "").isEmpty || !(remoteModel ?? "").isEmpty }

    var kind: OllamaModels.Kind? {
        if capabilities?.contains("decision") == true { return .decision }
        if capabilities?.contains("completion") == true { return .chat }
        return nil
    }
}

private struct ModelError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
