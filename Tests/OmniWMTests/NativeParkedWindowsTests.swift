// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NativeParkedWindowsTests: XCTestCase {
    func testOrderedOutWindowRemainsIdentifiableWithoutFocus() throws {
        let window = NSWindow(contentRect: CGRect(x: -300, y: -300, width: 20, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.orderBack(nil)
        let id = try XCTUnwrap(UInt32(exactly: window.windowNumber))
        window.orderOut(nil)
        XCTAssertEqual(NativeParkedWindows.windowPID(id), ProcessInfo.processInfo.processIdentifier)
    }

    func testUnconfirmedRevealRetainsOwnershipForRetry() throws {
        let suite = "NativeParkedWindowsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = WindowToken(pid: 7, windowId: 8)
        let identity = NativeParkedWindows.Owner(pid: 7, launchDate: Date())
        var visible = true
        var canReveal = false
        let manager = NativeParkedWindows(defaults: defaults, owner: { _ in identity },
                                          orderedIn: { _ in visible }, order: { _, show in
                                              visible = show && canReveal
                                              return true
                                          }, available: { true })
        manager.start()
        manager.hide(token)
        manager.reveal(token)
        XCTAssertTrue(manager.owns(token))
        canReveal = true
        manager.reveal(token)
        XCTAssertTrue(visible)
        XCTAssertFalse(manager.owns(token))
    }

    func testLateHideIsReversedOnRapidSwitchAndRelaunch() throws {
        for relaunch in [false, true] {
            let suite = "NativeParkedWindowsTests-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let token = WindowToken(pid: 7, windowId: 8)
            let identity = NativeParkedWindows.Owner(pid: token.pid, launchDate: Date())
            var orders: [Bool] = []
            func makeManager() -> NativeParkedWindows {
                // WindowServer still reports visible while the hide is in the Dock queue.
                NativeParkedWindows(defaults: defaults, owner: { _ in identity }, orderedIn: { _ in true },
                                    order: { _, show in
                                        orders.append(show)
                                        return show
                                    }, available: { true })
            }
            let manager = makeManager()
            manager.start()
            manager.hide(token)
            XCTAssertTrue(manager.owns(token))
            let restoring = relaunch ? makeManager() : manager
            if relaunch { restoring.start() } else { restoring.reveal(token) }
            XCTAssertEqual(orders, [false, true])
            XCTAssertFalse(restoring.owns(token))
        }
    }

    func testSwitchAwayWhileRevealIsPendingSubmitsAnotherHide() throws {
        let suite = "NativeParkedWindowsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = WindowToken(pid: 7, windowId: 8)
        let identity = NativeParkedWindows.Owner(pid: token.pid, launchDate: Date())
        var visible = true
        var orders: [Bool] = []
        let manager = NativeParkedWindows(defaults: defaults, owner: { _ in identity },
                                          orderedIn: { _ in visible }, order: { _, show in
                                              orders.append(show)
                                              if !show { visible = false }
                                              return !show
                                          }, available: { true })
        manager.start()
        manager.hide(token)
        manager.reveal(token)
        manager.hide(token)
        manager.hide(token)
        XCTAssertEqual(orders, [false, true, false])
        XCTAssertTrue(manager.owns(token))
    }

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
