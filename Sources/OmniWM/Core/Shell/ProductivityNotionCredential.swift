// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Security
import os

enum ProductivityNotionCredential {
    static let marker = "X-OmniWM-Notion-Connection"

    private static let tokens = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func item(_ source: String, legacy: Bool = false) -> [String: Any] {
        let service = legacy ? "com.barut.OmniWM" : (Bundle.main.bundleIdentifier ?? "com.barut.OmniWM") + ".widget"
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service + ".productivity.notion",
         kSecAttrAccount as String: source]
    }

    static func save(_ token: String?, source: String) -> OSStatus {
        tokens.withLock { cache in
            let store = ProductivityNotionTokenStore(source: source)
            do {
                if let token {
                    try store.save(token)
                } else {
                    for legacy in [false, true] {
                        let status = SecItemDelete(item(source, legacy: legacy) as CFDictionary)
                        guard status == errSecSuccess || status == errSecItemNotFound else { return status }
                    }
                    try store.remove()
                }
                cache[source] = token
                return errSecSuccess
            } catch { return errSecIO }
        }
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

        let token = try tokens.withLock { cache in
            if let token = cache[principal.source] { return token }
            let store = ProductivityNotionTokenStore(source: principal.source)
            let token: String
            do {
                if let saved = try store.load() {
                    token = saved
                } else {
                    token = try readSilently(source: principal.source)
                    // A readable legacy credential can still serve this session if migration fails.
                    try? store.save(token)
                }
            } catch let failure as ShellHTTPFailure { throw failure }
            catch { throw ShellHTTPFailure("notion_saved_token_unavailable") }
            cache[principal.source] = token
            return token
        }
        request.allHTTPHeaderFields = ["Authorization": "Bearer " + token, "Notion-Version": "2026-03-11",
                                       "Content-Type": "application/json"]
    }

    @diagnose(DeprecatedDeclaration, as: ignored, reason: "Existing tokens use the file-based login Keychain.")
    private static func readSilently(source: String) throws -> String {
        // The file-based login Keychain uses a process-wide interaction flag.
        // Hold the same lock as Save and Remove until the previous flag is restored.
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
        else { throw ShellHTTPFailure("notion_keychain_locked") }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }

        let (status, token) = read(source)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw ShellHTTPFailure("notion_keychain_locked")
        }
        guard status == errSecSuccess, let token
        else { throw ShellHTTPFailure("notion_token_unavailable") }
        return token
    }

    private static func read(_ source: String) -> (OSStatus, String?) {
        for legacy in [false, true] {
            var query = item(source, legacy: legacy)
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                return (status == errSecSuccess ? errSecDecode : status, nil)
            }
            return (errSecSuccess, token)
        }
        return (errSecItemNotFound, nil)
    }

    // Called only by the user's Reconnect button. Allow Keychain to request consent
    // here to import a token saved by an earlier build.
    static func reconnect(source: String) -> OSStatus {
        tokens.withLock { cache in
            let store = ProductivityNotionTokenStore(source: source)
            if let saved = try? store.load() {
                cache[source] = saved
                return errSecSuccess
            }
            let (status, token) = read(source)
            guard status == errSecSuccess, let token else { return status }
            do { try store.save(token) }
            catch { return errSecIO }
            cache[source] = token
            return errSecSuccess
        }
    }
}
