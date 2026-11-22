// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Darwin
@testable import OmniWM
import XCTest

final class NativeDockSwipeFilterTests: XCTestCase {
    func testBlocksLegacyHorizontalAndVerticalDockSwipesOnlyWhileEnabled() throws {
        let tap = InputTapThread()
        let event = try dockEvent(kind: 23, motion: 2)
        XCTAssertNotNil(tap.evaluateTap(type: event.type, event: event))

        tap.updateFilterSnapshot { $0.suppressNativeSpaceSwitchGestures = true }
        XCTAssertNil(tap.evaluateTap(type: event.type, event: event))
        XCTAssertNotNil(tap.evaluateTap(type: .keyDown, event: event))
        let horizontal = try dockEvent(kind: 23, motion: 1)
        XCTAssertNil(tap.evaluateTap(type: horizontal.type, event: horizontal))

        for event in try [dockEvent(kind: 23, motion: 3), dockEvent(kind: 8, motion: 2)] {
            XCTAssertNotNil(tap.evaluateTap(type: event.type, event: event))
        }

        tap.updateFilterSnapshot { $0.isInputSuppressed = true }
        XCTAssertNotNil(tap.evaluateTap(type: event.type, event: event))
    }

    func testDockSwipeReadsAttachedHIDMotionAndFallsBackForUnknownMotion() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("The HID payload is used on macOS 27.") }
        let tap = InputTapThread()
        tap.updateFilterSnapshot { $0.suppressNativeSpaceSwitchGestures = true }

        let vertical = try dockEvent(kind: 0, motion: 0)
        try attachHIDMotion(2, to: vertical)
        XCTAssertNil(tap.evaluateTap(type: vertical.type, event: vertical))

        let pinch = try dockEvent(kind: 23, motion: 2)
        try attachHIDMotion(3, to: pinch)
        XCTAssertNotNil(tap.evaluateTap(type: pinch.type, event: pinch))

        let incomplete = try dockEvent(kind: 23, motion: 1)
        try attachHIDMotion(0, to: incomplete)
        XCTAssertNil(tap.evaluateTap(type: incomplete.type, event: incomplete))
    }

    private func dockEvent(kind: Int64, motion: Int64) throws -> CGEvent {
        let type = try XCTUnwrap(CGEventType(rawValue: InputTapThread.dockSwipeEventType))
        let kindField = try XCTUnwrap(CGEventField(rawValue: 110))
        let motionField = try XCTUnwrap(CGEventField(rawValue: 123))
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = type
        event.setIntegerValueField(kindField, value: kind)
        event.setIntegerValueField(motionField, value: motion)
        return event
    }

    private func attachHIDMotion(_ motion: Int, to event: CGEvent) throws {
        let skyLight = try XCTUnwrap(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY))
        defer { dlclose(skyLight) }
        let ioKit = try XCTUnwrap(dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY))
        defer { dlclose(ioKit) }

        let create = unsafeBitCast(
            try XCTUnwrap(dlsym(ioKit, "IOHIDEventCreate")),
            to: (@convention(c) (UnsafeRawPointer?, UInt32, UInt64, UInt32) -> UnsafeMutableRawPointer?).self
        )
        let setInteger = unsafeBitCast(
            try XCTUnwrap(dlsym(ioKit, "IOHIDEventSetIntegerValue")),
            to: (@convention(c) (UnsafeMutableRawPointer, UInt32, Int) -> Void).self
        )
        let attach = unsafeBitCast(
            try XCTUnwrap(dlsym(skyLight, "SLEventSetIOHIDEvent")),
            to: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void).self
        )

        let payload = try XCTUnwrap(create(nil, 23, 0, 0))
        defer { Unmanaged<CFTypeRef>.fromOpaque(payload).release() }
        setInteger(payload, (23 << 16) | 1, motion)
        attach(Unmanaged.passUnretained(event).toOpaque(), payload)
    }
}
