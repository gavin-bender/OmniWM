// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMLayerCorners

@MainActor
class TabRailWindow: NSPanel {
    private let railView: TabRailView
    let hoverCard: TabRailHoverCardWindow
    private let surfaceID: String
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var lastFrame: CGRect?
    private var windowServerPlacement: (appKitFrame: CGRect, frame: CGRect)?
    private var isOrderedOutInWindowServer = false
    private var lastOrderingWindowId: Int?
    private var currentInfo: TabRailInfo?
    private var style: TabRailStyle = .compact
    private var animationGeometryNeedsAccessibilityRefresh = false
    private var registeredSurfaceWindowNumber: Int?
    private var accessibilityDisplayObserver: NSObjectProtocol?

    var resolvePreviewHandle: ((WindowToken) -> WindowHandle?)?
    var onHoverPreview: ((WorkspaceBarHoverTarget?) -> Void)?
    var onTabAction: ((TabRailInfo, WindowToken, TabBarAction) -> Void)?
    func insertion(atScreen point: CGPoint) -> (before: WindowToken?, marker: CGRect)? {
        railView.insertion(at: CGPoint(x: point.x - appliedFrame.minX, y: point.y - appliedFrame.minY))
    }

    var onSelect: ((TabRailInfo, Int, WindowToken?) -> Void)?
    var ringOrderedAbove: (@MainActor (UInt32) -> UInt32?)?

