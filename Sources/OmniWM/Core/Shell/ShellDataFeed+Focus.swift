// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellFocusModes: Equatable, Sendable {
    struct Mode: Equatable, Sendable {
        let id: String
        let name: String
        let symbol: String
    }

    var modes: [Mode] = []
    var activeID: String?

    var symbol: String? {
        activeID.map { id in modes.first { $0.id == id }?.symbol ?? "moon.fill" }
    }

    func write(into writer: inout ShellValueWriter) {
        writer.array(modes.count)
        for mode in modes {
            writer.map(4)
            writer.key("id")
            writer.string(mode.id)
            writer.key("name")
            writer.string(mode.name)
            writer.key("symbol")
            writer.string(mode.symbol)
            writer.key("active")
            writer.bool(mode.id == activeID)
        }
    }
}

extension ShellDataFeed {
    func listenToFocus(_ listening: Bool) {
        guard listening != (focusObservation != nil) else { return }
        guard listening else {
            focusObservation = nil
            focusRead?.cancel()
            focusRead = nil
            data.focusModes = ShellFocusModes()
            return
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/DoNotDisturb/DB")
        let paths = [directory.deletingLastPathComponent(), directory, directory.appending(path: "Assertions.json"),
                     directory.appending(path: "ModeConfigurations.json")]
        focusObservation = ShellProviderObservation.shared.observe(paths: Set(paths.map(\.path))) { [weak self] in
            Task { @MainActor in self?.refreshFocus(in: directory) }
        }
        refreshFocus(in: directory)
    }

    private func refreshFocus(in directory: URL) {
        guard focusObservation != nil else { return }
        focusRead?.cancel()
        focusRead = Task { [weak self] in
            let modes = await Self.readFocusModes(in: directory)
            guard !Task.isCancelled, let self, data.focusModes != modes else { return }
            data.focusModes = modes
            publish()
        }
    }

    @concurrent static func readFocusModes(in directory: URL) async -> ShellFocusModes {
        func store(_ file: String) -> [String: Any]? {
            guard let bytes = try? Data(contentsOf: directory.appending(path: file)),
                  let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { return nil }
            return (root["data"] as? [[String: Any]])?.first
        }
        let records = store("Assertions.json")?["storeAssertionRecords"] as? [[String: Any]] ?? []
        let id = records.compactMap { record in
            (record["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String
        }.last
        let configurations = store("ModeConfigurations.json")?["modeConfigurations"] as? [String: [String: Any]] ?? [:]
        let modes = configurations.compactMap { id, configuration -> ShellFocusModes.Mode? in
            guard let mode = configuration["mode"] as? [String: Any],
                  let name = mode["name"] as? String, !name.isEmpty else { return nil }
            let symbol = mode["symbolImageName"] as? String
            return .init(id: id, name: name, symbol: symbol.flatMap { $0.isEmpty ? nil : $0 } ?? "moon.fill")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ShellFocusModes(modes: modes, activeID: id)
    }
}
