// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellDataFeed {
    func listenToFocus(_ listening: Bool) {
        guard listening != (focusObservation != nil) else { return }
        guard listening else {
            focusObservation = nil
            focusRead?.cancel()
            focusRead = nil
            data.focusSymbol = nil
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
            let symbol = await Self.focusSymbol(in: directory)
            guard !Task.isCancelled, let self, data.focusSymbol != symbol else { return }
            data.focusSymbol = symbol
            publish()
        }
    }

    @concurrent static func focusSymbol(in directory: URL) async -> String? {
        func store(_ file: String) -> [String: Any]? {
            guard let bytes = try? Data(contentsOf: directory.appending(path: file)),
                  let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { return nil }
            return (root["data"] as? [[String: Any]])?.first
        }
        guard let records = store("Assertions.json")?["storeAssertionRecords"] as? [[String: Any]],
              let id = records.compactMap({ record in
                  (record["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String
              }).last else { return nil }
        let configurations = store("ModeConfigurations.json")?["modeConfigurations"] as? [String: [String: Any]]
        let mode = configurations?[id]?["mode"] as? [String: Any]
        guard let symbol = mode?["symbolImageName"] as? String, !symbol.isEmpty else { return "moon.fill" }
        return symbol
    }
}
