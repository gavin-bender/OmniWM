// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func interactiveMoveBegin(
        windowId: NodeId,
        windowToken: WindowToken,
        startLocation: CGPoint,
        allowsInsertion: Bool = false,
        reordersStrip: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId, in: context.workspaceId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: context.workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: context.workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowToken: windowToken,
            workspaceId: context.workspaceId,
            startMouseLocation: startLocation,
            reordersStrip: reordersStrip,
            allowsInsertion: allowsInsertion,
            orientation: context.orientation,
            currentHoverTarget: nil
        )

        let cols = columns(in: context.workspaceId)
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let settings = effectiveSettings(in: context.workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            context: context,
            animate: false,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
            scale: displayScale(in: context.workspaceId),
            viewFrame: monitorForWorkspace(context.workspaceId)?.frame
        )

        return true
    }

    func interactiveMoveUpdate(currentLocation: CGPoint) -> MoveHoverTarget? {
        guard let move = interactiveMove else { return nil }
        guard findNode(by: move.windowId, in: move.workspaceId) != nil else {
            interactiveMoveCancel()
            return nil
        }
        let hoverTarget = moveTarget(for: move, at: currentLocation)
        interactiveMove?.currentHoverTarget = hoverTarget
        return hoverTarget
    }

    func interactiveMoveTargetFrame() -> CGRect? {
        guard let move = interactiveMove,
              let target = move.currentHoverTarget,
              let window = findNode(by: target.nodeId, in: move.workspaceId) as? NiriWindow,
              let frame = window.renderedFrame ?? window.frame
        else { return nil }
        return WindowMoveGeometry.targetFrame(in: frame, direction: target.direction)
    }

    func interactiveMoveEnd(
        at location: CGPoint,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = moveTarget(for: move, at: location) else {
            return false
        }

        let context = NiriInteractionContext(
            workspaceId: move.workspaceId,
            motion: motion,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: move.orientation
        )
        return commitWindowDrop(move.windowId, onto: target, context: context, state: &state)
    }

    func commitWindowDrop(
        _ source: NodeId, onto target: MoveHoverTarget, context: NiriInteractionContext, state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let direction = target.direction else {
            return swapWindowsByMove(
                sourceWindowId: source,
                targetWindowId: target.nodeId,
                context: context,
                state: &state
            )
        }
        if let step = direction.primaryStep(for: context.orientation) {
            return insertWindowInNewColumnByMove(
                sourceWindowId: source,
                targetWindowId: target.nodeId,
                after: step > 0,
                context: context,
                state: &state
            )
        }
        let inserted = insertWindowByMove(
            sourceWindowId: source,
            targetWindowId: target.nodeId,
            position: direction.secondaryStep(for: context.orientation) == 1 ? .after : .before,
            context: context,
            state: &state
        )
        if inserted {
            activateWindow(source, in: context.workspaceId)
        }
        return inserted
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func interactiveMoveClearTarget() {
        interactiveMove?.currentHoverTarget = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        allowsInsertion: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard let root = root(for: workspaceId) else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      window.id != excludingWindowId,
                      isProjectedFocusableWindow(window, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame,
                      frame.contains(point)
                else { continue }
                return MoveHoverTarget(
                    nodeId: window.id,
                    token: window.token,
                    direction: allowsInsertion ? WindowMoveGeometry.insertionDirection(at: point, in: frame) : nil
                )
            }
        }

        return nil
    }

    private func moveTarget(for move: InteractiveMove, at location: CGPoint) -> MoveHoverTarget? {
        let dragDistance = hypot(
            location.x - move.startMouseLocation.x,
            location.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else { return nil }
        if move.reordersStrip {
            return stripDropTarget(for: move.windowId, at: location, from: move.startMouseLocation,
                                   orientation: move.orientation, in: move.workspaceId)
        }
        return hitTestMoveTarget(
            point: location,
            excludingWindowId: move.windowId,
            allowsInsertion: move.allowsInsertion,
            in: move.workspaceId
        )
    }

    func stripDropTarget(
        for source: NodeId, at point: CGPoint, from start: CGPoint,
        orientation: Monitor.Orientation, in workspace: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        let columns = projectedColumns(in: workspace)
        guard let sourceIndex = columns.firstIndex(where: { $0.windows.contains { $0.id == source } }) else { return nil }
        let horizontal = orientation == .horizontal
        let travel = horizontal ? point.x - start.x : point.y - start.y
        let crossTravel = horizontal ? point.y - start.y : point.x - start.x
        let index: Int
        if let hit = hitTestMoveTarget(point: point, excludingWindowId: source, in: workspace),
           let hitIndex = columns.firstIndex(where: { $0.windows.contains { $0.id == hit.nodeId } }),
           hitIndex != sourceIndex {
            index = hitIndex
        } else {
            // A wide source window can cover the display. Allow a deliberate drag toward
            // the next column without requiring the finger to land inside that column.
            guard abs(travel) >= 64, abs(travel) > abs(crossTravel) else { return nil }
            index = sourceIndex + (travel > 0 ? 1 : -1)
        }
        guard columns.indices.contains(index), let target = projectedActiveWindow(in: columns[index]),
              !target.isFullscreen else { return nil }
        let forward = index > sourceIndex
        return MoveHoverTarget(nodeId: target.id, token: target.token,
                               direction: horizontal ? (forward ? .right : .left) : (forward ? .up : .down))
    }

    private func insertWindowInNewColumnByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        after: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId, in: context.workspaceId) as? NiriWindow,
              let sourceColumn = findColumn(containing: sourceWindow, in: context.workspaceId),
              let sourceIndex = columnIndex(of: sourceColumn, in: context.workspaceId),
              let targetWindow = findNode(by: targetWindowId, in: context.workspaceId) as? NiriWindow,
              let targetColumn = findColumn(containing: targetWindow, in: context.workspaceId),
              let targetIndex = columnIndex(of: targetColumn, in: context.workspaceId)
        else {
            return false
        }
        let insertIndex = after ? targetIndex + 1 : targetIndex
        if sourceColumn.windowNodes.count == 1, insertIndex == sourceIndex || insertIndex == sourceIndex + 1 {
            return false
        }
        return insertWindowInNewColumn(sourceWindow, insertIndex: insertIndex, context: context, state: &state)
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId, in: context.workspaceId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId, in: context.workspaceId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: context.workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: context.workspaceId)
        else {
            return false
        }

        if sourceColumn.id == targetColumn.id {
            sourceWindow.swapWith(targetWindow)

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
        } else {
            guard let sourceIdx = sourceColumn.children.firstIndex(where: { $0.id == sourceWindowId }),
                  let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId })
            else {
                return false
            }

            guard columnCanAcceptTransfer(
                targetColumn,
                adding: sourceWindow,
                removing: targetWindow,
                in: context.workspaceId,
                geometry: context.sizingGeometry
            ), columnCanAcceptTransfer(
                sourceColumn,
                adding: targetWindow,
                removing: sourceWindow,
                in: context.workspaceId,
                geometry: context.sizingGeometry
            ) else {
                return false
            }

            swapColumnMembers(
                source: (sourceWindow, sourceColumn), target: (targetWindow, targetColumn),
                indices: (sourceIdx, targetIdx)
            )
        }

        ensureSelectionVisible(
            node: sourceWindow,
            context: context,
            state: &state
        )

        return true
    }

    private func swapColumnMembers(
        source: (window: NiriWindow, column: NiriContainer),
        target: (window: NiriWindow, column: NiriContainer),
        indices: (source: Int, target: Int)
    ) {
        let sourceSize = source.window.size
        let sourceHeight = source.window.height
        let targetSize = target.window.size
        let targetHeight = target.window.height

        source.window.detach()
        target.window.detach()

        source.column.insertChild(target.window, at: indices.source)
        target.column.insertChild(source.window, at: indices.target)

        source.window.size = targetSize
        source.window.height = targetHeight
        target.window.size = sourceSize
        target.window.height = sourceHeight

        if source.column.isTabbed {
            source.column.clampActiveTileIdx()
        }
        if target.column.isTabbed {
            target.column.clampActiveTileIdx()
        }
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let sourceWindow = findNode(by: sourceWindowId, in: context.workspaceId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId, in: context.workspaceId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: context.workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: context.workspaceId)
        else {
            return false
        }

        guard let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) else {
            return false
        }

        let sameColumn = sourceColumn.id == targetColumn.id
        let sourceColumnWillBeEmpty = sourceColumn.children.count == 1 && !sameColumn

        if !sameColumn {
            guard columnCanAcceptTransfer(
                targetColumn,
                adding: sourceWindow,
                in: context.workspaceId,
                geometry: context.sizingGeometry
            ) else {
                return false
            }
        }

        sourceWindow.detach()

        let insertIdx: Int
        if sameColumn {
            let currentTargetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) ?? targetIdx
            insertIdx = position == .before ? currentTargetIdx : currentTargetIdx + 1
        } else {
            insertIdx = position == .before ? targetIdx : targetIdx + 1
        }

        targetColumn.insertChild(sourceWindow, at: insertIdx)

        sourceWindow.size = 1.0
        sourceWindow.height = .default

        finishMoveColumns(sourceColumn, target: targetColumn, removeSource: sourceColumnWillBeEmpty)

        ensureSelectionVisible(
            node: sourceWindow,
            context: context,
            state: &state
        )

        return true
    }

    private func finishMoveColumns(
        _ sourceColumn: NiriContainer,
        target targetColumn: NiriContainer,
        removeSource: Bool
    ) {
        if removeSource {
            sourceColumn.remove()
        }

        if sourceColumn.isTabbed {
            sourceColumn.clampActiveTileIdx()
        }
        if targetColumn.isTabbed {
            targetColumn.clampActiveTileIdx()
        }
    }
}
