// SPDX-License-Identifier: GPL-2.0-only

import AppKit

extension MouseEventHandler {
    struct DirectTouchDrag {
        let contact: MultitouchContactSession
        let token: WindowToken
        let workspace: WorkspaceDescriptor.ID
        let layout: ActiveLayoutKind
        let start: CGPoint
        var lastLocation: CGPoint
        let initialFrame: CGRect
        let edges: ResizeEdge
        let mode: TrackpadGestureMode
    }

    func cancelDirectTouchDrag() {
        if directTouchDrag?.layout == .tabbed {
            state.tabbedTitleDrag = nil
            tabDropFeedback.hide()
        }
        directTouchDrag = nil
        if state.activeInteractionSource == .touchDisplay { cancelActiveMouseInteraction() }
    }

    func handleDirectTouchDrag(_ snapshot: GestureEventSnapshot) -> Bool {
        guard let contact = snapshot.contactSession, contact.isTouchScreen else { return false }
        let phase = NSEvent.Phase(rawValue: snapshot.phaseRawValue)
        if let drag = directTouchDrag, drag.contact != contact { return false }
        if phase == .cancelled, directTouchDrag != nil {
            cancelDirectTouchDrag()
            return true
        }
        guard let point = snapshot.directDisplayLocation ?? (phase == .ended ? directTouchDrag?.lastLocation : nil) else { return false }
        guard phase == .began || directTouchDrag != nil else { return false }
        let count = Self.activeTouchCount(in: snapshot.touches)
        guard let controller, controller.isEnabled, !controller.isOverviewOpen(),
              let wsId = workspaceIdForPointer(at: point),
              controller.workspaceManager.descriptor(for: wsId) != nil else {
            cancelDirectTouchDrag()
            return false
        }
        let layout = controller.workspaceManager.activeLayoutKind(for: wsId)
        guard layout == .niri || layout == .tabbed else {
            cancelDirectTouchDrag()
            return false
        }

        if phase == .began {
            if directTouchDrag != nil { cancelDirectTouchDrag() }
            guard count == 1, state.gesturePhase == .idle,
                  !shouldBlockOwnWindowGestureInput(at: point) else { return false }
            let target = frontTiledWindow(at: point, in: wsId)
                ?? (layout == .niri ? nearbyNiriHandle(at: point, in: wsId) : nil)
            guard let (token, frame) = target else { return false }
            if layout == .niri {
                guard let engine = controller.niriEngine, let window = engine.findNode(for: token, in: wsId),
                      !window.isFullscreen, engine.isProjectedFocusableWindow(window, in: wsId) else { return false }
            }
            let edges = ResizeConfiguration.handleEdges(at: point, in: frame, cornerTolerance: 28, edgeTolerance: 9)
            let isResize = layout == .niri ? !edges.isEmpty : ResizeConfiguration.isCorner(point, of: frame, tolerance: 20)
            // Keep taps and content drags in the app. Claim a handle only after the finger moves.
            let inTitle = Self.tabDropTitleRegion(in: frame).contains(point)
            guard isResize || (inTitle
                && Self.isTitleBarBackground(at: point, pid: token.pid)) else { return false }
            // A touchscreen press can also arrive as a primary mouse down before the raw contact.
            if state.activeInteractionSource != nil {
                guard layout == .niri, isResize, state.activeInteractionSource == .mouse(.left),
                      let resize = controller.niriEngine?.interactiveResize,
                      resize.workspaceId == wsId, resize.windowId == controller.niriEngine?.findNode(for: token, in: wsId)?.id,
                      hypot(point.x - resize.startMouseLocation.x, point.y - resize.startMouseLocation.y) <= 28
                else { return false }
                state.activeInteractionSource = .touchDisplay
                state.capturedInteractionButton = nil
            }
            directTouchDrag = DirectTouchDrag(
                contact: contact, token: token, workspace: wsId, layout: layout, start: point, lastLocation: point, initialFrame: frame, edges: edges,
                mode: isResize ? .windowResize : .windowMove
            )
            return true
        }
        guard let drag = directTouchDrag, drag.contact == contact else { return false }
        directTouchDrag?.lastLocation = point
        guard drag.workspace == wsId, drag.layout == layout, phase != .cancelled, count <= 1,
              let entry = controller.workspaceManager.entry(for: drag.token), entry.mode == .tiling, entry.hiddenState == nil
        else {
            cancelDirectTouchDrag()
            return false
        }
        if layout == .tabbed {
            // macOS moves and sizes the app window. Observe only the potential tab drop.
            if drag.mode == .windowMove {
                state.tabbedTitleDrag = (drag.token, drag.start, drag.initialFrame)
                updateTabbedTitleDrag(at: point, released: phase == .ended)
            }
            if phase == .ended { directTouchDrag = nil }
            return true
        }
        if phase == .ended {
            defer { directTouchDrag = nil }
            guard state.activeInteractionSource == .touchDisplay else { return true }
            if state.isMoving {
                completeActiveMove(at: point)
            } else {
                updateManagedResize(at: point)
                completeActiveResize()
            }
            return true
        }
        if state.activeInteractionSource != .touchDisplay {
            guard hypot(point.x - drag.start.x, point.y - drag.start.y) >= (controller.niriEngine?.moveConfiguration.dragThreshold ?? 8)
            else { return true }
            guard state.activeInteractionSource == nil else {
                directTouchDrag = nil
                return false
            }
            clearNativeTitleBarDrag()
            state.tabbedTitleDrag = nil
            guard let engine = controller.niriEngine, let window = engine.findNode(for: drag.token, in: wsId) else {
                directTouchDrag = nil
                return false
            }
            let started: Bool
            if drag.mode == .windowResize {
                started = beginNiriResize(window: window, engine: engine, wsId: wsId, at: drag.start,
                                          source: .touchDisplay, handleEdges: drag.edges)
            } else {
                started = beginNiriMove(window: window, engine: engine, wsId: wsId, at: drag.start, source: .touchDisplay)
            }
            guard started else {
                directTouchDrag = nil
                return false
            }
        }
        if state.isResizing {
            updateManagedResize(at: point)
        } else {
            updateActiveMove(at: point)
        }
        return true
    }

