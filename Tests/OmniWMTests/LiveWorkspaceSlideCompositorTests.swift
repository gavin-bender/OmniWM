// SPDX-License-Identifier: GPL-2.0-only

import AppKit
@testable import OmniWM
import OmniWMSystemGestures
import XCTest

@MainActor
final class LiveWorkspaceSlideCompositorTests: XCTestCase {
    func testHorizontalDockMovesPreserveWindowSizeAndRejectOtherAxes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMNIWM_LIVE_CHECKS"] == "1")
        try XCTSkipUnless(omniwm_dock_slide_available())
        _ = NSApplication.shared
        let display = try XCTUnwrap(NSScreen.main).frame
        let initial = CGRect(x: display.minX + 32, y: display.minY + 80, width: 320, height: 256)
        let panel = NSPanel(contentRect: initial, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        let id = UInt32(panel.windowNumber)
        let original = ScreenCoordinateSpace.toWindowServer(rect: panel.frame)
        XCTAssertFalse(omniwm_dock_scroll_window(id, original.offsetBy(dx: 12, dy: 50)))
        XCTAssertFalse(omniwm_dock_scroll_window(id, original.insetBy(dx: 10, dy: 0)))
        var confirmed = 0
        for delta: CGFloat in [12, 24, 36, 48, 36, 24, 12, 0] {
            let target = original.offsetBy(dx: delta, dy: 0)
            if omniwm_dock_scroll_window(id, target) {
                var base = CGRect.zero
                var matrix = CGAffineTransform.identity
                XCTAssertTrue(omniwm_dock_slide_geometry(id, &base, &matrix))
                XCTAssertTrue(omniwm_dock_slide_at_position(matrix, target.origin))
                XCTAssertEqual(base.size, original.size)
                if delta != 0 { confirmed += 1 }
            } else {
                panel.setFrameOrigin(ScreenCoordinateSpace.toAppKit(rect: target).origin)
            }
            try await Task.sleep(for: .milliseconds(12))
        }
        XCTAssertGreaterThan(confirmed, 0)
    }

    func testWindowWithExistingTranslationDoesNotDisableOtherWindowsSlide() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMNIWM_LIVE_CHECKS"] == "1")
        try XCTSkipUnless(omniwm_dock_slide_available())
        _ = NSApplication.shared
        let display = try XCTUnwrap(NSScreen.main).frame
        let frame = CGRect(x: display.midX, y: display.midY, width: 256, height: 256)
        let panels = (0..<2).map { _ in
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.orderFrontRegardless()
            return panel
        }
        defer { for panel in panels { panel.orderOut(nil) } }
        try await Task.sleep(for: .milliseconds(100))
        let foreignID = UInt32(panels[0].windowNumber)
        let base = ScreenCoordinateSpace.toWindowServer(rect: frame)
        let translated = CGPoint(x: base.minX - 100, y: base.minY)
        var move = OmniWMDockSlideMove(window: foreignID, baseWidth: 256, baseHeight: 256,
                                       target: translated, resetFirst: false, apply: true)
        XCTAssertTrue(omniwm_dock_slide_submit(&move, 1))
        defer { _ = omniwm_dock_slide_restore_translation(foreignID) }

