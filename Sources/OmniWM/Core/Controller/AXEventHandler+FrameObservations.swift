// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    struct FrameObservation {
        let generation: UInt64
        let hiddenState: HiddenState?
        let task: Task<Void, Never>
        var needsRequery = false
    }

    struct FrameObservations {
        var query: @MainActor (UInt32) async throws -> WindowServerInfo? = {
            try await SkyLight.shared.queryWindowInfoDeferred(windowIds: [$0])?[$0]
        }

        var nativeDragQuery: @MainActor (UInt32) -> WindowServerInfo? = {
            SkyLight.shared.queryWindowInfoOffMainConnection($0)
        }

        var byWindowId: [UInt32: FrameObservation] = [:]
        var tabBoundarySettlements: [UInt32: Task<Void, Never>] = [:]
        var nextGeneration: UInt64 = 1
    }

    func handleFrameChanged(windowId: UInt32) {
        guard let controller, !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        if controller.layoutRefreshController.workspaceSwipe.movingLiveWindow(windowId) {
            cancelFrameObservation(windowId: windowId)
            return
        }
        controller.layoutRefreshController.workspaceSwipe.windowFrameChanged(windowId)
        let tracked = controller.workspaceManager.withEntry(forWindowId: Int(windowId)) {
            (mode: $0.mode, hiddenState: $0.hiddenState, workspaceId: $0.workspaceId)
        }
        if let tracked, tracked.mode == .tiling, tracked.hiddenState == nil,
           controller.niriLayoutHandler.hasScrollAnimation(for: tracked.workspaceId)
        {
            return
        }
        if controller.mouseEventHandler.tracksNativeTitleBarDrag(windowId: Int(windowId)) {
            cancelFrameObservation(windowId: windowId)
            applyFrameChange(
                windowId: windowId,
                identity: WindowServerIdentityResolution(
                    windowId: windowId,
                    info: frameObservations.nativeDragQuery(windowId)
                ),
                controller: controller
            )
        } else if frameObservations.byWindowId[windowId] != nil {
            frameObservations.byWindowId[windowId]?.needsRequery = true
        } else {
            startFrameObservation(windowId: windowId, hiddenState: tracked?.hiddenState)
        }
    }

    func cancelFrameObservation(windowId: UInt32) {
        frameObservations.tabBoundarySettlements.removeValue(forKey: windowId)?.cancel()
        frameObservations.byWindowId.removeValue(forKey: windowId)?.task.cancel()
    }

    func cancelFrameObservations() {
        for task in frameObservations.tabBoundarySettlements.values { task.cancel() }
        frameObservations.tabBoundarySettlements.removeAll()
        for observation in frameObservations.byWindowId.values {
            observation.task.cancel()
        }
        frameObservations.byWindowId.removeAll()
    }

    private func startFrameObservation(windowId: UInt32, hiddenState: HiddenState?) {
        let generation = frameObservations.nextGeneration
        frameObservations.nextGeneration &+= 1
        let query = frameObservations.query
        let task = Task { @MainActor [weak self] in
            let info = try? await query(windowId)
            self?.completeFrameObservation(windowId: windowId, generation: generation, info: info)
        }
        frameObservations.byWindowId[windowId] = FrameObservation(
            generation: generation,
            hiddenState: hiddenState,
            task: task
        )
    }

    private func completeFrameObservation(windowId: UInt32, generation: UInt64, info: WindowServerInfo?) {
        guard let observation = frameObservations.byWindowId[windowId],
              observation.generation == generation
        else { return }
        frameObservations.byWindowId[windowId] = nil
        guard let controller, !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        let tracked = controller.workspaceManager.withEntry(forWindowId: Int(windowId)) {
            (mode: $0.mode, hiddenState: $0.hiddenState, workspaceId: $0.workspaceId)
        }
        if let tracked, tracked.mode == .tiling, tracked.hiddenState == nil,
           controller.niriLayoutHandler.hasScrollAnimation(for: tracked.workspaceId)
        {
            return
        }
        let isCurrent = tracked?.hiddenState == observation.hiddenState
        if isCurrent {
            applyFrameChange(
                windowId: windowId,
                identity: WindowServerIdentityResolution(windowId: windowId, info: info),
                controller: controller
            )
        }
        if !isCurrent || observation.needsRequery {
            startFrameObservation(
                windowId: windowId,
                hiddenState: controller.workspaceManager.withEntry(forWindowId: Int(windowId)) { $0.hiddenState } ?? nil
            )
        }
    }

    private func applyFrameChange(
        windowId: UInt32,
        identity: WindowServerIdentityResolution,
        controller: WMController
    ) {
        guard case let .exact(windowServerToken, windowInfo) = identity else { return }
        if retryAdmissionForFrameChange(windowId: windowId, windowServerToken: windowServerToken) { return }
        guard let entry = controller.workspaceManager.entry(for: windowServerToken) else { return }
        if controller.workspaceManager.borderFocusToken == entry.token,
           isWindowDisplayable(token: entry.token)
        {
            controller.surfaceReconciler.noteBorderChanged()
        }
        if entry.mode == .tiling, entry.hiddenState == nil, entry.layoutReason == .standard,
           controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .tabbed,
           isWorkspaceActive(entry.workspaceId),
           let engine = controller.dwindleEngine,
           let leaf = engine.existingState(for: entry.workspaceId)?.leafByToken[entry.token],
           let tile = leaf.tile, tile.activeToken == entry.token, !tile.activeMember.isFullscreen
        {
            let key = TabRailKey(workspaceId: entry.workspaceId, owner: .dwindleTile(tile.id))
            let gesture = controller.mouseEventHandler.state.tabbedGesture
            if (gesture?.token == entry.token && (gesture?.drag.handle != .grip || controller.mouseEventHandler.touchMovedTab == entry.token))
                || controller.tabRailManager.isResizing(entry.token, in: key) { return }
            let frame = ScreenCoordinateSpace.toAppKit(rect: windowInfo.frame)
            if !controller.axManager.isAwaitingFrameWrite(entry.windowId),
               !shouldSuppressFrameChangedRelayout(for: entry, observedFrame: frame),
               frame.width > 0, frame.height > 0, frame != leaf.cachedContentFrame,
               !leaf.hasActiveAnimations(at: controller.animationClock.now()),
               let monitor = controller.workspaceManager.monitor(for: entry.workspaceId), monitor.frame.intersects(frame)
            {
                tile.observedNativePlacement = nil
                tile.freeFrame = frame
                leaf.clearAnimations()
                leaf.cachedContentFrame = frame
                leaf.cachedFrame = engine.tabbedBar.tileFrame(around: frame, grouped: tile.isGrouped)
                controller.surfaceReconciler.noteWorldChanged()
                frameObservations.tabBoundarySettlements.removeValue(forKey: windowId)?.cancel()
                let working = monitor.visibleFrame
                let barTop = controller.insetWorkingFrame(for: monitor).intersection(working).maxY
                let target = engine.tabbedBar.settledWindowFrame(frame, in: working, barTop: barTop, grouped: tile.isGrouped)
                if !target.approximatelyEqual(to: frame, tolerance: 0.01) {
                    tile.observedNativePlacement = (entry.token, frame)
                    settleTabbedBoundary(windowId: windowId, entry: entry, observed: frame)
                }
            }
            return
        }
        if entry.mode == .tiling,
           controller.mouseEventHandler.handleNativeTitleBarDragFrameChanged(for: entry)
        {
            return
        }
        if repairParkedWindowFrame(entry, windowInfo: windowInfo, controller: controller) { return }
        let focusedObservedFrame = observedFrameForFocusedFrameChange(
            windowId: windowId,
            windowServerToken: windowServerToken,
            resolvedToken: windowServerToken
        )

        guard isWindowDisplayable(token: windowServerToken) else { return }

        applyObservedFrameChange(entry, focusedObservedFrame: focusedObservedFrame, controller: controller)
    }

    // WindowServer reports native touch moves even without a mouse drag session. Wait for motion
    // to settle so the compositor and OmniWM don't simultaneously position the same window.
    private func settleTabbedBoundary(windowId: UInt32, entry: WindowState, observed: CGRect) {
        let token = entry.token
        let workspace = entry.workspaceId
        frameObservations.tabBoundarySettlements[windowId] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(110)) } catch { return }
            guard let self else { return }
            frameObservations.tabBoundarySettlements[windowId] = nil
            guard let controller, controller.isEnabled, !controller.isOverviewOpen(), isWorkspaceActive(workspace),
                  controller.workspaceManager.activeLayoutKind(for: workspace) == .tabbed,
                  let current = controller.workspaceManager.entry(for: token), current.workspaceId == workspace,
                  current.hiddenState == nil, current.layoutReason == .standard, current.mode == .tiling,
                  let state = controller.dwindleEngine?.existingState(for: workspace),
                  let tile = state.leafByToken[token]?.tile,
                  tile.activeToken == token, !tile.activeMember.isFullscreen,
                  tile.freeFrame == observed else { return }
            if controller.mouseEventHandler.directTouchDrag?.token == token || controller.mouseEventHandler.pressedMouseButtonsProvider() & 1 != 0 {
                settleTabbedBoundary(windowId: windowId, entry: current, observed: observed)
                return
            }
            tile.observedNativePlacement = nil
            // The native compositor has already moved the window. Supersede any seed from a previous group operation.
            controller.workspaceManager.withEngineMutationScope(in: workspace) {
                state.pendingMovementFrameSeeds[token] = observed
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspace])
        }
    }

    private func retryAdmissionForFrameChange(windowId: UInt32, windowServerToken: WindowToken) -> Bool {
        if let retryState = admissionRetryStateByWindowId[windowId] {
            guard retryState.expectedToken.map({ $0 == windowServerToken }) ?? true else { return true }
            if retryAdmissionAfterFrameChangeRequiresEarlyReturn(windowId: windowId) { return true }
        }
        return false
    }

    private func repairParkedWindowFrame(
        _ entry: WindowState,
        windowInfo: WindowServerInfo,
        controller: WMController
    ) -> Bool {
        guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else { return false }
        let observedFrame = ScreenCoordinateSpace.toAppKit(rect: windowInfo.frame)
        if hiddenState.workspaceInactive {
            controller.layoutRefreshController.repairWorkspaceInactivePark(for: entry, observedFrame: observedFrame)
        } else if let side = hiddenState.offscreenSide {
            controller.layoutRefreshController.repairLayoutTransientPark(
                for: entry,
                side: side,
                observedFrame: observedFrame
            )
        }
        return true
    }

    private func applyObservedFrameChange(
        _ entry: WindowState,
        focusedObservedFrame: CGRect?,
        controller: WMController
    ) {
        if entry.mode == .floating {
            if let frame = focusedObservedFrame ?? observedFrame(for: entry),
               !shouldSuppressFrameChangedRelayout(for: entry, observedFrame: frame)
            {
                updateFloatingWindowGeometryAndMonitorMembership(
                    entry: entry,
                    frame: frame
                )
            }
            return
        }

        if controller.isInteractiveGestureActive {
            return
        }

        if controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) {
            return
        }

        if shouldSuppressFrameChangedRelayout(
            for: entry,
            observedFrame: focusedObservedFrame
        ) {
            return
        }

        let suppressionObservedFrame = focusedObservedFrame
            ?? (controller.axManager.lastAppliedFrame(for: entry.windowId) == nil ? nil : observedFrame(for: entry))
        if suppressionObservedFrame != focusedObservedFrame,
           shouldSuppressFrameChangedRelayout(
               for: entry,
               observedFrame: suppressionObservedFrame
           )
        {
            return
        }

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func shouldSuppressFrameChangedRelayout(
        for entry: WindowState,
        observedFrame: CGRect?
    ) -> Bool {
        guard let controller else { return false }
        return controller.axManager.shouldSuppressFrameChangeRelayout(
            for: entry.windowId,
            observedFrame: observedFrame
        )
    }

    private func observedFrameForFocusedFrameChange(
        windowId: UInt32,
        windowServerToken: WindowToken?,
        resolvedToken: WindowToken?
    ) -> CGRect? {
        guard let controller else { return nil }
        guard let target = controller.workspaceManager.renderableFocusToken,
              let entry = controller.workspaceManager.entry(for: target)
        else { return nil }

        if let windowServerToken {
            guard windowServerToken == target else { return nil }
        } else {
            guard resolvedToken == target,
                  entry.mode == .floating
            else { return nil }
            if needsFocusedAXConfirmationForUnresolvedFrameChange(entry),
               focusedWindowToken(for: target.pid) != target
            {
                return nil
            }
        }

        guard controller.axManager.pendingFrameWrite(for: entry.windowId) == nil else { return nil }
        guard let frame = observedFrame(for: entry) else { return nil }
        return frame
    }

    private func needsFocusedAXConfirmationForUnresolvedFrameChange(_ entry: WindowState) -> Bool {
        guard let controller else { return true }
        return entry.layoutReason == .nativeFullscreen
            || controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
    }

    func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
    }

    func observedFrame(for entry: WindowState) -> CGRect? {
        entry.axRef.flatMap { observedFrame(for: $0) }
    }
}
