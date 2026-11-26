// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeParkedWindowsTests: XCTestCase {
    func testHideRevealAndRelaunchRestoreOnlyOwnedWindows() throws {
        let suite = "NativeParkedWindowsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = WindowToken(pid: 7, windowId: 8)
        var identity = NativeParkedWindows.Owner(pid: 7, launchDate: Date())
        var visible = true
        var orders: [Bool] = []
        func makeManager() -> NativeParkedWindows {
            NativeParkedWindows(defaults: defaults, owner: { _ in identity }, orderedIn: { _ in visible },
                                order: { _, show in visible = show; orders.append(show); return true },
                                available: { true })
        }

        let manager = makeManager()
        manager.start()
        manager.hide(token)
        manager.hide(token)
        XCTAssertEqual(orders, [false])
        manager.restoreVisible { _ in false }
        XCTAssertFalse(visible)
        manager.reveal(token)
        XCTAssertEqual(orders, [false, true])
        visible = false
        manager.hide(token)
        XCTAssertFalse(manager.owns(token))
        visible = true
        manager.hide(token)
        let restarted = makeManager()
        restarted.start()
        XCTAssertTrue(visible)
        XCTAssertFalse(restarted.owns(token))
        restarted.hide(token)
        identity = .init(pid: 7, launchDate: Date(timeIntervalSince1970: 1))
        restarted.stop()
        XCTAssertFalse(visible)
    }
}
