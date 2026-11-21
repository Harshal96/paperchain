import ChainCore
import Foundation
import Security

enum KeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.paperchain.jev",
         kSecAttrAccount as String: "api-key"]
    }

    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func save(_ secret: String) throws {
        if secret.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let bytes = Data(secret.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = bytes
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

enum SessionFile {
    static func url() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Paper Chain", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("workspace-v1.json")
    }

    static func load() throws -> Workspace {
        let file = try url()
        if !FileManager.default.fileExists(atPath: file.path) { return Workspace() }
        return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file))
    }

    static func save(_ workspace: Workspace) throws {
        try JSONEncoder().encode(workspace).write(to: url(), options: .atomic)
    }
}
