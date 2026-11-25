// Read WindowServer geometry and hit-test results. No pixel or window-title queries.
import AppKit

_ = NSApplication.shared
let apps = ["com.openai.chat", "com.openai.codex", "com.google.Chrome"]
let screen = CGDisplayBounds(CGMainDisplayID())
let top = NSScreen.screens[0].frame.maxY

func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value)
    FileHandle.standardOutput.write(data + Data([10]))
}

func windows() -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
    return (list as? [[String: Any]] ?? []).compactMap { row in
        guard row[kCGWindowLayer as String] as? Int == 0,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier, apps.contains(bundle),
              let wid = row[kCGWindowNumber as String] as? Int,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bounds),
              r.width > 1, r.height > 1 else { return nil }
        return ["id": wid, "pid": pid, "bundle": bundle,
                "frame": [r.minX, r.minY, r.width, r.height]]
    }
}

for line in AnyIterator({ readLine() }) {
    let values = line.split(separator: " ").compactMap { Double($0) }
    let hits = stride(from: 0, to: values.count - values.count % 2, by: 2).map { index in
        NSWindow.windowNumber(at: CGPoint(x: values[index], y: top - values[index + 1]),
                              belowWindowWithWindowNumber: 0)
    }
    emit(["windows": windows(), "hits": hits, "screen": [screen.width, screen.height],
          "otherDisplays": NSScreen.screens.dropFirst().map {
              [$0.frame.minX, top - $0.frame.maxY, $0.frame.width, $0.frame.height]
          }])
}
