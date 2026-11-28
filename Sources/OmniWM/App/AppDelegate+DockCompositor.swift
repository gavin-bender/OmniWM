// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMSystemGestures

extension AppDelegate {
    func recoverDevDockCompositorIfNeeded(controller: WMController) {
        guard Bundle.main.bundleIdentifier == "com.barut.OmniWM.dev",
              !NSScreen.screens.isEmpty,
              !omniwm_dock_slide_available()
        else { return }

        let binary = "Library/Caches/OmniWM/static-move-yabai-sb-v2.0.0/archive/bin/yabai"
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(binary)
        let quake = controller.quakeTerminalController
        let message: String
        if !FileManager.default.isExecutableFile(atPath: path.path) {
            message = "Dock recovery unavailable: yabai-sb is missing or cannot run."
        } else if !controller.settings.quakeTerminal.enabled || controller.settings.quakeTerminal.provider != .ghostty {
            message = "Enable the Ghostty Quake terminal to stage Dock recovery."
        } else if quake.stageCommand("sudo \"$HOME/\(binary)\" --load-sa") {
            message = "Dock recovery is ready in Quake. Review and press Return."
        } else {
            message = "Dock recovery could not open a Quake tab."
        }

        let frame = quake.targetScreen().visibleFrame
        controller.columnModeToast.show(
            message: message,
            anchorFrame: frame,
            visibleFrame: frame,
            motion: controller.motionPolicy.snapshot()
        )
    }
}
