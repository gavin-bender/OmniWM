// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CryptoKit
import Foundation
import XCTest
@testable import OmniWM

final class ProductivityNotionTokenStoreTests: XCTestCase {
    func testSavedConnectionSurvivesReopeningAndCanBeReplacedAndRemoved() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func reopen() -> ProductivityNotionTokenStore {
            ProductivityNotionTokenStore(source: "widget-a", applicationSupport: directory)
        }
        XCTAssertNil(try reopen().load())
        try reopen().save("first-test-token")
        XCTAssertEqual(try reopen().load(), "first-test-token")
        XCTAssertNil(try ProductivityNotionTokenStore(source: "widget-b", applicationSupport: directory).load())
        try reopen().save("replacement-test-token")
        XCTAssertEqual(try reopen().load(), "replacement-test-token")
        try reopen().remove()
        XCTAssertNil(try reopen().load())
        XCTAssertNoThrow(try reopen().remove())
    }
}
