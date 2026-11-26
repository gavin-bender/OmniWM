// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Security

enum ProductivityNotionCredential {
    static let marker = "X-OmniWM-Notion-Connection"

    private static func item(_ source: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.barut.OmniWM.productivity.notion",
         kSecAttrAccount as String: source]
    }

    static func save(_ token: String?, source: String) -> OSStatus {
        let query = item(source)
        guard let token else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let value = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil)
    }

    static func permits(method: String?, path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "v1" else { return false }
        let id = parts[3].replacingOccurrences(of: "-", with: "")
        guard id.utf8.count == 32, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
        switch (method, parts[2], Array(parts.dropFirst(4))) {
        case ("GET", "blocks", ["children"]), ("PATCH", "blocks", []),
             ("GET", "views", []), ("GET", "databases", []), ("GET", "data_sources", []),
             ("POST", "data_sources", ["query"]), ("PATCH", "pages", []):
            return true
        default:
            return false
        }
    }

    static func authorize(_ request: inout URLRequest, policy: ShellHTTPPolicy) throws {
        guard request.value(forHTTPHeaderField: marker) != nil else { return }
        guard case let .widget(principal, _, _) = policy.current,
              principal.role == .bar, principal.name == "productivity",
              let url = request.url, url.scheme == "https", url.host == "api.notion.com", url.port == nil,
              permits(method: request.httpMethod, path: url.path)
        else { throw ShellHTTPFailure("invalid_notion_request") }

        var query = item(principal.source)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8)
        else { throw ShellHTTPFailure("notion_token_unavailable") }
        request.allHTTPHeaderFields = ["Authorization": "Bearer " + token, "Notion-Version": "2026-03-11",
                                       "Content-Type": "application/json"]
    }
}
