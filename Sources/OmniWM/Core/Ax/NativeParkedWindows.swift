// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMSystemGestures

@MainActor
final class NativeParkedWindows {
    struct Owner: Codable, Equatable {
        let pid: pid_t
        let launchDate: Date
    }

    private let defaults: UserDefaults
    private let owner: @MainActor (UInt32) -> Owner?
    private let orderedIn: @MainActor (UInt32) -> Bool?
    private let order: @MainActor (UInt32, Bool) -> Bool
    private let available: @MainActor () -> Bool
    private let key = "nativeParkedWindowOrders"
    private var records: [UInt32: Owner] = [:]
    private var active = false

    init(defaults: UserDefaults = .standard,
         owner: @escaping @MainActor (UInt32) -> Owner? = NativeParkedWindows.windowOwner,
         orderedIn: @escaping @MainActor (UInt32) -> Bool? = { SkyLight.shared.isWindowOrderedIn($0) },
         order: @escaping @MainActor (UInt32, Bool) -> Bool = { omniwm_dock_order_parked_window($0, $1) },
         available: @escaping @MainActor () -> Bool = { omniwm_dock_slide_available() }) {
        self.defaults = defaults
        self.owner = owner
        self.orderedIn = orderedIn
        self.order = order
        self.available = available
    }

    static func windowOwner(_ id: UInt32) -> Owner? {
        guard let pid = windowPID(id),
              let date = NSRunningApplication(processIdentifier: pid)?.launchDate else { return nil }
        return Owner(pid: pid, launchDate: date)
    }

    static func windowPID(_ id: UInt32) -> pid_t? {
        // The relative window-list API omits ordered-out windows. Request the
        // description by ID so a window we hid remains identifiable until reveal.
        var rawID = UnsafeRawPointer(bitPattern: UInt(id))
        guard let ids = CFArrayCreate(nil, &rawID, 1, nil),
              let rows = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == id else { return nil }
        return row[kCGWindowOwnerPID as String] as? pid_t
    }

    func start() {
        guard !active else { return }
        if let data = defaults.data(forKey: key),
           let previous = try? JSONDecoder().decode([UInt32: Owner].self, from: data) {
            records = previous
        }
        active = available()
        if active { restoreAll() }
    }

    func owns(_ token: WindowToken) -> Bool {
        UInt32(exactly: token.windowId).flatMap { records[$0]?.pid } == token.pid
    }

    func stillExists(_ token: WindowToken) -> Bool {
        guard let id = UInt32(exactly: token.windowId), let saved = records[id],
              saved.pid == token.pid else { return false }
        return owner(id) == saved
    }

    func hide(_ token: WindowToken) {
        guard active, let id = UInt32(exactly: token.windowId), records[id] == nil,
              orderedIn(id) == true, let identity = owner(id), identity.pid == token.pid else { return }
        // Persist ownership before dispatch so a relaunch can undo an interrupted hide.
        records[id] = identity
        save()
        if !order(id, false), orderedIn(id) == true {
            records[id] = nil
            save()
        }
    }

    func reveal(_ token: WindowToken) {
        guard owns(token), let id = UInt32(exactly: token.windowId) else { return }
        restore(id)
    }

    func restoreVisible(where shouldReveal: (WindowToken) -> Bool) {
        for (id, identity) in records where shouldReveal(.init(pid: identity.pid, windowId: Int(id))) {
            restore(id)
        }
    }

    func stop() {
        restoreAll()
        active = false
    }

    private func restoreAll() {
        for id in Array(records.keys) { restore(id) }
    }

    private func restore(_ id: UInt32) {
        guard let saved = records[id] else { return }
        guard let current = owner(id) else {
            // A failed read cannot establish that the saved owner was replaced.
            if NSRunningApplication(processIdentifier: saved.pid)?.launchDate == saved.launchDate { return }
            records[id] = nil
            save()
            return
        }
        if current == saved, orderedIn(id) != true {
            guard available(), order(id, true), orderedIn(id) == true else { return }
        }
        records[id] = nil
        save()
    }

    private func save() {
        if records.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}
