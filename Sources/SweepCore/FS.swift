import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What `lstat` says about a path (symlinks are not followed).
public struct FileInfo: Sendable {
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isRegular: Bool
    public let size: Int64
    public let allocated: Int64
    public let modified: Date
    public let accessed: Date
    public let uid: UInt32
    public let device: UInt64
    public let inode: UInt64
    public let linkCount: UInt64
    /// An iCloud/File Provider placeholder whose contents aren't on this Mac.
    public let isDataless: Bool
}

extension FileInfo {
    /// Network, FUSE or corrupt file systems can report nonsense block counts; never let that trap or
    /// poison later sums (1 PiB per file is far beyond any real file).
    static let maximumAllocation: Int64 = 1 << 50

    static func allocatedBytes(blocks: Int64) -> Int64 {
        let (bytes, overflow) = max(blocks, 0).multipliedReportingOverflow(by: 512)
        return overflow ? maximumAllocation : min(bytes, maximumAllocation)
    }

    init(_ st: stat) {
        let type = Int(st.st_mode) & 0o170000
        isDirectory = type == 0o040000
        isSymlink = type == 0o120000
        isRegular = type == 0o100000
        size = Int64(st.st_size)
        allocated = FileInfo.allocatedBytes(blocks: Int64(st.st_blocks))
        #if os(Linux)
        modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtim.tv_sec))
        accessed = Date(timeIntervalSince1970: TimeInterval(st.st_atim.tv_sec))
        isDataless = false
        #else
        modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        accessed = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
        isDataless = (UInt32(st.st_flags) & 0x40000000) != 0 // SF_DATALESS
        #endif
        uid = UInt32(st.st_uid)
        device = UInt64(truncatingIfNeeded: st.st_dev)
        inode = UInt64(st.st_ino)
        linkCount = UInt64(st.st_nlink)
    }
}

/// Small, fast file-system helpers built on POSIX calls so they behave the same on macOS and Linux.
public enum FS {
    public static func info(_ path: String) -> FileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileInfo(st)
    }

    /// Like `info` but follows symlinks.
    public static func targetInfo(_ path: String) -> FileInfo? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileInfo(st)
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDir(_ path: String) -> Bool { info(path)?.isDirectory == true }

    public static func isWritable(_ path: String) -> Bool { access(path, W_OK) == 0 }

    public static var currentUID: UInt32 { UInt32(getuid()) }

    /// Names inside a directory, sorted. Empty if it can't be read.
    public static func list(_ path: String) -> [String] {
        (try? listChecked(path)) ?? []
    }

    /// Names inside a directory, throwing when it exists but can't be read (usually a privacy restriction).
    public static func listChecked(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// True when the directory exists but macOS refuses to list it.
    public static func isBlocked(_ path: String) -> Bool {
        guard exists(path) else { return false }
        do { _ = try FileManager.default.contentsOfDirectory(atPath: path); return false } catch { return true }
    }

    public static func join(_ parts: String...) -> String { join(parts) }

    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if result.isEmpty {
                result = part
            } else if result.hasSuffix("/") {
                result += part.hasPrefix("/") ? String(part.dropFirst()) : part
            } else {
                result += part.hasPrefix("/") ? part : "/" + part
            }
        }
        return collapse(result)
    }

    /// Collapses repeated slashes, drops "." components and trailing slashes.
    public static func collapse(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }

    public static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    public static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    /// Lower-cased extension without the dot ("" when there is none).
    public static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    public static func stripExt(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    public static func modified(_ path: String) -> Date? { info(path)?.modified }

    public static func readData(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    public static func readText(_ path: String) -> String? {
        guard let data = readData(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = readData(path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    public static func readJSON(_ path: String) -> Any? {
        guard let data = readData(path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Info.plist of an app, plug-in, framework or other bundle.
    public static func bundleInfo(_ bundlePath: String) -> [String: Any]? {
        for candidate in ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"] {
            if let plist = readPlist(bundlePath + "/" + candidate) { return plist }
        }
        return nil
    }

    public static func bundleID(_ bundlePath: String) -> String? {
        bundleInfo(bundlePath)?["CFBundleIdentifier"] as? String
    }

    /// Compares version-like strings so "10.2" sorts after "9.12".
    public static func versionLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}
