// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class WorkspaceBarHostingView: NSHostingView<WorkspaceBarView> {
    static let widgetType = NSPasteboard.PasteboardType("com.omniwm.bar-widget")

    private var pressed: (slot: ShellWidgetClipView, point: CGPoint, profile: String)?
    private var dragSource: WidgetDragSource?
    private let insertionMark = CALayer()

    private var panel: WorkspaceBarPanel? { window as? WorkspaceBarPanel }

    private func slots(in view: NSView) -> [ShellWidgetClipView] {
        if let slot = view as? ShellWidgetClipView { return [slot] }
        return view.subviews.flatMap { slots(in: $0) }
    }

    private func slot(at point: CGPoint) -> ShellWidgetClipView? {
        slots(in: self).first { $0.visibleWidgetRect.contains($0.convert(point, from: self)) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown,
           event.modifierFlags.contains(.command), panel?.widgetProfile?() != nil,
           slot(at: convert(point, from: superview)) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.modifierFlags.contains(.command), let slot = slot(at: point),
              let profile = panel?.widgetProfile?() else { return super.mouseDown(with: event) }
        pressed = (slot, point, profile)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed != nil else { return super.mouseUp(with: event) }
        pressed = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) >= 3 else { return }
        let slot = pressed.slot
        let rect = slot.visibleWidgetRect
        guard slot.window === window, !rect.isEmpty, let bitmap = slot.bitmapImageRepForCachingDisplay(in: rect)
        else { return }
        slot.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        let payload = NSPasteboardItem()
        payload.setString(slot.widgetName, forType: Self.widgetType)
        let item = NSDraggingItem(pasteboardWriter: payload)
        item.setDraggingFrame(convert(rect, from: slot), contents: image)
        let source = WidgetDragSource(name: slot.widgetName, profile: pressed.profile)
        dragSource = source
        self.pressed = nil
        beginDraggingSession(with: [item], event: event, source: source)
    }

    private func destination(_ sender: any NSDraggingInfo) -> (name: String, after: Bool, mark: CGRect)? {
        guard let drag = sender.draggingSource as? WidgetDragSource,
              drag.profile == panel?.widgetProfile?() else { return nil }
        return destination(at: convert(sender.draggingLocation, from: nil), moving: drag.name)
    }

    func destination(at point: CGPoint, moving name: String) -> (name: String, after: Bool, mark: CGRect)? {
        let vertical = rootView.model.snapshot.orientation.isVertical
        guard bounds.contains(point) else { return nil }
        let axis = vertical ? point.y : point.x
        var nearest: (name: String, after: Bool, mark: CGRect)?
        var distance = CGFloat.infinity
        for slot in slots(in: self) where !slot.visibleWidgetRect.isEmpty {
            let frame = convert(slot.visibleWidgetRect, from: slot)
            let low = vertical ? frame.minY : frame.minX
            let high = vertical ? frame.maxY : frame.maxX
            let gap = max(low - axis, axis - high, 0)
            guard gap < distance else { continue }
            distance = gap
            let upper = axis >= (low + high) / 2
            let edge = upper ? high : low
            let mark = vertical
                ? CGRect(x: frame.minX, y: edge - 1, width: frame.width, height: 2)
                : CGRect(x: edge - 1, y: frame.minY, width: 2, height: frame.height)
            let after = vertical && !isFlipped ? !upper : upper
            nearest = slot.widgetName == name ? nil : (slot.widgetName, after, mark)
        }
        return nearest
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let target = destination(sender) else {
            insertionMark.removeFromSuperlayer()
            return []
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insertionMark.zPosition = 1
        insertionMark.frame = target.mark
        insertionMark.backgroundColor = NSColor.controlAccentColor.cgColor
        if insertionMark.superlayer == nil { layer?.addSublayer(insertionMark) }
        CATransaction.commit()
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        insertionMark.removeFromSuperlayer()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        insertionMark.removeFromSuperlayer()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        destination(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        insertionMark.removeFromSuperlayer()
        guard let drag = sender.draggingSource as? WidgetDragSource,
              let target = destination(sender), let move = panel?.moveWidget else { return false }
        move(drag.profile, drag.name, target.name, target.after)
        return true
    }
}

@MainActor
private final class WidgetDragSource: NSObject, NSDraggingSource {
    let name: String
    let profile: String

    init(name: String, profile: String) {
        self.name = name
        self.profile = profile
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

private extension ShellWidgetClipView {
    var visibleWidgetRect: CGRect {
        bounds.intersection(visibleRect)
    }
}
