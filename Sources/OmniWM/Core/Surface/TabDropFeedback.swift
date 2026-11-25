// SPDX-License-Identifier: GPL-2.0-only

import AppKit

enum TabBarAction {
    case drag(CGPoint, released: Bool)
    case geometry(CGRect, released: Bool, resizing: Bool)
    case ungroupAll
    case detach
    case close
    case cancel
}

/// A single pointer-transparent panel shows either the insertion caret, the receiving
/// title bar, or the proposed free window frame. It never takes focus from the app.
@MainActor
final class TabDropFeedback {
    private var panel: NSPanel?

    private var capture: Task<Void, Never>?
    private var previewToken: WindowToken?

    func show(_ frame: CGRect, caret: Bool = false, window token: WindowToken? = nil) {
        let panel = panel ?? makePanel()
        let color = NSColor.controlAccentColor
        panel.contentView?.layer?.backgroundColor = color.withAlphaComponent(caret ? 1 : 0.12).cgColor
        panel.contentView?.layer?.borderColor = color.cgColor
        panel.contentView?.layer?.cornerRadius = caret ? 1.5 : 9
        if previewToken != token {
            clearPreview()
            previewToken = token
            if let token, ScreenCapturePermissionMonitor.shared.isGranted {
                capture = Task { [weak self] in
                    let size = CGSize(width: max(1, frame.width.rounded()), height: max(1, frame.height.rounded()))
                    let image = await DragGhostController.captureWindowImage(token: token, pixelSize: size, previews: .shared)
                    guard !Task.isCancelled, self?.previewToken == token else { return }
                    self?.panel?.contentView?.layer?.contents = image
                }
            }
        }
        panel.alphaValue = token == nil ? 1 : 0.82
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func clearPreview() {
        capture?.cancel()
        capture = nil
        previewToken = nil
        panel?.contentView?.layer?.contents = nil
    }

    func hide() {
        clearPreview()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.masksToBounds = true
        panel.contentView?.layer?.borderWidth = 2
        self.panel = panel
        return panel
    }
}

enum TabChromeHandle {
    case grip, left, right, top, topLeft, topRight

    static func hit(_ point: CGPoint, bounds: CGRect, gripWidth: CGFloat) -> Self? {
        let rim = point.y < bounds.minY + 3 || point.y >= bounds.maxY - 3
        if point.x < bounds.minX + (rim ? 9 : 4) { return rim ? .topLeft : .left }
        if point.x >= bounds.maxX - (rim ? 9 : 4) { return rim ? .topRight : .right }
        if rim { return .top }
        return point.x < gripWidth ? .grip : nil
    }

    func frame(from frame: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        if self == .grip { return frame.offsetBy(dx: dx, dy: dy) }
        var result = frame
        if self == .left || self == .topLeft {
            result.size.width = max(1, frame.width - dx)
            result.origin.x = frame.maxX - result.width
        }
        if self == .right || self == .topRight { result.size.width = max(1, frame.width + dx) }
        if self == .top || self == .topLeft || self == .topRight { result.size.height = max(1, frame.height + dy) }
        return result
    }
}
