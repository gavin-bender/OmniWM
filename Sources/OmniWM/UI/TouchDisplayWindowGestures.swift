// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Darwin

extension MouseEventHandler {
    var canStartTouchDisplayWindowGestures: Bool {
        guard #available(macOS 27.0, *), let controller else { return false }
        return controller.hasStartedServices && controller.isEnabled && !controller.isOverviewOpen() && !isInputSuppressed
            && TouchDisplayWindowGestures.builtInTouchScreen() != nil
    }

    func startTouchDisplayWindowGestures() {
        guard #available(macOS 27.0, *), canStartTouchDisplayWindowGestures,
              let screen = TouchDisplayWindowGestures.builtInTouchScreen()
        else { return }
        touchDisplayWindowGestures.show(on: screen)
    }
}

@MainActor
final class TouchDisplayWindowGestures: NSObject, NSWindowDelegate {
    private static let surfaceId = "touch-display-window-gestures"
    private static let isPROLEDMac: Bool = {
        // macOS can report touch capability on every screen when Sidecar is connected.
        var model = [UInt8](repeating: 0, count: 32)
        var length = model.count
        guard model.withUnsafeMutableBytes({ sysctlbyname("hw.model", $0.baseAddress, &length, nil, 0) }) == 0
        else { return false }
        switch String(decoding: model.prefix { $0 != 0 }, as: UTF8.self) {
        case "Mac17,10", "Mac17,11", "Mac17,12", "Mac17,13": return true
        default: return false
        }
    }()
    private weak var mouse: MouseEventHandler?
    private var panel: NonactivatingPanel?
    private var activePan: NSPanGestureRecognizer?
    private var display: CGDirectDisplayID?
    private var workspace: WorkspaceDescriptor.ID?
    private var timeout: Task<Void, Never>?
    private let dismissalMonitor = PanelDismissalMonitor()

    init(mouse: MouseEventHandler) {
        self.mouse = mouse
    }

    @available(macOS 27.0, *)
    static func builtInTouchScreen() -> NSScreen? {
        guard isPROLEDMac else { return nil }
        return NSScreen.screens.first { screen in
            guard let display = screen.displayId else { return false }
            return CGDisplayIsBuiltin(display) != 0 && screen.touchCapabilities.contains(.multiTouch)
        }
    }

    @available(macOS 27.0, *)
    func show(on screen: NSScreen) {
        guard panel == nil, let controller = mouse?.controller, let display = screen.displayId else { return }
        let panel = NonactivatingPanel(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.12)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle]

        let content = NSView(frame: CGRect(origin: .zero, size: screen.visibleFrame.size))
        // AppKit delivers direct touch to the hit-tested view. Capture it only while this panel is open.
        content.allowedTouchTypes = .direct
        // macOS uses three fingers for its built-in Touch Display swipes by default.
        for fingerCount in [1, 2, 4] {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.allowedTouchTypes = .direct
            pan.buttonMask = 0
            pan.minimumNumberOfTouches = fingerCount
            pan.maximumNumberOfTouches = 0
            content.addGestureRecognizer(pan)
        }

