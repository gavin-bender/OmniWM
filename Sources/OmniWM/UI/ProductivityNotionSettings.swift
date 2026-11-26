// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Security
import SwiftUI

struct ProductivityNotionSettings: View {
    let source: String
    @State private var token = ""
    @State private var message = ""

    var body: some View {
        Section("Notion connection") {
            SecureField("Internal connection token", text: $token)
            HStack {
                Button("Save Token") { update(token.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove Token") { update(nil) }
            }
            Text("Share your checklist page with this Notion connection and paste its link above.")
                .font(.caption)
            if !message.isEmpty { Text(message).font(.caption) }
        }
    }

    private func update(_ value: String?) {
        let status = ProductivityNotionCredential.save(value, source: source)
        if status == errSecSuccess {
            token = ""
            message = value == nil ? String(localized: "Token removed.") : String(localized: "Token saved in Keychain.")
        } else {
            message = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Keychain unavailable.")
        }
    }
}
