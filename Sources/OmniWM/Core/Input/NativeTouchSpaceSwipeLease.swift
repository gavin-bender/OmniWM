// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMSystemGestures

@MainActor
final class NativeTouchSpaceSwipeLease {
    @MainActor struct Preference {
        var read: () -> Int32?
        var write: (Int32) -> Bool

        static let live = Self(
            read: {
                var count: Int32 = 0
                return omniwm_touch_spaces_finger_count(&count) ? count : nil
            },
            write: { omniwm_set_touch_spaces_finger_count($0) }
        )
    }

    private let restoreURL: URL
    private let preference: Preference
    private var original: Int32?
    private var didCheckForPendingRestore = false

    init(restoreURL: URL, preference: Preference = .live) {
        self.restoreURL = restoreURL
        self.preference = preference
    }

    func reconcile(shouldPause: Bool) {
        if !didCheckForPendingRestore {
            didCheckForPendingRestore = true
            if let data = try? Data(contentsOf: restoreURL),
               let count = Int32(String(decoding: data, as: UTF8.self)), count == 3 || count == 4
            {
                original = count
                restore()
            }
        }
        guard shouldPause else {
            restore()
            return
        }
        guard original == nil, let count = preference.read(), count == 3 || count == 4 else { return }
        do {
            try FileManager.default.createDirectory(
                at: restoreURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: restoreURL.path) else { return }
            try Data(String(count).utf8).write(to: restoreURL, options: .atomic)
        } catch {
            return
        }
        original = count
        if !preference.write(0), preference.read() == count {
            clearJournal()
        }
    }

    private func restore() {
        guard let original, let current = preference.read() else { return }
        // Preserve a new selection made in System Settings while OmniWM was running.
        guard current != 0 || preference.write(original) else { return }
        clearJournal()
    }

    private func clearJournal() {
        do {
            try FileManager.default.removeItem(at: restoreURL)
            original = nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            original = nil
        } catch {
            // Keep the original value for a later cleanup attempt.
        }
    }
}
