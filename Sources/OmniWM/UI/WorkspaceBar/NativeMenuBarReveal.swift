// SPDX-License-Identifier: GPL-2.0-only

import AppKit

@MainActor
final class NativeMenuBarReveal {
    private var timer: Timer?

    func start(interval: TimeInterval = 0.1, _ sample: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    isolated deinit { stop() }
}

extension WorkspaceBarManager {
    func updateMenuBarRevealTracking(_ bars: [DesiredBarSurface], settings: SettingsStore) {
        monitorsYieldingToMenuBar = Set(bars.compactMap { bar in
            let resolved = settings.workspaceBar.resolved(for: bar.monitor)
            guard bar.isRetained, resolved.yieldToNativeMenuBar,
                  WorkspaceBarGeometry.effectivePosition(for: bar.monitor, resolved: resolved) == .overlappingMenuBar
            else { return nil }
            return bar.monitor.id
        })
        if monitorsYieldingToMenuBar.isEmpty {
            nativeMenuBarReveal.stop()
            revealedMenuMonitor = nil
            return
        }
        nativeMenuBarReveal.start { [weak self] in
            guard let self, let controller else { return }
            updateNativeMenuBarVisibility(
                pointer: controller.currentMouseLocation(),
                monitors: controller.workspaceManager.monitors,
                nativeVisible: NSMenu.menuBarVisible()
            )
        }
    }

    func updateNativeMenuBarVisibility(pointer: CGPoint, monitors: [Monitor], nativeVisible: Bool) {
        guard let monitor = pointer.monitorApproximation(in: monitors),
              monitorsYieldingToMenuBar.contains(monitor.id) else {
            nativeMenuBarVisibilityChanged(on: nil)
            return
        }
        let distanceFromTop = monitor.frame.maxY - pointer.y
        let atRevealEdge = (0 ... 1).contains(distanceFromTop)
        let insideMenuStrip = (0 ... WorkspaceBarGeometry.menuBarHeight(for: monitor)).contains(distanceFromTop)
        // A click inside the bar can transiently report native visibility. Only the screen edge starts a handoff.
        let keepHidden = revealedMenuMonitor == monitor.id && (insideMenuStrip || nativeVisible)
        nativeMenuBarVisibilityChanged(on: atRevealEdge || keepHidden ? monitor.id : nil)
    }

    func nativeMenuBarVisibilityChanged(on monitor: Monitor.ID?) {
        guard revealedMenuMonitor != monitor else { return }
        revealedMenuMonitor = monitor
        for bar in lastBars where monitorsYieldingToMenuBar.contains(bar.monitor.id) {
            applyVisibility(bar.visible, on: bar.monitor.id)
        }
    }
}

extension WorkspaceBarManager {
    func updateOverlayMonitoring() {
        guard !barsByMonitor.isEmpty || !lastIslands.isEmpty else {
            overlayMonitor.stop()
            overlayDisplays = []
            return
        }
        // Nonactivating system overlays can appear without a workspace activation or window notification.
        overlayMonitor.start(interval: 0.2) { [weak self] in
            self?.refreshOverlayDisplays()
        }
    }

    private func refreshOverlayDisplays() {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }
        let frames = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowLayer as String] as? Int == NSWindow.Level.statusBar.rawValue,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != getpid(),
                  let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  ["com.apple.campo", "com.apple.Siri", "com.apple.Spotlight"].contains(id),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        let monitors = Set(barsByMonitor.keys).union(lastIslands.map { $0.monitor.id })
        let displays = monitors.filter { id in
            frames.contains { $0.intersects(CGDisplayBounds(id.displayId)) }
        }
        guard displays != overlayDisplays else { return }
        overlayDisplays = displays
        for (id, bar) in barsByMonitor {
            bar.primary.yieldsToOverlay = displays.contains(id)
            bar.secondary?.yieldsToOverlay = displays.contains(id)
        }
        shellHost?.overlayDisplays = displays
        shellHost?.reconcileIslandWindows()
    }
}
