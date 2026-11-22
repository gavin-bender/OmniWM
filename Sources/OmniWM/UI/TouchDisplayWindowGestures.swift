// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Darwin
import OmniWMSystemGestures

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
    struct NavigationSwipe {
        enum Action: Equatable {
            case focusWindow(Direction)
            case switchWorkspace(isNext: Bool)
        }

        private static let minimumTravel: CGFloat = 60
        private var axis: WorkspaceSwipeAxis?

        mutating func observe(translation: CGPoint) {
            guard axis == nil else { return }
            let horizontal = abs(translation.x)
            let vertical = abs(translation.y)
            guard max(horizontal, vertical) >= Self.minimumTravel,
                  max(horizontal, vertical) > min(horizontal, vertical) * 1.25
            else { return }
            axis = horizontal > vertical ? .horizontal : .vertical
        }

        mutating func finish(translation: CGPoint, naturalDirection: Bool) -> Action? {
            observe(translation: translation)
            guard let axis else { return nil }
            let travel = axis == .horizontal ? translation.x : translation.y
            guard abs(travel) >= Self.minimumTravel,
                  let isNext = TrackpadGestureIntent.isNextWorkspace(
                      axis: axis, displacement: travel, naturalDirection: naturalDirection
                  )
            else { return nil }
            return axis == .horizontal ? .focusWindow(isNext ? .right : .left) : .switchWorkspace(isNext: isNext)
        }
    }

    private static let surfaceId = "touch-display-window-gestures"
    static let isPROLEDMac: Bool = {
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
    private var navigationSwipe = NavigationSwipe()
    private var usesNativeGesturePreferenceFallback = false
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
        for fingerCount in 1 ... 3 {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.allowedTouchTypes = .direct
            pan.buttonMask = 0
            pan.minimumNumberOfTouches = fingerCount
            pan.maximumNumberOfTouches = 0
            content.addGestureRecognizer(pan)
        }

        let instructions = NSTextField(wrappingLabelWithString: String(
            localized: "One-finger drag to move. Two-finger drag near an edge to resize. Swipe with three fingers left or right for windows, or up or down for workspaces."
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
        if !omniwm_set_window_direct_touch_system_gestures_disabled(Unmanaged.passUnretained(panel).toOpaque(), true) {
            usesNativeGesturePreferenceFallback = true
            controller.serviceLifecycleManager.setTouchDisplayGestureCapture(active: true)
        }
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
        navigationSwipe = NavigationSwipe()
        timeout?.cancel()
        timeout = nil
        dismissalMonitor.stop()
        if let mouse, mouse.state.activeInteractionSource == .touchDisplay {
            mouse.cancelActiveMouseInteraction()
        }
        panel.delegate = nil
        panel.orderOut(nil)
        if usesNativeGesturePreferenceFallback {
            usesNativeGesturePreferenceFallback = false
            mouse?.controller?.serviceLifecycleManager.setTouchDisplayGestureCapture(active: false)
        }
        mouse?.controller?.ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        panel.close()
    }

    func windowDidResignKey(_: Notification) {
        dismiss()
    }

    @objc private func cancelTouchMode() {
        dismiss()
    }

    static func performNavigation(
        _ action: NavigationSwipe.Action,
        in workspace: WorkspaceDescriptor,
        on monitor: Monitor.ID,
        controller: WMController
    ) {
        switch action {
        case let .focusWindow(direction):
            switch controller.settings.workspaces.layoutType(for: workspace.name) {
            case .dwindle:
                if !controller.dwindleLayoutHandler.focusNeighbor(direction: direction, in: workspace.id) {
                    _ = controller.dwindleLayoutHandler.wrapGroupFocus(direction: direction, in: workspace.id)
                }
            case .niri,
                 .defaultLayout:
                guard let engine = controller.niriEngine,
                      let display = controller.workspaceManager.monitor(byId: monitor)
                else { return }
                let handler = controller.niriLayoutHandler
                let orientation = handler.resolvedOrientation(for: workspace.id, monitor: display, engine: engine)
                let columnDirection: Direction = switch (orientation, direction) {
                case (.vertical, .left): .down
                case (.vertical, .right): .up
                default: direction
                }
                _ = handler.focusNeighbor(direction: columnDirection, in: workspace.id)
            }
        case let .switchWorkspace(isNext):
            controller.workspaceNavigationHandler.switchWorkspaceBySwipe(isNext: isNext, monitorId: monitor)
        }
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
            if pan.minimumNumberOfTouches == 3 {
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
            if pan.minimumNumberOfTouches == 3 {
                let translation = pan.translation(in: view)
                if pan.state == .changed {
                    navigationSwipe.observe(translation: translation)
                    return
                }
                guard pan.state == .ended,
                      mouse.state.activeInteractionSource == nil, !mouse.isTrackpadSwipeSessionActive,
                      let action = navigationSwipe.finish(
                          translation: translation,
                          naturalDirection: controller.settings.gestures.invertDirection
                      )
                else { return }
                dismiss()
                Self.performNavigation(action, in: currentWorkspace, on: monitor.id, controller: controller)
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
