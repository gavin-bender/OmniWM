// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import OmniWMIPC

extension IPCPresentationCommand {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .overview: LocalizedStringResource(
                "command.presentation.overview", defaultValue: "Toggle Overview", table: "Commands", bundle: .omniWM
            )
        case .systemStats: LocalizedStringResource(
                "command.presentation.systemStats", defaultValue: "Toggle System Stats", table: "Commands",
                bundle: .omniWM
            )
        case .quakeTerminal: LocalizedStringResource(
                "command.presentation.quakeTerminal", defaultValue: "Toggle Quake Terminal", table: "Commands",
                bundle: .omniWM
            )
        case .workspaceBar: LocalizedStringResource(
                "command.presentation.workspaceBar", defaultValue: "Toggle Workspace Bar", table: "Commands",
                bundle: .omniWM
            )
        case .hideTopBar: LocalizedStringResource(
                "command.presentation.hideTopBar", defaultValue: "Hide Top Bar", table: "Commands", bundle: .omniWM
            )
        case .toggleTopBar: LocalizedStringResource(
                "command.presentation.toggleTopBar", defaultValue: "Switch Native and OmniWM Top Bars",
                table: "Commands",
                bundle: .omniWM
            )
        case .cycleTopBar: LocalizedStringResource(
                "command.presentation.cycleTopBar", defaultValue: "Cycle Top Bar Mode", table: "Commands",
                bundle: .omniWM
            )
        case .hiddenBar: LocalizedStringResource(
                "command.presentation.hiddenBar", defaultValue: "Toggle Hidden Icons Panel", table: "Commands",
                bundle: .omniWM
            )
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let keywords: [String]
        let binding: KeyBinding
        switch self {
        case .overview:
            id = "toggleOverview"
            keywords = ["overview"]
            binding = KeyBinding(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | shiftKey))
        case .systemStats:
            id = "toggleSystemStats"
            keywords = ["stats", "system", "cpu", "memory", "gpu", "disk", "fetch"]
            binding = .unassigned
        case .quakeTerminal:
            id = "toggleQuakeTerminal"
            keywords = ["quake", "terminal"]
            binding = KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey))
        case .workspaceBar:
            id = "toggleWorkspaceBarVisibility"
            keywords = ["workspace bar", "bar"]
            binding = .unassigned
        case .hideTopBar:
            id = "hideTopBar"
            keywords = ["hide", "top bar", "menu bar"]
            binding = .unassigned
        case .toggleTopBar:
            id = "toggleTopBar"
            keywords = ["switch", "top bar", "native", "workspace bar"]
            binding = .unassigned
        case .cycleTopBar:
            id = "cycleTopBar"
            keywords = ["cycle", "top bar", "native", "hidden", "workspace bar"]
            binding = KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey | shiftKey))
        case .hiddenBar:
            id = "toggleHiddenBarPanel"
            keywords = ["hidden bar", "icons", "menu bar"]
            binding = .unassigned
        }
        return ActionCatalog.action(
            id: id,
            command: .presentation(self),
            category: .focus,
            binding: binding,
            keywords: keywords
        )
    }
}
