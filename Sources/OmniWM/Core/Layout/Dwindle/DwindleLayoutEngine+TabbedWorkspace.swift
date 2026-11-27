// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics

extension DwindleLayoutEngine {
    /// Only newly admitted windows join automatically. A detached tab stays in its own group.
    func synchronizeTabbedGroups(
        tokens: [WindowToken], preferred: WindowToken?, previousSelection: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID, initialFrame: (WindowToken) -> CGRect?
    ) {
        let state = ensureState(for: workspaceId)
        let eligible = tokens.filter { !state.excludedTokens.contains($0) }
        let known = state.tabbedMembers ?? []
        let entering = known.isEmpty
        state.tabbedMembers = known.intersection(tokens).union(eligible)
        let additions = eligible.filter { !known.contains($0) }
        guard !additions.isEmpty else { return }
        let destination = [preferred, previousSelection].compactMap { $0 }.first {
            eligible.contains($0) && (entering || known.contains($0))
        } ?? eligible.first(where: known.contains) ?? additions[0]
        guard let tile = state.leafByToken[destination]?.tile else { return }
        if tile.freeFrame == nil { tile.freeFrame = initialFrame(destination) }
        for token in additions where state.leafByToken[token]?.tile !== tile {
            groupWindow(token, into: destination, in: workspaceId)
        }
        if entering, let preferred, tile.memberIndex(for: preferred) != nil {
            _ = activateWindowOutcome(preferred, in: workspaceId)
        }
    }

    func detachTab(_ token: WindowToken, to frame: CGRect, in workspace: WorkspaceDescriptor.ID) -> Bool {
        guard let source = tile(containing: token, in: workspace) else { return false }
        let priorFrame = source.freeFrame ?? tileSnapshot(for: token, in: workspace)?.contentFrame
        guard ungroupWindow(token, direction: .right, in: workspace) else { return false }
        source.freeFrame = priorFrame
        tile(containing: token, in: workspace)?.freeFrame = frame
        return true
    }

    func tabbedFrames(
        state: DwindleWorkspaceState, screen: CGRect, fullscreen: CGRect, barTop: CGFloat, touchMovedTab: WindowToken?
    ) -> [WindowToken: CGRect] {
        var frames: [WindowToken: CGRect] = [:]
        for leaf in state.root.collectAllLeaves() {
            guard let tile = leaf.tile, let active = visibleMember(in: tile, excluding: state.excludedTokens) else {
                continue
            }
            let free = tile.freeFrame ?? screen.insetBy(dx: screen.width * 0.1, dy: screen.height * 0.1)
            let grouped = tile.members.count(where: { !state.excludedTokens.contains($0.token) }) > 1
            let content: CGRect
            if active.isFullscreen {
                content = fullscreen
            } else if active.token == touchMovedTab || (tile.observedNativePlacement?.frame == free && tile.observedNativePlacement?.token == active.token) {
                content = free
            } else {
                content = tabbedBar.settledWindowFrame(free, in: screen, barTop: barTop, grouped: grouped)
            }
            tile.freeFrame = free
            leaf.cachedFrame = tabbedBar.tileFrame(around: content, grouped: grouped && !active.isFullscreen)
            leaf.cachedContentFrame = content
            frames[active.token] = content
        }
        return frames
    }

    /// Window Tabs orders overlapping groups by their centers, preferring groups aligned on the cross axis.
    func tabbedNeighbor(from token: WindowToken, direction: Direction, state: DwindleWorkspaceState) -> WindowToken? {
        guard let source = state.leafByToken[token]?.cachedContentFrame else { return nil }
        let horizontal = direction == .left || direction == .right
        var best: (token: WindowToken, aligned: Bool, score: CGFloat)?
        for leaf in state.root.collectAllLeaves() {
            guard let target = visibleMember(in: leaf.tile, excluding: state.excludedTokens)?.token,
                  leaf !== state.leafByToken[token], let frame = leaf.cachedContentFrame else { continue }
            let dx = frame.midX - source.midX
            let dy = frame.midY - source.midY
            let forward = switch direction {
            case .left: -dx
            case .right: dx
            case .up: dy
            case .down: -dy
            }
            guard forward > 1 else { continue }
            let gap = horizontal ? max(0, source.minY - frame.maxY, frame.minY - source.maxY)
                : max(0, source.minX - frame.maxX, frame.minX - source.maxX)
            let aligned = gap == 0
            let score = forward + 1.5 * abs(horizontal ? dy : dx) + 2 * gap
            if let best, best.aligned != aligned ? best.aligned : best.score <= score { continue }
            best = (target, aligned, score)
        }
        return best?.token
    }
}
