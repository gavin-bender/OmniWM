// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct TabbedBarOptions: Equatable, Codable, Sendable {
    enum Position: String, Codable { case top, left }
    enum Size: String, Codable { case small, medium, large }
    enum Content: String, Codable { case iconsAndTitles, icons, titles }

    var position: Position = .top
    var size: Size = .medium
    var content: Content = .iconsAndTitles

    var rowHeight: CGFloat {
        switch size {
        case .small: 28
        case .medium: 36
        case .large: 48
        }
    }

    static let closeButtonWidth: CGFloat = 22

    var thickness: CGFloat {
        position == .left ? (content == .icons ? rowHeight + Self.closeButtonWidth : rowHeight * 4) : rowHeight
    }

    func settledWindowFrame(_ frame: CGRect, in screen: CGRect, barTop: CGFloat, grouped: Bool) -> CGRect {
        let needsTopBar = grouped && position == .top
        let ceiling = needsTopBar ? min(screen.maxY, barTop) - thickness : screen.maxY
        let top = needsTopBar ? min(frame.maxY, ceiling) : frame.maxY
        let height = min(frame.height, max(1, ceiling - screen.minY))
        return CGRect(x: frame.minX, y: top - height, width: min(frame.width, screen.width), height: height)
    }

    func contentFrame(fitting frame: CGRect, in screen: CGRect, grouped: Bool) -> CGRect {
        let left = grouped && position == .left ? thickness : 0
        let top = grouped && position == .top ? thickness : 0
        let width = min(frame.width, max(1, screen.width - left))
        let height = min(frame.height, max(1, screen.height - top))
        return CGRect(x: min(max(frame.minX, screen.minX + left), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - top - height),
                      width: width, height: height)
    }

    func tileFrame(around content: CGRect, grouped: Bool) -> CGRect {
        guard grouped else { return content }
        if position == .top {
            return CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height + thickness)
        }
        return CGRect(x: content.minX - thickness, y: content.minY, width: content.width + thickness, height: content.height)
    }
}

extension TabbedBarOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        position = try values.decodeIfPresent(Position.self, forKey: .position) ?? position
        size = try values.decodeIfPresent(Size.self, forKey: .size) ?? size
        content = try values.decodeIfPresent(Content.self, forKey: .content) ?? content
    }
}

enum TabRailStyle: Equatable {
    case hidden
    case compact
    case appIcons
    case windowTabs(TabbedBarOptions)

    var options: TabbedBarOptions? {
        if case let .windowTabs(options) = self { return options }
        return nil
    }

    static let iconSize: CGFloat = 20
    static let iconRowHeight: CGFloat = 28

    init(appIcons: Bool) {
        self = appIcons ? .appIcons : .hidden
    }

    var reservedWidth: CGFloat {
        switch self {
        case .hidden: 0
        case .compact: TabRailMetrics.totalWidth
        case .appIcons: 28
        case let .windowTabs(options): options.thickness
        }
    }

    var hitWidth: CGFloat {
        max(reservedWidth, TabRailMetrics.hitWidth)
    }

    func fittedHeight(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        switch self {
        case .hidden: 0
        case .compact:
            TabRailLayout.fittedHeight(tabCount: tabCount, availableHeight: availableHeight)
        case let .windowTabs(options):
            min(availableHeight, CGFloat(tabCount) * options.rowHeight)
        case .appIcons:
            min(max(0, availableHeight), CGFloat(max(0, tabCount)) * Self.iconRowHeight)
        }
    }
}
