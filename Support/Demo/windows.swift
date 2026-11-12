// Prints a process's on-screen windows, front to back, as JSON lines: id, layer and bounds
// (points, top-left origin). Used by capture.py.
//
//     swiftc -O windows.swift -o windows && ./windows <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: windows <pid>\n".utf8))
    exit(1)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for info in list where (info[kCGWindowOwnerPID as String] as? Int) == pid {
    guard let id = info[kCGWindowNumber as String] as? Int,
          let bounds = info[kCGWindowBounds as String] as? [String: Double] else { continue }
    let line: [String: Any] = [
        "id": id,
        "layer": info[kCGWindowLayer as String] as? Int ?? 0,
        "alpha": info[kCGWindowAlpha as String] as? Double ?? 1,
        "x": bounds["X"] ?? 0, "y": bounds["Y"] ?? 0,
        "width": bounds["Width"] ?? 0, "height": bounds["Height"] ?? 0,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: line) {
        print(String(decoding: data, as: UTF8.self))
    }
}
