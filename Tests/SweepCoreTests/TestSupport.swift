import Foundation
@testable import SweepCore

/// Stands in for Finder and the administrator prompt: records what MacSweep asks and answers as told,
/// so no test ever waits on a real password prompt.
final class FakeHelpers: @unchecked Sendable {
    var scripts: [String] = []
    var finderRequests: [[String]] = []
    var administrator: (String) -> ShellResult = { _ in ShellResult(status: 1, stdout: "", stderr: "unexpected") }
    var finder: ([String]) -> ShellResult = { _ in ShellResult(status: 1, stdout: "", stderr: "unexpected") }

    var helpers: RemovalHelpers {
        RemovalHelpers(administrator: { script in
            self.scripts.append(script)
            return self.administrator(script)
        }, finder: { paths in
            self.finderRequests.append(paths)
            return self.finder(paths)
        })
    }
}

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
