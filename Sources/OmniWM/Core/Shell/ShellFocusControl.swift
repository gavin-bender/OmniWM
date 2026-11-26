// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

enum ShellFocusControl {
    // Use the system's own checkboxes so schedules and cross-device sync follow Control Center.
    @concurrent static func select(name: String, enabled: Bool) async -> Bool {
        guard AXIsProcessTrusted(), let control = application("com.apple.controlcenter") else { return false }
        let agent = application("com.apple.MenuBarAgent")
        let hosts = [agent, control].compactMap { $0 }
        var opened = false
        if picker(in: control) == nil {
            let roots = hosts.flatMap { app in
                elements(app, kAXWindowsAttribute) + (AXUIElement.from(attribute(app, "AXExtrasMenuBar")).map { [$0] } ?? [])
            }
            let item = find(in: roots) { identifier($0) == "com.apple.menuextra.focusmode" }
            let direct = item.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
            if !direct {
                guard await expandFocusModule(control, roots: roots) else { return false }
            }
            opened = true
        }
        for _ in 0 ..< 20 {
            if let window = picker(in: control) {
                let matches = elementsMatching(in: [window]) { element in
                    attribute(element, kAXRoleAttribute) as? String == kAXCheckBoxRole
                        && attribute(element, kAXDescriptionAttribute) as? String == name
                }
                if matches.count == 1, let button = matches.first,
                   let checked = attribute(button, kAXValueAttribute) as? NSNumber {
                    let success = checked.boolValue == enabled
                        || AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    if opened, success {
                        try? await Task.sleep(for: .milliseconds(100))
                        if picker(in: control) != nil {
                            // Escape dismisses only the system picker we just opened.
                            var pid: pid_t = 0
                            if AXUIElementGetPid(control, &pid) == .success {
                                for down in [true, false] {
                                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid)
                                }
                            }
                        }
                    }
                    return success
                }
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return false
    }

    private static func expandFocusModule(_ control: AXUIElement, roots: [AXUIElement]) async -> Bool {
        func tile() -> AXUIElement? {
            find(in: elements(control, kAXWindowsAttribute)) { identifier($0) == "controlcenter-focus-modes-compact-2" }
        }
        if tile() == nil {
            guard let item = find(in: roots, matching: { identifier($0) == "com.apple.menuextra.controlcenter" }),
                  AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return false }
        }
        for _ in 0 ..< 20 {
            if let button = tile() {
                // The compact tile's primary action toggles Focus. Its custom action opens the mode list.
                var names: CFArray?
                AXUIElementCopyActionNames(button, &names)
                let details = (names as? [String] ?? []).filter { $0.hasPrefix("Name:") }
                guard details.count == 1, let action = details.first else { return false }
                return AXUIElementPerformAction(button, action as CFString) == .success
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return false
    }

    private static func application(_ id: String) -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first.map {
            let app = AXUIElementCreateApplication($0.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.25)
            return app
        }
    }

    private static func picker(in app: AXUIElement) -> AXUIElement? {
        elements(app, kAXWindowsAttribute).first { window in
            find(in: [window], matching: { identifier($0) == "focus-modes-header" }) != nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }

    private static func elements(_ element: AXUIElement, _ key: String) -> [AXUIElement] {
        attribute(element, key) as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute) as? String
    }

    private static func find(in roots: [AXUIElement], matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        elementsMatching(in: roots, firstOnly: true, matching: predicate).first
    }

    private static func elementsMatching(
        in roots: [AXUIElement], firstOnly: Bool = false, matching predicate: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var pending = roots
        var matches: [AXUIElement] = []
        for _ in 0 ..< 512 {
            guard let element = pending.popLast() else { break }
            if predicate(element) {
                matches.append(element)
                if firstOnly { break }
            }
            pending.append(contentsOf: elements(element, kAXChildrenAttribute))
        }
        return matches
    }
}
