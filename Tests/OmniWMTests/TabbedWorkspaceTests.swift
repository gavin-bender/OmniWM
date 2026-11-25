// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class TabbedWorkspaceTests: XCTestCase {
    func testEveryBarSizeFitsAnOversizedWindowOnAnOffsetDisplay() {
        let screen = CGRect(x: -1400, y: 120, width: 1280, height: 750)
        for position in [TabbedBarOptions.Position.top, .left] {
            for size in [TabbedBarOptions.Size.small, .medium, .large] {
                let bar = TabbedBarOptions(position: position, size: size)
                let oversized = screen.insetBy(dx: -100, dy: -100)
                let content = bar.contentFrame(fitting: oversized, in: screen, grouped: true)
                XCTAssertEqual(bar.tileFrame(around: content, grouped: true), screen)
                let interior = screen.insetBy(dx: 200, dy: 100)
                XCTAssertEqual(bar.contentFrame(fitting: interior, in: screen, grouped: true), interior)
            }
        }
    }

    func testTabDropInsertionAndFreeFrameSurviveSynchronization() throws {
        let workspace = UUID()
        let tokens = (1...5).map { WindowToken(pid: 10, windowId: $0) }
        let engine = DwindleLayoutEngine()
        let frame = CGRect(x: 50, y: 75, width: 450, height: 390)
        let newFrame = frame.offsetBy(dx: 360, dy: 80)
        engine.selectWorkspaceStyle(tabbed: true, in: workspace)
        _ = engine.syncWindows(tokens, in: workspace, focusedToken: nil)
        engine.synchronizeTabbedGroups(tokens: tokens, preferred: tokens[0], previousSelection: nil, in: workspace) { _ in frame }
        let original = try XCTUnwrap(engine.tile(containing: tokens[0], in: workspace))
        let order = original.members.map(\.token)
        original.place(order[0], before: nil)
        XCTAssertEqual(original.members.map(\.token), Array(order.dropFirst()) + [order[0]])
        original.place(order[0], before: order[1])
        XCTAssertEqual(original.members.map(\.token), order)
        XCTAssertTrue(engine.detachTab(order[2], to: newFrame, in: workspace))
        XCTAssertEqual(original.freeFrame, frame)
        XCTAssertTrue(engine.groupWindow(order[1], into: order[2], in: workspace))
        let receiving = try XCTUnwrap(engine.tile(containing: order[2], in: workspace))
        receiving.place(order[1], before: order[2])
        engine.synchronizeTabbedGroups(tokens: tokens, preferred: order[1], previousSelection: nil, in: workspace) { _ in frame }
        XCTAssertEqual(receiving.freeFrame, newFrame)
        XCTAssertEqual(receiving.members.map(\.token), [order[1], order[2]])
        XCTAssertEqual(receiving.activeToken, order[1])
        XCTAssertEqual(original.members.map(\.token), [order[0], order[3], order[4]])
    }

    func testAutomaticGroupingFreePlacementTransfersAndLayoutRoundTrip() throws {
        let ws = WorkspaceDescriptor.ID()
        let engine = DwindleLayoutEngine()
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let frame = CGRect(x: 100, y: 120, width: 800, height: 600)
        let tokens = (1...4).map { WindowToken(pid: pid_t($0), windowId: $0) }

        func sync(_ count: Int, focus: WindowToken) {
            let windows = Array(tokens.prefix(count))
            let prior = engine.projectedActiveToken(in: ws)
            _ = engine.syncWindows(windows, in: ws, focusedToken: focus)
            engine.synchronizeTabbedGroups(tokens: windows, preferred: focus, previousSelection: prior, in: ws) { _ in frame }
        }

        engine.selectWorkspaceStyle(tabbed: false, in: ws)
        _ = engine.syncWindows(Array(tokens.prefix(3)), in: ws, focusedToken: nil)
        let splitFrames = engine.calculateLayout(for: ws, screen: screen)
        engine.selectWorkspaceStyle(tabbed: true, in: ws)
        sync(3, focus: tokens[1])
        XCTAssertEqual(engine.calculateLayout(for: ws, screen: screen), [tokens[1]: frame])
        XCTAssertEqual(engine.inactiveGroupTokens(in: ws), [tokens[0], tokens[2]])

        XCTAssertTrue(engine.ungroupWindow(tokens[1], direction: .right, in: ws))
        let detached = try XCTUnwrap(engine.tile(containing: tokens[1], in: ws))
        let moved = CGRect(x: 600, y: 200, width: 450, height: 500)
        detached.freeFrame = moved
        sync(4, focus: tokens[1])
        XCTAssertEqual(engine.tileCount(in: ws), 2)
        XCTAssertEqual(engine.tile(containing: tokens[3], in: ws)?.id, detached.id)
        XCTAssertEqual(engine.calculateLayout(for: ws, screen: screen)[tokens[3]], moved)
        XCTAssertTrue(engine.groupWindow(tokens[3], direction: .left, in: ws))
        XCTAssertNotEqual(engine.tile(containing: tokens[3], in: ws)?.id, detached.id)
        XCTAssertEqual(engine.calculateLayout(for: ws, screen: screen)[tokens[1]], moved)

        engine.selectWorkspaceStyle(tabbed: false, in: ws)
        XCTAssertEqual(engine.calculateLayout(for: ws, screen: screen), splitFrames)
        engine.selectWorkspaceStyle(tabbed: true, in: ws)
        XCTAssertEqual(engine.calculateLayout(for: ws, screen: screen)[tokens[1]], moved)

        let restored = DwindleLayoutEngine()
        restored.selectWorkspaceStyle(tabbed: true, in: ws)
        XCTAssertTrue(restored.restoreInitialPlacements(engine.persistedPlacements(in: ws), matching: tokens, in: ws))
        restored.synchronizeTabbedGroups(tokens: tokens, preferred: tokens[1], previousSelection: nil, in: ws) { _ in nil }
        XCTAssertEqual(restored.tileCount(in: ws), 2)
        XCTAssertEqual(restored.calculateLayout(for: ws, screen: screen)[tokens[1]], moved)
    }
}
