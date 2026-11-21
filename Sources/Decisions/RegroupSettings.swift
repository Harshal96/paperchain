import Foundation

public enum DecisionProvider: String, Sendable {
    case typeSafe, ollama
}

public struct RegroupSettings: Equatable, Sendable {
    public var provider: DecisionProvider
    public var ollamaModel: String

    private static let providerKey = "decision.provider"
    private static let modelKey = "decision.ollamaModel"

    public init(defaults: UserDefaults = .standard) {
        provider = defaults.string(forKey: Self.providerKey).flatMap(DecisionProvider.init(rawValue:)) ?? .typeSafe
        ollamaModel = defaults.string(forKey: Self.modelKey) ?? ""
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        defaults.set(ollamaModel, forKey: Self.modelKey)
    }

    public func isReady(categoryCount: Int, hasTypeSafeKey: Bool) -> Bool {
        guard categoryCount > 1 else { return categoryCount == 1 }
        switch provider {
        case .typeSafe: return hasTypeSafeKey
        case .ollama: return !ollamaModel.isEmpty
        }
    }

    public func classify(windows: [DecisionWindow], categories: [String], client: JevClient = JevClient(),
                         typeSafeKey: () throws -> String?) async throws -> [String: String] {
        switch provider {
        case .typeSafe:
            let key = !windows.isEmpty && categories.count > 1 ? try typeSafeKey() ?? "" : ""
            return try await client.classify(windows: windows, categories: categories, apiKey: key)
        case .ollama:
            return try await client.classify(windows: windows, categories: categories, ollamaModel: ollamaModel)
        }
    }
}
