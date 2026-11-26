// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import IOKit.ps
import OmniWMPowerMode
import ServiceManagement

enum ShellPowerMode: String, CaseIterable, Sendable {
    case automatic, low, high

    private var preferenceValue: Int {
        switch self {
        case .automatic: 0
        case .low: 1
        case .high: 2
        }
    }

    @MainActor
    static func sample(into power: inout ShellPower) {
        let source: CFString
        switch power.source {
        case "battery": source = kIOPMBatteryPowerKey as CFString
        case "ac": source = kIOPMACPowerKey as CFString
        default: return
        }
        guard let available = PowerPreferences.available,
              let preferences = PowerPreferences.copy?()?.takeRetainedValue() as? [String: [String: Any]],
              let profile = preferences[source as String],
              available("LowPowerMode" as CFString, source) != 0
        else { return }
        // pmset stores the three-valued power mode in the LowPowerMode preference.
        let value = profile["LowPowerMode"] as? Int ?? 0
        power.mode = allCases.first { $0.preferenceValue == value }
        power.supportsHighPower = available("HighPowerMode" as CFString, source) != 0
    }

    enum ApplyResult: Sendable {
        case applied
        case requiresApproval
        case unavailable
        case rejected
    }

    @MainActor
    func apply(onBattery: Bool) async throws -> ApplyResult {
        guard let setup = try PowerModeHelperSetup.register() else { return .unavailable }
        if setup.status == .requiresApproval { return .requiresApproval }
        let name = setup.name
        let connection = NSXPCConnection(machServiceName: name, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OmniWMPowerModeService.self)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                continuation.resume(throwing: error)
            }
            guard let helper = proxy as? OmniWMPowerModeService else {
                continuation.resume(throwing: CocoaError(.xpcConnectionInvalid))
                return
            }
            helper.setMode(preferenceValue, onBattery: onBattery) { @Sendable applied in
                continuation.resume(returning: applied ? .applied : .rejected)
            }
        }
    }
}

@MainActor
public enum PowerModeHelperSetup {
    static func register() throws -> (name: String, status: SMAppService.Status)? {
        let bundle = Bundle.main
        guard let identifier = bundle.bundleIdentifier else { return nil }
        let name = identifier + ".PowerMode"
        let plist = name + ".plist"
        let files = FileManager.default
        guard files.fileExists(atPath: bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + plist).path),
              files.isExecutableFile(atPath: bundle.bundleURL.appendingPathComponent("Contents/MacOS/OmniWMPowerHelper").path)
        else { return nil }

        let service = SMAppService.daemon(plistName: plist)
        let initial = service.status
        if initial == .enabled || initial == .requiresApproval { return (name, initial) }
        // Service Management can return notFound for a bundled daemon before its first registration.
        do {
            try service.register()
        } catch {
            let status = service.status
            guard status == .enabled || status == .requiresApproval else { throw error }
            return (name, status)
        }
        let status = service.status
        guard status == .enabled || status == .requiresApproval else {
            throw NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorJobNotFound))
        }
        return (name, status)
    }

    public static func run() throws {
        guard let setup = try register() else { throw CocoaError(.fileNoSuchFile) }
        if setup.status == .requiresApproval {
            print("Power mode helper registered. Approval required in Login Items & Extensions.")
            SMAppService.openSystemSettingsLoginItems()
        } else {
            print("Power mode helper enabled.")
        }
    }
}

@MainActor
private enum PowerPreferences {
    typealias Copy = @convention(c) () -> Unmanaged<CFDictionary>?
    typealias Available = @convention(c) (CFString, CFString) -> UInt8

    static let copy = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMCopyActivePMPreferences")
        .map { unsafeBitCast($0, to: Copy.self) }
    static let available = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMFeatureIsAvailable")
        .map { unsafeBitCast($0, to: Available.self) }
}
