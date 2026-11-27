// SPDX-License-Identifier: GPL-2.0-only

import AppKit

extension MouseEventHandler {
    private enum Drop {
        case bar(WindowToken, before: WindowToken?, caret: CGRect)
        case title(WindowToken, CGRect)
        case desktop(CGRect)

        var preview: CGRect {
            switch self {
            case let .bar(_, _, rect), let .title(_, rect), let .desktop(rect): rect
            }
        }
    }

    static func tabDropTitleRegion(in frame: CGRect) -> CGRect {
        let height = min(56, frame.height)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    private func resolveTabDrop(at point: CGPoint, token: WindowToken, workspace: WorkspaceDescriptor.ID,
                                frame: CGRect, native: Bool, stack: [(id: Int, frame: CGRect)]? = nil) -> Drop? {
        guard let controller, let destination = workspaceIdForPointer(at: point),
              controller.workspaceManager.activeLayoutKind(for: destination) == .tabbed else { return nil }
        let border = tabWindowBorderId()
        for (id, window) in stack ?? tabWindowStackAtPoint(point) where id != border {
            if let bar = controller.tabRailManager.dropRail(windowId: id, at: point, in: destination) {
                if native, controller.dwindleEngine?.tile(containing: token, in: workspace)?.memberIndex(for: bar.target) != nil { continue }
                return .bar(bar.target, before: bar.before, caret: bar.marker)
            }
            if native && id == token.windowId { continue }
            if let entry = controller.workspaceManager.entry(forWindowId: id), entry.workspaceId == destination,
               entry.hiddenState == nil, entry.token != token, Self.tabDropTitleRegion(in: window).contains(point),
               controller.dwindleLayoutHandler.groupMemberActivationIsAllowed(entry.token, workspaceId: destination) {
                return .title(entry.token, Self.tabDropTitleRegion(in: window))
            }
            break
        }
        guard !native, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame else { return nil }
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        let x = min(max(screen.minX, point.x - size.width / 2), screen.maxX - size.width)
        let y = min(max(screen.minY, point.y + 14 - size.height), screen.maxY - size.height)
        return .desktop(CGRect(origin: CGPoint(x: x, y: y), size: size))
    }

    func performTabBarAction(_ action: TabBarAction, token: WindowToken, info: TabRailInfo) {
        guard let controller, canHandleManagedMouseInteraction(controller: controller), !isInputSuppressed,
              let engine = controller.dwindleEngine,
              controller.workspaceManager.activeLayoutKind(for: info.workspaceId) == .tabbed,
              let tile = engine.tileSnapshot(for: token, in: info.workspaceId),
              info.owner == .dwindleTile(tile.id), let frame = tile.contentFrame, !tile.members[tile.activeIndex].isFullscreen,
              controller.dwindleLayoutHandler.groupMembershipMutationIsAllowed(for: token, engine: engine, workspaceId: info.workspaceId)
        else { tabDropFeedback.hide(); return }
        switch action {
        case let .geometry(drag, point, released):
            updateTabbedFrame(drag, at: point, token: token, workspace: info.workspaceId, released: released)
        case .ungroupAll:
            ungroupTabbedWorkspace(info.workspaceId)
        case .cancel:
            tabDropFeedback.hide()
        case .close:
            if let handle = controller.workspaceManager.handle(for: token) { _ = controller.windowActionHandler.closeWindow(handle: handle) }
        case .detach:
            applyTabDrop(.desktop(frame.offsetBy(dx: 28, dy: -28)), token: token, workspace: info.workspaceId)
        case let .drag(point, released):
            let drop = resolveTabDrop(at: point, token: token, workspace: info.workspaceId, frame: frame, native: false)
            presentTabDrop(drop, token: token, workspace: workspaceIdForPointer(at: point) ?? info.workspaceId, released: released)
        }
    }

    func updateTabbedFrame(_ drag: TabFrameDrag, at point: CGPoint, token: WindowToken,
                           workspace: WorkspaceDescriptor.ID, released: Bool) {
        guard let controller, let engine = controller.dwindleEngine,
              controller.workspaceManager.activeLayoutKind(for: workspace) == .tabbed,
              let tile = engine.tile(containing: token, in: workspace),
              tile.activeToken == token, !tile.activeMember.isFullscreen else { return }
        var bounds = CGRect.infinite
        if drag.handle != .grip, let monitor = controller.workspaceManager.monitor(for: workspace) {
            let working = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor).tabbedWorkingFrame
            if !working.isEmpty {
                bounds = engine.tabbedBar.contentFrame(fitting: working, in: working, grouped: tile.isGrouped)
            }
            if let id = UInt32(exactly: token.windowId) {
                controller.axEventHandler.cancelFrameObservation(windowId: id)
            }
        }
        let frame = drag.frame(at: point, minimum: engine.minimumSize(for: tile, excluding: []), within: bounds)
        guard released || tile.freeFrame != frame else { return }
        controller.workspaceManager.withEngineMutationScope {
            tile.freeFrame = frame
            if released, touchMovedTab == token {
                engine.existingState(for: workspace)?.pendingMovementFrameSeeds[token] = frame
            }
        }
        if released {
            if touchMovedTab == token, let id = UInt32(exactly: token.windowId) {
                controller.axEventHandler.cancelFrameObservation(windowId: id)
            }
            let operation: LayoutOperation = drag.handle == .grip ? .interactiveMoveEnded(token: token) : .interactiveResizeEnded(token: token)
            controller.dwindleLayoutHandler.recordLayoutOperation(operation, in: workspace, source: .mouse)
        }
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspace])
    }

    func ungroupTabbedWorkspace(_ workspace: WorkspaceDescriptor.ID) {
        guard let controller, let engine = controller.dwindleEngine,
              controller.workspaceManager.activeLayoutKind(for: workspace) == .tabbed,
              let state = engine.existingState(for: workspace) else { return }
        var detached = [WindowToken]()
        controller.workspaceManager.withEngineMutationScope {
            for leaf in state.root.collectAllLeaves() {
                guard let tile = leaf.tile, tile.isGrouped, let frame = leaf.cachedContentFrame,
                      controller.dwindleLayoutHandler.groupMembershipMutationIsAllowed(for: tile.activeToken, engine: engine, workspaceId: workspace)
                else { continue }
                let others = tile.members.filter { $0.token != tile.activeToken }
                for (index, member) in others.enumerated() {
                    let offset = CGFloat(index + 1) * 24
                    if engine.detachTab(member.token, to: frame.offsetBy(dx: offset, dy: -offset), in: workspace) {
                        detached.append(member.token)
                    }
                }
            }
        }
        for token in detached {
            controller.dwindleLayoutHandler.recordLayoutOperation(.groupMembershipChanged(token: token), in: workspace, source: .mouse)
        }
        if !detached.isEmpty { controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspace]) }
    }

    func updateTabbedTitleDrag(at point: CGPoint, released: Bool) {
        guard let drag = state.tabbedTitleDrag else { return }
        defer { if released { state.tabbedTitleDrag = nil; tabDropFeedback.hide() } }
        guard hypot(point.x - drag.start.x, point.y - drag.start.y) > 8, let controller,
              let source = controller.workspaceManager.entry(for: drag.token),
              controller.workspaceManager.activeLayoutKind(for: source.workspaceId) == .tabbed else {
            tabDropFeedback.hide()
            return
        }
        // Read the dragged window and its receiver from the same WindowServer sample.
        let stack = tabWindowStackAtPoint(point)
        guard let moved = stack.first(where: { $0.id == source.windowId })?.frame ?? fastNativeWindowFrame(for: source),
              moved.size.isWithinFrameTolerance(of: drag.frame.size),
              hypot(moved.minX - drag.frame.minX, moved.minY - drag.frame.minY) > 4 else {
            tabDropFeedback.hide()
            return
        }
        let drop = resolveTabDrop(at: point, token: source.token, workspace: source.workspaceId,
                                  frame: moved, native: true, stack: stack)
        presentTabDrop(drop, token: source.token, workspace: workspaceIdForPointer(at: point) ?? source.workspaceId, released: released)
    }

    func updateTouchTabDrop(at point: CGPoint, token: WindowToken, workspace: WorkspaceDescriptor.ID,
                            frame: CGRect, released: Bool) {
        let drop = resolveTabDrop(at: point, token: token, workspace: workspace, frame: frame, native: true)
        presentTabDrop(drop, token: token, workspace: workspaceIdForPointer(at: point) ?? workspace, released: released)
    }

    private func presentTabDrop(_ drop: Drop?, token: WindowToken, workspace: WorkspaceDescriptor.ID, released: Bool) {
        guard let drop else { tabDropFeedback.hide(); return }
        if released {
            tabDropFeedback.hide()
            guard let controller, let source = controller.workspaceManager.workspace(for: token) else { return }
            if source == workspace {
                applyTabDrop(drop, token: token, workspace: workspace)
            } else if let handle = controller.workspaceManager.handle(for: token),
                      case .changed = controller.workspaceNavigationHandler.commitWindowMove(handle: handle, toWorkspaceId: workspace) {
                // Destination admission runs during layout and may automatically place the arriving tab in a group.
                controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspace]) { [weak self] in
                    self?.applyTabDrop(drop, token: token, workspace: workspace)
                }
            }
        } else if case .bar = drop {
            tabDropFeedback.show(drop.preview, caret: true)
        } else if case .desktop = drop {
            tabDropFeedback.show(drop.preview, window: token)
        } else {
            tabDropFeedback.show(drop.preview)
        }
    }

    private func applyTabDrop(_ drop: Drop, token: WindowToken, workspace: WorkspaceDescriptor.ID) {
        guard let controller, let engine = controller.dwindleEngine,
              let source = engine.tile(containing: token, in: workspace),
              controller.dwindleLayoutHandler.groupMembershipMutationIsAllowed(for: token, engine: engine, workspaceId: workspace)
        else { return }
        let operation: LayoutOperation? = controller.workspaceManager.withEngineMutationScope {
            switch drop {
            case let .desktop(frame):
                if source.isGrouped {
                    guard engine.detachTab(token, to: frame, in: workspace) else { return nil }
                } else {
                    source.freeFrame = frame
                    return .interactiveMoveEnded(token: token)
                }
            case let .title(target, _), let .bar(target, _, _):
                guard let destination = engine.tile(containing: target, in: workspace),
                      !destination.activeMember.isFullscreen,
                      controller.dwindleLayoutHandler.groupMembershipMutationIsAllowed(for: target, engine: engine, workspaceId: workspace)
                else { return nil }
                if destination !== source {
                    guard engine.groupWindow(token, into: target, in: workspace) else { return nil }
                }
                if case let .bar(_, anchor, _) = drop { destination.place(token, before: anchor) }
                if destination === source { return .groupMemberMoved(token: token) }
            }
            return .groupMembershipChanged(token: token)
        }
        guard let operation else { return }
        controller.dwindleLayoutHandler.recordLayoutOperation(operation, in: workspace, source: .mouse)
        controller.dwindleLayoutHandler.commitGroupSelection(token, workspaceId: workspace, focusAfterLayout: true, focusOrigin: .pointerHover)
    }
}
