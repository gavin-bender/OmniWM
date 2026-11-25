// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMSystemGestures

@MainActor
final class NativeNavigationGestureLease {
    @MainActor struct Preference {
        var read: () -> Int32?
        var write: (Int32) -> Bool

        // macOS stores the Spaces enable switch separately from its optional minimum finger count.
        // Preserve an absent key so releasing the lease restores the system default.
        static func touchSpacesEnabled(domain: String = "com.apple.SystemGestures") -> Self {
            let domain = domain as CFString
            let key = "spaceSwap" as CFString
            return Self(
                read: {
                    guard let value = CFPreferencesCopyValue(
                        key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
                    ) else { return -1 }
                    guard let number = value as? NSNumber, [0, 1].contains(number.intValue) else { return nil }
                    return number.int32Value
                },
                write: { value in
                    let setting: CFBoolean?
                    switch value {
                    case -1: setting = nil
                    case 0: setting = kCFBooleanFalse
                    case 1: setting = kCFBooleanTrue
                    default: return false
                    }
                    CFPreferencesSetValue(key, setting, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                    return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                }
            )
        }

        static func system(_ gesture: OmniWMNativeGesturePreference) -> Self {
            Self(
                read: {
                    var value: Int32 = 0
                    return omniwm_native_gesture_value(gesture, &value) ? value : nil
                },
                write: { omniwm_set_native_gesture_value(gesture, $0) }
            )
        }
    }

    private let restoreURL: URL
    private let enabledValues: Set<Int32>
    private let preference: Preference
    private var original: Int32?
    private var didCheckForPendingRestore = false

    init(restoreURL: URL, enabledValues: Set<Int32> = [3, 4], preference: Preference) {
        self.restoreURL = restoreURL
        self.enabledValues = enabledValues
        self.preference = preference
    }

    func reconcile(shouldPause: Bool) {
        if !didCheckForPendingRestore {
            didCheckForPendingRestore = true
            if let data = try? Data(contentsOf: restoreURL),
               let value = Int32(String(decoding: data, as: UTF8.self)), enabledValues.contains(value)
            {
                original = value
                restore()
            }
        }
        guard shouldPause else {
            restore()
            return
        }
        guard original == nil, let value = preference.read(), enabledValues.contains(value) else { return }
        do {
            try FileManager.default.createDirectory(
                at: restoreURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: restoreURL.path) else { return }
            try Data(String(value).utf8).write(to: restoreURL, options: .atomic)
        } catch {
            return
        }
        original = value
        if !preference.write(0), preference.read() == value {
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
