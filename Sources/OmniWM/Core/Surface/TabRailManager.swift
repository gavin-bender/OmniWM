// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class TabRailManager {
    typealias SelectionHandler = (TabRailInfo, Int, WindowToken?) -> Void

    var onTabAction: ((TabRailInfo, WindowToken, TabBarAction) -> Void)?
    func dropRail(windowId: Int, at point: CGPoint, in workspace: WorkspaceDescriptor.ID)
        -> (target: WindowToken, before: WindowToken?, marker: CGRect)? {
        guard let window = railWindows.values.first(where: { $0.windowNumber == windowId && $0.isOrderedIn }),
              let info = railInfos.values.first(where: { railWindows[$0.key] === window }),
              info.workspaceId == workspace, info.styleOverride?.options != nil,
              let target = info.tabs.first(where: { $0.isActive })?.token,
              let slot = window.insertion(atScreen: point) else { return nil }
        return (target, slot.before, slot.marker)
    }

    var onSelect: SelectionHandler?
    var ringOrderedAbove: (@MainActor (UInt32) -> UInt32?)?

    private var railWindows: [TabRailKey: TabRailWindow] = [:]
    private var railInfos: [TabRailKey: TabRailInfo] = [:]
    private let motionPolicy: MotionPolicy
    private let appInfoCache: AppInfoCache
    private var style: TabRailStyle = .compact

    init(motionPolicy: MotionPolicy = MotionPolicy(), appInfoCache: AppInfoCache = AppInfoCache()) {
        self.motionPolicy = motionPolicy
        self.appInfoCache = appInfoCache
    }

    func updateRails(_ infos: [TabRailInfo], forceOrdering: Bool = false, style: TabRailStyle = .compact) {
        self.style = style
        var desiredKeys = Set<TabRailKey>()
        desiredKeys.reserveCapacity(infos.count)
        for info in infos where info.tabCount > 0 {
            desiredKeys.insert(info.key)
            railInfos[info.key] = info
            if railWindows[info.key] != nil || Self.isRenderable(visibleTileFrame: info.visibleTileFrame) {
                updateRail(info, forceOrdering: forceOrdering)
            }
        }

        let staleWindowKeys = railWindows.keys.filter { !desiredKeys.contains($0) }
        for key in staleWindowKeys {
            railWindows.removeValue(forKey: key)?.close()
        }
        let staleInfoKeys = railInfos.keys.filter { !desiredKeys.contains($0) }
        for key in staleInfoKeys {
            railInfos.removeValue(forKey: key)
        }
    }

    func applyAnimationGeometry(
        _ commands: [TabRailGeometryCommand],
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) {
        for command in commands {
            if let workspaceId, command.key.workspaceId != workspaceId {
                continue
            }
            if let window = railWindows[command.key] {
                window.updateAnimationGeometry(command)
                continue
            }
            guard Self.isRenderable(visibleTileFrame: command.visibleTileFrame),
                  let info = railInfos[command.key]
            else {
                continue
            }
            let presentedInfo = TabRailInfo(
                workspaceId: info.workspaceId,
                owner: info.owner,
                plannedSeq: info.plannedSeq,
                tileFrame: command.tileFrame,
                visibleTileFrame: command.visibleTileFrame,
                tabCount: info.tabCount,
                activeVisualIndex: info.activeVisualIndex,
                activeWindowId: info.activeWindowId,
                tabs: info.tabs,
                orderingWindowId: command.orderingWindowId,
                displayFrame: command.displayFrame,
                styleOverride: info.styleOverride
            )
            railInfos[command.key] = presentedInfo
            updateRail(presentedInfo, forceOrdering: false)
        }
    }

    func cancelDrag() -> Bool {
        railWindows.values.contains { $0.cancelDrag() }
    }

    func existingWindow(for key: TabRailKey) -> NSWindow? {
        railWindows[key]
    }

    private func updateRail(_ info: TabRailInfo, forceOrdering: Bool) {
        let key = info.key
        let window = railWindows[key] ?? {
            let window = TabRailWindow(
                owner: info.owner, workspaceId: info.workspaceId, motionPolicy: motionPolicy, appInfoCache: appInfoCache
            )
            window.onTabAction = { [weak self] info, token, action in self?.onTabAction?(info, token, action) }
            window.onSelect = { [weak self] info, visualIndex, token in
                self?.onSelect?(info, visualIndex, token)
            }
            window.ringOrderedAbove = { [weak self] in self?.ringOrderedAbove?($0) }
            railWindows[key] = window
            return window
        }()
        window.update(info: info, forceOrdering: forceOrdering, style: info.styleOverride ?? style)
    }

    func removeAll() {
        for (_, window) in railWindows {
            window.close()
        }
        railWindows.removeAll()
        railInfos.removeAll()
    }

    static func isRenderable(visibleTileFrame: CGRect) -> Bool {
        !visibleTileFrame.isNull
            && visibleTileFrame.width >= TabRailMetrics.minVisibleIntersection
            && visibleTileFrame.height >= TabRailMetrics.minVisibleIntersection
    }
}
