// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class TrackpadWindowGestureTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    @MainActor
    private struct GestureDriver {
        let handler: MouseEventHandler
        let location: CGPoint
        var contactSession: MultitouchContactSession?
        var time: TimeInterval = 100

        mutating func begin(fingers: Int, x: CGFloat, y: CGFloat = 0.5) {
            send(.began, fingers: fingers, x: x, y: y)
        }

        mutating func frame(fingers: Int, x: CGFloat, y: CGFloat = 0.5, after dt: TimeInterval = 0.01) {
            time += dt
            send(.changed, fingers: fingers, x: x, y: y)
        }

        mutating func drag(fingers: Int, fromX: CGFloat, toX: CGFloat, steps: Int = 10, y: CGFloat = 0.5) {
            for step in 1 ... steps {
                frame(fingers: fingers, x: fromX + (toX - fromX) * CGFloat(step) / CGFloat(steps), y: y)
            }
        }

        mutating func end(_ phase: NSEvent.Phase = .ended) {
            time += 0.01
            send(phase, fingers: 0, x: 0, y: 0)
        }

        private func send(_ phase: NSEvent.Phase, fingers: Int, x: CGFloat, y: CGFloat) {
            let touches = (0 ..< fingers).map { _ in
                MouseEventHandler.GestureTouchSample(phase: .moved, normalizedPosition: CGPoint(x: x, y: y))
            }
            handler.receiveTapGestureEvent(
                MouseEventHandler.GestureEventSnapshot(
                    location: location,
                    phaseRawValue: phase.rawValue,
                    timestamp: time,
                    touches: phase == .ended || phase == .cancelled ? [] : touches,
                    contactSession: contactSession
                )
            )
        }
    }

    @MainActor
    private struct NiriFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let first: NiriWindow
        let second: NiriWindow
        let firstFrame: CGRect
        let secondFrame: CGRect

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var travelToSecond: CGFloat {
            (secondFrame.center.x - firstFrame.center.x) / monitor.frame.width
        }

        var firstRightEdgeGrip: CGPoint {
            CGPoint(x: firstFrame.maxX - 20, y: firstFrame.midY)
        }

        func windowOrder() -> [WindowToken] {
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
        }

        func frames() -> [WindowToken: CGRect] {
            let gap = controller.innerGap(for: monitor)
            return engine.calculateLayout(
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: .horizontal
            )
        }

        func driver(at location: CGPoint) -> GestureDriver {
            GestureDriver(handler: handler, location: location)
        }
    }

    @MainActor
    private struct DwindleFixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let screen: CGRect
        let first: WindowToken
        let second: WindowToken
        let firstFrame: CGRect
        let secondFrame: CGRect

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        func presentedFrame(_ token: WindowToken) -> CGRect? {
            engine.presentedFrame(for: token, in: workspaceId, at: 0)
        }

        func relayout() {
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            engine.cancelAnimations(in: workspaceId)
        }

        func driver(at location: CGPoint) -> GestureDriver {
            GestureDriver(handler: handler, location: location)
        }
    }

    func testFourFingerDragMovesWindowAndSwapsOnRelease() throws {
        let fixture = try makeNiriFixture(pid: 9_101)
        let handler = fixture.handler
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        XCTAssertFalse(handler.state.isMoving)

        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)

        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertEqual(handler.state.activeGestureMode, .windowMove)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
        XCTAssertEqual(handler.state.activeInteractionSource, .trackpadGesture)
        XCTAssertEqual(handler.state.moveLayout, .niri)
        XCTAssertNil(handler.state.activeInteractionButton)
        XCTAssertEqual(fixture.engine.interactiveMove?.windowToken, fixture.first.token)
        XCTAssertFalse(handler.isViewportGestureActive)
        XCTAssertTrue(handler.isInteractiveGestureActive)
        let hoverTarget = try XCTUnwrap(
            fixture.engine.interactiveMove?.currentHoverTarget,
            "Expected the virtual cursor to hover the second window"
        )
        XCTAssertEqual(hoverTarget.token, fixture.second.token)
        XCTAssertNil(hoverTarget.direction)

        gesture.end()

        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testTouchDisplayMoveUsesAbsolutePositionAndHasNoMouseButton() throws {
        let fixture = try makeNiriFixture(pid: 9_150)
        let handler = fixture.handler
        let workspace = try XCTUnwrap(fixture.controller.workspaceManager.descriptor(for: fixture.workspaceId))
        XCTAssertTrue(handler.beginWindowInteraction(
            .windowMove,
            target: fixture.first.token,
            workspace: workspace,
            at: fixture.firstFrame.center,
            source: .touchDisplay
        ))
        XCTAssertNil(handler.state.activeInteractionButton)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        handler.pressedMouseButtonsProvider = { 0 }
        handler.dispatchMouseDragged(at: fixture.firstFrame.center)
        handler.dispatchMouseUp(at: fixture.firstFrame.center)
        XCTAssertEqual(handler.state.activeInteractionSource, .touchDisplay)

        handler.updateActiveMove(at: fixture.secondFrame.center)
        handler.completeActiveMove(at: fixture.secondFrame.center)

        XCTAssertNil(handler.state.activeInteractionSource)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testNiriCornerResizeWithPrimaryButtonAndDirectTouch() throws {
        for source in [MouseInputState.InteractionSource.mouse(.left), .touchDisplay] {
            let fixture = try makeNiriFixture(pid: 9_153)
            let handler = fixture.handler
            let frame = fixture.firstFrame
            let corner = CGPoint(x: frame.maxX - 3, y: frame.minY + 3)
            let workspace = try XCTUnwrap(fixture.controller.workspaceManager.descriptor(for: fixture.workspaceId))
            if source == .touchDisplay {
                XCTAssertTrue(handler.beginWindowInteraction(
                    .windowMove, target: fixture.first.token, workspace: workspace, at: corner, source: source
                ))
            } else {
                let id = fixture.first.token.windowId
                handler.tabWindowStackAtPoint = { _ in [(id, frame)] }
                let previous = MouseEventHandler._instance
                MouseEventHandler._instance = handler
                defer { MouseEventHandler._instance = previous }
                var snapshot = handler.inputTapThread.filterSnapshot
                snapshot.niriResizeFrames[fixture.monitor.displayId] = [frame]
                XCTAssertTrue(handler.inputTapThread.evaluateLeftMouseDown(
                    at: corner, modifiers: [], timestamp: 0, snapshot: snapshot
                ) {
                    XCTFail("A managed corner press should capture the resize synchronously")
                    return [:]
                })
            }
            XCTAssertEqual(handler.state.currentHoveredEdges, [.right, .bottom])
            XCTAssertEqual(handler.state.activeInteractionSource, source)
            let end = CGPoint(x: corner.x + 75, y: corner.y)
            if source == .touchDisplay {
                handler.updateManagedResize(at: end)
                handler.completeActiveResize()
            } else {
                handler.receiveTapMouseUp(at: end)
            }
            XCTAssertGreaterThan(try XCTUnwrap(fixture.frames()[fixture.first.token]).width, frame.width)
        }
    }

    func testNiriTrackpadClickDragJustOutsideSideEdgePersistsAfterRelease() throws {
        let fixture = try makeNiriFixture(pid: 9_157)
        let handler = fixture.handler
        let frame = fixture.firstFrame
        let press = CGPoint(x: frame.maxX + 2, y: frame.midY)
        let end = CGPoint(x: press.x + 65, y: press.y + 15)
        handler.tabWindowStackAtPoint = { frame.contains($0) ? [(fixture.first.token.windowId, frame)] : [] }
        let previous = MouseEventHandler._instance
        MouseEventHandler._instance = handler
        defer { MouseEventHandler._instance = previous }
        var snapshot = handler.inputTapThread.filterSnapshot
        snapshot.niriResizeFrames[fixture.monitor.displayId] = [frame]
        XCTAssertTrue(handler.inputTapThread.evaluateLeftMouseDown(at: press, modifiers: [], timestamp: 0,
                                                                  snapshot: snapshot) { [:] })
        XCTAssertEqual(handler.state.currentHoveredEdges, [.right])
        handler.dispatchQueuedMouseDragged(at: end, button: .left)
        let live = try XCTUnwrap(fixture.frames()[fixture.first.token])
        XCTAssertGreaterThan(live.width, frame.width)
        XCTAssertEqual(live.height, frame.height)
        handler.receiveTapMouseUp(at: end)
        XCTAssertEqual(try XCTUnwrap(fixture.frames()[fixture.first.token]).size, live.size)
    }

    func testNiriGestureDropAtFarEdgeInsertsColumn() throws {
        for source in [MouseInputState.InteractionSource.trackpadGesture, .touchDisplay] {
            let fixture = try makeNiriFixture(pid: 9_154)
            let workspace = try XCTUnwrap(fixture.controller.workspaceManager.descriptor(for: fixture.workspaceId))
            let targetColumn = try XCTUnwrap(fixture.engine.findColumn(containing: fixture.second, in: workspace.id))
            XCTAssertTrue(fixture.handler.beginWindowInteraction(
                .windowMove, target: fixture.first.token, workspace: workspace, at: fixture.firstFrame.center,
                source: source
            ))
            let drop = CGPoint(x: fixture.secondFrame.maxX - 3, y: fixture.secondFrame.midY)
            fixture.handler.updateActiveMove(at: drop)
            XCTAssertEqual(fixture.engine.interactiveMove?.currentHoverTarget?.direction, .right)
            fixture.handler.completeActiveMove(at: drop)
            XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
            XCTAssertEqual(targetColumn.windowNodes.map(\.token), [fixture.second.token])
        }
    }

    func testShortTouchDragAcrossAWideWindowMovesItOneStripPosition() throws {
        let fixture = try makeNiriFixture(pid: 9_156)
        let workspace = try XCTUnwrap(fixture.controller.workspaceManager.descriptor(for: fixture.workspaceId))
        let start = CGPoint(x: fixture.firstFrame.midX, y: fixture.firstFrame.maxY - 12)
        let end = CGPoint(x: start.x + 90, y: start.y)
        XCTAssertTrue(fixture.firstFrame.contains(end))
        XCTAssertTrue(fixture.handler.beginWindowInteraction(
            .windowMove, target: fixture.first.token, workspace: workspace, at: start, source: .touchDisplay
        ))
        fixture.handler.updateActiveMove(at: end)
        XCTAssertEqual(fixture.engine.interactiveMove?.currentHoverTarget?.token, fixture.second.token)
        fixture.handler.completeActiveMove(at: end)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testTouchscreenKeepsCornerThroughSynthesizedMouseEventsInEitherOrder() throws {
        for mouseFirst in [true, false] {
            let fixture = try makeNiriFixture(pid: 9_156)
            let handler = fixture.handler
            let frame = fixture.firstFrame
            let corner = CGPoint(x: frame.maxX - 4, y: frame.minY + 4)
            handler.tabWindowStackAtPoint = { _ in [(fixture.first.token.windowId, frame)] }
            let contact = MultitouchContactSession(generation: 1, slot: 0, session: 1, senderId: nil, isTouchScreen: true)
            func touch(_ phase: NSEvent.Phase, _ point: CGPoint) {
                var snapshot = MouseEventHandler.GestureEventSnapshot(
                    location: point, phaseRawValue: phase.rawValue,
                    touches: phase == .ended ? [] : [.init(phase: .moved, normalizedPosition: .zero)],
                    contactSession: contact
                )
                snapshot.directDisplayLocation = point
                XCTAssertTrue(handler.handleDirectTouchDrag(snapshot))
            }
            if mouseFirst { XCTAssertTrue(handler.dispatchMouseDown(at: corner, modifiers: [])) }
            touch(.began, corner)
            if !mouseFirst { XCTAssertTrue(handler.dispatchMouseDown(at: corner, modifiers: [])) }
            let mid = CGPoint(x: corner.x + 35, y: corner.y)
            touch(.changed, mid)
            handler.receiveTapMouseUp(at: mid)
            XCTAssertEqual(handler.state.activeInteractionSource, .touchDisplay)
            let end = CGPoint(x: corner.x + 70, y: corner.y)
            touch(.changed, end)
            let liveWidth = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
            touch(.ended, end)
            XCTAssertGreaterThan(liveWidth, frame.width)
            XCTAssertEqual(try XCTUnwrap(fixture.frames()[fixture.first.token]).width, liveWidth)
        }
    }

    func testDirectScreenContactReordersTitleBarsAndResizesCornersWithoutAPanel() throws {
        let fixture = try makeNiriFixture(pid: 9_155)
        let handler = fixture.handler
        let frames = [(fixture.first.token.windowId, fixture.firstFrame), (fixture.second.token.windowId, fixture.secondFrame)]
        handler.tabWindowStackAtPoint = { point in frames.filter { $0.1.contains(point) } }
        let contact = MultitouchContactSession(generation: 1, slot: 0, session: 1, senderId: nil, isTouchScreen: true)
        func touch(_ phase: NSEvent.Phase, at point: CGPoint, count: Int = 1) {
            var snapshot = MouseEventHandler.GestureEventSnapshot(
                location: .zero, phaseRawValue: phase.rawValue,
                touches: Array(repeating: .init(phase: .moved, normalizedPosition: .zero), count: count),
                contactSession: contact
            )
            snapshot.directDisplayLocation = point
            handler.receiveTapGestureEvent(snapshot)
        }

        let first = fixture.firstFrame
        let second = fixture.secondFrame
        let title = CGPoint(x: first.midX, y: first.maxY - 40)
        let destination = CGPoint(x: second.midX, y: second.maxY - 12)
        touch(.began, at: first.center)
        touch(.changed, at: destination)
        touch(.ended, at: destination, count: 0)
        XCTAssertNil(handler.state.activeInteractionSource)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        touch(.began, at: title)
        touch(.ended, at: title, count: 0)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])
        touch(.began, at: title)
        touch(.changed, at: destination)
        XCTAssertEqual(handler.state.activeInteractionSource, .touchDisplay)
        touch(.cancelled, at: destination, count: 0)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        let corner = CGPoint(x: first.maxX + 2, y: first.minY + 5)
        let end = CGPoint(x: corner.x + 60, y: corner.y)
        touch(.began, at: corner)
        touch(.changed, at: end)
        XCTAssertTrue(handler.state.isResizing)
        let liveNeighbor = try XCTUnwrap(fixture.frames()[fixture.second.token])
        XCTAssertGreaterThan(liveNeighbor.minX, second.minX)
        touch(.ended, at: end, count: 0)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.frames()[fixture.first.token]).width, first.width)

        let target = try XCTUnwrap(fixture.frames()[fixture.second.token])
        let drop = CGPoint(x: target.midX, y: target.maxY - 12)
        touch(.began, at: title)
        touch(.changed, at: drop)
        touch(.ended, at: drop, count: 0)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map { $0.windowNodes.map(\.token) },
                       [[fixture.second.token], [fixture.first.token]])
        XCTAssertNil(handler.state.activeInteractionSource)
    }

    func testPauseNativeNavigationSwipesDropsHorizontalAndVerticalDockGesturesWhileEnabled() throws {
        let type = try XCTUnwrap(CGEventType(rawValue: InputTapThread.dockSwipeEventType))
        let kind = try XCTUnwrap(CGEventField(rawValue: 110))
        let axis = try XCTUnwrap(CGEventField(rawValue: 123))
        let event = try XCTUnwrap(CGEvent(source: nil))
        let tap = InputTapThread()
        event.type = type
        event.setIntegerValueField(kind, value: 23)
        event.setIntegerValueField(axis, value: 1)
        XCTAssertNotNil(tap.evaluateTap(type: type, event: event))

        tap.updateFilterSnapshot { $0.suppressNativeSpaceSwitchGestures = true }
        XCTAssertNil(tap.evaluateTap(type: type, event: event))
        event.setIntegerValueField(axis, value: 2)
        XCTAssertNil(tap.evaluateTap(type: type, event: event))
        event.setIntegerValueField(axis, value: 3)
        XCTAssertNotNil(tap.evaluateTap(type: type, event: event))
        event.setIntegerValueField(axis, value: 1)
        event.setIntegerValueField(kind, value: 8)
        XCTAssertNotNil(tap.evaluateTap(type: type, event: event))
        event.setIntegerValueField(kind, value: 23)

        tap.updateFilterSnapshot { $0.isInputSuppressed = true }
        XCTAssertNotNil(tap.evaluateTap(type: type, event: event))
        tap.updateFilterSnapshot {
            $0.isInputSuppressed = false
            $0.suppressNativeSpaceSwitchGestures = false
        }
        XCTAssertNotNil(tap.evaluateTap(type: type, event: event))
    }

    func testTouchDisplaySpacesSettingIsRestoredAndRespectsSystemSettingsChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("touch-space-swipe-restore")
        var count: Int32 = 4
        var writes: [Int32] = []
        let preference = NativeNavigationGestureLease.Preference(read: { count }, write: { newCount in
            writes.append(newCount)
            count = newCount
            return true
        })
        let firstRun = NativeNavigationGestureLease(restoreURL: journal, preference: preference)
        firstRun.reconcile(shouldPause: true)
        firstRun.reconcile(shouldPause: true)
        XCTAssertEqual(writes, [0])
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "4")

        firstRun.reconcile(shouldPause: false)
        XCTAssertEqual(writes, [0, 4])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))

        firstRun.reconcile(shouldPause: true)
        count = 3
        firstRun.reconcile(shouldPause: false)
        XCTAssertEqual(writes, [0, 4, 0])
        XCTAssertEqual(count, 3)

        firstRun.reconcile(shouldPause: true)
        let nextRun = NativeNavigationGestureLease(restoreURL: journal, preference: preference)
        nextRun.reconcile(shouldPause: false)
        XCTAssertEqual(writes, [0, 4, 0, 0, 3])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testThreeFingerResizePreservesLifecycleAcrossSensitivities() throws {
        let cases: [(Double, CGFloat, pid_t)] = [(1, 160, 9_102), (0.5, 80, 9_103)]
        for (sensitivity, delta, pid) in cases {
            let fixture = try makeNiriFixture(pid: pid)
            fixture.controller.settings.gestures.windowGestureSensitivity = sensitivity
            let handler = fixture.handler
            let widthBefore = fixture.firstFrame.width

            var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
            gesture.begin(fingers: 3, x: 0.4)
            gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5, steps: 8)

            XCTAssertEqual(handler.state.activeGestureMode, .windowResize)
            XCTAssertTrue(handler.state.isResizing)
            XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
            XCTAssertEqual(handler.state.resizeLayout, .niri)
            XCTAssertNil(handler.state.activeInteractionButton)
            let resize = try XCTUnwrap(fixture.engine.interactiveResize)
            XCTAssertTrue(resize.edges.contains(.right))
            XCTAssertEqual(resize.startMouseLocation, gesture.location)

            gesture.end()

            XCTAssertFalse(handler.state.isResizing)
            XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertEqual(handler.state.gesturePhase, .idle)
            let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
            XCTAssertEqual(widthAfter, widthBefore + delta)
        }
    }

    func testWindowGestureWithNoWindowUnderCursorNeverArms() throws {
        let fixture = try makeNiriFixture(pid: 9_104)
        let handler = fixture.handler

        var gesture = fixture.driver(at: CGPoint(x: workingFrame.maxX + 400, y: workingFrame.midY))
        gesture.begin(fingers: 4, x: 0.2)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertTrue(
            handler.state.suppressGestureStartUntilAllTouchesLift,
            "The cursor cannot move while fingers rest, so retrying every frame is pointless"
        )
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.45, steps: 5)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        gesture.end()
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
    }

    func testDisabledWindowGesturesIgnoreTheirFingerCount() throws {
        let fixture = try makeNiriFixture(pid: 9_105)
        fixture.controller.settings.gestures.windowMoveEnabled = false
        fixture.controller.settings.gestures.windowResizeEnabled = false
        fixture.controller.settings.gestures.workspaceSwipeEnabled = true
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.45, steps: 5)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        gesture.end()
    }

    func testAmbiguousWindowResizeAndColumnScrollDoesNotArm() throws {
        let fixture = try makeNiriFixture(pid: 9_106)
        fixture.controller.settings.gestures.scrollEnabled = true
        fixture.controller.settings.gestures.fingerCount = .three
        fixture.controller.settings.gestures.windowResizeFingerCount = .three
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.48, steps: 4)
        XCTAssertNil(handler.state.activeGestureMode)
        XCTAssertFalse(handler.state.isResizing)
        XCTAssertFalse(handler.isViewportGestureActive)
        gesture.end()
        XCTAssertFalse(handler.state.isResizing)
    }

    func testCancelledTouchSessionRevertsMoveInsteadOfDropping() throws {
        let fixture = try makeNiriFixture(pid: 9_107)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)
        XCTAssertTrue(handler.state.isMoving)

        gesture.end(.cancelled)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])
    }

    func testLiftingOneFingerDropsTheWindowAfterTheFlickerGrace() throws {
        let fixture = try makeNiriFixture(pid: 9_108)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        let endX = 0.2 + fixture.travelToSecond
        gesture.drag(fingers: 4, fromX: 0.2, toX: endX)
        XCTAssertTrue(handler.state.isMoving)

        for _ in 0 ..< 5 {
            gesture.frame(fingers: 3, x: endX, after: 0.02)
        }
        XCTAssertTrue(handler.state.isMoving, "100ms of three fingers is flicker, not a release")
        gesture.frame(fingers: 3, x: endX, after: 0.1)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)

        gesture.end()
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
    }

    func testBriefFingerCountDipDoesNotEndResize() throws {
        let fixture = try makeNiriFixture(pid: 9_113)
        let handler = fixture.handler
        let widthBefore = fixture.firstFrame.width

        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.45, steps: 4)
        XCTAssertTrue(handler.state.isResizing)

        gesture.frame(fingers: 2, x: 0.46)
        gesture.frame(fingers: 2, x: 0.47)
        XCTAssertTrue(handler.state.isResizing, "a two-frame dip must not end the resize")
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)

        gesture.drag(fingers: 3, fromX: 0.45, toX: 0.5, steps: 4)
        XCTAssertTrue(handler.state.isResizing)
        gesture.end()

        let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        XCTAssertEqual(widthAfter, widthBefore + 160, "the full travel must land despite the dip")
    }

    func testTransientExtraFingerDoesNotAbortMove() throws {
        let fixture = try makeNiriFixture(pid: 9_114)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        gesture.frame(fingers: 5, x: 0.29)
        XCTAssertTrue(handler.state.isMoving, "a resting palm for one frame must not cancel the move")
        gesture.frame(fingers: 4, x: 0.3)
        XCTAssertTrue(handler.state.isMoving)

        gesture.end()
        XCTAssertFalse(handler.state.isMoving)
    }

    func testLateFourthFingerReArmsFromResizeToMoveBeforeCommit() throws {
        let fixture = try makeNiriFixture(pid: 9_112)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 3, x: 0.2)
        gesture.frame(fingers: 3, x: 0.21)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        XCTAssertEqual(handler.state.lockedGestureContext?.fingerCount, 3)

        gesture.frame(fingers: 4, x: 0.21)
        gesture.drag(fingers: 4, fromX: 0.21, toX: 0.21 + fixture.travelToSecond)
        XCTAssertEqual(handler.state.lockedGestureContext?.fingerCount, 4)
        XCTAssertEqual(handler.state.activeGestureMode, .windowMove)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertFalse(handler.state.isResizing)

        gesture.end()
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testMouseEventsDoNotDisturbGestureOwnedMove() throws {
        let fixture = try makeNiriFixture(pid: 9_109)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        handler.pressedMouseButtonsProvider = { 0 }
        handler.dispatchMouseDragged(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A mouse drag without a held button must not cancel a gesture move")
        handler.dispatchMouseUp(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A stray mouse-up must not drop a gesture move")
        XCTAssertFalse(
            handler.dispatchMouseDown(at: fixture.secondFrame.center, modifiers: .maskAlternate),
            "A modifier click cannot start a second interaction while the gesture owns one"
        )
        XCTAssertNotNil(fixture.engine.interactiveMove)

        gesture.end()
        XCTAssertFalse(handler.state.isMoving)
    }

    func testDisablingControllerMidGestureCancelsMoveAndClearsGestureState() throws {
        let fixture = try makeNiriFixture(pid: 9_110)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        fixture.controller.isEnabled = false
        gesture.frame(fingers: 4, x: 0.3)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        gesture.end()
        fixture.controller.isEnabled = true
    }

    func testCleanupWhileGestureOwnsMoveReconcilesEverything() throws {
        let fixture = try makeNiriFixture(pid: 9_111)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        handler.cleanup()

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.isInteractiveGestureActive)
    }

    func testFourFingerMoveTranslatesWholeTabGroup() throws {
        let fixture = try makeDwindleFixture(pid: 9_206)
        let controller = fixture.controller
        let engine = fixture.engine
        let workspace = fixture.workspaceId
        controller.settings.workspaces.configurations[0].layoutType = .tabbed
        controller.workspaceManager.applySettings()
        let start = fixture.screen.insetBy(dx: 250, dy: 150)
        controller.workspaceManager.withEngineMutationScope(in: workspace) {
            engine.selectWorkspaceStyle(tabbed: true, in: workspace)
            _ = engine.syncWindows([fixture.first, fixture.second], in: workspace, focusedToken: fixture.first)
            engine.synchronizeTabbedGroups(tokens: [fixture.first, fixture.second], preferred: fixture.first,
                                           previousSelection: nil, in: workspace) { _ in start }
        }
        fixture.relayout()
        fixture.handler.tabWindowStackAtPoint = { _ in [(fixture.first.windowId, start)] }
        var gesture = fixture.driver(at: start.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.3)
        let group = try XCTUnwrap(engine.tile(containing: fixture.first, in: workspace))
        let moved = try XCTUnwrap(group.freeFrame)
        XCTAssertGreaterThan(moved.minX, start.minX)
        XCTAssertEqual(moved.size, start.size)
        gesture.end()
        fixture.relayout()
        let snapshot = try XCTUnwrap(engine.tileSnapshot(for: fixture.first, in: workspace))
        XCTAssertEqual(snapshot.members.count, 2)
        XCTAssertEqual(snapshot.tileFrame, engine.tabbedBar.tileFrame(around: moved, grouped: true))
        XCTAssertNil(fixture.handler.state.tabbedGesture)
    }

    func testFourFingerDragSwapsDwindleTilesOnRelease() throws {
        let fixture = try makeDwindleFixture(pid: 9_201)
        let handler = fixture.handler
        let travel = (fixture.secondFrame.minX + 32 - fixture.firstFrame.center.x) / fixture.screen.width

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + travel)

        XCTAssertTrue(handler.state.isMoving)
        XCTAssertEqual(handler.state.moveLayout, .dwindle)
        XCTAssertEqual(fixture.engine.interactiveMove?.token, fixture.first)
        XCTAssertEqual(fixture.engine.interactiveMove?.targetToken, fixture.second)
        XCTAssertNil(fixture.engine.interactiveMove?.targetDirection)
        XCTAssertEqual(fixture.engine.interactiveMoveTargetFrame(at: 0), fixture.secondFrame)

        gesture.end()

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)
    }

    func testThreeFingerDragResizesDwindleSplit() throws {
        let fixture = try makeDwindleFixture(pid: 9_202)
        let handler = fixture.handler

        var gesture = fixture.driver(at: CGPoint(x: fixture.firstFrame.maxX - 20, y: fixture.firstFrame.midY))
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5, steps: 8)
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertEqual(handler.state.resizeLayout, .dwindle)
        XCTAssertEqual(fixture.engine.interactiveResize?.token, fixture.first)

        gesture.end()

        XCTAssertFalse(handler.state.isResizing)
        XCTAssertNil(fixture.engine.interactiveResize)
        fixture.relayout()
        let widthAfter = try XCTUnwrap(fixture.presentedFrame(fixture.first)).width
        XCTAssertGreaterThan(widthAfter, fixture.firstFrame.width + 100)
    }

    func testDwindleResizeGestureFallsBackToTheEdgeThatCanMove() throws {
        let fixture = try makeDwindleFixture(pid: 9_203)
        let handler = fixture.handler

        var gesture = fixture.driver(at: CGPoint(x: fixture.firstFrame.minX + 20, y: fixture.firstFrame.minY + 20))
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5, steps: 8)
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertEqual(fixture.engine.interactiveResize?.edges, .right)
        XCTAssertEqual(handler.state.currentHoveredEdges, .right)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)

        gesture.end()

        XCTAssertFalse(handler.state.isResizing)
        fixture.relayout()
        let widthAfter = try XCTUnwrap(fixture.presentedFrame(fixture.first)).width
        XCTAssertGreaterThan(widthAfter, fixture.firstFrame.width + 100)
    }

    func testMouseResizeKeepsExactEdgesAndRefusesAnImmovableOne() throws {
        let fixture = try makeDwindleFixture(pid: 9_204)
        let leftGrip = CGPoint(x: fixture.firstFrame.minX + 20, y: fixture.firstFrame.midY)
        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: leftGrip, modifiers: .maskAlternate, button: .right))
        XCTAssertNil(fixture.engine.interactiveResize)
    }

    func testRearmingPreservesContactConsumptionUntilFreshContact() throws {
        let fixture = try makeNiriFixture(pid: 9_115)
        let handler = fixture.handler
        let contact = MultitouchContactSession(generation: 1, slot: 0, session: 1, senderId: 0x677)
        var contacts = MultitouchContactSessions()
        contacts.generation = 1
        contacts.sessions[0] = 1
        handler.updateContactSessions(contacts)
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.contactSession = contact
        gesture.begin(fingers: 3, x: 0.2)
        gesture.frame(fingers: 4, x: 0.21)
        XCTAssertEqual(handler.state.lockedGestureContext?.contactSession, contact)
        gesture.drag(fingers: 4, fromX: 0.21, toX: 0.21 + fixture.travelToSecond)
        gesture.end()
        XCTAssertTrue(handler.consumesTrackpadSession(senderId: 0x677))
        XCTAssertFalse(handler.consumesTrackpadSession(senderId: 0x999))
        contacts.sessions[0] = 2
        handler.updateContactSessions(contacts)
        XCTAssertFalse(handler.consumesTrackpadSession(senderId: 0x677))
    }

    func testArmedOverviewCannotRearmIntoWindowMoveBeforeLift() throws {
        let fixture = try makeNiriFixture(pid: 9_116)
        let handler = fixture.handler
        fixture.controller.settings.gestures.windowResizeEnabled = false
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        fixture.controller.settings.gestures.overviewGestureFingerCount = .three
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 3, x: 0.2)
        XCTAssertEqual(handler.state.lockedGestureContext?.overviewAction, .open)
        gesture.frame(fingers: 4, x: 0.21)
        gesture.frame(fingers: 4, x: 0.5)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)
        gesture.end()
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)
        XCTAssertTrue(handler.state.isMoving)
        gesture.end()
    }

    func testSourceReplacementClearsMoveAndResizeAndAllowsNewGesture() throws {
        for fingers in [3, 4] {
            let fixture = try makeNiriFixture(pid: 9_117)
            let handler = fixture.handler
            var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
            gesture.begin(fingers: fingers, x: 0.2)
            gesture.drag(fingers: fingers, fromX: 0.2, toX: 0.35)
            XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
            handler.resetForMultitouchSourceReplacement()
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertNil(handler.state.activeInteractionSource)
            XCTAssertEqual(handler.state.gesturePhase, .idle)
            XCTAssertFalse(handler.state.isMoving)
            XCTAssertFalse(handler.state.isResizing)
            gesture.begin(fingers: fingers, x: 0.2)
            gesture.drag(fingers: fingers, fromX: 0.2, toX: 0.35)
            XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
            gesture.end()
        }
    }

    func testFullLiftDuringFingerGraceDropsImmediately() throws {
        let fixture = try makeNiriFixture(pid: 9_118)
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)
        gesture.frame(fingers: 3, x: 0.3)
        XCTAssertTrue(fixture.handler.state.isMoving)
        gesture.end()
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
        XCTAssertNil(fixture.handler.state.gestureFingerCountMismatchSince)
        XCTAssertFalse(fixture.handler.state.isMoving)
    }

    func testCancelledResizeKeepsAppliedDimensions() throws {
        let fixture = try makeNiriFixture(pid: 9_119)
        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5)
        let during = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        XCTAssertGreaterThan(during, fixture.firstFrame.width)
        gesture.end(.cancelled)
        XCTAssertEqual(try XCTUnwrap(fixture.frames()[fixture.first.token]).width, during)
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertNil(fixture.handler.state.activeInteractionSource)
    }

    func testRestingFingerBelowTheGestureFloorStillEndsAMoveAfterTheFlickerGrace() async throws {
        let fixture = try makeNiriFixture(pid: 9_121)
        let handler = fixture.handler
        let backend = FakeMultitouchBackend()
        backend.enumerations = [FakeMultitouchBackend.enumeration([
            FakeMultitouchBackend.device(pointer: 0xA1, registryId: 101)
        ])]
        let sleeper = ManualMultitouchSleeper()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: sleeper),
            topologyMonitoringEnabled: false
        )
        defer {
            fixture.controller.layoutRefreshController.resetState()
            handler.cleanup()
            await sleeper.resumeAll()
        }
        XCTAssertTrue(handler.installMultitouchSource(source))
        try await sleeper.waitForScheduledSleep(of: source)
        try await sleeper.resumeNext()
        try await sleeper.waitForScheduledSleep(of: source)

        let location = fixture.firstFrame.center
        let startX: Float = 0.2
        let endX = startX + Float(fixture.travelToSecond)
        var time = 100.0
        func emit(fingers: Int, x: Float) {
            time += 0.01
            backend.emitFrame(
                registryId: 101,
                touches: Array(repeating: (x: x, y: Float(0.5)), count: fingers),
                timestamp: time
            )
            source.drainRawFrameMailbox(location: location)
        }

        emit(fingers: 4, x: startX)
        for step in 1 ... 10 {
            emit(fingers: 4, x: startX + (endX - startX) * Float(step) / 10)
        }
        XCTAssertTrue(handler.state.isMoving)

        for _ in 0 ..< 20 {
            emit(fingers: 1, x: endX)
        }
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])

        emit(fingers: 0, x: 0)
    }

    func testMoveOvershootKeepsEdgeWindowAsDropTarget() throws {
        let fixture = try makeNiriFixture(pid: 9_120)
        fixture.second.renderedFrame = CGRect(x: 800, y: 0, width: 800, height: 900)
        fixture.controller.settings.gestures.windowGestureSensitivity = 5
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 1)
        let hoverTarget = try XCTUnwrap(
            fixture.engine.interactiveMove?.currentHoverTarget,
            "Overshoot lost the edge drop target"
        )
        XCTAssertEqual(hoverTarget.token, fixture.second.token)
        XCTAssertEqual(hoverTarget.direction, .right)
        gesture.end()
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    private func makeController() -> WMController {
        let controller = WindowAdmissionTestSupport.controller(prefix: "TrackpadWindowGestureTests")
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let settings = controller.settings
        settings.animationsEnabled = false
        settings.gestures.scrollEnabled = false
        settings.gestures.workspaceSwipeEnabled = false
        settings.gestures.windowMoveEnabled = true
        settings.gestures.windowMoveFingerCount = .four
        settings.gestures.windowResizeEnabled = true
        settings.gestures.windowResizeFingerCount = .three
        settings.gestures.windowGestureSensitivity = 1.0
        return controller
    }

    private func makeMonitor() -> Monitor {
        Monitor(
            id: .init(displayId: 52_001),
            displayId: 52_001,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Trackpad Window Gesture"
        )
    }

    private func makeNiriFixture(pid: pid_t) throws -> NiriFixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        var windows: [NiriWindow] = []
        for windowId in 1 ... 2 {
            let token = WindowToken(pid: pid, windowId: windowId)
            _ = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            windows.append(engine.addWindow(token: token, to: workspaceId, afterSelection: windows.last?.id))
        }
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                windows[0].token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 700
        }
        let partial = NiriFixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId,
            first: windows[0],
            second: windows[1],
            firstFrame: .zero,
            secondFrame: .zero
        )
        let frames = partial.frames()
        let firstFrame = try XCTUnwrap(frames[windows[0].token])
        let secondFrame = try XCTUnwrap(frames[windows[1].token])
        XCTAssertLessThan(firstFrame.maxX, secondFrame.minX)
        XCTAssertNotNil(engine.hitTestTiled(point: firstFrame.center, in: workspaceId))
        XCTAssertNotNil(engine.hitTestTiled(point: secondFrame.center, in: workspaceId))

        return NiriFixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId,
            first: windows[0],
            second: windows[1],
            firstFrame: firstFrame,
            secondFrame: secondFrame
        )
    }

    private func makeDwindleFixture(pid: pid_t) throws -> DwindleFixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .dwindle
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        var tokens: [WindowToken] = []
        for windowId in 1 ... 2 {
            let token = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: WindowToken(pid: pid, windowId: windowId)),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
            tokens.append(token)
        }
        let screen = controller.insetWorkingFrame(for: monitor)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        engine.cancelAnimations(in: workspaceId)
        let firstFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[0], in: workspaceId, at: 0))
        let secondFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[1], in: workspaceId, at: 0))
        XCTAssertNotEqual(firstFrame, secondFrame)
        XCTAssertEqual(controller.settings.workspaces.layoutType(for: "1"), .dwindle)

        return DwindleFixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            screen: screen,
            first: tokens[0],
            second: tokens[1],
            firstFrame: firstFrame,
            secondFrame: secondFrame
        )
    }
}
