// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowShutdownSwipeTests: XCTestCase {
    func testSettingsWindowCanSlideOntoAndOffWorkspaceFour() throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let window = fixture.manager.makeWindow(fixture.definition)
        let monitor = fixture.destinationMonitor
        let layout = CGRect(origin: monitor.frame.origin, size: window.frame.size)
        window.setFrame(layout, display: false)
        let token = try XCTUnwrap(fixture.manager.admitSettingsWindow(window, to: fixture.destinationOther))
        let handle = try XCTUnwrap(fixture.world.handle(for: token))
        let swipe = fixture.controller.layoutRefreshController.workspaceSwipe
        let three = WorkspaceSwipePresentation.Workspace(id: fixture.destination, items: [])
        let four = WorkspaceSwipePresentation.Workspace(id: fixture.destinationOther, items: [.init(handle: handle, frame: layout)])
        for (source, destination) in [(three, four), (four, three)] {
            let incoming = destination.id == four.id
            XCTAssertTrue(fixture.world.setActiveWorkspace(source.id, on: monitor.id))
            fixture.manager.setHidden(incoming, for: token)
            let original = window.frame
            let preparation = WorkspaceSwipePresentation.Preparation(
                monitor: monitor, frame: monitor.visibleFrame, source: source,
                previous: incoming ? nil : destination, next: incoming ? destination : nil
            )
            let flight = WorkspaceSwipePresentation.Flight(
                preparation: preparation, destination: destination, axis: .horizontal,
                cumulative: 0, isNext: incoming, timestamp: 1, recognitionMovement: nil, captureFree: true
            )
            XCTAssertTrue(swipe.beginLiveSlide(flight))
            let slide = try XCTUnwrap(flight.liveSlide)
            let offset = CGVector(dx: 40, dy: 0)
            XCTAssertTrue(slide.update(source: offset, destination: offset))
            XCTAssertEqual(window.frame.minX, layout.minX + offset.dx)
            XCTAssertTrue(window.isVisible)
            swipe.cancel(flight, reason: "test")
            XCTAssertEqual(window.frame, original)
            XCTAssertEqual(window.isVisible, !incoming)
        }
    }

    func testShutdownCancelsConcurrentSwipesBeforeRemovalCanSettleFocus() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let window = fixture.manager.makeWindow(fixture.definition)
        let token = try XCTUnwrap(fixture.manager.admit(
            window,
            metadata: HostedWindowMetadata(
                appId: fixture.definition.id, title: fixture.definition.title,
                minimumSize: fixture.definition.minimumContentSize
            ), to: fixture.source
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let wallpaper = OverviewWallpaperCache()
        let frame = fixture.sourceMonitor.frame
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(frame.width)), height: Int(ceil(frame.height)),
            bitsPerComponent: UInt8.bitWidth, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        wallpaper.desktopImageURL = { _ in nil }
        wallpaper.captureWallpaper = { _ in image }
        let backdrop = WorkspaceSwipeBackdrop(wallpaperCache: wallpaper)
        let driver = OverviewPreviewTestDriver()
        defer { driver.finish() }
        let timestamp = fixture.controller.animationClock.now()
        let swipe = WorkspaceSwipePresentation(
            refreshController: fixture.controller.layoutRefreshController,
            previewFactory: { controller in
                WorkspaceSwipePreview(
                    ownedWindowRegistry: controller.ownedWindowRegistry,
                    previewCapture: driver.makeCapture(consumer: .workspaceSwipe),
                    backdrop: backdrop, hasCaptureAccess: { true }, captureDisplay: { _, _ in nil }
                )
            }, mediaTimeProvider: { timestamp }
        )
        fixture.controller.layoutRefreshController.workspaceSwipe = swipe
        fixture.controller.motionPolicy.animationsEnabled = true
        let workspaces = [
            (fixture.destinationMonitor, fixture.destination, fixture.destinationOther),
            (fixture.sourceMonitor, fixture.source, fixture.sourceOther)
        ]
        for (monitor, source, destination) in workspaces {
            let target = WorkspaceSwipePresentation.Workspace(id: destination, items: [])
            swipe.preparation = WorkspaceSwipePresentation.Preparation(
                monitor: monitor, frame: monitor.visibleFrame,
                source: WorkspaceSwipePresentation.Workspace(id: source, items: []), previous: target, next: target
            )
            XCTAssertTrue(swipe.begin(axis: .horizontal, cumulative: -monitor.visibleFrame.width, timestamp: timestamp))
        }
        XCTAssertEqual(Set(swipe.flights.keys), Set(workspaces.map { $0.0.id }))
        let intent = fixture.controller.intentLedger.newestFocusIntentId()
        fixture.clearOperations()

        fixture.manager.shutdown()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertFalse(swipe.hasPresentation)
        XCTAssertEqual(fixture.controller.intentLedger.newestFocusIntentId(), intent)
        XCTAssertEqual(fixture.activationCount, 0)
        XCTAssertNil(fixture.world.entry(for: token))
        XCTAssertNotNil(fixture.world.entry(for: fixture.external))
    }
}
