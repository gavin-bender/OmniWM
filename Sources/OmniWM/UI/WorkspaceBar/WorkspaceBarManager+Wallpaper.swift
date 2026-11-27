// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func updateWallpaperMonitoring() {
        guard shellHost != nil, barsByMonitor.values.contains(where: { $0.model.snapshot.backgroundStyle == .transparent }) else {
            wallpaperRefresh?.cancel()
            wallpaperRefresh = nil
            shellHost?.setWallpaperContrast([:])
            return
        }
        guard wallpaperRefresh == nil else { return }
        let wallpapers = OverviewWallpaperCache()
        wallpaperRefresh = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshWallpaperContrast(using: wallpapers)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func refreshWallpaperContrast(using wallpapers: OverviewWallpaperCache) {
        var values: [ShellBarKey: Bool] = [:]
        for instance in barsByMonitor.values where instance.model.snapshot.backgroundStyle == .transparent {
            let panels = [instance.primary, instance.secondary].compactMap { $0 }.filter { $0.panel.isVisible }
            let monitor = instance.monitor
            var darkWallpaper: [WorkspaceBarIslandSlice: Bool] = [:]
            defer { instance.model.darkWallpaper = darkWallpaper }
            guard !panels.isEmpty, let image = wallpapers.fileImage(for: monitor.displayId, maxPixelSize: 512) else { continue }
            for panel in panels {
                guard let frame = panel.lastAppliedFrame else { continue }
                let key = ShellBarKey(monitor: monitor.id, island: panel.slice)
                let dark = Self.wallpaperIsDark(image, behind: frame, on: monitor.frame)
                values[key] = dark
                darkWallpaper[panel.slice] = dark
            }
        }
        shellHost?.setWallpaperContrast(values)
    }

    static func wallpaperIsDark(_ image: CGImage, behind frame: CGRect, on screen: CGRect) -> Bool? {
        let region = screen.intersection(frame)
        guard !region.isEmpty else { return nil }
        // Center-crop the wallpaper file to the display’s aspect ratio.
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(width / screen.width, height / screen.height)
        let crop = CGRect(
            x: (width - screen.width * scale) / 2 + (region.minX - screen.minX) * scale,
            y: (height - screen.height * scale) / 2 + (screen.maxY - region.maxY) * scale,
            width: region.width * scale,
            height: region.height * scale
        ).integral
        guard let strip = image.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(strip, in: CGRect(x: 0, y: 0, width: 32, height: 8))
        let luminance = UnsafeBufferPointer(start: pixels, count: 256).reduce(0) { $0 + Int($1) }
        // White and black have equal contrast at a relative luminance of approximately 0.179.
        return Double(luminance) / (256 * 255) < 0.179
    }
}
