// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellBarIconSizeTests: XCTestCase {
    private static let scales: [Double] = [1, 1.5]
    private static let overriddenBarSymbol = 20.0
    private static let bundledLookModule = "lib/look.luau"

    private static let symbolWidgets: [(name: String, symbols: [String])] = [
        ("battery", ["battery.75percent"]),
        ("calendar", ["calendar"]),
        ("clock", ["calendar"]),
        ("control-center", ["switch.2"]),
        ("launcher", ["magnifyingglass"]),
        ("media", ["play.fill"]),
        ("notifications", ["bell.badge"]),
        ("omniwm", ["omniwm", "rectangle.split.3x1"]),
        ("privacy", ["mic.fill", "video.fill"]),
        ("stats", ["cpu", "memorychip"]),
        ("volume", ["speaker.wave.2.fill"]),
        ("weather", ["sun.max"]),
        ("world-clock", ["globe"]),
        ("wifi", ["wifi.slash"])
    ]

    func testDefaultBarSymbolsRenderAtBarSymbolSizeTimesScale() throws {
        let barSymbol = try Self.look("module.size.barSymbol")
        for (name, expected) in Self.symbolWidgets {
            let widget = try ShellRenderedWidget(name)
            for scale in Self.scales {
                let symbols = try renderSymbols(widget, name: name, scale: scale, expected: expected)
                for (symbol, node) in symbols {
                    XCTAssertEqual(
                        ShellTextStyle.symbolSize(for: node.content.style),
                        Float(barSymbol * scale),
                        "\(name) \(symbol) scale=\(scale)"
                    )
                }
            }
        }
    }

    func testDefaultBarSymbolsUseTheSharedBarWeight() throws {
        let barWeight = try Self.barWeight()
        for (name, expected) in Self.symbolWidgets {
            let widget = try ShellRenderedWidget(name)
            for scale in Self.scales {
                let symbols = try renderSymbols(widget, name: name, scale: scale, expected: expected)
                for (symbol, node) in symbols {
                    XCTAssertEqual(
                        ShellTextStyle.symbolWeight(for: node.content.style),
                        barWeight,
                        "\(name) \(symbol) scale=\(scale)"
                    )
                }
            }
        }
    }

    func testDefaultBarSymbolsFollowTheSharedBarSymbolToken() throws {
        let override = """
        return require("./skin")({ capsules = true, size = { barSymbol = \(Self.overriddenBarSymbol) } })
        """
        for (name, expected) in Self.symbolWidgets {
            let widget = try restyledWidget(name, look: override)
            for scale in Self.scales {
                let symbols = try renderSymbols(widget, name: name, scale: scale, expected: expected)
                for (symbol, node) in symbols {
                    XCTAssertEqual(
                        ShellTextStyle.symbolSize(for: node.content.style),
                        Float(Self.overriddenBarSymbol * scale),
                        "\(name) \(symbol) scale=\(scale)"
                    )
                }
            }
        }
    }

    func testMusicBarKeepsQualifiersOnlyWhenTheyFit() throws {
        let widget = try ShellRenderedWidget("media")
        let bar = try bar(scale: 1)
        var media = ShellMedia()
        for (title, base, expected) in [
            ("One [Remix]", "One", "One [Remix]"),
            ("DARK AURA FUNK (Super Slowed)", "DARK AURA FUNK", "DARK AURA FUNK")
        ] {
            media.title = title
            media.musicTitle = base
            widget.set("media") { media.write(into: &$0) }
            widget.render(bar)
            XCTAssertTrue(widget.strings().contains(expected))
        }
    }

    func testMediaBarSizesArtworkAndSwapsThePlaybackIndicator() throws {
        let widget = try ShellRenderedWidget("media")
        let bar = try bar(scale: 1)
        var media = ShellMedia()
        media.title = "A lengthy video title about configuring TopBar Plus"
        media.bundle = "com.apple.Music"
        media.artwork = "media/cover"
        media.playing = true
        widget.set("media") { media.write(into: &$0) }
        widget.render(bar)
        let originalSize = widget.surface.size
        media.compactTitle = "iPhone Duo"
        var playingSize: CGSize?
        for ratio in [1.0, 16.0 / 9.0] {
            media.artworkAspectRatio = ratio
            widget.set("media") { media.write(into: &$0) }
            widget.render(bar)
            XCTAssertLessThan(widget.surface.size.width, originalSize.width - 40)
            if let playingSize { XCTAssertEqual(widget.surface.size, playingSize) }
            playingSize = widget.surface.size
            XCTAssertTrue(widget.strings().contains("iPhone Duo"))
            let art = try XCTUnwrap(widget.tree().first { $0.kind == .bitmap })
            XCTAssertEqual(art.layout.width, Float(18 * ratio), accuracy: 0.01)
            XCTAssertEqual(art.layout.height, 18)
            let waveform = try XCTUnwrap(widget.tree().first { $0.kind == .shader })
            XCTAssertFalse(waveform.content.audio)
            XCTAssertGreaterThan(waveform.content.rate, 0)
            let source = widget.text.string(waveform.content.text)
            let directory = try XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("shaders")
            _ = try ShellShaderLibrary.pipeline(Data(contentsOf: directory.appendingPathComponent(source)), name: source)
        }
        media.artwork = nil
        media.artworkAspectRatio = nil
        media.playing = false
        widget.set("media") { media.write(into: &$0) }
        widget.render(bar)
        XCTAssertEqual(widget.surface.size, playingSize)
        XCTAssertFalse(widget.tree().contains { $0.kind == .shader || $0.kind == .bitmap })
        XCTAssertTrue(widget.tree().contains { $0.kind == .image && widget.text.string($0.content.text) == media.bundle })
        XCTAssertTrue(widget.tree().contains { $0.kind == .symbol && widget.text.string($0.content.text) == "play.fill" })
    }

    func testSystemStatsNeedleTracksSharedCPUReading() throws {
        let widget = try ShellRenderedWidget("system-stats")
        let data = try bar(scale: 1)
        for (load, angle): (Double?, Float) in [(nil, -135), (0, -135), (49, 0), (51, 0), (100, 135)] {
            widget.set("cpu") { writer in
                if let load { writer.number(load) } else { writer.null() }
            }
            widget.render(data)
            let needle = try XCTUnwrap(widget.tree().last { $0.kind == .path })
            XCTAssertEqual(needle.paint.rotate, angle)
            XCTAssertNotEqual(needle.content.motion, 0)
        }
    }

    func testGaugeColorsOnlyOnePressureSegmentAndFillsTheTrackAtCritical() throws {
        let widget = try ShellRenderedWidget("system-stats")
        let data = try bar(scale: 1)
        var segments = Set<String>()
        for state in ["nominal", "fair", "serious", "critical"] {
            widget.set("thermalPressure") { $0.string(state) }
            widget.render(data)
            let paths = widget.tree().filter { $0.kind == .path }
            guard paths.count == 3 else { return XCTFail("Expected track, pressure segment, and needle") }
            XCTAssertEqual(paths[1].paint.opacity, state == "nominal" ? 0 : 1)
            XCTAssertEqual(paths[0].content.text == paths[1].content.text, state == "critical")
            if state != "nominal" { segments.insert(widget.text.string(paths[1].content.text)) }
            let color = state == "critical" ? ShellRole.error : .warning
            XCTAssertEqual(Int(paths[1].paint.fill.role & 0xFF), color.rawValue + 1)
        }
        XCTAssertEqual(segments.count, 3)
    }

    func testWiFiFanFillsTheBarSymbolBox() throws {
        let barSymbol = try Self.look("module.size.barSymbol")
        let bands = try ShellRenderedWidget.bundledNumber("module.bandCount", requiring: "wifi", from: "wifi")
        let widget = try ShellRenderedWidget("wifi")
        for scale in Self.scales {
            feed(widget, name: "wifi-on")
            try widget.render(bar(scale: scale))
            let paths = widget.tree().filter { $0.kind == .path }
            XCTAssertEqual(paths.count, Int(bands), "scale=\(scale)")
            for path in paths {
                XCTAssertEqual(path.layout.width, Float(barSymbol * scale), "scale=\(scale)")
                XCTAssertEqual(path.layout.height, Float(barSymbol * scale), "scale=\(scale)")
            }
        }
    }

    func testBluetoothRuneIsTheRuneScaleOfTheBarSymbol() throws {
        let barSymbol = try Self.look("module.size.barSymbol")
        let runeScale = try ShellRenderedWidget.bundledNumber(
            "module.runeScale", requiring: "bluetooth", from: "bluetooth"
        )
        let widget = try ShellRenderedWidget("bluetooth")
        for scale in Self.scales {
            feed(widget, name: "bluetooth")
            try widget.render(bar(scale: scale))
            let rune = try XCTUnwrap(widget.tree().first { $0.kind == .path }, "scale=\(scale)")
            XCTAssertEqual(rune.layout.height, Float(barSymbol * scale * runeScale), "scale=\(scale)")
        }
    }

    func testBluetoothRuneUsesSharedDrawnIconStroke() throws {
        let runeStroke = try ShellRenderedWidget.bundledNumber(
            "module.runeStroke", requiring: "bluetooth", from: "bluetooth"
        )
        let widget = try ShellRenderedWidget("bluetooth")
        for scale in Self.scales {
            feed(widget, name: "bluetooth")
            try widget.render(bar(scale: scale))
            let rune = try XCTUnwrap(widget.tree().first { $0.kind == .path }, "scale=\(scale)")
            XCTAssertEqual(rune.paint.strokeWidth, Float(runeStroke), "scale=\(scale)")
        }
    }

    private func renderSymbols(
        _ widget: ShellRenderedWidget,
        name: String,
        scale: Double,
        expected: [String]
    ) throws -> [(String, TreeNode)] {
        feed(widget, name: name)
        var data = try bar(scale: scale)
        if name == "omniwm" {
            data.layout = .niri
        }
        widget.render(data)
        let symbols = widget.tree().filter { $0.kind == .symbol }.map { (widget.text.string($0.content.text), $0) }
        XCTAssertEqual(symbols.map { $0.0 }.sorted(), expected.sorted(), "\(name) scale=\(scale)")
        return symbols
    }

    private static func look(_ expression: String) throws -> Double {
        try ShellRenderedWidget.bundledNumber(expression, requiring: "look", from: "battery")
    }

    private static func barWeight() throws -> NSFont.Weight {
        let probe = try ShellRenderedWidget.probe("""
        local look = require("../lib/look")
        function render(ctx)
            return ui.symbol{ name = "bell", weight = look.barWeight }
        end
        """, modulesOf: "battery")
        let symbol = try XCTUnwrap(probe.tree().first { $0.kind == .symbol })
        return ShellTextStyle.symbolWeight(for: symbol.content.style)
    }

    private func bar(scale: Double) throws -> ShellBarData {
        var bar = ShellBarData(badges: "text")
        bar.style.height = try Self.look("module.base") * scale
        bar.style.vertical = false
        bar.style.position = "top"
        bar.style.statsButton = true
        return bar
    }

    private func restyledWidget(_ name: String, look: String) throws -> ShellRenderedWidget {
        let source = try ShellRenderedWidget.bundledSource(name)
        var replaced = false
        let modules = source.modules.map { module in
            guard module.path == Self.bundledLookModule else { return module }
            replaced = true
            return ShellWidgetSource.Module(path: module.path, source: look)
        }
        XCTAssertTrue(replaced, "\(name) does not load lib/look.luau")
        return try ShellRenderedWidget(name: name, source: source.main, modules: modules, chunk: source.chunk)
    }

    private func settings(_ widget: ShellRenderedWidget, _ values: [String: ShellServiceValue]) {
        widget.set("settings") { ShellServiceValue.object(values).write(to: &$0) }
    }

    private func feed(_ widget: ShellRenderedWidget, name: String) {
        switch name {
        case "battery":
            widget.set("battery") { $0.number(76) }
            widget.set("charging") { $0.bool(false) }
            widget.set("power") { ShellPower(source: "battery", remaining: 254).write(into: &$0) }
        case "calendar":
            widget.set("calendar") { ShellCalendar(access: "full", events: [], month: nil).write(into: &$0) }
            widget.set("seconds") { $0.number(1_000_000) }
        case "clock":
            settings(widget, ["icon": .bool(true)])
            widget.set("clock") { $0.string("9:41 AM") }
            widget.set("date") { $0.string("Fri Oct 23") }
        case "media":
            var media = ShellMedia()
            media.title = "Northern Lights"
            media.artist = "Sample Artist"
            media.bundle = "com.apple.Music"
            widget.set("media") { media.write(into: &$0) }
            widget.set("seconds") { $0.number(1012) }
        case "privacy":
            settings(widget, ["icons": .bool(true)])
            widget.set("privacy") { ShellPrivacy(microphone: true, camera: true).write(into: &$0) }
        case "stats":
            widget.set("cpu") { $0.number(38) }
            widget.set("memory") { $0.number(64) }
        case "volume":
            widget.set("volume") { $0.number(62) }
            widget.set("muted") { $0.bool(false) }
        case "weather":
            widget.set("weather") { ShellWeather(temp: 18, code: 0, day: true, unit: "°C").write(into: &$0) }
        case "world-clock":
            widget.set("seconds") { $0.number(1_791_924_120) }
        case "wifi":
            widget.set("wifi") { ShellWiFi(power: false).write(into: &$0) }
        case "wifi-on":
            widget.set("wifi") {
                ShellWiFi(power: true, connected: true, ssid: "Harbour Home", rssi: -55, location: "authorized")
                    .write(into: &$0)
            }
        case "bluetooth":
            widget.set("bluetooth") {
                ShellBluetooth(power: true, access: "granted", devices: [
                    ShellBluetoothDevice(id: "airpods", name: "AirPods Pro", kind: "headphones", connected: true)
                ]).write(into: &$0)
            }
        default:
            break
        }
    }
}
