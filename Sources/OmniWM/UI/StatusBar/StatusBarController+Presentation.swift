// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension StatusBarController {
    static let menuIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "OmniWM")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }()
    static let layoutSymbolPointSize: CGFloat = 14
    static let layoutIconSpacing: CGFloat = 5

    private static let niriLayoutGlyph = layoutGlyph(systemSymbolName: layoutSymbolName(.niri))
    private static let dwindleLayoutGlyph = layoutGlyph(systemSymbolName: layoutSymbolName(.dwindle))
    private static let menuNiriLayoutImage = statusButtonImage(
        icon: menuIcon, layout: .niri
    )
    private static let menuDwindleLayoutImage = statusButtonImage(
        icon: menuIcon, layout: .dwindle
    )

    static func statusButtonTitle(
        workspaceLabel: String?,
        focusedAppName: String?,
        modeTitle: String? = nil
    ) -> String {
        var title = workspaceLabel.map { " \($0)" } ?? ""
        if let focusedAppName, !focusedAppName.isEmpty {
            title += " \u{2013} \(truncatedStatusBarAppName(focusedAppName))"
        }
        if let modeTitle {
            title = " \(modeTitle)" + (title.isEmpty ? "" : " \u{00B7}" + title)
        }
        return title
    }

    nonisolated static func layoutSymbolName(_ layout: ActiveLayoutKind) -> String {
        switch layout {
        case .niri: "rectangle.split.3x1"
        case .dwindle: "rectangle.split.2x2"
        case .tabbed: "macwindow.on.rectangle"
        }
    }

    nonisolated static func layoutDisplayName(_ layout: ActiveLayoutKind) -> String {
        switch layout {
        case .niri: LayoutType.niri.localizedDisplayName
        case .dwindle: LayoutType.dwindle.localizedDisplayName
        case .tabbed: LayoutType.tabbed.localizedDisplayName
        }
    }

    nonisolated static func statusButtonAccessibilityValue(
        workspaceLabel: String?,
        focusedAppName: String?,
        isRecording: Bool,
        isSecureInputActive: Bool,
        layout: ActiveLayoutKind? = nil
    ) -> String {
        var components: [String] = []
        if isRecording {
            components.append(String(localized: "Recording diagnostics"))
        }
        if isSecureInputActive {
            components.append(String(localized: "Secure Input is on"))
        }
        if let workspaceLabel, !workspaceLabel.isEmpty {
            components.append(String(localized: "Workspace \(workspaceLabel)"))
        }
        if let focusedAppName, !focusedAppName.isEmpty {
            components.append(String(localized: "Focused app \(focusedAppName)"))
        }
        if let layout {
            components.append(Self.layoutDisplayName(layout))
        }
        return components.isEmpty ? String(localized: "Window manager controls") : components
            .joined(separator: String(localized: ", "))
    }

    static func layoutGlyph(_ layout: ActiveLayoutKind) -> NSImage? {
        switch layout {
        case .niri: niriLayoutGlyph
        case .dwindle: dwindleLayoutGlyph
        case .tabbed: layoutGlyph(systemSymbolName: layoutSymbolName(.tabbed))
        }
    }

    static func menuLayoutImage(_ layout: ActiveLayoutKind) -> NSImage? {
        switch layout {
        case .niri: menuNiriLayoutImage
        case .dwindle: menuDwindleLayoutImage
        case .tabbed: statusButtonImage(icon: menuIcon, layout: .tabbed)
        }
    }

    static func statusButtonImage(icon: NSImage?, layout: ActiveLayoutKind?) -> NSImage? {
        guard let layout, let glyph = layoutGlyph(layout) else { return icon }
        guard let icon else { return glyph }
        let height = max(icon.size.height, glyph.size.height)
        let iconRect = NSRect(
            x: 0, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height
        )
        let glyphRect = NSRect(
            x: icon.size.width + layoutIconSpacing, y: (height - glyph.size.height) / 2,
            width: glyph.size.width, height: glyph.size.height
        )
        let isTemplate = icon.isTemplate
        let drawnGlyph = isTemplate
            ? glyph
            : glyph.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? glyph
        let image = NSImage(size: NSSize(width: glyphRect.maxX, height: height), flipped: false) { _ in
            icon.draw(in: iconRect)
            drawnGlyph.draw(in: glyphRect)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    private static func layoutGlyph(systemSymbolName: String) -> NSImage? {
        NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: layoutSymbolPointSize, weight: .regular))
    }
}
