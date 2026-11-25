// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

struct AppAXEnhancedUITiming {
    let probeNs: UInt64
    let disableNs: UInt64
    let restoreNs: UInt64
}

struct AppAXEnhancedUIWriteScope {
    private let axApp: AXUIElement
    private let key: CFString
    private let tracing: Bool
    let wasEnabled: Bool
    private let activeOverride: LockedEnhancedUIStateMap.Override?
    private let probeNs: UInt64
    private let disableNs: UInt64

    init(axApp: AXUIElement, pid: pid_t, tracing: Bool) {
        self.axApp = axApp
        self.tracing = tracing
        let key = "AXEnhancedUserInterface" as CFString
        self.key = key
        let cache = LockedEnhancedUIStateMap.shared
        var value: CFTypeRef?
        let probeStartNs = tracing ? DispatchTime.now().uptimeNanoseconds : 0
        if cache.state(for: pid) == nil {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            if AXUIElementCopyAttributeValue(axApp, key, &value) == .success,
               let boolValue = value as? Bool
            {
                cache.store(boolValue, for: pid)
            }
        }
        let probeEndNs = tracing ? DispatchTime.now().uptimeNanoseconds : 0
        let gate = cache.enabledOverride(for: pid)
        wasEnabled = gate != nil
        let disableStartNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let acquired = gate?.acquire {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            return AXUIElementSetAttributeValue(axApp, key, kCFBooleanFalse) == .success
        }
        activeOverride = acquired == true ? gate : nil
        let disableEndNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        probeNs = AppAXFrameWriteTrace.elapsedNanoseconds(from: probeStartNs, to: probeEndNs)
        disableNs = AppAXFrameWriteTrace.elapsedNanoseconds(from: disableStartNs, to: disableEndNs)
    }

    func restore() -> AppAXEnhancedUITiming {
        let restoreStartNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        activeOverride?.release {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            AXUIElementSetAttributeValue(axApp, key, kCFBooleanTrue)
        }
        let restoreEndNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        return AppAXEnhancedUITiming(
            probeNs: probeNs,
            disableNs: disableNs,
            restoreNs: AppAXFrameWriteTrace.elapsedNanoseconds(from: restoreStartNs, to: restoreEndNs)
        )
    }
}