    func nearbyNiriHandle(at point: CGPoint, in workspace: WorkspaceDescriptor.ID, tolerance: CGFloat = 9) -> (WindowToken, CGRect)? {
        guard let engine = controller?.niriEngine,
              tabWindowStackAtPoint(point).allSatisfy({ $0.id == tabWindowBorderId() }) else { return nil }
        var closest: (token: WindowToken, point: CGPoint, distance: CGFloat)?
        for column in engine.columns(in: workspace) {
            for window in column.windowNodes where engine.isProjectedFocusableWindow(window, in: workspace) {
                guard let frame = window.renderedFrame ?? window.frame,
                      !ResizeConfiguration.handleEdges(at: point, in: frame, cornerTolerance: tolerance, edgeTolerance: tolerance).isEmpty else { continue }
                let inside = CGPoint(x: max(frame.minX + 1, min(point.x, frame.maxX - 1)),
                                     y: max(frame.minY + 1, min(point.y, frame.maxY - 1)))
                let distance = hypot(point.x - inside.x, point.y - inside.y)
                if let closest, closest.distance <= distance { continue }
                closest = (window.token, inside, distance)
            }
        }
        guard let closest, let front = frontTiledWindow(at: closest.point, in: workspace),
              front.0 == closest.token, !ResizeConfiguration.handleEdges(at: point, in: front.1, cornerTolerance: tolerance, edgeTolerance: tolerance).isEmpty else { return nil }
        return front
    }

    private static func isTitleBarBackground(at point: CGPoint, pid: pid_t) -> Bool {
        let location = ScreenCoordinateSpace.toWindowServer(point: point)
        var element: AXUIElement?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard AXUIElementCopyElementAtPosition(app, Float(location.x), Float(location.y), &element) == .success,
              let element else { return true }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return true }
        return [kAXWindowRole, kAXToolbarRole, kAXGroupRole, kAXStaticTextRole, kAXUnknownRole].contains(role)
    }
}
