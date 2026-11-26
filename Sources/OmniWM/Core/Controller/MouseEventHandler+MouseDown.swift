// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func handleMouseDownFromTap(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        windowIdUnderPointer: Int?,
        windowServerFramesAtMouseDown: [WindowToken: CGRect]?
    ) -> Bool {
        guard let controller else { return false }
        guard canHandleManagedMouseInteraction(controller: controller) else { return false }

        if shouldBlockOwnWindowInput(at: location) {
            return false
        }
        guard !state.isMoving, !state.isResizing else { return false }

        guard let wsId = workspaceIdForPointer(at: location) ?? controller.activeWorkspace()?.id else {
            return false
        }

        if controller.workspaceManager.activeLayoutKind(for: wsId) == .tabbed {
            if button == .left, modifiers.isDisjoint(with: Self.relevantModifierFlags),
               let (token, visibleFrame) = frontTiledWindow(at: location, in: wsId) {
                let frame = windowServerFramesAtMouseDown?[token].map(ScreenCoordinateSpace.toAppKit(rect:)) ?? visibleFrame
                guard Self.tabDropTitleRegion(in: frame).contains(location) else { return false }
                state.tabbedTitleDrag = (token, location, frame)
                controller.axEventHandler.noteMouseFocusIntent(token: token)
            }
            return false
        }

        if button == .left, modifiers.isDisjoint(with: Self.relevantModifierFlags) {
            recordPointerFocusIntent(
                at: location,
                workspaceId: wsId,
                windowIdUnderPointer: windowIdUnderPointer,
                windowServerFramesAtMouseDown: windowServerFramesAtMouseDown
            )
        }

        let layoutType = controller.workspaceManager.descriptor(for: wsId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) }
        if layoutType?.usesGroupedTiles == true {
            return handleDwindleMouseDown(at: location, modifiers: modifiers, button: button, wsId: wsId)
        }

        guard let engine = controller.niriEngine else { return false }

        if button == .left,
           Self.mouseMoveModifiersMatch(
               modifiers,
               required: controller.settings.gestures.mouseMoveModifierKey.cgEventFlags
           )
        {
            beginNiriMouseMove(at: location, engine: engine, workspaceId: wsId, button: button)
            return false
        }

        guard button == .right,
              Self.modifierFlagsMatch(
                  modifiers,
                  required: controller.settings.gestures.mouseResizeModifierKey.cgEventFlag
              )
        else { return false }

        return beginNiriMouseResize(at: location, engine: engine, workspaceId: wsId, button: button)
    }

    private func beginNiriMouseMove(
        at location: CGPoint, engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID, button: MouseButton
    ) {
        guard let window = engine.hitTestTiled(point: location, in: workspaceId) else { return }
        _ = beginNiriMove(window: window, engine: engine, wsId: workspaceId, at: location, source: .mouse(button))
    }

    private func beginNiriMouseResize(
        at location: CGPoint, engine: NiriLayoutEngine, workspaceId wsId: WorkspaceDescriptor.ID, button: MouseButton
    ) -> Bool {
        guard let controller else { return false }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let window = engine.hitTestTiled(point: location, in: wsId)
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            )
            .flatMap { engine.findNode(for: $0, in: wsId) }
        guard let window else { return false }
        return beginNiriResize(window: window, engine: engine, wsId: wsId, at: location, source: .mouse(button))
    }

    private func recordPointerFocusIntent(
        at location: CGPoint,
        workspaceId wsId: WorkspaceDescriptor.ID,
        windowIdUnderPointer: Int?,
        windowServerFramesAtMouseDown: [WindowToken: CGRect]?
    ) {
        guard let controller else { return }
        state.awaitsNativeTitleBarDragTarget = windowIdUnderPointer == nil
        state.nativeTitleBarDragFallbackReleased = false
        let exactToken = nativeTitleBarDragCandidate(windowIdUnderPointer: windowIdUnderPointer)
        let focusIntentToken = exactToken ?? (windowIdUnderPointer == nil
            ? geometricFocusIntentCandidate(at: location, workspaceId: wsId)
            : nil)
        captureNativeCrossDisplayMove(for: focusIntentToken)
        captureNativeResizeStart(
            for: focusIntentToken,
            at: location,
            windowServerFramesAtMouseDown: windowServerFramesAtMouseDown
        )
        if let token = focusIntentToken {
            controller.axEventHandler.noteMouseFocusIntent(token: token)
        } else {
            controller.axEventHandler.noteUnmanagedPointerClick()
        }
        state.nativeTitleBarDragFallbackToken = exactToken == nil ? focusIntentToken : nil
        if let exactToken {
            state.awaitsNativeTitleBarDragTarget = false
            let token = exactToken
            state.nativeTitleBarDrag = .init(token: token)
        }
    }

    private func handleDwindleMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        wsId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller, let engine = controller.dwindleEngine else { return false }
        if button == .left {
            guard Self.mouseMoveModifiersMatch(
                      modifiers,
                      required: controller.settings.gestures.mouseMoveModifierKey.cgEventFlags
                  ),
                  let token = engine.hitTestFocusableWindow(
                      point: location,
                      in: wsId,
                      at: controller.animationClock.now()
                  )
            else { return false }
            _ = beginDwindleMove(
                token: token, engine: engine, wsId: wsId, at: location,
                source: .mouse(button)
            )
            return false
        }
        guard button == .right,
              Self.modifierFlagsMatch(
                  modifiers,
                  required: controller.settings.gestures.mouseResizeModifierKey.cgEventFlag
              )
        else { return false }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let token = engine.hitTestFocusableWindow(point: location, in: wsId, at: controller.animationClock.now())
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            )
        guard let token else { return false }
        return beginDwindleResize(token: token, engine: engine, wsId: wsId, at: location, source: .mouse(button))
    }

    func focusedBorderResizeToken(
        at location: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        scale: CGFloat,
        appliedBorder: DesiredBorderSurface?
    ) -> WindowToken? {
        guard let controller,
              let appliedBorder,
              appliedBorder.token == controller.workspaceManager.borderFocusToken,
              let entry = controller.workspaceManager.entry(for: appliedBorder.token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling
        else {
            return nil
        }
        let geometry = appliedBorder.config.resolvedGeometry(for: appliedBorder.frame, scale: scale)
        guard geometry.width > 0,
              geometry.targetFrame.insetBy(dx: -geometry.width, dy: -geometry.width).contains(location),
              !geometry.targetFrame.contains(location)
        else {
            return nil
        }
        return appliedBorder.token
    }

    func resizeEdges(for location: CGPoint, in frame: CGRect) -> ResizeEdge {
        var edges: ResizeEdge = location.x < frame.midX ? [.left] : [.right]
        edges.insert(location.y < frame.midY ? .bottom : .top)
        return edges
    }

    func shouldAcceptInteractionButton(_ button: MouseButton) -> Bool {
        state.activeInteractionSource == nil || state.activeInteractionSource == .mouse(button)
    }

    func isCapturedInteraction(_ button: MouseButton) -> Bool {
        state.capturedInteractionButton == button
    }
}

extension MouseEventHandler {
    static func tabWindowStack(at point: CGPoint) -> [(id: Int, frame: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return (list as? [[String: Any]] ?? []).compactMap { item in
            guard item[kCGWindowLayer as String] as? Int == 0, let id = item[kCGWindowNumber as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let frame = ScreenCoordinateSpace.toAppKit(rect: rect)
            return frame.contains(point) ? (id, frame) : nil
        }
    }

    func tabWindowBorderId() -> Int? {
        guard let controller, let focus = controller.workspaceManager.borderFocusToken,
              let id = UInt32(exactly: focus.windowId) else { return nil }
        return controller.surfaceReconciler.ringWindowId(orderedAbove: id).map(Int.init)
    }

    func frontTiledWindow(at point: CGPoint, in workspaceId: WorkspaceDescriptor.ID) -> (WindowToken, CGRect)? {
        let border = tabWindowBorderId()
        guard let controller, let window = tabWindowStackAtPoint(point).first(where: { $0.id != border }),
              let entry = controller.workspaceManager.entry(forWindowId: window.id), entry.workspaceId == workspaceId,
              entry.hiddenState == nil, entry.mode == .tiling, entry.layoutReason == .standard else { return nil }
        return (entry.token, window.frame)
    }
}
