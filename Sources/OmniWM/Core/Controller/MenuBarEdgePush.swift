// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct MenuBarEdgePush: Sendable {
    // WindowServer can reveal the native menu while the cursor is still two points below the edge.
    static let inset: CGFloat = 8

    private static let revealDistance: CGFloat = 192

    private static let minimumPushDurationNs: UInt64 = 400_000_000
    private static let maximumPushGapNs: UInt64 = 100_000_000

    private var display: Monitor.ID?
    private var pressure: CGFloat = 0
    private var pushStartedAt: UInt64?
    private var lastPush: UInt64 = 0
    private var released = false

    func workspaceBarPointer(_ point: CGPoint, topology: PointerEdgeTopology) -> CGPoint {
        guard !released, let display, let frame = topology.monitor(display)?.frame,
              point.y == frame.maxY - Self.inset, point.x >= frame.minX, point.x < frame.maxX
        else { return point }
        return CGPoint(x: point.x, y: frame.maxY)
    }

    mutating func clamp(
        _ point: CGPoint, upward: CGFloat, now: UInt64, topology: PointerEdgeTopology
    ) -> CGPoint? {
        // AppKit's maximum Y is the screen's top, including where Quartz pins the cursor.
        guard !topology.menuBarPushDisplays.isEmpty, let monitor = topology.monitors.first(where: {
            topology.menuBarPushDisplays.contains($0.id) && point.x >= $0.frame.minX && point.x < $0.frame.maxX
                && point.y >= $0.frame.maxY - Self.inset && point.y <= $0.frame.maxY
        }), !topology.monitors.contains(where: {
            $0.id != monitor.id && $0.frame.contains(CGPoint(x: point.x, y: monitor.frame.maxY + 0.5))
        }) else {
            self = Self()
            return nil
        }

        if display != monitor.id {
            self = Self()
            display = monitor.id
        } else if released {
            return nil
        } else if upward > 0 {
            if pushStartedAt == nil || now - lastPush > Self.maximumPushGapNs {
                pushStartedAt = now
                pressure = 0
            }
            lastPush = now
            pressure += upward
            if pressure >= Self.revealDistance, let pushStartedAt, now - pushStartedAt >= Self.minimumPushDurationNs {
                released = true
                return nil
            }
        } else if upward < 0 {
            pushStartedAt = nil
        }
        return CGPoint(x: point.x, y: monitor.frame.maxY - Self.inset)
    }
}
