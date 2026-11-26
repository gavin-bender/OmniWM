// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class TabRailIconRowView: NSView {
    let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    var onClose: ((WindowToken) -> Void)?
    private var token: WindowToken?
    private var options: TabbedBarOptions?
    let selectionLayer = CAShapeLayer()
    private let motionPolicy: MotionPolicy
    private var selected = false
    private var hovered = false

    init(image: NSImage?, motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
        super.init(frame: .zero)
        wantsLayer = true
        selectionLayer.fillColor = NSColor.clear.cgColor
        selectionLayer.actions = [
            "path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
            "bounds": NSNull(), "position": NSNull()
        ]
        layer?.addSublayer(selectionLayer)
        imageView.image = image ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setAccessibilityElement(false)
        titleField.isHidden = true
        addSubview(titleField)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        closeButton.toolTip = String(localized: "Close Tab")
        closeButton.setAccessibilityLabel(String(localized: "Close Tab"))
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    func configure(tab: TabRailTabInfo, options: TabbedBarOptions?, appInfoCache: AppInfoCache) {
        self.options = options
        token = tab.token
        closeButton.isHidden = options == nil || token == nil
        titleField.isHidden = options == nil || options?.content == .icons
        imageView.isHidden = options?.content == .titles
        titleField.stringValue = tab.title?.nilIfEmpty ?? tab.appName?.nilIfEmpty ?? String(localized: "Tab \(tab.visualIndex + 1)")
        if let image = tab.icon ?? tab.token.flatMap({ appInfoCache.info(for: $0.pid)?.icon }) {
            imageView.image = image
        }
        layoutContents()
    }

    @objc private func closePressed() {
        if let token { onClose?(token) }
    }

    private func layoutContents() {
        let trailing = closeButton.isHidden ? 0 : TabbedBarOptions.closeButtonWidth
        let available = max(0, bounds.width - trailing)
        closeButton.frame = CGRect(x: available, y: (bounds.height - 20) / 2, width: trailing, height: 20)
        let size = min(available, bounds.height, options.map { $0.rowHeight - 10 } ?? TabRailStyle.iconSize)
        imageView.frame = CGRect(x: titleField.isHidden ? (available - size) / 2 : 5, y: (bounds.height - size) / 2, width: size, height: size)
        if !titleField.isHidden {
            titleField.font = .systemFont(ofSize: options?.size == .large ? 15 : 13)
            let start = imageView.isHidden ? 7 : imageView.frame.maxX + 5
            let height = titleField.intrinsicContentSize.height
            titleField.frame = CGRect(x: start, y: (bounds.height - height) / 2, width: max(0, available - start - 5), height: height)
        }
        selectionLayer.frame = bounds
        selectionLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 5, cornerHeight: 5, transform: nil
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        selectionLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func update(selected: Bool, hovered: Bool, animate: Bool) {
        let changed = self.selected != selected
        guard changed || self.hovered != hovered else { return }
        self.selected = selected
        self.hovered = hovered
        updateAppearance(animate: animate && changed && motionPolicy.animationsEnabled)
    }

    func refreshAppearance() {
        updateAppearance(animate: false)
    }

    private func updateAppearance(animate: Bool) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let fill = selected
            ? NSColor.controlAccentColor.withAlphaComponent(highContrast ? 0.45 : 0.25)
            : (hovered ? TabRailMetrics.hoverColor : NSColor.clear)
        let fromColor = selectionLayer.presentation()?.fillColor ?? selectionLayer.fillColor
        selectionLayer.removeAnimation(forKey: "selection.color")
        selectionLayer.fillColor = fill.cgColor
        selectionLayer.strokeColor = selected ? NSColor.labelColor.withAlphaComponent(highContrast ? 1 : 0.65)
            .cgColor : nil
        selectionLayer.lineWidth = highContrast ? 2 : 1
        guard animate, let fromColor else { return }
        let animation = CABasicAnimation(keyPath: "fillColor")
        animation.fromValue = fromColor
        animation.toValue = fill.cgColor
        animation.duration = 0.25
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        selectionLayer.add(animation, forKey: "selection.color")
    }
}
