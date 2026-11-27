// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func nativeTitleBarDragCandidate(
        windowIdUnderPointer: Int?
    ) -> WindowToken? {
        guard let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling, entry.axRef != nil
        else { return nil }
        return entry.token
    }

    func geometricFocusIntentCandidate(
        at location: CGPoint,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let controller else { return nil }
        let layoutType = controller.workspaceManager.descriptor(for: workspaceId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) }
        let token: WindowToken?
        if layoutType?.usesGroupedTiles == true {
            token = controller.dwindleEngine?.hitTestFocusableWindow(
                point: location,
                in: workspaceId,
                at: controller.animationClock.now()
            )
        } else {
            token = controller.niriEngine?.hitTestFocusableWindow(
                point: location,
                in: workspaceId
            )?.token
        }
        guard let token,
              controller.workspaceManager.entry(for: token)?.mode == .tiling
        else { return nil }
        return token
    }

    func captureNativeCrossDisplayMove(
        for token: WindowToken?, pressLocation: CGPoint? = nil, windowServerFrames: [WindowToken: CGRect]? = nil
    ) {
        guard let controller,
              let token,
              let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .tiling,
              controller.settings.gestures.adoptNativeMoveAcrossDisplays
                  || controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              !controller.axManager.isAwaitingFrameWrite(token.windowId),
              let applied = controller.axManager.lastAppliedFrame(for: token.windowId)
        else {
            state.nativeCrossDisplayMove = nil
            return
        }
        // A constrained app can accept a different size from the layout request.
        // A move preserves the physical size it had when the user grabbed its title bar.
        let captured = windowServerFrames?[token].map(ScreenCoordinateSpace.toAppKit(rect:))
        let titlePress = pressLocation.map(Self.tabDropTitleRegion(in: applied).contains) ?? false
        let frame = captured ?? (titlePress ? fastNativeWindowFrame(for: entry) : nil) ?? applied
        state.nativeCrossDisplayMove = .init(token: token, workspaceId: entry.workspaceId, startFrame: frame)
    }

    func confirmNativeMouseDrag(at location: CGPoint, button: MouseButton) {
        guard button == .left else { return }
        state.nativeCrossDisplayMove?.wasDragged = true
        if let start = state.nativeResizeStart, !start.wasDragged,
           abs(location.x - start.location.x) <= FrameTolerance.frameWrite,
           abs(location.y - start.location.y) <= FrameTolerance.frameWrite
        {
            return
        }
        state.nativeResizeStart?.wasDragged = true
        let deferredToken = state.nativeResizeStart.flatMap { $0.hasDeferredFrameChange ? $0.token : nil }
        beginNativeTitleBarDragIfNeeded(button: button)
        handleDeferredNativeTitleBarFrameIfNeeded(for: deferredToken)
    }

    private func handleDeferredNativeTitleBarFrameIfNeeded(for token: WindowToken? = nil) {
        let deferredToken = token ?? state.nativeResizeStart.flatMap { $0.hasDeferredFrameChange ? $0.token : nil }
        guard let deferredToken,
              let entry = controller?.workspaceManager.entry(for: deferredToken)
        else { return }
        if let drag = state.nativeTitleBarDrag {
            guard drag.token == deferredToken, drag.phase == .dragging else { return }
        } else {
            guard state.awaitsNativeTitleBarDragTarget,
                  state.nativeTitleBarDragFallbackToken == deferredToken
            else { return }
        }
        _ = handleNativeTitleBarDragFrameChanged(for: entry)
    }

    func correctDeferredNativeResizeFrameIfNeeded(excluding token: WindowToken? = nil) {
        guard let start = state.nativeResizeStart,
              start.hasDeferredFrameChange,
              start.token != token
        else { return }
        state.nativeResizeStart = nil
        guard let controller,
              controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: start.token),
              entry.mode == .tiling,
              entry.hiddenState == nil
        else { return }
        requestNativeTitleBarDragCorrection(for: entry)
    }

    func rejectNativeTitleBarDragTarget() {
        let fallbackToken = state.nativeTitleBarDragFallbackToken
        let releasedToken = state.nativeTitleBarDrag == nil && state.nativeTitleBarDragFallbackReleased
            ? fallbackToken : nil
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        state.nativeCrossDisplayMove = nil
        guard let releasedToken, let controller, controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: releasedToken),
              entry.mode == .tiling, entry.hiddenState == nil
        else {
            correctDeferredNativeResizeFrameIfNeeded()
            state.nativeResizeStart = nil
            if let fallbackToken { recheckRetainedNativeResizeCorrection(for: fallbackToken) }
            return
        }
        state.nativeResizeStart = nil
        state.nativeTitleBarDrag = .init(token: releasedToken, phase: .awaitingFrameChange, targetWasRejected: true)
        _ = handleNativeTitleBarDragFrameChanged(for: entry)
    }

    var nativeTitleBarDragBlocksOverview: Bool {
        guard let drag = state.nativeTitleBarDrag else { return false }
        guard drag.targetWasRejected, drag.phase == .awaitingFrameChange,
              let controller,
              controller.axManager.pendingFrameWrite(for: drag.token.windowId) == nil,
              let entry = controller.workspaceManager.entry(for: drag.token),
              let observedFrame = fastNativeWindowFrame(for: entry),
              nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
        else { return true }
        return false
    }

    func retainNativeResizeCorrection(for token: WindowToken) {
        guard let controller, controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .tiling, entry.hiddenState == nil, entry.axRef != nil
        else { return }
        if state.nativeResizeCorrectionsByWindowId[token.windowId]?.token != token {
            state.nativeResizeCorrectionsByWindowId[token.windowId] = .init(token: token)
        }
    }

    func handleRetainedNativeResizeCorrection(for entry: WindowState) -> Bool {
        guard var correction = state.nativeResizeCorrectionsByWindowId[entry.windowId] else { return false }
        guard correction.token == entry.token, let controller, controller.hasStartedServices,
              entry.mode == .tiling, entry.hiddenState == nil, entry.axRef != nil
        else {
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = nil
            return false
        }
        if controller.axManager.pendingFrameWrite(for: entry.windowId) != nil {
            correction.needsFrameWriteRecheck = true
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
            return true
        }
        correction.needsFrameWriteRecheck = false
        if let observedFrame = fastNativeWindowFrame(for: entry) {
            correction.issuedUnreadableCorrection = false
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
            if nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry) { return true }
        } else {
            guard !correction.issuedUnreadableCorrection else {
                state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
                controller.axManager.invalidateAppliedFrame(for: entry.windowId)
                return true
            }
            correction.issuedUnreadableCorrection = true
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
        }
        requestNativeTitleBarDragCorrection(for: entry)
        return true
    }

    func beginNativeTitleBarDragIfNeeded(button: MouseButton) {
        guard button == .left,
              var drag = state.nativeTitleBarDrag,
              drag.phase == .armed,
              let controller,
              controller.workspaceManager.entry(for: drag.token)?.mode == .tiling
        else { return }
        state.nativeResizeCorrectionsByWindowId[drag.token.windowId] = nil
        let hadUnsettledFrameWrite = controller.axManager.isAwaitingFrameWrite(drag.token.windowId)
            || controller.axManager.hasInFlightFrameWrite(for: drag.token)
        let startFrame = state.nativeResizeStart.flatMap { $0.token == drag.token ? $0.frame : nil }
        let pendingFrameChangesSize = startFrame.map {
            controller.axManager.hasPendingFrameSizeChange(for: drag.token.windowId, comparedTo: $0.size)
        } ?? true
        state.nativeResizeStart = nil
        drag.phase = .dragging
        drag.adoptionStartFrame = hadUnsettledFrameWrite ? nil : startFrame
        state.nativeTitleBarDrag = drag
        controller.axManager.beginNativeTitleBarDrag(for: drag.token)

        guard hadUnsettledFrameWrite,
              controller.settings.gestures.adoptNativeResize,
              !pendingFrameChangesSize,
              let startFrame,
              let entry = controller.workspaceManager.entry(for: drag.token),
              !controller.axManager.hasInFlightFrameWrite(for: drag.token),
              !controller.axManager.isAwaitingFrameWrite(entry.windowId),
              controller.axManager.lastAppliedFrame(for: entry.windowId)?.approximatelyEqual(
                  to: startFrame, tolerance: FrameTolerance.frameWrite
              ) == true,
              var currentDrag = state.nativeTitleBarDrag,
              currentDrag.token == drag.token,
              currentDrag.phase == .dragging
        else { return }
        currentDrag.adoptionStartFrame = startFrame
        state.nativeTitleBarDrag = currentDrag
    }

    private func prepareNativeTitleBarDragForSettlement(button: MouseButton) -> MouseInputState.NativeTitleBarDrag? {
        if state.moveTap != nil, state.nativeTitleBarDrag == nil, state.nativeResizeStart?.wasDragged != true {
            correctDeferredNativeResizeFrameIfNeeded()
        }
        markNativeTitleBarDragFallbackReleased(button: button)
        if state.nativeTitleBarDrag == nil,
           state.nativeTitleBarDragFallbackReleased
        {
            handleDeferredNativeTitleBarFrameIfNeeded()
            return nil
        }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        return state.nativeTitleBarDrag
    }

    func finishNativeTitleBarDragIfNeeded(button: MouseButton) {
        guard button == .left, var drag = prepareNativeTitleBarDragForSettlement(button: button) else { return }
        switch drag.phase {
        case .armed,
             .dragging:
            break
        case .awaitingFrameChange,
             .awaitingFrameWrite,
             .awaitingCorrection:
            return
        }
        guard let controller else {
            discardNativeTitleBarDragState()
            return
        }
        let excludedFrameWrite = controller.axManager.endNativeTitleBarDrag(for: drag.token)
        guard drag.phase == .dragging,
              controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }

        drag.pendingExcludedCorrection = excludedFrameWrite
        state.nativeTitleBarDrag = drag
        let observedFrame = terminalNativeWindowFrame(for: entry)
        let lastAppliedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId)
        let observedDisplacement = Self.nativeTitleBarWasDisplaced(
            observedFrame: observedFrame, lastAppliedFrame: lastAppliedFrame,
            receivedFrameChange: drag.receivedFrameChange
        )
        settleReleasedNativeTitleBarDrag(
            drag,
            entry: entry,
            observedFrame: observedFrame,
            needsCorrection: excludedFrameWrite || observedDisplacement
        )
    }

    private func settleReleasedNativeTitleBarDrag(
        _ drag: MouseInputState.NativeTitleBarDrag,
        entry: WindowState,
        observedFrame: CGRect?,
        needsCorrection: Bool
    ) {
        var drag = drag
        if settleNativeMoveIfNeeded(entry, observedFrame: observedFrame) { return }
        guard needsCorrection || drag.dwindleResizeWorkspaceId != nil else {
            if drag.receivedFrameChange {
                state.nativeTitleBarDrag = nil
            } else {
                drag.phase = .awaitingFrameChange
                state.nativeTitleBarDrag = drag
            }
            return
        }

        if adoptNativeResizeIfEligible(&drag, entry: entry, observedFrame: observedFrame) {
            state.nativeTitleBarDrag = drag
            return
        }
        drag.phase = .awaitingCorrection
        state.nativeTitleBarDrag = drag
        requestNativeTitleBarDragCorrection(for: entry)
    }

    func settleNativeMoveIfNeeded(_ entry: WindowState, observedFrame: CGRect?) -> Bool {
        if settleNativeNiriStripDrop(entry, observedFrame: observedFrame) { return true }
        guard let controller,
              controller.hasStartedServices,
              controller.settings.gestures.adoptNativeMoveAcrossDisplays,
              let move = state.nativeCrossDisplayMove,
              move.wasDragged,
              let point = move.releaseLocation,
              move.token == entry.token,
              move.workspaceId == entry.workspaceId,
              entry.mode == .tiling,
              state.nativeTitleBarDrag?.dwindleResizeWorkspaceId == nil,
              case let .crossDisplay(drop) = classifyMoveLocation(
                  point, sourceToken: move.token, sourceWorkspaceId: move.workspaceId
              )
        else {
            state.nativeCrossDisplayMove = nil
            return false
        }
        if observedFrame == nil || observedFrame?.approximatelyEqual(
            to: move.startFrame, tolerance: FrameTolerance.screenMatch
        ) == true {
            var drag = state.nativeTitleBarDrag ?? .init(token: entry.token)
            drag.phase = .awaitingFrameChange
            state.nativeTitleBarDrag = drag
            return true
        }
        guard let observedFrame,
              abs(observedFrame.width - move.startFrame.width) <= FrameTolerance.screenMatch,
              abs(observedFrame.height - move.startFrame.height) <= FrameTolerance.screenMatch,
              !nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry),
              let plan = controller.crossDisplayDropPlan(for: drop)
        else {
            state.nativeCrossDisplayMove = nil
            return false
        }
        discardNativeTitleBarDragState()
        controller.axManager.cancelPendingFrameJobs(
            [(pid: entry.pid, windowId: entry.windowId)], reason: "native-cross-display-drop"
        )
        controller.performCrossDisplayDrop(plan)
        return true
    }

    private func settleNativeNiriStripDrop(_ entry: WindowState, observedFrame: CGRect?) -> Bool {
        guard let controller, controller.hasStartedServices,
              let move = state.nativeCrossDisplayMove, move.wasDragged, move.token == entry.token,
              let point = move.releaseLocation, move.workspaceId == entry.workspaceId,
              entry.mode == .tiling, entry.hiddenState == nil, entry.layoutReason == .standard,
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId), monitor.frame.contains(point),
              let engine = controller.niriEngine, let window = engine.findNode(for: entry.token, in: entry.workspaceId),
              !window.isFullscreen,
              let target = engine.hitTestMoveTarget(
                  point: point, excludingWindowId: window.id, allowsInsertion: true, in: entry.workspaceId
              )
        else { return false }

        guard let observedFrame,
              !observedFrame.approximatelyEqual(to: move.startFrame, tolerance: FrameTolerance.screenMatch)
        else {
            var drag = state.nativeTitleBarDrag ?? .init(token: entry.token)
            drag.phase = .awaitingFrameChange
            state.nativeTitleBarDrag = drag
            return true
        }
        guard abs(observedFrame.width - move.startFrame.width) <= FrameTolerance.screenMatch,
              abs(observedFrame.height - move.startFrame.height) <= FrameTolerance.screenMatch,
              !nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
        else { return false }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let context = NiriInteractionContext(
            workspaceId: entry.workspaceId, motion: controller.motionPolicy.snapshot(),
            workingFrame: geometry.workingFrame, gaps: geometry.innerGap,
            orientation: resolvedNiriOrientation(engine: engine, workspaceId: entry.workspaceId, monitor: monitor)
        )
        var changed = false
        controller.workspaceManager.withNiriViewportState(for: entry.workspaceId) { state in
            changed = engine.commitWindowDrop(window.id, onto: target, context: context, state: &state)
        }
        guard changed else { return false }
        discardNativeTitleBarDragState()
        controller.axManager.forceApplyNextFrame(for: entry.windowId)
        controller.workspaceManager.recordLayoutOperation(
            .interactiveMoveEnded(token: entry.token), in: entry.workspaceId, source: .mouse
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        return true
    }

    private static func nativeTitleBarWasDisplaced(
        observedFrame: CGRect?, lastAppliedFrame: CGRect?, receivedFrameChange: Bool
    ) -> Bool {
        if let observedFrame, let lastAppliedFrame {
            return !observedFrame.approximatelyEqual(
                to: lastAppliedFrame,
                tolerance: FrameTolerance.frameWrite
            )
        } else if observedFrame != nil {
            return true
        } else {
            return receivedFrameChange
        }
    }

    func retireNativeTitleBarDragAtInputBoundary() {
        guard let drag = state.nativeTitleBarDrag else {
            discardNativeTitleBarDragState()
            return
        }
        guard drag.phase != .armed,
              let controller,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        if drag.phase == .awaitingFrameChange,
           !drag.pendingExcludedCorrection,
           controller.axManager.pendingFrameWrite(for: entry.windowId) == nil,
           let lastAppliedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId),
           let axRef = entry.axRef,
           let observedFrame = nativeWindowFrameProvider(axRef),
           observedFrame.approximatelyEqual(
               to: lastAppliedFrame,
               tolerance: FrameTolerance.frameWrite
           )
        {
            discardNativeTitleBarDragState()
            return
        }
        let priorTerminalFailureRequestId = drag.terminalFailureRetryRequestId
        var correctionScheduledDuringCancellation = false
        if controller.axManager.pendingFrameWrite(for: entry.windowId) != nil {
            controller.axManager.cancelPendingFrameJobs(
                [(pid: entry.pid, windowId: entry.windowId)],
                reason: "native-drag-end"
            )
            if let currentDrag = state.nativeTitleBarDrag,
               currentDrag.token == drag.token,
               currentDrag.terminalFailureRetryRequestId != nil,
               currentDrag.terminalFailureRetryRequestId != priorTerminalFailureRequestId
            {
                correctionScheduledDuringCancellation = true
            }
        }
        discardNativeTitleBarDragState()
        if !correctionScheduledDuringCancellation {
            controller.axManager.invalidateAppliedFrame(for: entry.windowId)
            requestNativeTitleBarDragCorrection(for: entry)
        }
    }

    func discardNativeTitleBarDragState() {
        correctDeferredNativeResizeFrameIfNeeded()
        state.nativeResizeStart = nil
        state.nativeCrossDisplayMove = nil
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragPressTimestamp = nil
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        if var drag = state.nativeTitleBarDrag {
            finishNativeDwindleResize(&drag)
            _ = controller?.axManager.endNativeTitleBarDrag(for: drag.token)
        }
        state.nativeTitleBarDrag = nil
    }

    func clearNativeTitleBarDrag() {
        guard let drag = state.nativeTitleBarDrag else {
            discardNativeTitleBarDragState()
            return
        }
        discardNativeTitleBarDragState()
        if drag.phase != .armed || drag.receivedFrameChange,
           let controller,
           controller.workspaceManager.entry(for: drag.token)?.mode == .tiling
        {
            controller.axManager.invalidateAppliedFrame(for: drag.token.windowId)
            controller.axManager.forceApplyNextFrame(for: drag.token.windowId)
        }
    }

    func tracksNativeTitleBarDrag(windowId: Int) -> Bool {
        state.nativeTitleBarDrag?.token.windowId == windowId
            || state.nativeTitleBarDragFallbackToken?.windowId == windowId
            || state.nativeResizeCorrectionsByWindowId[windowId] != nil
    }

    func discardNativeTitleBarDrag(for token: WindowToken) {
        if state.nativeResizeCorrectionsByWindowId[token.windowId]?.token == token {
            state.nativeResizeCorrectionsByWindowId[token.windowId] = nil
        }
        guard state.nativeTitleBarDrag?.token == token
            || state.nativeTitleBarDragFallbackToken == token
            || state.nativeCrossDisplayMove?.token == token
        else { return }
        discardNativeTitleBarDragState()
    }

    func requestNativeTitleBarDragCorrection(for entry: WindowState) {
        guard let controller else { return }
        controller.axManager.forceApplyNextFrame(for: entry.windowId)
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    func markNativeTitleBarDragFallbackReleased(button: MouseButton, at location: CGPoint? = nil) {
        if button == .left, let location {
            state.nativeCrossDisplayMove?.releaseLocation = location
        }
        guard button == .left,
              state.nativeTitleBarDrag == nil,
              state.awaitsNativeTitleBarDragTarget,
              state.nativeTitleBarDragFallbackToken != nil,
              state.moveTap == nil || state.nativeResizeStart?.wasDragged == true
        else { return }
        state.nativeTitleBarDragFallbackReleased = true
    }
}
