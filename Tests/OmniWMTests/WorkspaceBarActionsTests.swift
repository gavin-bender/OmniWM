// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarActionsTests: XCTestCase {
    struct Fixture {
        let controller: WMController
        let mainMonitor: Monitor
        let sideMonitor: Monitor
        let ws1: WorkspaceDescriptor.ID
        let ws2: WorkspaceDescriptor.ID
        let ws3: WorkspaceDescriptor.ID
    }

    func testMenuMoveOfAnUnfocusedWindowHonorsTheFollowSettingWithoutWarping() async throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(followsFocus: followsFocus)
            let manager = fixture.controller.workspaceManager
            let neighbor = try addWindow(pid: 700_003, windowId: 3, to: fixture.ws1, fixture: fixture)
            let moved = try addWindow(pid: 700_002, windowId: 2, to: fixture.ws1, fixture: fixture)
            let focused = try addWindow(pid: 700_001, windowId: 1, to: fixture.ws1, fixture: fixture)
            try select(focused, in: fixture.ws1, fixture: fixture)
            let focusedNode = try XCTUnwrap(fixture.controller.niriEngine?.findNode(for: focused, in: fixture.ws1))

            fixture.controller.performWorkspaceBarMenuAction(
                .moveWindowsToWorkspace([moved.id], fixture.ws2),
                barMonitorId: fixture.mainMonitor.id
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            XCTAssertEqual(manager.workspace(for: moved.id), fixture.ws2)
            XCTAssertEqual(manager.workspace(for: neighbor.id), fixture.ws1)
            if followsFocus {
                XCTAssertEqual(manager.activeWorkspace(on: fixture.mainMonitor.id)?.id, fixture.ws2)
                let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
                XCTAssertEqual(request.token, moved.id)
                XCTAssertEqual(request.origin, .pointerSelection)
            } else {
                XCTAssertEqual(manager.activeWorkspace(on: fixture.mainMonitor.id)?.id, fixture.ws1)
                XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
                XCTAssertEqual(manager.selectedManagedToken, focused.id)
                XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).selectedNodeId, focusedNode.id)
            }
        }
    }

    func testMenuMoveOfTheFocusedWindowRefocusesTheSourceWithoutWarping() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let neighbor = try addWindow(pid: 700_004, windowId: 4, to: fixture.ws1, fixture: fixture)
        let focused = try addWindow(pid: 700_005, windowId: 5, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        fixture.controller.performWorkspaceBarMenuAction(
            .moveWindowsToWorkspace([focused.id], fixture.ws2),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: focused.id), fixture.ws2)
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, neighbor.id)
        XCTAssertEqual(request.origin, .pointerSelection)
    }

    func testShiftClickMovesTheSelectedWindow() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_011, windowId: 1, to: fixture.ws1, fixture: fixture)
        let other = try addWindow(pid: 700_012, windowId: 2, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.workspaceNavigationHandler
            .moveFocusedWindowFromBar(toWorkspaceId: fixture.ws2))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: focused.id), fixture.ws2)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: other.id), fixture.ws1)
    }

    func testMoveToMonitorTargetsThatMonitorsActiveWorkspace() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_021, windowId: 1, to: fixture.ws1, fixture: fixture)
        let moved = try addWindow(pid: 700_022, windowId: 2, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        fixture.controller.performWorkspaceBarMenuAction(
            .moveWindowsToMonitor([moved.id], fixture.sideMonitor.id),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: moved.id), fixture.ws3)
    }

    func testMenuAndDropMoveEveryGroupedWindow() async throws {
        for drop in [false, true] {
            let fixture = try makeFixture(followsFocus: false)
            let first = try addWindow(
                pid: drop ? 700_078 : 700_031,
                windowId: drop ? 8 : 1,
                to: fixture.ws1,
                fixture: fixture
            )
            let second = try addWindow(
                pid: drop ? 700_078 : 700_031,
                windowId: drop ? 9 : 2,
                to: fixture.ws1,
                fixture: fixture
            )
            let anchor = try addWindow(pid: 700_032, windowId: 3, to: fixture.ws1, fixture: fixture)
            try select(anchor, in: fixture.ws1, fixture: fixture)
            let destination = drop ? fixture.ws3 : fixture.ws2
            if drop {
                XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
                    .moveToWorkspace(fixture.ws3),
                    source: .init(
                        tokens: [first.id, second.id],
                        workspaceId: fixture.ws1,
                        isFloating: false
                    )
                ))
            } else {
                fixture.controller.performWorkspaceBarMenuAction(
                    .moveWindowsToWorkspace([first.id, second.id], fixture.ws2),
                    barMonitorId: fixture.mainMonitor.id
                )
            }
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let manager = fixture.controller.workspaceManager
            XCTAssertEqual(manager.workspace(for: first.id), destination)
            XCTAssertEqual(manager.workspace(for: second.id), destination)
            XCTAssertEqual(manager.workspace(for: anchor.id), fixture.ws1)
        }
    }

    func testMoveWorkspaceToMonitorByIdentifier() async throws {
        let fixture = try makeFixture(followsFocus: false)

        fixture.controller.performWorkspaceBarMenuAction(
            .moveWorkspaceToMonitor(fixture.ws2, fixture.sideMonitor.id),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: fixture.ws2), fixture.sideMonitor.id)
    }

    func testRenameAndLayoutApplyOnlyToConfiguredWorkspaces() throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller

        XCTAssertEqual(controller.setWorkspaceDisplayName("Mail", forWorkspaceNamed: "2"), .executed)
        XCTAssertEqual(controller.settings.workspaces.displayName(for: "2"), "Mail")
        XCTAssertEqual(controller.setWorkspaceDisplayName("Mail", forWorkspaceNamed: "2"), .noChange)
        XCTAssertEqual(controller.setWorkspaceDisplayName("", forWorkspaceNamed: "2"), .executed)
        XCTAssertEqual(controller.settings.workspaces.displayName(for: "2"), "2")
        XCTAssertEqual(controller.setWorkspaceDisplayName("Mail", forWorkspaceNamed: "9"), .notFound)

        controller.performWorkspaceBarMenuAction(
            .setLayout(fixture.ws2, .dwindle),
            barMonitorId: fixture.mainMonitor.id
        )
        XCTAssertEqual(controller.workspaceManager.activeLayoutKind(for: fixture.ws2), .dwindle)

        let dynamic = try XCTUnwrap(controller.workspaceManager.createDynamicWorkspace(
            named: "8",
            on: fixture.mainMonitor.id
        ))
        XCTAssertEqual(controller.workspaceBarWorkspaceMenuTarget(for: dynamic.id)?.isConfigured, false)
        XCTAssertEqual(controller.workspaceBarWorkspaceMenuTarget(for: fixture.ws2)?.isConfigured, true)
    }

    func testToggleFloatingAndScratchpadAssignmentTargetTheClickedWindow() throws {
        let fixture = try makeFixture(followsFocus: false)
        let manager = fixture.controller.workspaceManager
        let focused = try addWindow(pid: 700_041, windowId: 700_141, to: fixture.ws1, fixture: fixture)
        let floated = try addWindow(pid: 700_042, windowId: 700_142, to: fixture.ws1, fixture: fixture)
        let assigned = try addWindow(pid: 700_043, windowId: 700_143, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)
        fixture.controller.axManager.confirmFrameWrite(
            for: assigned.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        fixture.controller.performWorkspaceBarMenuAction(
            .toggleFloating(floated.id),
            barMonitorId: fixture.mainMonitor.id
        )
        XCTAssertEqual(manager.manualLayoutOverride(for: floated.id), .forceFloat)
        XCTAssertNil(manager.manualLayoutOverride(for: focused.id))

        fixture.controller.performWorkspaceBarMenuAction(
            .assignToScratchpad(assigned.id, 3),
            barMonitorId: fixture.mainMonitor.id
        )
        XCTAssertEqual(manager.scratchpadIndex(for: assigned.id), 3)
        XCTAssertNil(manager.scratchpadIndex(for: focused.id))
    }

    func testMarkActionsTargetTheClickedWindowAndRemoveOnlyTheChosenMark() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller
        let focused = try addWindow(pid: 700_046, windowId: 700_146, to: fixture.ws1, fixture: fixture)
        let clicked = try addWindow(pid: 700_047, windowId: 700_147, to: fixture.ws2, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        let initialTarget = try XCTUnwrap(controller.workspaceBarWindowMenuTarget(for: clicked.id, title: "Clicked"))
        XCTAssertTrue(initialTarget.canMark)
        XCTAssertFalse(initialTarget.hasMarks)

        controller.commandHandler.requestWindowMarkName = { "work" }
        controller.performWorkspaceBarMenuAction(.windowMark(clicked.id, .set), barMonitorId: fixture.mainMonitor.id)
        controller.commandHandler.requestWindowMarkName = { "later" }
        controller.performWorkspaceBarMenuAction(.windowMark(clicked.id, .set), barMonitorId: fixture.mainMonitor.id)

        XCTAssertEqual(controller.windowMarkRegistry.names(for: clicked.id), ["later", "work"])
        XCTAssertTrue(controller.windowMarkRegistry.names(for: focused.id).isEmpty)
        XCTAssertEqual(controller.workspaceBarWindowMenuTarget(for: clicked.id, title: "Clicked")?.hasMarks, true)

        controller.commandHandler.chooseWindowMarkNameToRemove = { names in
            XCTAssertEqual(names, ["later", "work"])
            return "work"
        }
        controller.performWorkspaceBarMenuAction(.windowMark(clicked.id, .remove), barMonitorId: fixture.mainMonitor.id)

        XCTAssertEqual(controller.windowMarkRegistry.names(for: clicked.id), ["later"])
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, focused.id)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: fixture.mainMonitor.id)?.id, fixture.ws1)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
    }

    func testAssigningTheFocusedWindowToAScratchpadRecoversFocusWithoutWarping() throws {
        let fixture = try makeFixture(followsFocus: false)
        let neighbor = try addWindow(pid: 700_044, windowId: 700_144, to: fixture.ws1, fixture: fixture)
        let focused = try addWindow(pid: 700_045, windowId: 700_145, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)
        fixture.controller.axManager.confirmFrameWrite(
            for: focused.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        fixture.controller.performWorkspaceBarMenuAction(
            .assignToScratchpad(focused.id, 2),
            barMonitorId: fixture.mainMonitor.id
        )

        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadIndex(for: focused.id), 2)
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, neighbor.id)
        XCTAssertEqual(request.origin, .pointerSelection)
    }

    func testSummonAnchorPrefersTheFocusedWindowThenTheRememberedOne() throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_051, windowId: 1, to: fixture.ws1, fixture: fixture)
        let other = try addWindow(pid: 700_052, windowId: 2, to: fixture.ws2, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        XCTAssertEqual(fixture.controller.summonAnchorToken(in: fixture.ws1), focused.id)
        XCTAssertNil(fixture.controller.summonAnchorToken(in: fixture.ws2))
        _ = fixture.controller.workspaceManager.rememberFocus(other.id, in: fixture.ws2)
        XCTAssertEqual(fixture.controller.summonAnchorToken(in: fixture.ws2), other.id)

        let target = try XCTUnwrap(fixture.controller.workspaceBarWindowMenuTarget(for: other.id, title: "Other"))
        XCTAssertTrue(target.canSummon)
        let anchorTarget = try XCTUnwrap(
            fixture.controller.workspaceBarWindowMenuTarget(for: focused.id, title: "Focused")
        )
        XCTAssertFalse(anchorTarget.canSummon)
    }

    func testMenuFactsListEveryMonitorsWorkspacesAndScratchpadSlots() throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_061, windowId: 1, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        let facts = fixture.controller.workspaceBarMenuFacts()

        XCTAssertEqual(facts.displays.map(\.id), [fixture.mainMonitor.id, fixture.sideMonitor.id])
        XCTAssertEqual(facts.displays.first?.workspaces.map(\.id), [fixture.ws1, fixture.ws2])
        XCTAssertEqual(facts.displays.last?.workspaces.map(\.id), [fixture.ws3])
        XCTAssertEqual(facts.focusedWindowWorkspaceId, fixture.ws1)
        XCTAssertEqual(facts.scratchpadSlots.map(\.index.rawValue), Array(ScratchpadIndex.range))
    }

    func testDroppingASingleColumnInAGapReordersTheColumnAndFocusesIt() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_071, windowId: 1, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_072, windowId: 2, to: fixture.ws1, fixture: fixture)
        let third = try addWindow(pid: 700_073, windowId: 3, to: fixture.ws1, fixture: fixture)
        try select(second, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriMoveColumn(fixture.ws1, oneBasedIndex: 3),
            source: .init(tokens: [first.id], workspaceId: fixture.ws1, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[second.id], [third.id], [first.id]])
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, first.id)
        XCTAssertEqual(request.origin, .pointerSelection)
    }

    func testColumnMoveUsesProjectedIndicesAroundExcludedColumns() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_081, windowId: 12, to: fixture.ws1, fixture: fixture)
        let excluded = try addWindow(pid: 700_082, windowId: 13, to: fixture.ws1, fixture: fixture)
        let last = try addWindow(pid: 700_083, windowId: 14, to: fixture.ws1, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.ws1) {
            engine.setProjectionExclusions([excluded.id], in: fixture.ws1)
        }
        let layout = fixture.controller.workspaceBarDropLayout(for: fixture.ws1)
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.placements[last.id]?.column, 1)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriMoveColumn(fixture.ws1, oneBasedIndex: 2),
            source: .init(tokens: [first.id], workspaceId: fixture.ws1, isFloating: false)
        ))

        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[excluded.id], [last.id], [first.id]])
    }

    func testDroppingOntoAnIconStacksAndAGapSplitsTheStackAgain() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_074, windowId: 4, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_075, windowId: 5, to: fixture.ws1, fixture: fixture)
        try select(second, in: fixture.ws1, fixture: fixture)
        let source = WorkspaceBarDragSource(tokens: [first.id], workspaceId: fixture.ws1, isFloating: false)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(fixture.ws1, target: second.id, position: .after),
            source: source
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[second.id, first.id]])

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(.niriNewColumn(fixture.ws1, gap: 0), source: source))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[first.id], [second.id]])
    }

    func testDwindleDropSwapsTheTwoTiles() async throws {
        let fixture = try makeFixture(followsFocus: false)
        fixture.controller.performWorkspaceBarMenuAction(
            .setLayout(fixture.ws2, .dwindle),
            barMonitorId: fixture.mainMonitor.id
        )
        let first = try addWindow(pid: 700_076, windowId: 6, to: fixture.ws2, fixture: fixture)
        let second = try addWindow(pid: 700_077, windowId: 7, to: fixture.ws2, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let before = try XCTUnwrap(engine.root(for: fixture.ws2)).collectAllWindows()

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .dwindleSwap(fixture.ws2, target: second.id),
            source: .init(tokens: [first.id], workspaceId: fixture.ws2, isFloating: false)
        ))

        XCTAssertEqual(try XCTUnwrap(engine.root(for: fixture.ws2)).collectAllWindows(), before.reversed())
    }

    func testDroppingIntoAnotherNiriRowInsertsAtThatPosition() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let moved = try addWindow(pid: 700_084, windowId: 15, to: fixture.ws1, fixture: fixture)
        let stayed = try addWindow(pid: 700_085, windowId: 16, to: fixture.ws1, fixture: fixture)
        let target = try addWindow(pid: 700_086, windowId: 17, to: fixture.ws2, fixture: fixture)
        try select(stayed, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(fixture.ws2, target: target.id, position: .before),
            source: .init(tokens: [moved.id], workspaceId: fixture.ws1, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try columnTokens(in: fixture.ws2, fixture: fixture), [[moved.id, target.id]])
        XCTAssertEqual(fixture.controller.workspaceManager.activeWorkspace(on: fixture.mainMonitor.id)?.id, fixture.ws1)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, stayed.id)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriNewColumn(fixture.ws1, gap: 0),
            source: .init(tokens: [moved.id], workspaceId: fixture.ws2, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[moved.id], [stayed.id]])
    }

    func testDroppingADwindleWindowIntoANiriRowWaitsForAdmission() async throws {
        let fixture = try makeFixture(followsFocus: false)
        fixture.controller.performWorkspaceBarMenuAction(
            .setLayout(fixture.ws2, .dwindle),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let niriWindow = try addWindow(pid: 700_087, windowId: 18, to: fixture.ws1, fixture: fixture)
        let dwindleWindow = try addWindow(pid: 700_088, windowId: 19, to: fixture.ws2, fixture: fixture)
        try select(niriWindow, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriNewColumn(fixture.ws1, gap: 0),
            source: .init(tokens: [dwindleWindow.id], workspaceId: fixture.ws2, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dwindleWindow.id), fixture.ws1)
        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[dwindleWindow.id], [niriWindow.id]])
    }

    func testDropLayoutReportsProjectedColumnPlacements() throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_079, windowId: 10, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_080, windowId: 11, to: fixture.ws1, fixture: fixture)
        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(fixture.ws1, target: first.id, position: .after),
            source: .init(tokens: [second.id], workspaceId: fixture.ws1, isFloating: false)
        ))

        let layout = fixture.controller.workspaceBarDropLayout(for: fixture.ws1)

        XCTAssertEqual(layout.layout, .niri)
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.placements[first.id], .init(column: 0, row: 0, columnTileCount: 2))
        XCTAssertEqual(layout.placements[second.id], .init(column: 0, row: 1, columnTileCount: 2))
    }

    private func columnTokens(in workspaceId: WorkspaceDescriptor.ID, fixture: Fixture) throws -> [[WindowToken]] {
        try XCTUnwrap(fixture.controller.niriEngine).columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
    }

    func testTabbedBoundaryAnimatesAfterNativeFrameChangeWithoutMouseEvents() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller
        let ws = fixture.ws1
        let engine = try XCTUnwrap(controller.dwindleEngine)
        for index in 1...2 {
            _ = try addWindow(pid: pid_t(731_000 + index), windowId: 500 + index, to: ws, fixture: fixture)
        }
        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.tabbed))
        func layout() {
            _ = controller.layoutRefreshController.buildRelayoutEffectPlan(
                useScrollAnimationPath: false, recoverFocus: false, affectedWorkspaceIds: [ws]
            )
        }
        layout()
        let token = try XCTUnwrap(engine.projectedActiveToken(in: ws))
        let leaf = try XCTUnwrap(engine.findNode(for: token, in: ws))
        controller.layoutRefreshController.resetState()
        let refresh = controller.layoutRefreshController
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        refresh.layoutState.activeRefreshTask = Task { for await _ in stream {} }
        refresh.layoutState.activeRefresh = .init(kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: [ws])
        defer {
            continuation.finish()
            controller.axEventHandler.cancelFrameObservations()
            controller.layoutRefreshController.resetState()
        }
        let monitor = controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.mainMonitor)
        let working = monitor.tabbedWorkingFrame
        let moved = CGRect(x: working.midX - 200, y: working.maxY - 300, width: 400, height: 300)
        let id = UInt32(token.windowId)
        controller.axEventHandler.frameObservations.query = { _ in
            WindowServerInfo(id: id, pid: token.pid, level: 0, frame: ScreenCoordinateSpace.toWindowServer(rect: moved))
        }
        controller.motionPolicy.animationsEnabled = true
        controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: id))
        await controller.axEventHandler.frameObservations.byWindowId[id]?.task.value
        XCTAssertEqual(leaf.cachedContentFrame, moved)
        let settlement = try XCTUnwrap(controller.axEventHandler.frameObservations.tabBoundarySettlements[id])
        await settlement.value
        XCTAssertNotNil(refresh.layoutState.pendingRefresh)
        layout()
        let animation = try XCTUnwrap(leaf.frameAnimation)
        XCTAssertEqual(animation.fromFrame, moved)
        XCTAssertEqual(animation.toFrame, moved.offsetBy(dx: 0, dy: -controller.settings.tabbedBar.thickness))
        XCTAssertTrue(working.contains(try XCTUnwrap(leaf.cachedFrame)))
    }

    func testTabbedWorkspaceMoveCommandsSplitAndJoinGroups() throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller
        let ws = fixture.ws1
        let engine = try XCTUnwrap(controller.dwindleEngine)
        for index in 1...3 {
            _ = try addWindow(pid: pid_t(710_000 + index), windowId: index, to: ws, fixture: fixture)
        }
        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.tabbed))
        func layout() {
            _ = controller.layoutRefreshController.buildRelayoutEffectPlan(
                useScrollAnimationPath: false, recoverFocus: false, affectedWorkspaceIds: [ws]
            )
        }
        layout()
        XCTAssertEqual(engine.tileCount(in: ws), 1)
        let selected = try XCTUnwrap(engine.projectedActiveToken(in: ws))
        _ = controller.commandHandler.performCommand(.move(.right))
        layout()
        XCTAssertEqual(engine.tileCount(in: ws), 2)
        XCTAssertEqual(engine.tileSnapshot(for: selected, in: ws)?.members.count, 1)
        _ = controller.commandHandler.performCommand(.move(.left))
        layout()
        XCTAssertEqual(engine.tileCount(in: ws), 1)
        XCTAssertEqual(engine.tileSnapshot(for: selected, in: ws)?.members.count, 3)
    }

    func testTabbedNativeTitleDropHonorsOcclusionAndTabBarDropUsesVisibleSlot() throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller
        let ws = fixture.ws1
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let mouse = controller.mouseEventHandler
        defer {
            controller.tabRailManager.removeAll()
            mouse.tabDropFeedback.hide()
            controller.layoutRefreshController.resetState()
        }
        let tokens = try (1...4).map { try addWindow(pid: pid_t(710_000 + $0), windowId: $0, to: ws, fixture: fixture).id }
        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.tabbed))
        func layout() {
            _ = controller.layoutRefreshController.buildRelayoutEffectPlan(
                useScrollAnimationPath: false, recoverFocus: false, affectedWorkspaceIds: [ws]
            )
        }
        layout()
        let nativeFrame = CGRect(x: 600, y: 100, width: 400, height: 300)
        controller.workspaceManager.withEngineMutationScope {
            XCTAssertTrue(engine.detachTab(tokens[0], to: nativeFrame, in: ws))
            XCTAssertTrue(engine.detachTab(tokens[1], to: nativeFrame, in: ws))
        }
        layout()
        mouse.nativeWindowFrameProvider = { _ in nativeFrame }
        let mouseUp = CGPoint(x: 700, y: 390)
        func dragWindow(blocked: Bool) {
            mouse.state.tabbedTitleDrag = (tokens[0], CGPoint(x: 450, y: 390), nativeFrame.offsetBy(dx: -250, dy: 0))
            mouse.tabWindowStackAtPoint = { _ in
                let ids = blocked ? [tokens[0].windowId, 999, tokens[1].windowId] : [tokens[0].windowId, tokens[1].windowId]
                return ids.map { ($0, nativeFrame) }
            }
            mouse.updateTabbedTitleDrag(at: mouseUp, released: false)
            mouse.updateTabbedTitleDrag(at: mouseUp, released: true)
        }
        dragWindow(blocked: true)
        XCTAssertEqual(engine.tileCount(in: ws), 3)
        dragWindow(blocked: false)
        XCTAssertEqual(engine.tileCount(in: ws), 2)
        layout()
        let infos = controller.dwindleLayoutHandler.desiredTabRailInfos()
        let target = try XCTUnwrap(infos.first { $0.tabs.contains { $0.token == tokens[0] } })
        let source = try XCTUnwrap(infos.first { $0.tabs.contains { $0.token == tokens[2] } })
        controller.tabRailManager.updateRails(infos)
        let rail = try XCTUnwrap(controller.tabRailManager.existingWindow(for: target.key) as? TabRailWindow)
        let point = CGPoint(x: rail.appliedFrame.minX + 26, y: rail.appliedFrame.midY)
        mouse.tabWindowStackAtPoint = { _ in [(rail.windowNumber, rail.appliedFrame)] }
        mouse.performTabBarAction(.drag(point, released: true), token: tokens[2], info: source)
        XCTAssertEqual(engine.tile(containing: tokens[0], in: ws)?.members.first?.token, tokens[2])
        mouse.ungroupTabbedWorkspace(ws)
        XCTAssertEqual(engine.tileCount(in: ws), 4)
    }

    func testToggleWorkspaceLayoutCyclesThroughTabbed() throws {
        let controller = try makeFixture(followsFocus: false).controller
        defer { controller.columnModeToast.destroy() }
        for expected in [LayoutType.dwindle, .tabbed, .niri] {
            controller.commandHandler.toggleWorkspaceLayout()
            XCTAssertEqual(controller.activeStatusBarWorkspaceSummary()?.layout.rawValue, expected.rawValue)
            let panel = try XCTUnwrap(controller.ownedWindowRegistry.visibleWindows(kind: .columnModeToast).first)
            let view = try XCTUnwrap(panel.contentView as? NSHostingView<ColumnModeToastView>)
            XCTAssertEqual(view.rootView.message, expected.localizedDisplayName)
        }
    }

    func testStatusSummaryResolvesLayoutAcrossWorkspacesAndMonitors() throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        XCTAssertEqual(controller.activeStatusBarWorkspaceSummary()?.layout, .niri)

        controller.settings.workspaces.defaultLayoutType = .dwindle
        XCTAssertEqual(controller.activeStatusBarWorkspaceSummary()?.layout, .dwindle)
        let mainWorkspaceName = try XCTUnwrap(manager.descriptor(for: fixture.ws2)).name
        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.niri, forWorkspaceNamed: mainWorkspaceName))
        XCTAssertTrue(manager.setActiveWorkspace(fixture.ws2, on: fixture.mainMonitor.id))
        XCTAssertEqual(controller.activeStatusBarWorkspaceSummary()?.layout, .niri)

        XCTAssertTrue(manager.setInteractionMonitor(fixture.sideMonitor.id))
        XCTAssertEqual(controller.activeStatusBarWorkspaceSummary()?.monitorId, fixture.sideMonitor.id)
        XCTAssertEqual(controller.activeStatusBarWorkspaceSummary()?.layout, .dwindle)
        let sideWorkspaceName = try XCTUnwrap(manager.descriptor(for: fixture.ws3)).name
        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.niri, forWorkspaceNamed: sideWorkspaceName))
        XCTAssertEqual(controller.activeStatusBarWorkspaceSummary()?.layout, .niri)
    }

    func testLayoutMutationsRefreshTheNativeStatusItem() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller
        controller.hotkeysEnabled = false
        controller.settings.workspaceBar.enabled = false
        controller.settings.hiddenBar.enabled = false
        controller.settings.statusBar.showLayout = true
        controller.settings.statusBar.showWorkspaceName = false
        controller.settings.statusBar.showIcon = false
        let suite = "StatusBarRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let statusBar = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: controller.hiddenBarController,
            statusItemDefaults: defaults
        )
        controller.statusBarController = statusBar
        defer {
            statusBar.cleanup()
            controller.layoutRefreshController.resetState()
            defaults.removePersistentDomain(forName: suite)
        }
        statusBar.setup()
        let button = try XCTUnwrap(statusBar.statusButton)
        XCTAssertEqual(button.accessibilityValue() as? String, LayoutType.niri.localizedDisplayName)

        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.dwindle))
        XCTAssertEqual(button.accessibilityValue() as? String, LayoutType.dwindle.localizedDisplayName)
        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.defaultLayout))
        XCTAssertEqual(button.accessibilityValue() as? String, LayoutType.niri.localizedDisplayName)

        controller.settings.workspaces.defaultLayoutType = .dwindle
        controller.updateWorkspaceConfig()
        XCTAssertEqual(button.accessibilityValue() as? String, LayoutType.dwindle.localizedDisplayName)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
    }

    func testLayoutMutationsRefreshTheShellBarLayout() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller
        let reconciler = controller.surfaceReconciler
        let settings = controller.settings
        XCTAssertEqual(settings.workspaces.defaultLayoutType, .niri)
        settings.hiddenBar.enabled = false
        settings.workspaceBar.enabled = true
        settings.workspaceBar.hoverPreviewsEnabled = false
        let shell = ShellWidgetHost.shellDirectory(in: settings.settingsFileURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try Data("leading = [\"omniwm\"]\ntrailing = []\n".utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let bars = controller.workspaceBarManager
        bars.screenProvider = { _ in nil }
        bars.frameApplier = { _, _ in }
        bars.setup(controller: controller, settings: settings)
        controller.hasStartedServices = true
        defer {
            controller.hasStartedServices = false
            bars.cleanup()
            controller.layoutRefreshController.resetState()
        }
        let layouts = {
            [fixture.mainMonitor, fixture.sideMonitor].map { monitor -> ActiveLayoutKind?? in
                bars.shellHost?.bars[ShellBarKey(monitor: monitor.id)].map(\.layout)
            }
        }
        let reconcileIfPending = {
            if reconciler.pendingReconcileScope != nil { reconciler.reconcileNow() }
        }

        reconciler.reconcileNow()
        XCTAssertEqual(layouts(), [.some(nil), .some(nil)])

        settings.statusBar.showLayout = true
        controller.requestWorkspaceBarRefresh()
        XCTAssertNotNil(reconciler.pendingReconcileScope)
        reconciler.reconcileNow()
        XCTAssertEqual(layouts(), [.niri, .niri])

        XCTAssertNil(reconciler.pendingReconcileScope)
        XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.dwindle))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        reconcileIfPending()
        XCTAssertEqual(layouts(), [.dwindle, .niri])

        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(fixture.ws2, on: fixture.mainMonitor.id))
        reconciler.reconcileNow()
        XCTAssertEqual(layouts(), [.niri, .niri])

        settings.workspaces.defaultLayoutType = .dwindle
        controller.updateWorkspaceConfig()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        reconcileIfPending()
        XCTAssertEqual(layouts(), [.dwindle, .dwindle])

        settings.statusBar.showLayout = false
        controller.requestWorkspaceBarRefresh()
        reconciler.reconcileNow()
        XCTAssertEqual(layouts(), [.some(nil), .some(nil)])
    }

    private func makeFixture(followsFocus: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceBarActionsTests-\(UUID().uuidString)", isDirectory: true)
        let mainMonitor = Monitor(
            id: .init(displayId: 700_000), displayId: 700_000,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false, name: "Main"
        )
        let sideMonitor = Monitor(
            id: .init(displayId: 700_001), displayId: 700_001,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false, name: "Side"
        )
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        settings.focus.followsWindowToMonitor = followsFocus
        settings.workspaces.defaultLayoutType = .niri
        settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .specificDisplay(OutputId(from: mainMonitor))),
            WorkspaceConfiguration(name: "2", monitorAssignment: .specificDisplay(OutputId(from: mainMonitor))),
            WorkspaceConfiguration(name: "3", monitorAssignment: .specificDisplay(OutputId(from: sideMonitor)))
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([mainMonitor, sideMonitor])
        controller.workspaceManager.applySettings()
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let dwindleEngine = DwindleLayoutEngine()
        dwindleEngine.animationClock = controller.animationClock
        controller.dwindleEngine = dwindleEngine

        let manager = controller.workspaceManager
        let ws1 = try XCTUnwrap(manager.workspaceId(named: "1"))
        let ws2 = try XCTUnwrap(manager.workspaceId(named: "2"))
        let ws3 = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(manager.setActiveWorkspace(ws3, on: sideMonitor.id, updateInteractionMonitor: false))
        XCTAssertTrue(manager.setActiveWorkspace(ws1, on: mainMonitor.id))
        controller.layoutRefreshController.resetState()
        return Fixture(
            controller: controller,
            mainMonitor: mainMonitor,
            sideMonitor: sideMonitor,
            ws1: ws1,
            ws2: ws2,
            ws3: ws3
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) throws -> WindowHandle {
        let manager = fixture.controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        manager.withEngineMutationScope(in: workspaceId) {
            switch manager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = fixture.controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle, .tabbed:
                _ = fixture.controller.dwindleEngine?.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }
        return try XCTUnwrap(manager.handle(for: token))
    }

    private func select(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID, fixture: Fixture) throws {
        let manager = fixture.controller.workspaceManager
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let node = try XCTUnwrap(engine.findNode(for: handle, in: workspaceId))
        manager.withEngineMutationScope(in: workspaceId) {
            engine.activateWindow(node.id, in: workspaceId)
        }
        let monitorId = manager.monitorId(for: workspaceId)
        _ = manager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: handle.id,
            in: workspaceId,
            onMonitor: monitorId
        )
        _ = manager.setManagedFocus(handle.id, in: workspaceId, onMonitor: monitorId)
    }
}
