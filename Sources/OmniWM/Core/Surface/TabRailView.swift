// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class TabRailView: NSView {
    private var tabs: [TabRailTabInfo] = []
    private let trackView: TabRailTrackView
    private let motionPolicy: MotionPolicy
    private let appInfoCache: AppInfoCache
    private var iconView: TabRailIconView?
    private var style: TabRailStyle = .compact
    private var railLayout = TabRailLayout.empty

    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateTrackView()
            if !isHovered {
                onHoverChange?(nil, nil)
            }
        }
    }

    private var hoveredVisualIndex: Int? {
        didSet {
            guard oldValue != hoveredVisualIndex else { return }
            updateTrackView()
        }
    }

    private var tracking: NSTrackingArea?
    private var accessibilityTabElements: [TabRailAccessibilityElement] = []
    private var suppressAccessibilityGeometryUpdates = false

    private var tabCount: Int {
        tabs.count
    }

    private var activeVisualIndex = 0

    var onTabAction: ((WindowToken, TabBarAction) -> Void)?
    private var pressedTab: (token: WindowToken, start: CGPoint)?
    private var isDraggingTab = false
    var groupContentFrame: CGRect?
    private var chromePress: (token: WindowToken, start: CGPoint, frame: CGRect, edge: TabChromeHandle)?
    private var menuToken: WindowToken?

    var onSelect: ((Int) -> Void)?
    var onHoverChange: ((TabRailTabInfo?, CGRect?) -> Void)?

    init(frame frameRect: NSRect, motionPolicy: MotionPolicy, appInfoCache: AppInfoCache = AppInfoCache()) {
        self.motionPolicy = motionPolicy
        self.appInfoCache = appInfoCache
        trackView = TabRailTrackView(frame: .zero, motionPolicy: motionPolicy)
        super.init(frame: frameRect)
        addSubview(trackView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tabs: [TabRailTabInfo], activeVisualIndex: Int, style: TabRailStyle = .compact) {
        let styleChanged = self.style != style
        if styleChanged {
            invalidateHover()
            self.style = style
            configureStyle()
        }
        let metadataChanged = !Self.hasSameAccessibilityMetadata(self.tabs, tabs)
        let tabsChanged = self.tabs != tabs
        let activeChanged = self.activeVisualIndex != activeVisualIndex
        let countChanged = self.tabs.count != tabs.count
        self.tabs = tabs
        self.activeVisualIndex = activeVisualIndex
        if style != .compact {
            iconView?.update(tabs: tabs, activeVisualIndex: activeVisualIndex)
        }
        updateTrackView(rebuildLayout: countChanged || activeChanged || styleChanged)

        if metadataChanged || styleChanged {
            refreshAccessibilityElements()
        } else if activeChanged {
            refreshAccessibilityFrames()
            updateAccessibilitySelection(postNotification: true)
        }
        if tabsChanged || activeChanged {
            notifyHoverChange()
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        super.setFrameSize(newSize)
        guard sizeChanged else { return }
        iconView?.frame = bounds
        updateTrackView(rebuildLayout: true)
        if !suppressAccessibilityGeometryUpdates {
            refreshAccessibilityElements()
        }
    }

    func performWithoutAccessibilityGeometryUpdates(_ body: () -> Void) {
        suppressAccessibilityGeometryUpdates = true
        body()
        suppressAccessibilityGeometryUpdates = false
    }

    func refreshAppearance() {
        trackView.refreshAppearance()
        iconView?.refreshAppearance()
        updateTrackView()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateTrackView(rebuildLayout: true)
        refreshAccessibilityFrames()
    }

    func invalidateHover() {
        isHovered = false
        hoveredVisualIndex = nil
    }

    func refreshAccessibilityFrames() {
        let items = currentLayout().items
        guard items.count == accessibilityTabElements.count,
              zip(accessibilityTabElements, items).allSatisfy({ pair in
                  pair.0.visualIndex == pair.1.visualIndex
              })
        else {
            refreshAccessibilityElements()
            NSAccessibility.post(element: self, notification: .layoutChanged)
            return
        }
        for (element, item) in zip(accessibilityTabElements, items) {
            element.updateScreenFrame(screenFrame(for: item.hitRect))
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let nextTracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = nextTracking
        addTrackingArea(nextTracking)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredVisualIndex(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredVisualIndex(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        invalidateHover()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handle = chromeHandle(at: point), let frame = groupContentFrame,
           let active = tabs.first(where: { $0.visualIndex == activeVisualIndex })?.token {
            chromePress = (active, screenPoint(event), frame, handle)
            invalidateHover()
            return
        }
        guard let item = item(at: point) else { return }
        if style.options != nil, let token = tabs.first(where: { $0.visualIndex == item.visualIndex })?.token {
            pressedTab = (token, screenPoint(event))
            isDraggingTab = false
        }
        onSelect?(item.visualIndex)
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        window?.convertToScreen(CGRect(origin: event.locationInWindow, size: .zero)).origin ?? NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        if updateChromePress(event, released: false) { return }
        guard let press = pressedTab else { return }
        let point = screenPoint(event)
        guard isDraggingTab || hypot(point.x - press.start.x, point.y - press.start.y) >= 5 else { return }
        isDraggingTab = true
        invalidateHover()
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local), let slot = insertion(at: local) {
            iconView?.previewDrag(token: press.token, at: point, from: press.start, before: slot.before)
        } else {
            iconView?.clearDragPreview()
        }
        onTabAction?(press.token, .drag(point, released: false))
    }

    func cancelDrag() -> Bool {
        guard isDraggingTab, let press = pressedTab else { return false }
        pressedTab = nil
        isDraggingTab = false
        iconView?.clearDragPreview()
        onTabAction?(press.token, .cancel)
        return true
    }

    override func mouseUp(with event: NSEvent) {
        if updateChromePress(event, released: true) { return }
        defer {
            pressedTab = nil
            isDraggingTab = false
            iconView?.clearDragPreview()
        }
        guard let press = pressedTab, isDraggingTab else { return }
        onTabAction?(press.token, .drag(screenPoint(event), released: true))
    }

    private func chromeHandle(at point: CGPoint) -> TabChromeHandle? {
        guard style.options?.position == .top else { return nil }
        return TabChromeHandle.hit(point, bounds: bounds, gripWidth: iconView?.gripWidth ?? 0)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard style.options?.position == .top else { return }
        let grip = CGRect(x: 4, y: 3, width: max(0, (iconView?.gripWidth ?? 0) - 4), height: max(0, bounds.height - 6))
        addCursorRect(grip, cursor: .openHand)
        for y in [bounds.minY, bounds.maxY - 3] {
            addCursorRect(CGRect(x: 0, y: y, width: bounds.width, height: 3), cursor: .resizeUpDown)
        }
        for x in [bounds.minX, bounds.maxX - 4] {
            addCursorRect(CGRect(x: x, y: 0, width: 4, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    private func updateChromePress(_ event: NSEvent, released: Bool) -> Bool {
        guard let press = chromePress else { return false }
        if released { chromePress = nil }
        let point = screenPoint(event)
        let frame = press.edge.frame(from: press.frame, dx: point.x - press.start.x, dy: point.y - press.start.y)
        onTabAction?(press.token, .geometry(frame, released: released, resizing: press.edge != .grip))
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard style.options != nil, let item = item(at: convert(event.locationInWindow, from: nil)),
              let token = tabs.first(where: { $0.visualIndex == item.visualIndex })?.token else { return nil }
        menuToken = token
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Move Tab to New Window"), action: #selector(popTab), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Close Tab"), action: #selector(closeTab), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Ungroup All Windows"), action: #selector(ungroupAll), keyEquivalent: "").target = self
        return menu
    }

    @objc private func ungroupAll() { if let menuToken { onTabAction?(menuToken, .ungroupAll) } }
    @objc private func popTab() { if let menuToken { onTabAction?(menuToken, .detach) } }
    @objc private func closeTab() { if let menuToken { onTabAction?(menuToken, .close) } }

    func insertion(at point: CGPoint) -> (before: WindowToken?, marker: CGRect)? {
        let horizontal = style.options?.position == .top
        let items = currentLayout().items.filter { !$0.hitRect.isEmpty }
        guard let last = items.last else { return nil }
        let next = items.first { horizontal ? point.x < $0.hitRect.midX : point.y > $0.hitRect.midY }
        let rect = (next ?? last).hitRect
        let index = next?.visualIndex ?? last.visualIndex + 1
        let before = tabs.first(where: { $0.visualIndex == index })?.token
        let marker = horizontal
            ? CGRect(x: (next == nil ? rect.maxX - 3 : rect.minX), y: rect.minY + 3, width: 3, height: max(1, rect.height - 6))
            : CGRect(x: rect.minX + 3, y: (next == nil ? rect.minY : rect.maxY - 3), width: max(1, rect.width - 6), height: 3)
        return (before, screenFrame(for: marker))
    }

    override func scrollWheel(with event: NSEvent) {
        if style != .compact {
            iconView?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func item(at point: CGPoint) -> TabRailLayout.Item? {
        if style != .compact {
            return currentLayout().items.first { !$0.hitRect.isEmpty && $0.hitRect.contains(point) }
        }
        guard railLayout.railRect.contains(point) else { return nil }
        let markerRects = trackView.presentedMarkerRects()
        let hitRects = TabRailSegmentGeometry.hitRects(markerRects: markerRects, railRect: railLayout.railRect)
        guard let item = railLayout.items.first(where: { hitRects[$0.visualIndex]?.contains(point) == true }),
              let hitRect = hitRects[item.visualIndex],
              let markerRect = markerRects[item.visualIndex] else { return nil }
        return .init(visualIndex: item.visualIndex, hitRect: hitRect, pillRect: markerRect)
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityTabElements
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityTabElements.filter(\.isSelected)
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Window tabs")
    }

    override func accessibilityValue() -> Any? {
        guard tabCount > 0 else { return String(localized: "No tabs") }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)
        return String(localized: "Tab \(clampedActiveVisualIndex + 1) of \(tabCount) selected")
    }

    override func accessibilityHelp() -> String? {
        if style.options != nil {
            return String(localized: "Drag a tab to reorder it, move it to another group, or place its window on the desktop.")
        }
        return style != .compact
            ? String(localized: "Click an app icon to select its window. Scroll to see more tabs.")
            : String(localized: "Click a segment to select that tab.")
    }

    private func updateHoveredVisualIndex(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let item = item(at: point)
        let changed = !isHovered || hoveredVisualIndex != item?.visualIndex
        isHovered = item != nil
        hoveredVisualIndex = item?.visualIndex
        guard changed else { return }
        let tab = tabs.first { $0.visualIndex == item?.visualIndex }
        onHoverChange?(tab, item?.pillRect)
    }

    private func updateTrackView(rebuildLayout: Bool = false) {
        guard style == .compact else {
            iconView?.updateHover(hoveredVisualIndex)
            return
        }
        if rebuildLayout {
            railLayout = TabRailLayout(
                tabCount: tabCount,
                bounds: bounds,
                activeVisualIndex: activeVisualIndex,
                scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            )
            trackView.frame = railLayout.barRect
        }
        trackView.update(
            layout: railLayout,
            activeVisualIndex: activeVisualIndex,
            hoveredVisualIndex: hoveredVisualIndex,
            railHovered: isHovered
        )
    }

    private func notifyHoverChange() {
        guard isHovered,
              let hoveredVisualIndex,
              let tab = tabs.first(where: { $0.visualIndex == hoveredVisualIndex }),
              let item = currentLayout().items.first(where: { $0.visualIndex == hoveredVisualIndex })
        else {
            onHoverChange?(nil, nil)
            return
        }
        onHoverChange?(tab, item.pillRect)
    }

    private func currentLayout() -> TabRailLayout {
        style != .compact ? (iconView?.railLayout(in: self) ?? .empty) : railLayout
    }

    private func configureStyle() {
        iconView?.removeFromSuperview()
        trackView.isHidden = style != .compact
        if style != .compact {
            let icons = TabRailIconView(motionPolicy: motionPolicy, appInfoCache: appInfoCache)
            icons.options = style.options
            icons.frame = bounds
            icons.onWillScroll = { [weak self] in self?.invalidateHover() }
            icons.onDidScroll = { [weak self] in
                guard let self, !suppressAccessibilityGeometryUpdates else { return }
                refreshAccessibilityFrames()
            }
            iconView = icons
            addSubview(icons)
        } else {
            iconView?.removeFromSuperview()
            iconView = nil
        }
    }
}

extension TabRailView {
    private func refreshAccessibilityElements() {
        let layout = currentLayout()
        let tabsByVisualIndex = Dictionary(tabs.map { ($0.visualIndex, $0) }, uniquingKeysWith: { first, _ in first })
        let existingElements = Dictionary(
            accessibilityTabElements.map { ($0.visualIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        accessibilityTabElements = layout.items.compactMap { item in
            guard let tab = tabsByVisualIndex[item.visualIndex] else {
                return nil
            }
            let screenFrame = screenFrame(for: item.hitRect)
            if let element = existingElements[item.visualIndex] {
                element.update(tab: tab, screenFrame: screenFrame)
                return element
            }
            let element = TabRailAccessibilityElement(
                parent: self,
                tab: tab,
                screenFrame: screenFrame,
                pressAction: { [weak self] visualIndex in
                    _ = self?.performAccessibilitySelection(visualIndex)
                },
                revealAction: { [weak self] visualIndex in
                    self?.iconView?.reveal(visualIndex)
                }
            )
            return element
        }
        updateAccessibilitySelection(postNotification: false)
    }

    private func updateAccessibilitySelection(postNotification: Bool) {
        for element in accessibilityTabElements {
            element.updateSelected(element.visualIndex == activeVisualIndex, postNotification: postNotification)
        }
    }

    private func performAccessibilitySelection(_ visualIndex: Int) -> Bool {
        guard tabs.contains(where: { $0.visualIndex == visualIndex }) else { return false }
        iconView?.reveal(visualIndex)
        onSelect?(visualIndex)
        return true
    }

    private func screenFrame(for rect: CGRect) -> CGRect {
        guard let window, !rect.isEmpty else { return .zero }
        let windowRect = convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    private static func hasSameAccessibilityMetadata(
        _ lhs: [TabRailTabInfo],
        _ rhs: [TabRailTabInfo]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.visualIndex == right.visualIndex,
                  left.windowId == right.windowId,
                  left.appName == right.appName,
                  left.title == right.title
            else {
                return false
            }
        }
        return true
    }
}
