import Foundation
@testable import SweepCore

/// A throwaway folder tree that is removed when the test finishes.
final class Sandbox {
    let root: String

    init() {
        root = FileManager.default.temporaryDirectory.path + "/macsweep-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func file(_ relative: String, bytes: Int = 16, fill: UInt8 = 0x41) -> String {
        let full = path(relative)
        try? FileManager.default.createDirectory(atPath: FS.parent(full), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: full, contents: Data(repeating: fill, count: bytes))
        return full
    }

    @discardableResult
    func text(_ relative: String, _ contents: String) -> String {
        let full = path(relative)
        try? FileManager.default.createDirectory(atPath: FS.parent(full), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: full, contents: Data(contents.utf8))
        return full
    }

    @discardableResult
    func dir(_ relative: String) -> String {
        let full = path(relative)
        try? FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    func plist(_ relative: String, _ value: [String: Any]) {
        let full = path(relative)
        try? FileManager.default.createDirectory(atPath: FS.parent(full), withIntermediateDirectories: true)
        let data = try! PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        _ = FileManager.default.createFile(atPath: full, contents: data)
    }
}
