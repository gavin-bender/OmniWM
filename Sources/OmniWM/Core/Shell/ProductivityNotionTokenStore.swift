// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CryptoKit
import Foundation
import LocalAuthentication

/// One device-encrypted credential per widget source, outside the exported configuration.
struct ProductivityNotionTokenStore {
    private struct Record: Codable {
        let wrappedPrivateKey: Data
        let encapsulatedKey: Data
        let ciphertext: Data
    }

    private let file: URL
    private let context: Data

    init(source: String, applicationSupport: URL = .applicationSupportDirectory) {
        let app = Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"
        context = Data((app + "/productivity/notion/v1/" + source).utf8)
        let name = SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        file = applicationSupport.appending(path: app)
            .appending(path: "Notion Credentials").appending(path: name)
    }

    func load() throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        return try decrypt(JSONDecoder().decode(Record.self, from: data))
    }

    func save(_ token: String) throws {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        var sender = try HPKE.Sender(recipientKey: key.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: context)
        let record = try Record(wrappedPrivateKey: key.dataRepresentation, encapsulatedKey: sender.encapsulatedKey,
                                ciphertext: sender.seal(Data(token.utf8)))
        guard try decrypt(record) == token else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }

    func remove() throws {
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile { }
    }

    private func decrypt(_ record: Record) throws -> String {
        let auth = LAContext()
        auth.interactionNotAllowed = true
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.wrappedPrivateKey,
                                                                 authenticationContext: auth)
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .P256_SHA256_AES_GCM_256, info: context,
                                           encapsulatedKey: record.encapsulatedKey)
        let plaintext = try recipient.open(record.ciphertext)
        guard let token = String(data: plaintext, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return token
    }
}
