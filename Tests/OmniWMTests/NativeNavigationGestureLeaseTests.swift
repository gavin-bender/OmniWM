// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeNavigationGestureLeaseTests: XCTestCase {
    func testNavigationPreferencesRestoreIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missionControlJournal = directory.appendingPathComponent("trackpad-mission-control-restore")
        let exposeJournal = directory.appendingPathComponent("touch-app-expose-restore")
        var missionControl: Int32 = 1
        var expose: Int32 = 0
        let trackpad = NativeNavigationGestureLease(
            restoreURL: missionControlJournal, enabledValues: [1],
            preference: .init(read: { missionControl }, write: {
                missionControl = $0
                return true
            })
        )
        let touch = NativeNavigationGestureLease(
            restoreURL: exposeJournal, enabledValues: [1],
            preference: .init(read: { expose }, write: {
                expose = $0
                return true
            })
        )

        trackpad.reconcile(shouldPause: true)
        touch.reconcile(shouldPause: true)

        XCTAssertEqual(missionControl, 0)
        XCTAssertEqual(try String(contentsOf: missionControlJournal, encoding: .utf8), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exposeJournal.path))

        touch.reconcile(shouldPause: false)
        XCTAssertEqual(missionControl, 0)
        trackpad.reconcile(shouldPause: false)
        XCTAssertEqual(missionControl, 1)
        XCTAssertEqual(expose, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missionControlJournal.path))
    }
}