    init(
        owner: TabRailOwner, workspaceId: WorkspaceDescriptor.ID, motionPolicy: MotionPolicy,
        appInfoCache: AppInfoCache = AppInfoCache()
    ) {
        surfaceID = Self.surfaceID(workspaceId: workspaceId, owner: owner)
        railView = TabRailView(frame: .zero, motionPolicy: motionPolicy, appInfoCache: appInfoCache)
        hoverCard = TabRailHoverCardWindow()

        omniwm_window_manager_begin_coordinator_capture()
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
        level = .normal
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.managed, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        omniwm_window_manager_end_coordinator_capture()

        railView.onTabAction = { [weak self] token, action in
            guard let self, let currentInfo else { return }
            self.onTabAction?(currentInfo, token, action)
        }
        railView.onSelect = { [weak self] visualIndex in
            guard let self, let currentInfo else { return }
            let token = currentInfo.tabs.first(where: { $0.visualIndex == visualIndex })?.token
            self.onSelect?(currentInfo, visualIndex, token)
        }
        railView.onHoverChange = { [weak self] tab, itemRect in
            self?.updateHoverCard(tab: tab, itemRect: itemRect)
        }
        contentView = railView

        accessibilityDisplayObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak railView, weak hoverCard] _ in
            Task { @MainActor [weak railView, weak hoverCard] in
                railView?.refreshAppearance()
                hoverCard?.refreshAppearance()
            }
        }
    }

    var resizingToken: WindowToken? { railView.resizingToken }

    @discardableResult
    func cancelDrag() -> Bool { railView.cancelDrag() }

    override func close() {
        cancelDrag()
        dismissHover()
        if let accessibilityDisplayObserver {
            NotificationCenter.default.removeObserver(accessibilityDisplayObserver)
            self.accessibilityDisplayObserver = nil
        }
        surfaceCoordinator.unregister(id: surfaceID)
        registeredSurfaceWindowNumber = nil
        super.close()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        guard !event.isWindowServerMove else { return }
        super.sendEvent(event)
    }

    var isOrderedIn: Bool {
        isVisible && !isOrderedOutInWindowServer
    }

    var appliedFrame: CGRect {
        guard let windowServerPlacement, windowServerPlacement.appKitFrame == frame else { return frame }
        return windowServerPlacement.frame
    }

    override func convertToScreen(_ rect: NSRect) -> NSRect {
        let origin = appliedFrame.origin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    func update(info: TabRailInfo, forceOrdering: Bool, style: TabRailStyle = .compact) {
        let frame = TabRailPlacement.frame(
            for: info.visibleTileFrame, tabCount: info.tabCount, style: style, displayFrame: info.displayFrame
        )
        let placedFrame = appliedFrame
        if self.style != style || frame != lastFrame || frame != placedFrame || !isOrderedIn {
            dismissHover()
        }
        self.style = style
        currentInfo = info
        updateGroupContentFrame(info.tileFrame)
        let clampedActiveVisualIndex = min(max(0, info.activeVisualIndex), max(0, info.tabCount - 1))
        guard frame.width > 1, frame.height > 1 else {
            railView.update(tabs: info.normalizedTabs, activeVisualIndex: clampedActiveVisualIndex, style: style)
            dismissHover()
            orderOutOfWindowServer()
            lastFrame = nil
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }

        let accessibilityGeometryChanged = animationGeometryNeedsAccessibilityRefresh || placedFrame != frame
        let settledFrame = Self.appKitPlacement(of: frame)
        if lastFrame != frame || placedFrame != settledFrame {
            if !canKeepWindowServerPlacement(at: settledFrame) || !placeInWindowServer(settledFrame) {
                setFrameReconcilingWindowServer(frame)
            }
            lastFrame = frame
        }
        railView.update(tabs: info.normalizedTabs, activeVisualIndex: clampedActiveVisualIndex, style: style)

        if accessibilityGeometryChanged {
            railView.refreshAccessibilityFrames()
        }
        animationGeometryNeedsAccessibilityRefresh = false

        let orderingWindowId = info.orderingWindowId ?? info.activeWindowId
        if TabRailOrderingPolicy.shouldReorder(
            forceOrdering: forceOrdering,
            wasOrderedIn: isOrderedIn,
            lastActiveWindowId: lastOrderingWindowId,
            activeWindowId: orderingWindowId
        ) {
            orderAbove(orderingWindowId)
        }
        syncSurfaceRegistration()
        lastOrderingWindowId = orderingWindowId
    }

    private func updateGroupContentFrame(_ frame: CGRect) {
        guard let options = style.options else { railView.groupContentFrame = nil; return }
        var content = frame
        if options.position == .top { content.size.height -= options.thickness }
        else { content.origin.x += options.thickness; content.size.width -= options.thickness }
        railView.groupContentFrame = content
    }

    func updateAnimationGeometry(_ command: TabRailGeometryCommand) {
        guard let currentInfo, currentInfo.key == command.key else { return }
        updateGroupContentFrame(command.tileFrame)
        let frame = TabRailPlacement.frame(
            for: command.visibleTileFrame, tabCount: currentInfo.tabCount, style: style,
            displayFrame: command.displayFrame
        )
        guard frame.width > 1, frame.height > 1 else {
            dismissHover()
            orderOutOfWindowServer()
            if registeredSurfaceWindowNumber != nil {
                surfaceCoordinator.unregister(id: surfaceID)
                registeredSurfaceWindowNumber = nil
            }
            lastFrame = nil
            return
        }
        let orderingWindowId = command.orderingWindowId ?? currentInfo.activeWindowId
        let needsOrdering = !isOrderedIn || lastOrderingWindowId != orderingWindowId
        let alignedFrame = Self.appKitPlacement(of: frame)
        if frame != lastFrame || alignedFrame != appliedFrame {
            dismissHover()
            animationGeometryNeedsAccessibilityRefresh = true
            if frame.size != self.frame.size || !placeInWindowServer(alignedFrame) {
                railView.performWithoutAccessibilityGeometryUpdates {
                    setFrameReconcilingWindowServer(frame)
                    railView.needsDisplay = true
                }
            }
            lastFrame = frame
        }

        guard needsOrdering else { return }
        orderAbove(orderingWindowId)
        syncSurfaceRegistration()
        lastOrderingWindowId = orderingWindowId
    }

    private func orderAbove(_ target: Int?) {
        let target = target.flatMap(UInt32.init(exactly:))
        if !isVisible || target == nil { orderFront(nil) }
        if isOrderedOutInWindowServer {
            orderInWindowServer(above: target)
            isOrderedOutInWindowServer = false
        }
        if let target { orderDirectly(above: ringOrderedAbove?(target) ?? target) }
    }

    private func orderOutOfWindowServer() {
        guard isOrderedIn else { return }
        hideInWindowServer()
        isOrderedOutInWindowServer = true
    }

    func hideInWindowServer() {
        SkyLight.shared.transactionHide(UInt32(windowNumber))
    }

    func orderInWindowServer(above target: UInt32?) {
        SkyLight.shared.orderWindow(UInt32(windowNumber), relativeTo: target ?? 0)
    }

    func orderDirectly(above target: UInt32) {
        order(.above, directlyRelativeTo: target)
    }

    private func canKeepWindowServerPlacement(at target: CGRect) -> Bool {
        windowServerPlacement?.appKitFrame == frame
            && target.size == frame.size
            && staysOnItsDisplay(at: target)
    }

    func moveInWindowServer(to target: CGRect) -> Bool {
        SkyLight.shared.transactionMove(
            UInt32(windowNumber),
            origin: ScreenCoordinateSpace.toWindowServer(rect: target).origin
        )
    }

    private func placeInWindowServer(_ target: CGRect) -> Bool {
        guard moveInWindowServer(to: target) else { return false }
        windowServerPlacement = (frame, target)
        return true
    }

    private func setFrameReconcilingWindowServer(_ target: CGRect) {
        let previousAppliedFrame = appliedFrame
        let windowServerOriginDiverged = previousAppliedFrame != frame
        setFrame(target, display: false)
        railView.frame = CGRect(origin: .zero, size: target.size)
        if windowServerOriginDiverged, !moveInWindowServer(to: Self.appKitPlacement(of: target)) {
            setFrame(previousAppliedFrame, display: false)
            setFrame(target, display: false)
            railView.frame = CGRect(origin: .zero, size: target.size)
        }
        windowServerPlacement = nil
    }

    private static func appKitPlacement(of frame: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: frame.minX.rounded(.down), y: frame.minY.rounded(.down)), size: frame.size)
    }

    private func dismissHover() {
        onHoverPreview?(nil)
        railView.invalidateHover()
        hoverCard.hide()
    }

    private func updateHoverCard(tab: TabRailTabInfo?, itemRect: CGRect?) {
        guard let tab, let itemRect, let currentInfo, isOrderedIn else {
            onHoverPreview?(nil)
            hoverCard.hide()
            return
        }
        let screenFrame = screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(appliedFrame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        guard let screenFrame else {
            onHoverPreview?(nil)
            hoverCard.hide()
            return
        }
        if let token = tab.token, let handle = resolvePreviewHandle?(token) {
            let item = convertToScreen(itemRect)
            let preferred: PopupAttachment.Edge = style.options?.position == .top ? .below : .right
            var attachment = PopupAttachment(sourceFrame: item, edge: preferred)
            let available = attachment.availableSize(in: screenFrame)
            if (preferred == .below && available.height < 200) || (preferred == .right && available.width < 256) {
                let other = PopupAttachment(sourceFrame: item, edge: preferred == .below ? .above : .left)
                let alternate = other.availableSize(in: screenFrame)
                if preferred == .below ? alternate.height > available.height : alternate.width > available.width {
                    attachment = other
                }
            }
            let title = tab.title?.nilIfEmpty ?? tab.appName?.nilIfEmpty ?? String(localized: "Untitled window")
            onHoverPreview?(.init(key: .window(currentInfo.workspaceId, token),
                                  windows: [.init(handle: handle, title: title, appName: tab.appName ?? "", icon: tab.icon)],
                                  attachment: attachment, visibleFrame: screenFrame, level: .floating))
            return
        }
        onHoverPreview?(nil)
        guard style.options == nil else { return }
        let cardFrame = TabRailHoverCardPlacement.frame(
            railFrame: lastFrame ?? appliedFrame,
            itemRect: itemRect,
            cardSize: TabRailMetrics.hoverCardSize,
            visibleFrame: screenFrame,
            gap: TabRailMetrics.hoverCardGap
        )
        hoverCard.show(tab: tab, tabCount: currentInfo.tabCount, frame: cardFrame)
    }

    private func syncSurfaceRegistration() {
        let currentWindowNumber = windowNumber
        guard currentWindowNumber > 0 else {
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }
        guard registeredSurfaceWindowNumber != currentWindowNumber else { return }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: currentWindowNumber,
            frameProvider: { [weak self] in
                self?.lastFrame
            },
            visibilityProvider: { [weak self] in
                self?.isOrderedIn == true && self?.lastFrame != nil
            },
            policy: SurfacePolicy(
                kind: .tabRail,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredSurfaceWindowNumber = currentWindowNumber
    }

    private static func surfaceID(workspaceId: WorkspaceDescriptor.ID, owner: TabRailOwner) -> String {
        "tab-rail-\(workspaceId.uuidString)-\(owner.surfaceIdentifier)"
    }
}
