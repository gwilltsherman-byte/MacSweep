import Foundation
#if os(macOS)
import CoreServices
#endif

public struct AppInfo: Sendable, Hashable {
    public var path: String
    public var name: String
    public var bundleID: String?
    public var version: String?
    public var isAppStore: Bool

    public var isApple: Bool { bundleID?.lowercased().hasPrefix("com.apple.") == true }
}

/// Bundle identifiers and names of everything installed, used to tell leftovers from live data.
public struct KnownSoftware: Sendable {
    public var bundleIDs: Set<String>
    public var names: Set<String>

    public init(bundleIDs: Set<String>, names: Set<String>) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.names = Set(names.map(KnownSoftware.normalize).filter { $0.count >= 2 })
    }

    public static func normalize(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// True if something installed owns this reverse-DNS identifier (or a parent/child of it).
    public func matches(bundleLike raw: String) -> Bool {
        let id = raw.lowercased()
        if bundleIDs.contains(id) { return true }
        var candidates: [String] = [id]
        for separator in ["-", "_"] {
            if let cut = id.range(of: separator, options: .backwards) {
                candidates.append(String(id[..<cut.lowerBound]))
            }
        }
        for candidate in candidates {
            var parts = candidate.split(separator: ".").map(String.init)
            while parts.count >= 2 {
                if bundleIDs.contains(parts.joined(separator: ".")) { return true }
                parts.removeLast()
                if parts.count < 3 { break }
            }
        }
        let prefix = id + "."
        return bundleIDs.contains { $0.hasPrefix(prefix) }
    }

    /// True if another app from the same developer (same first two id components) is installed.
    public func vendorInstalled(_ raw: String) -> Bool {
        let parts = raw.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return false }
        let vendor = parts[0] + "." + parts[1] + "."
        return bundleIDs.contains { $0.hasPrefix(vendor) }
    }

    /// Loose match for folders named after an app ("Slack", "Code", "JetBrains").
    public func matches(name raw: String) -> Bool {
        let name = KnownSoftware.normalize(raw)
        guard name.count >= 2 else { return true }
        if names.contains(name) { return true }
        if name.count >= 3 {
            if names.contains(where: { $0.contains(name) || (name.count >= 4 && $0.count >= 4 && name.contains($0)) }) {
                return true
            }
            if bundleIDs.contains(where: { KnownSoftware.normalize($0).contains(name) }) { return true }
        }
        return false
    }
}

public enum AppCatalog {
    public static func readApp(_ path: String) -> AppInfo? {
        guard FS.isDir(path) else { return nil }
        let info = FS.bundleInfo(path)
        return AppInfo(
            path: path,
            name: FS.stripExt(FS.name(path)),
            bundleID: info?["CFBundleIdentifier"] as? String,
            version: (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String),
            isAppStore: FS.exists(path + "/Contents/_MASReceipt/receipt")
        )
    }

    /// Apps in /Applications and ~/Applications (including one level of sub-folders).
    public static func visibleApps(home: String) -> [AppInfo] {
        var paths: [String] = []
        for root in ["/Applications", home + "/Applications"] {
            paths += appPaths(in: root, depth: 2)
        }
        return paths.compactMap(readApp)
    }

    static func appPaths(in root: String, depth: Int) -> [String] {
        var found: [String] = []
        for name in FS.list(root) {
            let path = root + "/" + name
            if FS.ext(name) == "app" {
                if FS.isDir(path) { found.append(path) }
            } else if depth > 1, FS.isDir(path), !name.hasPrefix("."), FS.ext(name).isEmpty {
                found += appPaths(in: path, depth: depth - 1)
            }
        }
        return found
    }

    /// Everything that counts as "installed" when deciding whether support files are orphaned.
    public static func knownSoftware(apps: [AppInfo], home: String, extraNames: [String], shell: Shell) -> KnownSoftware {
        var bundlePaths: [String] = apps.map(\.path)
        for root in ["/System/Applications", "/System/Library/CoreServices", "/System/Library/CoreServices/Applications",
                     "/Library/Application Support", "/Applications/Utilities"] {
            bundlePaths += appPaths(in: root, depth: 2)
        }
        // Spotlight knows about apps in unusual places (dev folders, Caskroom, inside other apps).
        let spotlight = shell.runSync("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 20)
        if spotlight.ok {
            bundlePaths += spotlight.lines.filter { $0.hasPrefix("/") && !$0.contains("/.Trash/") }.prefix(6000)
        }

        var ids = Set<String>()
        var names = Set<String>(extraNames)
        var seen = Set<String>()
        for path in bundlePaths where seen.insert(path).inserted {
            names.insert(FS.stripExt(FS.name(path)))
            if let id = FS.bundleID(path) { ids.insert(id) }
            // Helpers, login items and extensions often have their own identifiers.
            for sub in ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/PlugIns", "Contents/XPCServices",
                        "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions", "Contents/Frameworks"] {
                let dir = path + "/" + sub
                for child in FS.list(dir) where ["app", "appex", "xpc", "systemextension", ""].contains(FS.ext(child)) {
                    if let id = FS.bundleID(dir + "/" + child) { ids.insert(id) }
                }
            }
        }
        return KnownSoftware(bundleIDs: ids, names: names)
    }

    /// When the user last opened something, according to Spotlight.
    public static func lastUsed(_ path: String) -> Date? {
        #if os(macOS)
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        #else
        return nil
        #endif
    }

    /// When a file arrived (e.g. in Downloads), according to Spotlight.
    public static func dateAdded(_ path: String) -> Date? {
        #if os(macOS)
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        #else
        return nil
        #endif
    }
}
