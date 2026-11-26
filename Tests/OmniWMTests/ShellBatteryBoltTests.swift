// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellBatteryBoltTests: XCTestCase {
    private enum Layout: CaseIterable {
        case beside
        case off
        case vertical

        var settings: [String: ShellServiceValue] {
            switch self {
            case .beside,
                 .vertical: [:]
            case .off: ["percent": .text("off")]
            }
        }

        var vertical: Bool {
            self == .vertical
        }
    }

    private struct TintCase {
        let level: Double
        let charging: Bool
        let power: ShellPower
        let tint: ShellRole
        let label: String
    }

    private struct PluggedCase {
        let level: Double
        let power: ShellPower
        let label: String
    }

    private static let fullyCharged = ShellPower(source: "ac", charged: true)
    private static let pluggedIn = ShellPower(source: "ac")
    private static let charging = ShellPower(source: "ac", full: 40)
    private static let onBattery = ShellPower(source: "battery", remaining: 254)

    func testBatteryDetailsShowsBoltOnACWhenFullyChargedButNotCharging() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            let tree = render(widget, level: 100, charging: false, power: Self.fullyCharged, layout: layout)
            XCTAssertNotNil(bolt(in: tree, widget), "100% on AC, not charging, \(layout)")
        }
    }

    func testBatteryDetailsShowsBoltOnACDuringOptimizedChargingHold() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            let tree = render(widget, level: 80, charging: false, power: Self.pluggedIn, layout: layout)
            XCTAssertNotNil(bolt(in: tree, widget), "80% hold on AC, not charging, \(layout)")
        }
    }

    func testBatteryDetailsHidesBoltOnBatteryPower() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            for level in [100.0, 76, 15] {
                let tree = render(widget, level: level, charging: false, power: Self.onBattery, layout: layout)
                XCTAssertNil(bolt(in: tree, widget), "\(level)% on battery, \(layout)")
            }
        }
    }

    func testBatteryDetailsKeepsBoltWhileCharging() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            let tree = render(widget, level: 40, charging: true, power: Self.charging, layout: layout)
            XCTAssertNotNil(bolt(in: tree, widget), "40% charging, \(layout)")
        }
    }

    func testBatteryDetailsTintsFillGreenOnlyWhileActuallyCharging() throws {
        let widget = try ShellRenderedWidget("battery-details")
        let cases = [
            TintCase(level: 80, charging: true, power: Self.charging, tint: .success, label: "80% charging"),
            TintCase(level: 40, charging: true, power: Self.charging, tint: .success, label: "40% charging"),
            TintCase(
                level: 100, charging: false, power: Self.fullyCharged, tint: .foreground, label: "100% on AC, charged"
            ),
            TintCase(level: 80, charging: false, power: Self.pluggedIn, tint: .foreground, label: "80% hold on AC"),
            TintCase(
                level: 15, charging: false, power: Self.pluggedIn, tint: .warning, label: "15% on AC, not charging"
            ),
            TintCase(level: 76, charging: false, power: Self.onBattery, tint: .foreground, label: "76% on battery")
        ]
        for test in cases {
            let tree = render(widget, level: test.level, charging: test.charging, power: test.power, layout: .beside)
            let cellFill = try opaqueLevelFill(in: tree, test.label)
            XCTAssertEqual(role(cellFill.paint.fill), test.tint, test.label)
        }
    }

    func testBatteryDetailsDrawsBoltInBackgroundWhereFillReachesUnderIt() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for level in try [100, Self.boltContrastLevel()] {
            for (charging, power) in [(false, Self.pluggedIn), (true, Self.charging)] {
                let label = "\(level)% charging=\(charging)"
                let tree = render(widget, level: level, charging: charging, power: power, layout: .beside)
                let glyph = try XCTUnwrap(bolt(in: tree, widget), label)
                XCTAssertEqual(role(glyph.content.color), .background, label)
            }
        }
    }

    func testBatteryDetailsDrawsBoltInForegroundBelowTheFillThreshold() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for level in try [Self.boltContrastLevel().nextDown, 0] {
            for (charging, power) in [(false, Self.pluggedIn), (true, Self.charging)] {
                let label = "\(level)% charging=\(charging)"
                let tree = render(widget, level: level, charging: charging, power: power, layout: .beside)
                let glyph = try XCTUnwrap(bolt(in: tree, widget), label)
                XCTAssertEqual(role(glyph.content.color), .foreground, label)
            }
        }
    }

    func testBatterySymbolUsesBoltVariantOnACEvenWhenNotCharging() throws {
        let widget = try ShellRenderedWidget("battery")
        let cases = [
            PluggedCase(level: 100, power: Self.fullyCharged, label: "100% on AC, charged"),
            PluggedCase(level: 80, power: Self.pluggedIn, label: "80% hold on AC")
        ]
        for test in cases {
            let tree = render(widget, level: test.level, charging: false, power: test.power, layout: .beside)
            let name = try XCTUnwrap(batterySymbol(in: tree, widget), test.label)
            XCTAssertTrue(name.contains("bolt"), "\(test.label): \(name)")
        }
    }

    func testBatterySymbolUsesBoltVariantWhileCharging() throws {
        let widget = try ShellRenderedWidget("battery")
        let tree = render(widget, level: 40, charging: true, power: Self.charging, layout: .beside)
        let name = try XCTUnwrap(batterySymbol(in: tree, widget))
        XCTAssertTrue(name.contains("bolt"), name)
    }

    func testBatterySymbolHasNoBoltOnBatteryPower() throws {
        let widget = try ShellRenderedWidget("battery")
        for level in [100.0, 76] {
            let tree = render(widget, level: level, charging: false, power: Self.onBattery, layout: .beside)
            let name = try XCTUnwrap(batterySymbol(in: tree, widget), "\(level)%")
            XCTAssertFalse(name.contains("bolt"), "\(level)%: \(name)")
        }
    }

    func testPowerModeIndicatorsAndTooltipsFollowTheActiveMode() throws {
        let cases: [(ShellPowerMode?, Bool, String?, String?)] = [
            (.low, false, "Low Power Mode", "leaf.fill"),
            (.high, true, "High Power Mode", "chevron.up.2"),
            (.automatic, true, "Automatic Power Mode", nil),
            (nil, true, "Low Power Mode", "leaf.fill"),
            (nil, false, nil, nil)
        ]
        for name in ["battery", "battery-wifi"] {
            let widget = try ShellRenderedWidget(source: ShellRenderedWidget.bundledSource(name),
                                                 resources: ShellResources(motion: MotionPolicy(animationsEnabled: true)))
            for (mode, lowPower, label, symbol) in cases {
                let power = ShellPower(lowPower: lowPower, mode: mode, supportsHighPower: true)
                for layout in [Layout.beside, .vertical] {
                    let bar = render(widget, level: 76, charging: true, power: power, layout: layout)
                    let help = try XCTUnwrap(bar.first.map { widget.text.string($0.content.help) })
                    XCTAssertTrue(help.contains("76"), name)
                    if let label {
                        XCTAssertTrue(help.contains(label), help)
                    } else {
                        XCTAssertFalse(help.contains("Power Mode"), help)
                    }
                    let popout = widget.renderPopout()
                    if mode == .high {
                        let chevron = try XCTUnwrap(bar.first {
                            $0.kind == .symbol && widget.text.string($0.content.text) == "chevron.up.2"
                        })
                        XCTAssertEqual(role(chevron.content.color), .accent, name)
                    }
                    let shaders = popout.filter { $0.kind == .shader }.map { widget.text.string($0.content.text) }
                    XCTAssertEqual(shaders, symbol == nil ? [] : ["battery-power-curves.metal"], name)
                    if let content = popout.first(where: { $0.kind == .shader })?.content {
                        let low = symbol == "leaf.fill"
                        XCTAssertEqual(content.params.x, low ? 1 : 0)
                        XCTAssertEqual(content.shaderDurationMS, low ? 3000 : 0)
                        XCTAssertEqual(widget.surface.shaderInput(content, lowPower: true).rate, low ? 8 : 0)
                        XCTAssertEqual(widget.surface.shaderInput(content, lowPower: false).rate, low ? 8 : 60)
                        widget.resources.motion.systemReducesMotion = true
                        XCTAssertEqual(widget.surface.shaderInput(content, lowPower: true).rate, 0)
                        widget.resources.motion.systemReducesMotion = false
                    }
                    XCTAssertFalse(bar.contains { $0.kind == .shader }, name)
                    for tree in [bar, popout] {
                        let badges = tree.filter { $0.kind == .symbol }.map { widget.text.string($0.content.text) }
                            .filter { ["leaf.fill", "chevron.up.2"].contains($0) }
                        XCTAssertEqual(badges, symbol.map { [$0] } ?? [], name)
                    }
                }
            }
        }
    }

    func testLowPowerCurvesSettleAndHighPowerPulsesLoopInThemeAccent() async throws {
        let widget = try ShellRenderedWidget("battery")
        let shaders = try XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("shaders")
        let program = widget.resources.shaders.program(source: "battery-power-curves.metal", directories: [shaders])
        await waitForShaders(in: widget.resources.shaders) { !program.isCompiling }
        let pipeline = try XCTUnwrap(program.pipeline, program.failure ?? "")
        let size = CGSize(width: 320, height: 280)
        func frame(at time: Double, low: Bool, accent: SIMD4<Float>, still: Bool = false) throws -> [UInt8] {
            var colors = ShellShaderInput.Colors(repeating: .zero)
            colors[ShellRole.accent.rawValue] = accent
            colors[ShellRole.foreground.rawValue] = SIMD4(repeating: 1)
            let input = ShellShaderInput(values: SIMD4(low ? 1 : 0, 0, 0, 0), rate: still ? 0 : (low ? 8 : 60), colors: colors, playFor: low ? 3 : 0)
            return try ShellShaderTests.pixels(pipeline, input.uniforms(
                size: size, scale: 1, elapsed: time, now: 0, transition: .settled
            ), width: Int(size.width), height: Int(size.height))
        }
        for low in [true, false] {
            let accent = SIMD4<Float>(1, 0, 0, 1)
            let first = try frame(at: 0, low: low, accent: accent)
            let alpha = stride(from: 3, to: first.count, by: 4).map { first[$0] }
            XCTAssertTrue(alpha.contains(0))
            XCTAssertGreaterThan(alpha.max() ?? 0, 50)
            XCTAssertNotEqual(first, try frame(at: 0.5, low: low, accent: accent))
            XCTAssertNotEqual(first, try frame(at: 0, low: low, accent: SIMD4(0, 0, 1, 1)))
            if low {
                let settled = try frame(at: 3, low: true, accent: accent)
                XCTAssertEqual(settled, try frame(at: 6, low: true, accent: accent))
                XCTAssertEqual(settled, try frame(at: 0, low: true, accent: accent, still: true))
            } else {
                let loop = try frame(at: 4.8, low: false, accent: accent)
                XCTAssertTrue(zip(first, loop).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
            }
        }
    }

    private func render(
        _ widget: ShellRenderedWidget,
        level: Double,
        charging: Bool,
        power: ShellPower,
        layout: Layout
    ) -> [TreeNode] {
        widget.set("settings") { ShellServiceValue.object(layout.settings).write(to: &$0) }
        widget.set("battery") { $0.number(level) }
        widget.set("charging") { $0.bool(charging) }
        widget.set("power") { power.write(into: &$0) }
        var bar = ShellBarData(badges: "text")
        bar.style.height = 32
        bar.style.vertical = layout.vertical
        bar.style.position = layout.vertical ? "left" : "top"
        widget.render(bar)
        return widget.tree()
    }

    private static func boltContrastLevel() throws -> Double {
        try ShellRenderedWidget.bundledNumber(
            "module.boltContrastLevel", requiring: "battery", from: "battery-details"
        )
    }

    private func bolt(in tree: [TreeNode], _ widget: ShellRenderedWidget) -> TreeNode? {
        tree.first { $0.kind == .symbol && widget.text.string($0.content.text) == "bolt.fill" }
    }

    private func batterySymbol(in tree: [TreeNode], _ widget: ShellRenderedWidget) -> String? {
        tree.lazy
            .filter { $0.kind == .symbol }
            .map { widget.text.string($0.content.text) }
            .first { $0.hasPrefix("battery.") }
    }

    private func opaqueLevelFill(in tree: [TreeNode], _ label: String) throws -> TreeNode {
        let tints: Set<ShellRole> = [.foreground, .success, .warning, .error]
        let fills = tree.filter { node in
            node.kind != .symbol && node.kind != .label
                && role(node.paint.fill).map(tints.contains) == true
                && node.paint.fill.role >> 8 == 255
        }
        XCTAssertEqual(fills.count, 1, label)
        return try XCTUnwrap(fills.first, label)
    }

    private func role(_ color: Color) -> ShellRole? {
        ShellRole(rawValue: Int(color.role & 0xFF) - 1)
    }
}
