// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class WorkspaceBarIslandPanel {
    static let topBarCeiling = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    static let islandLevel = NSWindow.Level(rawValue: topBarCeiling.rawValue + 1)
    static let overlayCeiling = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 2)

    private var configuredLevel: NSWindow.Level = .normal
    private var usesTopEdge = false
    var yieldsToOverlay = false {
        didSet { updateLevel() }
    }

    private func updateLevel() {
        let level = yieldsToOverlay && usesTopEdge
            ? NSWindow.Level(rawValue: min(configuredLevel.rawValue, Self.overlayCeiling.rawValue))
            : configuredLevel
        if panel.level != level { panel.level = level }
    }

    let panel: WorkspaceBarPanel
    let hostingView: NSHostingView<WorkspaceBarView>
    var slice: WorkspaceBarIslandSlice
    var lastAppliedFrame: NSRect?
    private var lastObservedFrame: NSRect?

    init(panel: WorkspaceBarPanel, rootView: WorkspaceBarView, resolved: ResolvedBarSettings, monitor: Monitor) {
        let hostingView = WorkspaceBarHostingView(rootView: rootView)
        hostingView.registerForDraggedTypes([WorkspaceBarHostingView.widgetType])
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        let appearance = NSApplication.shared.appearance
        panel.appearance = appearance
        hostingView.appearance = appearance
        self.panel = panel
        self.hostingView = hostingView
        slice = rootView.slice
        lastAppliedFrame = nil
        applySettings(resolved: resolved, monitor: monitor)
    }

    func applySettings(resolved: ResolvedBarSettings, monitor: Monitor) {
        let fillsMenuBar = resolved.notchMode == .fillLeftOfNotch
        panel.collectionBehavior = fillsMenuBar
            ? [.canJoinAllSpaces, .stationary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let level = resolved.windowLevel.nsWindowLevel
        let position = WorkspaceBarGeometry.effectivePosition(for: monitor, resolved: resolved)
        usesTopEdge = fillsMenuBar || position.usesNotch
        if fillsMenuBar || (position == .overlappingMenuBar && (resolved.fullWidth || resolved.yieldToNativeMenuBar)) {
            configuredLevel = Self.topBarCeiling
        } else if position.usesNotch {
            configuredLevel = NSWindow.Level(rawValue: min(level.rawValue, Self.topBarCeiling.rawValue))
        } else {
            configuredLevel = level
        }
        updateLevel()
    }

    func applyFrame(
        _ frame: NSRect,
        using frameApplier: (WorkspaceBarPanel, NSRect) -> Void
    ) {
        guard lastAppliedFrame != frame || lastObservedFrame != panel.frame else { return }
        frameApplier(panel, frame)
        panel.layoutIfNeeded()
        lastAppliedFrame = frame
        lastObservedFrame = panel.frame
    }
}
