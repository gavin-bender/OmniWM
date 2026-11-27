// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func desiredTabRailInfos() -> [TabRailInfo] {
        guard let controller, let engine = controller.dwindleEngine else { return [] }

        var infos: [TabRailInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
                  controller.workspaceManager.activeLayoutKind(for: workspace.id).usesGroupedTiles
            else {
                continue
            }

            let presentationTime = controller.animationClock.now()
            let scale = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor).scale
            let tabbed = controller.workspaceManager.activeLayoutKind(for: workspace.id) == .tabbed
            let railBounds = tabbed ? controller.insetWorkingFrame(for: monitor).intersection(monitor.visibleFrame) : monitor.visibleFrame
            for snapshot in engine.groupedTileSnapshots(in: workspace.id) {
                let presentedFrame = presentedTileFrame(
                    geometry: .init(
                        id: snapshot.id,
                        activeToken: snapshot.activeToken,
                        tileFrame: snapshot.tileFrame,
                        contentFrame: snapshot.contentFrame
                    ),
                    engine: engine,
                    workspaceId: workspace.id,
                    at: presentationTime,
                    scale: scale
                )
                let frame = presentedFrame ?? snapshot.tileFrame ?? .zero
                let visibleFrame = presentedFrame.map { tabbed ? pinnedTabArea($0, in: railBounds) : $0.intersection(railBounds) } ?? .null

                let tabs = tabInfos(for: snapshot, controller: controller)

                infos.append(
                    TabRailInfo(
                        workspaceId: workspace.id,
                        owner: .dwindleTile(snapshot.id),
                        plannedSeq: controller.workspaceManager.worldSeq,
                        tileFrame: frame,
                        visibleTileFrame: visibleFrame,
                        tabCount: tabs.count,
                        activeVisualIndex: snapshot.activeIndex,
                        activeWindowId: controller.workspaceManager.entry(for: snapshot.activeToken)?.windowId,
                        tabs: tabs,
                        displayFrame: tabbed ? railBounds : nil,
                        styleOverride: controller.workspaceManager.activeLayoutKind(for: workspace.id) == .tabbed
                            ? .windowTabs(controller.settings.tabbedBar) : nil
                    )
                )
            }
        }
        return infos
    }

    private func pinnedTabArea(_ tile: CGRect, in bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(tile.width, bounds.width), height: min(tile.height, bounds.height))
        return FloatingFrameGeometry.clamped(CGRect(origin: tile.origin, size: size), in: bounds)
    }

    func swipeTabRail(for token: WindowToken, frame: CGRect, in workspace: WorkspaceDescriptor.ID) -> TabRailInfo? {
        guard let controller, controller.workspaceManager.activeLayoutKind(for: workspace) == .tabbed,
              let tile = controller.dwindleEngine?.tileSnapshot(for: token, in: workspace), tile.isGrouped,
              tile.activeToken == token, !tile.members[tile.activeIndex].isFullscreen else { return nil }
        guard let monitor = controller.workspaceManager.monitor(for: workspace) else { return nil }
        let options = controller.settings.tabbedBar
        let tileFrame = options.tileFrame(around: frame, grouped: true)
        let bounds = controller.insetWorkingFrame(for: monitor).intersection(monitor.visibleFrame)
        return TabRailInfo(workspaceId: workspace, owner: .dwindleTile(tile.id), plannedSeq: controller.workspaceManager.worldSeq,
                           tileFrame: tileFrame, visibleTileFrame: pinnedTabArea(tileFrame, in: bounds), tabCount: tile.members.count,
                           activeVisualIndex: tile.activeIndex, activeWindowId: token.windowId,
                           tabs: tabInfos(for: tile, controller: controller), displayFrame: bounds, styleOverride: .windowTabs(options))
    }

    private func tabInfos(for snapshot: DwindleTileSnapshot, controller: WMController) -> [TabRailTabInfo] {
        var tabs: [TabRailTabInfo] = []
        tabs.reserveCapacity(snapshot.members.count)
        for (index, member) in snapshot.members.enumerated() {
            let entry = controller.workspaceManager.entry(for: member.token)
            let presentation = entry.map { entry in
                controller.appInfoCache.presentation(
                    for: entry,
                    title: entry.managedReplacementMetadata?.title ?? UInt32(exactly: entry.windowId).flatMap {
                        AXWindowService.titlePreferFast(windowId: $0)
                    },
                    cachedProcessOnly: true
                )
            }
            tabs.append(
                TabRailTabInfo(
                    visualIndex: index,
                    token: member.token,
                    windowId: entry?.windowId,
                    appName: presentation?.name,
                    title: presentation?.title,
                    isActive: index == snapshot.activeIndex,
                    icon: presentation?.icon
                )
            )
        }

        return tabs
    }

    func dwindleTabRailGeometryCommands(
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: LayoutMonitorSnapshot,
        targetTime: TimeInterval
    ) -> [TabRailGeometryCommand] {
        var commands: [TabRailGeometryCommand] = []
        let tabbed = engine.existingState(for: workspaceId)?.tabbedMembers != nil
        let railBounds = tabbed ? monitor.tabbedWorkingFrame : monitor.visibleFrame
        engine.forEachGroupedTileGeometry(in: workspaceId) { geometry in
            let key = TabRailKey(workspaceId: workspaceId, owner: .dwindleTile(geometry.id))
            guard let frame = presentedTileFrame(
                geometry: geometry,
                engine: engine,
                workspaceId: workspaceId,
                at: targetTime,
                scale: monitor.scale
            ) else {
                commands.append(
                    TabRailGeometryCommand(
                        key: key,
                        tileFrame: .zero,
                        visibleTileFrame: .null
                    )
                )
                return
            }
            commands.append(
                TabRailGeometryCommand(
                    key: key,
                    tileFrame: frame,
                    visibleTileFrame: tabbed ? pinnedTabArea(frame, in: railBounds) : frame.intersection(railBounds),
                    displayFrame: tabbed ? railBounds : nil
                )
            )
        }
        return commands
    }

    func presentedTileFrame(
        geometry: DwindleGroupedTileGeometry,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        at targetTime: TimeInterval,
        scale: CGFloat
    ) -> CGRect? {
        guard let tileFrame = geometry.tileFrame,
              let contentFrame = geometry.contentFrame,
              let presentedContentFrame = engine.presentedFrame(
                  for: geometry.activeToken,
                  in: workspaceId,
                  at: targetTime
              )
        else {
            return nil
        }
        let left = max(0, contentFrame.minX - tileFrame.minX)
        let right = max(0, tileFrame.maxX - contentFrame.maxX)
        let bottom = max(0, contentFrame.minY - tileFrame.minY)
        let top = max(0, tileFrame.maxY - contentFrame.maxY)
        let frame = CGRect(
            x: presentedContentFrame.minX - left,
            y: presentedContentFrame.minY - bottom,
            width: presentedContentFrame.width + left + right,
            height: presentedContentFrame.height + bottom + top
        ).roundedToPhysicalPixels(scale: max(scale, 1))
        guard !frame.isNull,
              !frame.isInfinite,
              frame.width > 0,
              frame.height > 0
        else {
            return nil
        }
        return frame
    }
}
