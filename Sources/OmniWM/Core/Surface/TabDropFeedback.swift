// SPDX-License-Identifier: GPL-2.0-only

import AppKit

enum TabBarAction {
    case drag(CGPoint, released: Bool)
    case geometry(TabFrameDrag, point: CGPoint, released: Bool)
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

struct TabFrameDrag {
    let start: CGPoint
    let frame: CGRect
    let handle: TabChromeHandle

    func frame(at point: CGPoint, minimum: CGSize) -> CGRect {
        let dx = point.x - start.x
        let dy = point.y - start.y
        if handle == .grip { return frame.offsetBy(dx: dx, dy: dy) }
        var result = frame
        switch handle {
        case .left, .topLeft, .bottomLeft:
            result.size.width = max(minimum.width, frame.width - dx)
            result.origin.x = frame.maxX - result.width
        case .right, .topRight, .bottomRight:
            result.size.width = max(minimum.width, frame.width + dx)
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight:
            result.size.height = max(minimum.height, frame.height + dy)
        case .bottomLeft, .bottomRight:
            result.size.height = max(minimum.height, frame.height - dy)
            result.origin.y = frame.maxY - result.height
        default: break
        }
        return result
    }
}

enum TabChromeHandle {
    case grip, left, right, top, topLeft, topRight, bottomLeft, bottomRight

    static func corners(in bounds: CGRect, position: TabbedBarOptions.Position) -> [(CGRect, Self)] {
        let side = min(10, bounds.width / 2, bounds.height / 2)
        return [false, true].flatMap { right in
            [false, true].map { top in
                let rect = CGRect(x: right ? bounds.maxX - side : bounds.minX,
                                  y: top ? bounds.maxY - side : bounds.minY, width: side, height: side)
                let handle: Self = position == .left ? (top ? .topLeft : .bottomLeft) : (right ? .topRight : .topLeft)
                return (rect, handle)
            }
        }
    }

    static func hit(_ point: CGPoint, bounds: CGRect, gripWidth: CGFloat, position: TabbedBarOptions.Position) -> Self? {
        if let corner = corners(in: bounds, position: position).first(where: { $0.0.contains(point) }) { return corner.1 }
        guard position == .top else { return nil }
        if point.x < bounds.minX + 4 { return .left }
        if point.x >= bounds.maxX - 4 { return .right }
        if point.y < bounds.minY + 3 || point.y >= bounds.maxY - 3 { return .top }
        return point.x < gripWidth ? .grip : nil
    }
}
