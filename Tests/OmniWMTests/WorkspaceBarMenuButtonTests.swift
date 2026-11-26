// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarMenuButtonTests: XCTestCase {
    func testMenuButtonIsTwentyFourPointsOnATwentyEightPointBar() throws {
        let widget = try ShellRenderedWidget("omniwm")
        for vertical in [false, true] {
            var style = ShellBarStyle()
            style.height = 28
            style.vertical = vertical
            widget.render(ShellBarData(style: style))
            XCTAssertEqual(widget.surface.size, CGSize(width: 24, height: 24), "vertical \(vertical)")
        }
    }

    func testLeftAndRightClicksBothOpenTheStatusMenuWithTheirButton() throws {
        let widget = try ShellRenderedWidget("omniwm")
        widget.render(ShellBarData())
        let center = CGPoint(x: 10, y: 10)
        widget.surface.press(at: center)
        widget.surface.release(at: center, event: ShellEvent(button: .left, modifiers: []))
        widget.surface.press(at: center, button: .right)
        widget.surface.release(at: center, event: ShellEvent(button: .right, modifiers: []))
        XCTAssertEqual(widget.clicks.map(\.action), [ShellRequest.statusMenuCommand, ShellRequest.statusMenuCommand])
        XCTAssertEqual(widget.clicks.map(\.button), [.left, .right])
    }

    func testMergedButtonRoutesRightClickToAppleWhenReplacingTheMenuBar() throws {
        let widget = try ShellRenderedWidget("omniwm")
        var style = ShellBarStyle()
        style.hidesMenuBar = true
        widget.render(ShellBarData(style: style))
        XCTAssertTrue(widget.strings().contains("gearshape.fill"))
        let center = CGPoint(x: 10, y: 10)
        for button in [ShellEvent.Button.left, .right] {
            widget.surface.press(at: center, button: button)
            widget.surface.release(at: center, event: ShellEvent(button: button, modifiers: []))
        }
        XCTAssertEqual(widget.clicks.map(\.action), [ShellRequest.statusMenuCommand, "menu apple"])
    }

    func testControlsSymbolChoicesRenderAndYieldToSecureInput() throws {
        let widget = try ShellRenderedWidget("omniwm")
        for (choice, symbol) in [("tiled-windows", "rectangle.split.2x1.fill"), ("sliders", "slider.horizontal.3"),
                                 ("apple-logo", "applelogo"), ("unknown", "gearshape.fill")] {
            widget.set("settings") { ShellServiceValue.object(["controlsSymbol": .text(choice)]).write(to: &$0) }
            widget.render(ShellBarData())
            XCTAssertTrue(widget.strings().contains(symbol), choice)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
        }
        widget.set("settings") { ShellServiceValue.object(["controlsSymbol": .text("sliders")]).write(to: &$0) }
        var style = ShellBarStyle()
        style.secureInput = true
        widget.render(ShellBarData(style: style))
        XCTAssertTrue(widget.strings().contains("lock.fill"))
    }

    func testSignatureChoicesLoadBundledArtworkAtButtonSize() throws {
        let defaults = try XCTUnwrap(ShellDefaults.bundled)
        let source = try ShellRenderedWidget.bundledSource("omniwm")
        let widget = try ShellRenderedWidget(
            name: "omniwm", source: source.main, directories: [defaults], modules: source.modules, chunk: source.chunk
        )
        for choice in ["gb-signature", "gb-apple-cutout"] {
            widget.set("settings") { ShellServiceValue.object(["controlsSymbol": .text(choice)]).write(to: &$0) }
            widget.render(ShellBarData())
            let bitmap = try XCTUnwrap(widget.tree().first { $0.kind == .bitmap })
            let path = widget.text.string(bitmap.content.text)
            XCTAssertEqual(path, "assets/\(choice).png")
            XCTAssertGreaterThan(bitmap.layout.width, 0)
            XCTAssertEqual(bitmap.layout.width, bitmap.layout.height)
            XCTAssertNotNil(widget.resources.images.image(path, folders: [defaults])?.frames.first)
        }
    }

    func testMenuButtonShowsTheSecureInputLockOnlyWhileActive() throws {
        let widget = try ShellRenderedWidget("omniwm")
        var style = ShellBarStyle()
        style.secureInput = true
        widget.render(ShellBarData(style: style))
        XCTAssertEqual(widget.strings(), [
            ShellLocalizer.string("Secure Input is on: Option shortcuts are paused", []),
            "lock.fill"
        ])

        style.secureInput = false
        widget.render(ShellBarData(style: style))
        XCTAssertEqual(widget.strings(), [ShellLocalizer.string("Window manager controls", []), "gearshape.fill"])
    }
}
