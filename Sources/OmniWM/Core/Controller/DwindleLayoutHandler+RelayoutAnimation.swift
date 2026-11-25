// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func startRelayoutAnimations(
        _ transition: DwindleFrameTransition,
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        now: TimeInterval
    ) -> Bool {
        var movement = transition
        if let state = engine.existingState(for: snapshot.workspaceId), state.tabbedMembers != nil {
            // Free placement follows the hand directly. Animate only groups displaced to fit their strip.
            var starts: [WindowToken: CGRect] = [:]
            var previous: [WindowToken: CGRect] = [:]
            for (token, target) in transition.newFrames {
                guard let leaf = state.leafByToken[token], let tile = leaf.tile else { continue }
                guard tile.isGrouped, !tile.activeMember.isFullscreen,
                      let requested = tile.freeFrame, requested != target else {
                    leaf.clearAnimations()
                    continue
                }
                starts[token] = transition.oldFrames[token] ?? requested
                previous[token] = transition.previousTargetFrames[token] ?? requested
            }
            movement = DwindleFrameTransition(oldFrames: starts, previousTargetFrames: previous, newFrames: transition.newFrames)
        }
        engine.animateWindowMovements(
            movement,
            in: snapshot.workspaceId,
            startTime: now,
            motion: controller?.motionPolicy.snapshot() ?? .enabled
        )

        let animationsActive = snapshot.isActiveWorkspace
            && engine.hasActiveAnimations(in: snapshot.workspaceId, at: now)
        if !snapshot.isActiveWorkspace {
            engine.cancelAnimations(in: snapshot.workspaceId)
        }
        return animationsActive
    }

    func animationTargetDisposition(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        frames: [WindowToken: CGRect],
        active: Bool
    ) -> DwindleAnimationTargetDisposition {
        if active {
            return .replace(
                DwindleAnimationTargetCandidate(
                    workspaceId: snapshot.workspaceId,
                    engineIdentifier: ObjectIdentifier(engine),
                    geometry: geometryContext(monitor: snapshot.monitor, settings: snapshot.settings),
                    targetFrames: frames
                )
            )
        } else {
            return .clear(
                engineIdentifier: ObjectIdentifier(engine),
                geometry: geometryContext(monitor: snapshot.monitor, settings: snapshot.settings)
            )
        }
    }
}
