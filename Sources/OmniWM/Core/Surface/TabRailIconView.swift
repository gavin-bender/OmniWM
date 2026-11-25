// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class TabRailIconView: NSVisualEffectView {
    let scrollView = NSScrollView()
    var options: TabbedBarOptions?
    private var isHorizontal: Bool { options?.position == .top }
    private let grip = NSImageView()
    private let document = TabRailIconDocumentView()
    private let motionPolicy: MotionPolicy
    private let appInfoCache: AppInfoCache
    private var tokens: [WindowToken?] = []
    private(set) var rows: [TabRailIconRowView] = []
    private var activeVisualIndex = 0
    private var hoveredVisualIndex: Int?
    var onWillScroll: (() -> Void)?
    var onDidScroll: (() -> Void)?

    init(motionPolicy: MotionPolicy, appInfoCache: AppInfoCache) {
        self.motionPolicy = motionPolicy
        self.appInfoCache = appInfoCache
        super.init(frame: .zero)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = TabRailMetrics.trackCornerRadius
        layer?.masksToBounds = true
        let clip = scrollView.contentView
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: clip
        )
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = document
        addSubview(scrollView)
        let gripImage = NSImage(size: CGSize(width: 10, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            for x in [1, 6] {
                for y in [1, 6, 11] {
                    NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 3, height: 3)).fill()
                }
            }
            return true
        }
        gripImage.isTemplate = true
        grip.image = gripImage
        grip.contentTintColor = .secondaryLabelColor
        grip.imageScaling = .scaleProportionallyUpOrDown
        grip.setAccessibilityElement(false)
        addSubview(grip)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func scrollWheel(with event: NSEvent) {
        onWillScroll?()
        if isHorizontal {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            let origin = scrollView.contentView.bounds.origin
            scroll(to: CGPoint(x: origin.x - delta * (event.hasPreciseScrollingDeltas ? 1 : 10), y: 0))
        } else {
            scrollView.scrollWheel(with: event)
        }
    }

    @objc private func clipBoundsChanged() {
        onWillScroll?()
        needsDisplay = true
        onDidScroll?()
    }

    var gripWidth: CGFloat { isHorizontal ? min(24, bounds.width / 5) : 0 }

    override func setFrameSize(_ newSize: NSSize) {
        let wasEmpty = bounds.height == 0
        super.setFrameSize(newSize)
        grip.isHidden = !isHorizontal
        grip.frame = CGRect(x: (gripWidth - 10) / 2, y: (bounds.height - 16) / 2, width: 10, height: 16)
        scrollView.frame = CGRect(x: gripWidth, y: 0, width: bounds.width - gripWidth, height: bounds.height)
        layoutRows()
        if wasEmpty, newSize.height > 0 { reveal(activeVisualIndex) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func update(tabs: [TabRailTabInfo], activeVisualIndex: Int) {
        let nextTokens = tabs.map(\.token)
        let membershipChanged = tokens != nextTokens || rows.count != tabs.count
        let activeChanged = self.activeVisualIndex != activeVisualIndex
        if membershipChanged {
            rebuildRows(tabs: tabs, tokens: nextTokens)
        }
        for (tab, row) in zip(tabs, rows) {
            row.configure(tab: tab, options: options, appInfoCache: appInfoCache)
        }
        self.activeVisualIndex = activeVisualIndex
        updateSelection(animate: activeChanged && !membershipChanged)
        if membershipChanged || activeChanged {
            reveal(activeVisualIndex)
        }
    }

    func updateHover(_ visualIndex: Int?) {
        guard hoveredVisualIndex != visualIndex else { return }
        hoveredVisualIndex = visualIndex
        updateSelection(animate: false)
    }

    func previewDrag(token: WindowToken, at point: CGPoint, from start: CGPoint, before anchor: WindowToken?) {
        guard let source = tokens.firstIndex(of: token), rows.indices.contains(source) else { return }
        let insertion = anchor.flatMap { tokens.firstIndex(of: $0) } ?? rows.count
        let destination = insertion > source ? insertion - 1 : insertion
        for (index, row) in rows.enumerated() {
            guard let layer = row.layer else { continue }
            let offset: CGFloat
            if index == source {
                offset = isHorizontal ? point.x - start.x : point.y - start.y
            } else {
                let step = isHorizontal ? row.frame.width : -row.frame.height
                if index > source && index <= destination { offset = -step }
                else if index < source && index >= destination { offset = step }
                else { offset = 0 }
            }
            let transform = CATransform3DMakeTranslation(isHorizontal ? offset : 0, isHorizontal ? 0 : offset, 0)
            guard !CATransform3DEqualToTransform(layer.transform, transform) else { continue }
            let previous = layer.presentation()?.transform ?? layer.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = transform
            layer.zPosition = index == source ? 1 : 0
            CATransaction.commit()
            if index != source && motionPolicy.animationsEnabled {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = NSValue(caTransform3D: previous)
                animation.toValue = NSValue(caTransform3D: transform)
                animation.duration = 0.13
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "tabShift")
            }
        }
    }

    func clearDragPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in rows {
            row.layer?.removeAnimation(forKey: "tabShift")
            row.layer?.transform = CATransform3DIdentity
            row.layer?.zPosition = 0
        }
        CATransaction.commit()
    }

    func reveal(_ visualIndex: Int) {
        guard rows.indices.contains(visualIndex) else { return }
        let rect = rows[visualIndex].frame
        let visible = scrollView.contentView.bounds
        var origin = visible.origin
        if isHorizontal {
            if rect.minX < visible.minX { origin.x = rect.minX }
            else if rect.maxX > visible.maxX { origin.x = rect.maxX - visible.width }
        } else if rect.height > visible.height {
            origin.y = rect.midY - visible.height / 2
        } else if rect.minY < visible.minY {
            origin.y = rect.minY
        } else if rect.maxY > visible.maxY {
            origin.y = rect.maxY - visible.height
        }
        scroll(to: origin)
    }

    func railLayout(in view: NSView) -> TabRailLayout {
        let viewport = convert(scrollView.frame, to: view)
        let items = rows.enumerated().map { index, row in
            let hit = document.convert(row.frame, to: view).intersection(viewport)
            let icon = row.convert(row.imageView.frame, to: view).intersection(viewport)
            return TabRailLayout.Item(
                visualIndex: index,
                hitRect: hit.isNull ? .zero : hit,
                pillRect: icon.isNull ? (hit.isNull ? .zero : hit) : icon
            )
        }
        return TabRailLayout(railRect: viewport, barRect: viewport, items: items)
    }

    func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material = reduceTransparency ? .windowBackground : .hudWindow
        blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
        layer?.borderColor = TabRailMetrics.trackBorderColor.cgColor
        layer?.borderWidth = TabRailMetrics.trackBorderWidth
        for row in rows { row.refreshAppearance() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHorizontal { return }
        let visible = scrollView.contentView.bounds
        NSColor.labelColor.withAlphaComponent(0.7).setStroke()
        if visible.minY > 0 {
            drawEdgeCue(at: bounds.maxY - 2, direction: -1)
        }
        if visible.maxY < document.bounds.height {
            drawEdgeCue(at: bounds.minY + 2, direction: 1)
        }
    }

    private func drawEdgeCue(at y: CGFloat, direction: CGFloat) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.midX - 3, y: y + direction * 2))
        path.line(to: CGPoint(x: bounds.midX, y: y))
        path.line(to: CGPoint(x: bounds.midX + 3, y: y + direction * 2))
        path.lineWidth = 1
        path.stroke()
    }

    private func rebuildRows(tabs: [TabRailTabInfo], tokens nextTokens: [WindowToken?]) {
        var reusable: [WindowToken: TabRailIconRowView] = [:]
        for (token, row) in zip(tokens, rows) {
            if let token { reusable[token] = row }
            row.removeFromSuperview()
        }
        tokens = nextTokens
        rows = tabs.map { tab in
            let row = tab.token.flatMap { reusable.removeValue(forKey: $0) }
                ?? TabRailIconRowView(
                    image: tab.icon ?? tab.token.flatMap { appInfoCache.info(for: $0.pid)?.icon },
                    motionPolicy: motionPolicy
                )
            document.addSubview(row)
            return row
        }
        layoutRows()
    }

    private func layoutRows() {
        let rowHeight = options?.rowHeight ?? TabRailStyle.iconRowHeight
        if isHorizontal {
            let rowWidth = options?.content == .icons ? rowHeight
                : max(rowHeight * 2.5, scrollView.frame.width / CGFloat(max(1, rows.count)))
            document.setFrameSize(CGSize(width: max(scrollView.frame.width, CGFloat(rows.count) * rowWidth), height: bounds.height))
            for (index, row) in rows.enumerated() {
                row.frame = CGRect(x: CGFloat(index) * rowWidth, y: 0, width: rowWidth, height: bounds.height)
            }
            scroll(to: scrollView.contentView.bounds.origin)
            return
        }
        document.setFrameSize(CGSize(width: bounds.width, height: CGFloat(rows.count) * rowHeight))
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
        }
        scroll(to: scrollView.contentView.bounds.origin)
    }

    private func scroll(to origin: CGPoint) {
        let clip = scrollView.contentView
        let maxOffset = max(0, document.bounds.height - clip.bounds.height)
        onWillScroll?()
        clip.scroll(to: CGPoint(x: min(max(0, origin.x), max(0, document.bounds.width - clip.bounds.width)), y: min(max(0, origin.y), maxOffset)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateSelection(animate: Bool) {
        for (index, row) in rows.enumerated() {
            row.update(selected: index == activeVisualIndex, hovered: index == hoveredVisualIndex, animate: animate)
        }
    }
}

private final class TabRailIconDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
