// SPDX-License-Identifier: GPL-2.0-only

import AppKit

@MainActor
final class NativeMenuBarReveal {
    private var timer: Timer?

    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        guard timer == nil else { return }
        var previous = NSMenu.menuBarVisible()
        changed(previous)
        // Hover reveals change AppKit's visibility without posting Carbon menu bar events.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let visible = NSMenu.menuBarVisible()
                if visible != previous {
                    previous = visible
                    changed(visible)
                }
            }
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
        nativeMenuBarReveal.start { [weak self] shown in
            guard let self else { return }
            let pointer = NSEvent.mouseLocation
            let monitor = pointer.monitorApproximation(in: controller?.workspaceManager.monitors ?? [])
            nativeMenuBarVisibilityChanged(on: shown ? monitor?.id : nil)
        }
    }

    func nativeMenuBarVisibilityChanged(on monitor: Monitor.ID?) {
        guard revealedMenuMonitor != monitor else { return }
        revealedMenuMonitor = monitor
        for bar in lastBars where monitorsYieldingToMenuBar.contains(bar.monitor.id) {
            applyVisibility(bar.visible, on: bar.monitor.id)
        }
    }
}
