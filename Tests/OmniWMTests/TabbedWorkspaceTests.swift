// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class TabbedWorkspaceTests: XCTestCase {
    func testControlTabCyclesOnlyWhenTheFocusedGroupHandlesIt() throws {
        let center = HotkeyCenter()
        center.start()
        defer { center.stop() }
        var directions: [Bool] = []
        center.cycleFocusedTabGroup = { directions.append($0); return true }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Tab), keyDown: true))
        for flags: CGEventFlags in [.maskControl, [.maskControl, .maskShift]] {
            event.flags = flags
            XCTAssertNil(center.handleHyperTriggerEvent(type: .keyDown, event: event))
            XCTAssertNil(center.handleHyperTriggerEvent(type: .keyUp, event: event))
        }
        XCTAssertEqual(directions, [false, true])
        center.cycleFocusedTabGroup = { _ in false }
        XCTAssertFalse(center.handleWindowSwitcherEvent(type: .keyDown, event: event))
    }

    func testCloseButtonTargetsInactiveTabWithoutSelectingIt() throws {
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 36),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let view = TabRailView(frame: window.frame, motionPolicy: MotionPolicy(animationsEnabled: false))
        window.contentView = view
        let tabs = (0 ..< 2).map { index in
            TabRailTabInfo(visualIndex: index, token: WindowToken(pid: 1, windowId: index + 1),
                           windowId: index + 1, appName: nil, title: "Window", isActive: index == 0)
        }
        view.update(tabs: tabs, activeVisualIndex: 0, style: .windowTabs(.init()))
        var closed: WindowToken?
        view.onTabAction = { token, action in
            if case .close = action { closed = token }
        }
        view.onSelect = { _ in XCTFail("Closing an inactive tab selected it") }
        let icons = try XCTUnwrap(view.subviews.compactMap { $0 as? TabRailIconView }.first)
        let button = icons.rows[1].closeButton
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view)
        XCTAssertTrue(view.hitTest(center) === button)
        button.performClick(nil)
        XCTAssertEqual(closed, tabs[1].token)
    }

    func testCornerDragsPreserveOppositeCornerAtMinimumSize() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let minimum = CGSize(width: 100, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 36)
        XCTAssertEqual(TabChromeHandle.hit(CGPoint(x: 8, y: 8), bounds: bounds, gripWidth: 24, position: .top), .topLeft)
        XCTAssertEqual(TabChromeHandle.hit(CGPoint(x: 392, y: 28), bounds: bounds, gripWidth: 24, position: .top), .topRight)
        let drag = TabFrameDrag(start: .zero, frame: frame, handle: .topLeft)
        XCTAssertEqual(drag.frame(at: CGPoint(x: 500, y: -500), minimum: minimum),
                       CGRect(x: 400, y: 200, width: 100, height: 80))
        let sideDrag = TabFrameDrag(start: .zero, frame: frame, handle: .bottomLeft)
        XCTAssertEqual(sideDrag.frame(at: CGPoint(x: 500, y: 500), minimum: minimum),
                       CGRect(x: 400, y: 420, width: 100, height: 80))
    }

    func testWindowTabsUseOneBarAndAnchorPreviewToHoveredTab() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let handle = WindowHandle(id: WindowToken(pid: 1, windowId: 7))
        let tile = try XCTUnwrap(NSScreen.main?.visibleFrame).insetBy(dx: 100, dy: 120).integral
        let tabs = [TabRailTabInfo(visualIndex: 0, token: handle.token, windowId: handle.windowId,
                                   appName: "Editor", title: "Document", isActive: true)]
        let legacy = TabRailInfo(workspaceId: UUID(), owner: .niriColumn(NodeId()), plannedSeq: 1,
                                 tileFrame: tile, tabCount: 2, activeVisualIndex: 0, activeWindowId: nil)
        let bar = TabRailInfo(workspaceId: UUID(), owner: .dwindleTile(UUID()), plannedSeq: 1,
                              tileFrame: tile, tabCount: 2, activeVisualIndex: 0, activeWindowId: nil,
                              tabs: tabs, styleOverride: .windowTabs(.init()))
        manager.updateRails([legacy, bar], style: .hidden)
        manager.applyAnimationGeometry([.init(key: legacy.key, tileFrame: tile, visibleTileFrame: tile)])
        XCTAssertNil(manager.existingWindow(for: legacy.key))
        let window = try XCTUnwrap(manager.existingWindow(for: bar.key) as? TabRailWindow)
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        var target: WorkspaceBarHoverTarget?
        manager.resolvePreviewHandle = { $0 == handle.token ? handle : nil }
        window.onHoverPreview = { target = $0 }
        let point = CGPoint(x: view.bounds.width / 4, y: view.bounds.midY)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 1, clickCount: 0, pressure: 0))
        view.mouseMoved(with: event)
        XCTAssertTrue(target?.windows.first?.handle === handle)
        XCTAssertEqual(target?.attachment.edge, .below)
        XCTAssertEqual(target?.attachment.anchor.y, window.appliedFrame.minY)
        XCTAssertFalse(window.hoverCard.isVisible)
        view.mouseExited(with: event)
        XCTAssertNil(target)
    }

    func testLiveSwipeMovesRailUntilWorkspacePlacementResumes() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let viewport = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let info = TabRailInfo(workspaceId: UUID(), owner: .dwindleTile(UUID()), plannedSeq: 1,
                               tileFrame: viewport.insetBy(dx: 100, dy: 100).integral, tabCount: 2,
                               activeVisualIndex: 0, activeWindowId: nil, styleOverride: .windowTabs(.init()))
        manager.updateRails([info])
        let rail = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
        let original = rail.appliedFrame
        manager.presentSwipeRails([info], offset: CGVector(dx: 30, dy: -20), viewport: viewport)
        manager.updateRails([info])
        XCTAssertEqual(rail.appliedFrame, original.offsetBy(dx: 30, dy: -20))
        XCTAssertTrue(rail.ignoresMouseEvents)
        manager.releaseSwipeRails([info])
        manager.updateRails([info])
        XCTAssertEqual(rail.appliedFrame, original)
        XCTAssertFalse(rail.ignoresMouseEvents)
    }

    func testCommittedSwipeKeepsIncomingPanelThroughLayoutHandoff() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let viewport = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let tile = viewport.insetBy(dx: 100, dy: 100).integral
        func group() -> TabRailInfo {
            TabRailInfo(workspaceId: UUID(), owner: .dwindleTile(UUID()), plannedSeq: 1,
                        tileFrame: tile, tabCount: 2, activeVisualIndex: 0, activeWindowId: nil,
                        styleOverride: .windowTabs(.init()))
        }
        let source = group(), destination = group(), otherDisplay = group()
        manager.updateRails([source, otherDisplay])
        let otherWindow = try XCTUnwrap(manager.existingWindow(for: otherDisplay.key))
        manager.presentSwipeRails([source], offset: CGVector(dx: -viewport.width, dy: 0), viewport: viewport)
        manager.presentSwipeRails([destination], offset: CGVector(dx: 2, dy: 0), viewport: viewport)
        let incoming = try XCTUnwrap(manager.existingWindow(for: destination.key) as? TabRailWindow)
        XCTAssertTrue(incoming.isOrderedIn)

        manager.releaseSwipeRails([source, destination])
        manager.updateRails([destination, otherDisplay])
        XCTAssertNil(manager.existingWindow(for: source.key))
        XCTAssertTrue(manager.existingWindow(for: destination.key) === incoming)
        XCTAssertTrue(incoming.isOrderedIn)
        XCTAssertFalse(incoming.ignoresMouseEvents)
        manager.updateRails([destination, otherDisplay])
        XCTAssertTrue(manager.existingWindow(for: destination.key) === incoming)
        XCTAssertTrue(manager.existingWindow(for: otherDisplay.key) === otherWindow)
    }

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
