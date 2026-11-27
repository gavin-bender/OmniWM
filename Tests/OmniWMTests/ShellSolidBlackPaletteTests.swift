// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class ShellSolidBlackPaletteTests: XCTestCase {
    func testSolidBlackBarsDrawWithTheDarkPaletteAndFollowTheSettingLive() throws {
        let source = SolidBlackBarSource()
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let host = ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: resources,
            world: { ShellWorldData() }, vars: { [:] }, bars: { source.bars }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        host.config.trailing = ["clock"]
        let key = ShellBarKey(monitor: Monitor.ID(displayId: 92201))
        let clock = ShellWidgetHost.WidgetState(name: "clock", sourceURL: URL(fileURLWithPath: "/tmp/clock/init.luau"))
        clock.instances = [key: ShellWidgetHost.InstanceState()]
        host.widgets = [clock.name: clock]

        source.bars = [key: bar(solidBlack: true)]
        host.updateBars()
        XCTAssertNotNil(host.surfaceView(widget: clock.name, key: key, scale: 1))
        let surface = try XCTUnwrap(clock.instances[key]?.surface)
        XCTAssertTrue(surface.palette === resources.darkPalette)

        source.bars = [key: bar(solidBlack: false)]
        host.updateBars()
        XCTAssertTrue(clock.instances[key]?.surface === surface)
        XCTAssertTrue(surface.palette === resources.palette)

        source.bars[key]?.style.transparent = true
        host.updateBars()
        host.setWallpaperContrast([key: false])
        XCTAssertTrue(surface.palette === resources.lightPalette)
        host.setWallpaperContrast([key: true])
        XCTAssertTrue(surface.palette === resources.darkPalette)
        host.setWallpaperContrast([:])
        XCTAssertTrue(surface.palette === resources.palette)

        source.bars = [key: bar(solidBlack: true)]
        host.updateBars()
        XCTAssertTrue(surface.palette === resources.darkPalette)
    }

    func testIslandPlacementKeepsTheAppPaletteUnderASolidBlackBar() {
        let host = ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        let island = ShellBarKey(monitor: Monitor.ID(displayId: 92202), placement: .island)
        host.bars = [island: bar(solidBlack: true)]
        XCTAssertTrue(host.palette(for: island) === host.resources.palette)
    }

    func testDarkPaletteForegroundIsReadableOnBlackWhileTheAppIsLight() throws {
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        defer { NSApplication.shared.appearance = previous }
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let black = ShellRGBA(CGColor(gray: 0, alpha: 1))
        for role in [ShellRole.foreground, .secondaryForeground] {
            let color = ShellRGBA(resources.darkPalette.color(Color(packed: 0), default: role))
            XCTAssertGreaterThanOrEqual(color.contrast(black), ShellRGBA.readableTextContrast, "\(role)")
        }
    }

    func testWallpaperSamplesTheBarOnAnOffsetDisplay() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 90, width: 50, height: 10))
        let image = try XCTUnwrap(context.makeImage())
        let screen = CGRect(x: -200, y: 30, width: 200, height: 200)
        let left = CGRect(x: -200, y: 210, width: 100, height: 20)
        XCTAssertEqual(WorkspaceBarManager.wallpaperIsDark(image, behind: left, on: screen), false)
        XCTAssertEqual(WorkspaceBarManager.wallpaperIsDark(image, behind: left.offsetBy(dx: 100, dy: 0), on: screen), true)
        XCTAssertNil(WorkspaceBarManager.wallpaperIsDark(image, behind: left.offsetBy(dx: 200, dy: 0), on: screen))
    }

    private func bar(solidBlack: Bool) -> ShellBarData {
        var data = ShellBarData()
        data.style.solidBlack = solidBlack
        return data
    }
}

@MainActor
private final class SolidBlackBarSource {
    var bars: [ShellBarKey: ShellBarData] = [:]
}
