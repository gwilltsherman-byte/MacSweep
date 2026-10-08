import Foundation

public struct ScanSettings: Sendable, Equatable {
    public var home: String
    public var largeFileThreshold: Int64
    public var oldDownloadDays: Int
    public var duplicateMinSize: Int64
    public var extraRoots: [String]
    public var selfBundleID: String?

    public init(home: String = NSHomeDirectory(), largeFileThreshold: Int64 = 500_000_000, oldDownloadDays: Int = 90,
                duplicateMinSize: Int64 = 1_000_000, extraRoots: [String] = [], selfBundleID: String? = nil) {
        self.home = home
        self.largeFileThreshold = largeFileThreshold
        self.oldDownloadDays = oldDownloadDays
        self.duplicateMinSize = duplicateMinSize
        self.extraRoots = extraRoots
        self.selfBundleID = selfBundleID
    }
}

/// Shared state for one scan: settings, cancellation and lookups that several categories need.
public final class ScanContext: @unchecked Sendable {
    public let settings: ScanSettings
    public let cancel = CancelToken()
    public let shell: Shell
    private let memo = Memo()

    public init(settings: ScanSettings, shell: Shell = .shared) {
        self.settings = settings
        self.shell = shell
    }

    public var home: String { settings.home }
    public var uid: UInt32 { FS.currentUID }
    public var isCancelled: Bool { cancel.isCancelled }

    /// Expands a leading "~".
    public func p(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }

    /// Shortens a path for display ("~/Library/…").
    public func display(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    public func size(_ path: String) -> Int64 { DiskUsage.allocatedSize(path, cancel: cancel) }

    public func sizes(_ paths: [String]) async -> [Int64] {
        let token = cancel
        return await Background.map(paths) { DiskUsage.allocatedSize($0, cancel: token) }
    }

    // MARK: Shared lookups

    public func apps() async -> [AppInfo] {
        let home = self.home
        let selfID = settings.selfBundleID
        return await memo.value("apps") {
            await Background.run {
                AppCatalog.visibleApps(home: home).filter { $0.bundleID == nil || $0.bundleID != selfID }
            }
        }
    }

    public func known() async -> KnownSoftware {
        let apps = await self.apps()
        let brew = await self.brew()
        let home = self.home
        let shell = self.shell
        var extra = brew.map { $0.formulae.map(\.name) + $0.casks.map(\.token) } ?? []
        extra += ["Homebrew", "MacPorts"]
        let extraNames = extra
        return await memo.value("known") {
            await Background.run {
                AppCatalog.knownSoftware(apps: apps, home: home, extraNames: extraNames, shell: shell)
            }
        }
    }

    public func appName(forBundleID id: String) async -> String? {
        let lowered = id.lowercased()
        return await apps().first { $0.bundleID?.lowercased() == lowered }?.name
    }

    /// Maps lower-cased bundle identifier → app name for quick title lookups.
    public func appNamesByID() async -> [String: String] {
        var map: [String: String] = [:]
        for app in await apps() {
            if let id = app.bundleID?.lowercased() { map[id] = app.name }
        }
        return map
    }

    public func homeWalk() async -> HomeWalkResult {
        let settings = self.settings
        let token = cancel
        return await memo.value("homeWalk") {
            await Background.run { HomeWalker(settings: settings, cancel: token).walk() }
        }
    }

    public func brew() async -> BrewSnapshot? {
        let shell = self.shell
        return await memo.value("brew") { await Homebrew.snapshot(shell: shell) }
    }

    public func docker() async -> DockerSnapshot? {
        let shell = self.shell
        return await memo.value("docker") { await Docker.snapshot(shell: shell) }
    }

    /// Friendly title for a folder named after a bundle id, e.g. "Spotify (com.spotify.client)".
    public func friendlyName(_ name: String, using names: [String: String]) -> String {
        let key = name.lowercased()
        if let app = names[key] { return "\(app) (\(name))" }
        return name
    }
}