        let instructions = NSTextField(wrappingLabelWithString: String(
            localized: "One-finger drag to move. Two-finger drag near an edge to resize. Four-finger swipe to switch workspaces."
        ))
        instructions.alignment = .center
        instructions.textColor = .labelColor
        instructions.font = .systemFont(ofSize: 15, weight: .medium)
        instructions.translatesAutoresizingMaskIntoConstraints = false
        let banner = NSVisualEffectView()
        banner.material = .hudWindow
        banner.blendingMode = .withinWindow
        banner.state = .active
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 12
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(instructions)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelTouchMode))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(cancel)
        content.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            banner.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            banner.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            instructions.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            instructions.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
            instructions.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 16),
            instructions.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12)
        ])
        panel.contentView = content
        panel.delegate = self
        self.panel = panel
        self.display = display
        controller.ownedWindowRegistry.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: .init(
                kind: .utility, hitTestPolicy: .passthrough, capturePolicy: .excluded,
                suppressesManagedFocusRecovery: true
            )
        )
        panel.makeKeyAndOrderFront(nil)
        dismissalMonitor.start(
            panels: [panel],
            isExemptWindow: { _ in false },
            onEscape: { [weak self] in self?.dismiss() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        timeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            if self?.activePan == nil { self?.dismiss() }
        }
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        activePan = nil
        workspace = nil
        display = nil
        timeout?.cancel()
        timeout = nil
        dismissalMonitor.stop()
        if let mouse, mouse.state.activeInteractionSource == .touchDisplay {
            mouse.cancelActiveMouseInteraction()
        }
        panel.delegate = nil
        panel.orderOut(nil)
        mouse?.controller?.ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        panel.close()
    }

    func windowDidResignKey(_: Notification) {
        dismiss()
    }

    @objc private func cancelTouchMode() {
        dismiss()
    }

    nonisolated static func workspaceSwipeDirection(
        translation: CGPoint, axis: WorkspaceSwipeAxis, naturalDirection: Bool
    ) -> Bool? {
        let primary = axis == .horizontal ? translation.x : translation.y
        let cross = axis == .horizontal ? translation.y : translation.x
        guard abs(primary) >= 60, abs(primary) > abs(cross) * 1.25 else { return nil }
        return TrackpadGestureIntent.isNextWorkspace(axis: axis, displacement: primary, naturalDirection: naturalDirection)
    }

    @available(macOS 27.0, *)
    @objc private func handlePan(_ pan: NSPanGestureRecognizer) {
        guard let panel, let view = pan.view, view.window === panel, let mouse,
              let controller = mouse.controller, let display,
              let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == display }),
              let currentWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
              controller.isEnabled, !controller.isOverviewOpen(), !mouse.isInputSuppressed
        else {
            dismiss()
            return
        }

        switch pan.state {
        case .began:
            guard activePan == nil, mouse.state.activeInteractionSource == nil,
                  !mouse.isTrackpadSwipeSessionActive else { return }
            if pan.minimumNumberOfTouches == 4 {
                activePan = pan
                workspace = currentWorkspace.id
                return
            }
            let location = pan.location(in: view)
            let translation = pan.translation(in: view)
            let start = view.convert(CGPoint(x: location.x - translation.x, y: location.y - translation.y), to: nil)
            let startOnScreen = panel.convertPoint(toScreen: start)
            let layout = controller.settings.workspaces.layoutType(for: currentWorkspace.name)
            guard !mouse.shouldBlockOwnWindowGestureInput(at: startOnScreen),
                  let target = mouse.windowGestureTarget(at: startOnScreen, wsId: currentWorkspace.id, layoutType: layout),
                  mouse.beginWindowInteraction(
                      pan.minimumNumberOfTouches == 1 ? .windowMove : .windowResize,
                      target: target,
                      workspace: currentWorkspace,
                      at: startOnScreen,
                      source: .touchDisplay
                  ) else { return }
            activePan = pan
            workspace = currentWorkspace.id
        case .changed, .ended, .cancelled, .failed:
            guard activePan === pan else { return }
            defer {
                if pan.state != .changed { dismiss() }
            }
            guard workspace == currentWorkspace.id else {
                dismiss()
                return
            }
            if pan.minimumNumberOfTouches == 4 {
                if pan.state == .ended,
                   let isNext = Self.workspaceSwipeDirection(
                       translation: pan.translation(in: view), axis: controller.settings.gestures.workspaceSwipeAxis,
                       naturalDirection: controller.settings.gestures.invertDirection
                   )
                {
                    dismiss()
                    controller.workspaceNavigationHandler.switchWorkspaceBySwipe(isNext: isNext, monitorId: monitor.id)
                }
                return
            }
            guard mouse.state.activeInteractionSource == .touchDisplay else {
                dismiss()
                return
            }
            let location = panel.convertPoint(toScreen: view.convert(pan.location(in: view), to: nil))
            if pan.state == .changed {
                if mouse.state.isMoving { mouse.updateActiveMove(at: location) }
                if mouse.state.isResizing { mouse.updateManagedResize(at: location) }
            } else if pan.state == .ended {
                if mouse.state.isMoving { mouse.completeActiveMove(at: location) }
                if mouse.state.isResizing {
                    mouse.updateManagedResize(at: location)
                    mouse.completeActiveResize()
                }
            }
        default:
            break
        }
    }
}
