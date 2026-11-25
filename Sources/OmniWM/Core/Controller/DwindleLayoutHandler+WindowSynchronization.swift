// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func prepareRelayoutTransition(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        now: TimeInterval
    ) -> DwindleFrameTransition {
        var previousTargetFrames = engine.currentFrames(in: snapshot.workspaceId)
        var oldFrames = engine.presentedFrames(in: snapshot.workspaceId, at: now)
        engine.consumePendingMovementFrameSeeds(
            in: snapshot.workspaceId,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargetFrames
        )
        let windowTokens = snapshot.windows.map(\.token)
        restoreInitialDwindlePlacementsIfNeeded(
            windowTokens: windowTokens,
            engine: engine,
            workspaceId: snapshot.workspaceId
        )
        let isTabbed = controller?.workspaceManager.activeLayoutKind(for: snapshot.workspaceId) == .tabbed
        let previousSelection = engine.projectedActiveToken(in: snapshot.workspaceId)
        let removedTokens = engine.syncWindows(
            windowTokens,
            in: snapshot.workspaceId,
            focusedToken: snapshot.preferredFocusToken,
            bootstrapScreen: snapshot.monitor.workingFrame,
            bootstrapBorderSafeFillScreen: snapshot.monitor.borderSafeFillFrame,
            bootstrapFullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )

        if isTabbed {
            engine.synchronizeTabbedGroups(tokens: windowTokens, preferred: snapshot.preferredFocusToken,
                                          previousSelection: previousSelection, in: snapshot.workspaceId) { token in
                guard let controller, let entry = controller.workspaceManager.entry(for: token),
                      entry.hiddenState == nil,
                      let frame = controller.mouseEventHandler.fastNativeWindowFrame(for: entry),
                      frame.intersection(snapshot.monitor.workingFrame).width > 40 else { return nil }
                return frame
            }
        }

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
        }

        let newFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: isTabbed ? snapshot.monitor.tabbedWorkingFrame : snapshot.monitor.workingFrame,
            borderSafeFillScreen: snapshot.monitor.borderSafeFillFrame,
            fullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )
        if !removedTokens.isEmpty {
            controller?.windowActionHandler.refreshOverviewProjection(
                affectedWorkspaceIds: [snapshot.workspaceId],
                selectedToken: engine.projectedActiveToken(in: snapshot.workspaceId)
            )
        }

        return DwindleFrameTransition(
            oldFrames: oldFrames,
            previousTargetFrames: previousTargetFrames,
            newFrames: newFrames
        )
    }

    private func restoreInitialDwindlePlacementsIfNeeded(
        windowTokens: [WindowToken],
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        var placements: [WindowToken: PersistedDwindlePlacement] = [:]
        for token in windowTokens {
            if let placement = controller.workspaceManager.restoreIntent(for: token)?.dwindlePlacement {
                placements[token] = placement
            }
        }
        engine.restoreInitialPlacements(placements, matching: windowTokens, in: workspaceId)
    }
}
