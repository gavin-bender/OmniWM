// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func supportsColumnScroll(_ layoutType: LayoutType, in controller: WMController) -> Bool {
        switch layoutType {
        case .niri,
             .defaultLayout:
            controller.niriEngine != nil
        case .dwindle, .tabbed:
            false
        }
    }

    func workspaceSwipeAxis(for workspace: WorkspaceDescriptor, on monitor: Monitor) -> WorkspaceSwipeAxis? {
        guard let controller, let config = trackpadGestureConfig else { return nil }
        let layoutType = controller.settings.workspaces.layoutType(for: workspace.name)
        let columnScrollAxis = supportsColumnScroll(layoutType, in: controller)
            ? gestureColumnScrollAxis(workspaceId: workspace.id, monitor: monitor, supportsColumnScroll: true)
            : nil
        return TrackpadGestureIntent.effectiveWorkspaceSwipeAxis(config, columnScrollAxis: columnScrollAxis)
    }

    func gestureColumnScrollAxis(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        supportsColumnScroll: Bool
    ) -> WorkspaceSwipeAxis {
        guard let engine = controller?.niriEngine, supportsColumnScroll else { return .horizontal }
        return resolvedNiriOrientation(engine: engine, workspaceId: workspaceId, monitor: monitor) == .horizontal
            ? .horizontal
            : .vertical
    }

    func windowGestureTarget(
        at location: CGPoint,
        wsId: WorkspaceDescriptor.ID,
        layoutType: LayoutType
    ) -> WindowToken? {
        guard let controller else { return nil }
        switch layoutType {
        case .niri,
             .defaultLayout:
            return controller.niriEngine?.hitTestTiled(point: location, in: wsId)?.token
        case .tabbed:
            let border = tabWindowBorderId()
            guard let front = tabWindowStackAtPoint(location).first(where: { $0.id != border }) else { return nil }
            if let rail = controller.tabRailManager.dropRail(windowId: front.id, at: location, in: wsId) { return rail.target }
            guard let entry = controller.workspaceManager.entry(forWindowId: front.id), entry.workspaceId == wsId,
                  entry.mode == .tiling, entry.hiddenState == nil, entry.layoutReason == .standard else { return nil }
            return entry.token
        case .dwindle:
            return controller.dwindleEngine?.hitTestFocusableWindow(
                point: location,
                in: wsId,
                at: controller.animationClock.now()
            )
        }
    }

    func beginGestureWindowInteraction(
        _ mode: TrackpadGestureMode,
        lockedContext: MouseInputState.LockedGestureContext
    ) -> Bool {
        guard let controller,
              let token = lockedContext.windowGestureTarget,
              let workspace = controller.workspaceManager.descriptor(for: lockedContext.workspaceId)
        else { return false }
        let location = lockedContext.startLocation
        guard beginWindowInteraction(mode, target: token, workspace: workspace, at: location, source: .trackpadGesture)
        else {
            MouseTrace.record("gesture: \(mode) begin refused for \(token) at \(TraceFormat.point(location))")
            return false
        }
        MouseTrace.record(
            "gesture: \(mode) began on \(token) at \(TraceFormat.point(location))"
                + (mode == .windowResize ? " edges=\(state.currentHoveredEdges)" : "")
        )
        return true
    }

    func beginWindowInteraction(
        _ mode: TrackpadGestureMode,
        target token: WindowToken,
        workspace: WorkspaceDescriptor,
        at location: CGPoint,
        source: MouseInputState.InteractionSource
    ) -> Bool {
        guard let controller else { return false }
        let wsId = workspace.id
        switch (controller.settings.workspaces.layoutType(for: workspace.name), mode) {
        case (.tabbed, .windowMove), (.tabbed, .windowResize):
            guard let snapshot = controller.dwindleEngine?.tileSnapshot(for: token, in: wsId),
                  snapshot.activeToken == token, !snapshot.members[snapshot.activeIndex].isFullscreen,
                  let frame = snapshot.contentFrame else { return false }
            let handle: TabChromeHandle
            if mode == .windowMove {
                handle = .grip
                state.isMoving = true
                state.moveLayout = .tabbed
            } else {
                let left = location.x < frame.midX
                handle = location.y >= frame.midY ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
                state.isResizing = true
                state.resizeLayout = .tabbed
            }
            if source == .touchDisplay, let id = UInt32(exactly: token.windowId) {
                controller.axEventHandler.cancelFrameObservation(windowId: id)
            }
            state.activeInteractionSource = source
            state.tabbedGesture = (token, wsId, TabFrameDrag(start: location, frame: frame, handle: handle), location)
            return true
        case (.dwindle, .windowMove):
            guard let engine = controller.dwindleEngine else { return false }
            return beginDwindleMove(token: token, engine: engine, wsId: wsId, at: location, source: source)
        case (.dwindle, .windowResize):
            guard let engine = controller.dwindleEngine else { return false }
            return beginDwindleResize(
                token: token,
                engine: engine,
                wsId: wsId,
                at: location,
                edgePolicy: .nearestMovable,
                source: source
            )
        case (_, .windowMove):
            guard let engine = controller.niriEngine, let window = engine.findNode(for: token, in: wsId) else {
                return false
            }
            return beginNiriMove(window: window, engine: engine, wsId: wsId, at: location, source: source)
        case (_, .windowResize):
            guard let engine = controller.niriEngine, let window = engine.findNode(for: token, in: wsId) else {
                return false
            }
            return beginNiriResize(window: window, engine: engine, wsId: wsId, at: location, source: source)
        case (_, .overview),
             (_, .columnScroll),
             (_, .workspaceSwitch):
            return false
        }
    }

    var touchMovedTab: WindowToken? {
        guard state.activeInteractionSource == .touchDisplay, let session = state.tabbedGesture,
              session.drag.handle == .grip else { return nil }
        return session.token
    }

    func updateTabbedGesture(at point: CGPoint, released: Bool = false) {
        guard let session = state.tabbedGesture else { return }
        state.tabbedGesture?.point = point
        updateTabbedFrame(session.drag, at: point, token: session.token, workspace: session.workspace, released: released)
        if state.activeInteractionSource == .touchDisplay, session.drag.handle == .grip {
            updateTouchTabDrop(at: point, token: session.token, workspace: session.workspace,
                               frame: session.drag.frame, released: released)
        }
    }

    func gestureWindowLocation(for lockedContext: MouseInputState.LockedGestureContext) -> CGPoint {
        guard let monitor = controller?.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            return lockedContext.startLocation
        }
        return TrackpadGestureIntent.windowGestureLocation(
            start: lockedContext.startLocation,
            startTouch: CGPoint(x: state.gestureStartX, y: state.gestureStartY),
            currentTouch: CGPoint(x: state.gestureLastAverageX, y: state.gestureLastAverageY),
            monitorFrame: monitor.frame,
            sensitivity: CGFloat(controller?.settings.gestures.windowGestureSensitivity ?? 1.0),
            clampToMonitor: state.activeGestureMode == .windowMove
        )
    }

    func commitGestureWindowInteraction(lockedContext: MouseInputState.LockedGestureContext) {
        guard state.gestureOwnsWindowInteraction else { return }
        let location = gestureWindowLocation(for: lockedContext)
        MouseTrace.record(
            "gesture: \(state.activeGestureMode.map { "\($0)" } ?? "") completed at \(TraceFormat.point(location))"
        )
        if state.isMoving {
            completeActiveMove(at: location)
        } else if state.isResizing {
            completeActiveResize()
        }
    }

    func cancelGestureWindowInteraction() {
        guard state.gestureOwnsWindowInteraction else { return }
        MouseTrace.record("gesture: \(state.activeGestureMode.map { "\($0)" } ?? "") cancelled")
        cancelActiveMouseInteraction()
    }
}
