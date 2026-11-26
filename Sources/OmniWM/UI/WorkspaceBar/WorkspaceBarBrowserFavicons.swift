// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers

@MainActor
final class WorkspaceBarBrowserFavicons {
    struct Window: Equatable {
        let reference: AXWindowRef
        let title: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title && sameAXWindowIdentity(lhs.reference, rhs.reference)
        }
    }

    static func supports(_ bundle: String?) -> Bool {
        switch bundle?.lowercased() {
        case "com.officecommun.search", "com.apple.safari", "com.google.chrome": true
        default: false
        }
    }

    private var windows: [String: Window] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let cache = NSCache<NSURL, NSImage>()
    private(set) var images: [String: NSImage] = [:]
    private let changed: (String) -> Void

    init(changed: @escaping (String) -> Void) {
        self.changed = changed
        cache.countLimit = 128
    }

    func synchronize(_ next: [String: Window]) {
        guard windows != next else { return }
        for (id, old) in windows where next[id] != old {
            tasks.removeValue(forKey: id)?.cancel()
            setImage(nil, for: id)
        }
        windows = next
        for (id, window) in next where tasks[id] == nil {
            tasks[id] = Task { [weak self] in
                var previous: URL?
                var retryAfter = Date.distantPast
                while !Task.isCancelled {
                    let page = await Self.pageURL(window.reference)
                    guard !Task.isCancelled, self != nil else { return }
                    if previous != page || (page != nil && Date.now >= retryAfter && self?.images[id] == nil) {
                        previous = page
                        let cached = page.flatMap { self?.cache.object(forKey: $0 as NSURL) }
                        self?.setImage(cached, for: id)
                        if let page, cached == nil {
                            let image = await Self.fetchIcon(page)
                            guard !Task.isCancelled else { return }
                            if let image {
                                self?.cache.setObject(image, forKey: page as NSURL)
                                self?.setImage(image, for: id)
                            }
                            retryAfter = Date.now.addingTimeInterval(60)
                        }
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func setImage(_ image: NSImage?, for id: String) {
        guard images[id] !== image else { return }
        images[id] = image
        changed(id)
    }

    @concurrent
    private static func pageURL(_ window: AXWindowRef) async -> URL? {
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }

        func url(_ value: CFTypeRef?) -> URL? {
            guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host != nil, parts.user == nil, parts.password == nil
            else { return nil }
            parts.fragment = nil
            return parts.url
        }

        if let document = attribute(window.element, kAXDocumentAttribute) {
            return url(document)
        }
        // WebKit windows may expose the address only on their web area.
        var queue = [window.element]
        var index = 0
        while index < queue.count, !Task.isCancelled {
            let element = queue[index]
            index += 1
            if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" {
                return url(attribute(element, kAXURLAttribute))
            }
            if queue.count < 96, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(96 - queue.count))
            }
        }
        return nil
    }

    private static func fetchIcon(_ url: URL) async -> NSImage? {
        let provider = LPMetadataProvider()
        provider.timeout = 5
        guard let metadata = try? await provider.startFetchingMetadata(for: url),
              !Task.isCancelled, let icon = metadata.iconProvider
        else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = icon.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary)
        else { return nil }
        return tile(for: bitmap)
    }

    static func tile(for favicon: CGImage) -> NSImage? {
        let size = 64
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let sample = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                     bytesPerRow: 4, space: colorSpace, bitmapInfo: format),
              let pixel = sample.data?.assumingMemoryBound(to: UInt8.self),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace, bitmapInfo: format)
        else { return nil }

        // Use the visible artwork to choose a contrasting neutral background.
        sample.interpolationQuality = .high
        sample.draw(favicon, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let brightness = 0.21 * CGFloat(pixel[0]) + 0.72 * CGFloat(pixel[1]) + 0.07 * CGFloat(pixel[2])
        let lightArtwork = brightness > 0.65 * CGFloat(pixel[3])

        let face = CGRect(x: 3, y: 3, width: 58, height: 58)
        let outline = CGPath(roundedRect: face, cornerWidth: 13, cornerHeight: 13, transform: nil)
        context.addPath(outline)
        context.setFillColor(gray: lightArtwork ? 0.23 : 0.94, alpha: 1)
        context.fillPath()
        context.addPath(outline)
        context.setStrokeColor(gray: lightArtwork ? 1 : 0, alpha: 0.18)
        context.setLineWidth(1)
        context.strokePath()

        let scale = 44 / CGFloat(max(favicon.width, favicon.height))
        let width = CGFloat(favicon.width) * scale
        let height = CGFloat(favicon.height) * scale
        context.interpolationQuality = .high
        context.draw(favicon, in: CGRect(x: face.midX - width / 2, y: face.midY - height / 2,
                                         width: width, height: height))
        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
    }
}