        let members = panels.enumerated().map { index, panel in
            LiveWorkspaceSlide.Member(token: .init(pid: getpid(), windowId: panel.windowNumber),
                                      window: AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: panel.windowNumber),
                                      layout: frame, original: frame, parkOrigin: frame.origin,
                                      minimumHeight: 1, incoming: index == 1)
        }
        let slide = LiveWorkspaceSlide(members: members, viewport: display, dockDisplay: display)
        XCTAssertTrue(slide.followsDisplayLink)
        defer { _ = slide.restore(keepingIncomingPlacement: false) { _ in XCTFail("unexpected park") } }
        XCTAssertTrue(slide.update(source: .zero, destination: CGVector(dx: 0, dy: 40)))
        XCTAssertFalse(slide.ownsTranslation(for: Int(foreignID)))
        XCTAssertTrue(slide.ownsTranslation(for: panels[1].windowNumber))
        var bounds = CGRect.zero
        var matrix = CGAffineTransform.identity
        XCTAssertTrue(omniwm_dock_slide_geometry(foreignID, &bounds, &matrix))
        XCTAssertTrue(omniwm_dock_slide_at_position(matrix, translated))
    }

    func testParkedWindowsFollowAndLandWithDelayedPhysicalMoves() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMNIWM_LIVE_CHECKS"] == "1")
        try XCTSkipUnless(omniwm_dock_slide_available())
        _ = NSApplication.shared
        let display = try XCTUnwrap(NSScreen.main).frame
        let size = CGSize(width: 512, height: 512)
        let park = CGPoint(x: display.maxX - 1, y: display.midY - size.height / 2)
        let slots = [display.minX - 140, display.midX]
        let frames = slots.map { CGRect(origin: CGPoint(x: $0, y: park.y), size: size) }
        let panels = (0..<4).map { index in
            let frame = index < 2 ? frames[index] : CGRect(origin: park, size: size)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.orderFrontRegardless()
            return panel
        }
        defer { for panel in panels { panel.orderOut(nil) } }
        try await Task.sleep(for: .milliseconds(100))
        let byId = Dictionary(uniqueKeysWithValues: panels.map { ($0.windowNumber, $0) })
        let element = AXUIElementCreateApplication(getpid())
        func drawingOrigin(_ id: Int) throws -> CGPoint {
            var base = CGRect.zero
            var matrix = CGAffineTransform.identity
            guard omniwm_dock_slide_geometry(UInt32(id), &base, &matrix) else {
                throw NSError(domain: "Missing test window", code: id)
            }
            XCTAssertEqual(base.size, size)
            XCTAssertEqual(matrix.a, 1)
            XCTAssertEqual(matrix.d, 1)
            return CGPoint(x: -matrix.tx, y: -matrix.ty)
        }

        var showingFirst = true
        for turn in 0..<12 {
            let commits = turn % 3 != 1
            let members: [LiveWorkspaceSlide.Member] = panels.enumerated().map { index, panel in
                let incoming = (index >= 2) == showingFirst
                return .init(token: WindowToken(pid: getpid(), windowId: panel.windowNumber),
                             window: AXWindowRef(element: element, windowId: panel.windowNumber),
                             layout: frames[index % 2], original: panel.frame, parkOrigin: park,
                             minimumHeight: size.height, incoming: incoming)
            }
            // The app owns its test panels. Reproduce the observed AX acknowledgement
            // before the new physical position is published by WindowServer.
            var pending: [Int: Task<Void, Never>] = [:]
            let quickCancel = turn == 4 || turn == 10
            let delay = quickCancel ? 50 : [0, 8, 50][turn % 3]
            let slide = LiveWorkspaceSlide(members: members, viewport: display, dockDisplay: display) { member, frame, verify in
                let id = member.window.windowId
                pending[id]?.cancel()
                if verify {
                    byId[id]?.setFrameOrigin(frame.origin)
                } else {
                    pending[id] = Task {
                        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                        byId[id]?.setFrameOrigin(frame.origin)
                    }
                }
                return true
            }
            guard slide.followsDisplayLink else {
                for panel in panels {
                    var base = CGRect.zero
                    var matrix = CGAffineTransform.identity
                    let readable = omniwm_dock_slide_geometry(UInt32(panel.windowNumber), &base, &matrix)
                    XCTFail("Unavailable compositor for panel \(panel.windowNumber), read=\(readable), base=\(base), transform=\(matrix)")
                }
                return
            }
            let direction: CGFloat = showingFirst ? 1 : -1
            let stride = display.height * 1.1
            let samples: [CGFloat]
            if commits { samples = [0.06, 0.25, 0.43, 0.6, 0.8, 0.94, 0.998] }
            else if quickCancel { samples = [0.1] }
            else { samples = [0.1, 0.34, 0.62, 0.46, 0.2, 0.03, 0] }
            let start = ContinuousClock.now
            for (index, progress) in samples.enumerated() {
                let source = CGVector(dx: 0, dy: direction * progress * stride)
                let destination = CGVector(dx: 0, dy: direction * (progress - 1) * stride)
                let updated = slide.update(source: source, destination: destination)
                XCTAssertTrue(updated, "turn \(turn), sample \(index)")
                try await Task.sleep(for: .milliseconds(12))
                if updated {
                    for member in members {
                        let offset = member.incoming ? destination : source
                        let projected = member.layout.offsetBy(dx: offset.dx, dy: offset.dy)
                        guard projected.intersects(display) else { continue }
                        let drawing = try drawingOrigin(member.window.windowId)
                        let target = ScreenCoordinateSpace.toWindowServer(rect: projected).origin
                        let drawingFrame = CGRect(origin: drawing, size: size)
                        let waitingForApp = member.incoming && start.duration(to: .now) < .milliseconds(delay + 25)
                        if waitingForApp, !drawingFrame.intersects(ScreenCoordinateSpace.toWindowServer(rect: display)) { continue }
                        XCTAssertEqual(drawing.x, target.x, accuracy: 1)
                        XCTAssertEqual(drawing.y, target.y, accuracy: 1)
                    }
                }
            }
            if commits {
                let task = try XCTUnwrap(slide.beginLanding())
                for member in members {
                    byId[member.window.windowId]?.setFrameOrigin(member.incoming ? member.layout.origin : park)
                }
                for _ in 0..<10 {
                    for member in members where member.incoming {
                        let drawing = try drawingOrigin(member.window.windowId)
                        XCTAssertEqual(drawing.x, member.layout.minX, accuracy: 1, "incoming column moved at landing")
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                await task.value
                showingFirst.toggle()
            }
            XCTAssertTrue(slide.restore(keepingIncomingPlacement: commits) { _ in XCTFail("repark failed") }.isEmpty)
            try await Task.sleep(for: .milliseconds(12))
            for (index, panel) in panels.enumerated() {
                let expected = (index < 2) == showingFirst ? frames[index % 2].origin : park
                XCTAssertEqual(panel.frame.origin, expected)
                let drawing = try drawingOrigin(panel.windowNumber)
                let physical = ScreenCoordinateSpace.toWindowServer(rect: panel.frame).origin
                XCTAssertEqual(drawing.x, physical.x, accuracy: 1)
                XCTAssertEqual(drawing.y, physical.y, accuracy: 1)
            }
        }
    }
}
