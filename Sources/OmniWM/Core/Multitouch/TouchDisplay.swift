// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Darwin

@MainActor
enum TouchDisplay {
    static var isAvailable: Bool {
        if #available(macOS 27.0, *) { return builtInTouchScreen() != nil }
        return false
    }

    static let isPROLEDMac: Bool = {
        // macOS can report touch capability on every screen when Sidecar is connected.
        var model = [UInt8](repeating: 0, count: 32)
        var length = model.count
        guard model.withUnsafeMutableBytes({ sysctlbyname("hw.model", $0.baseAddress, &length, nil, 0) }) == 0
        else { return false }
        switch String(decoding: model.prefix { $0 != 0 }, as: UTF8.self) {
        case "Mac17,10", "Mac17,11", "Mac17,12", "Mac17,13": return true
        default: return false
        }
    }()

    @available(macOS 27.0, *)
    static func builtInTouchScreen() -> NSScreen? {
        guard isPROLEDMac else { return nil }
        return NSScreen.screens.first { screen in
            guard let display = screen.displayId else { return false }
            return CGDisplayIsBuiltin(display) != 0 && screen.touchCapabilities.contains(.multiTouch)
        }
    }
}
