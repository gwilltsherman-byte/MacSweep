import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum JunkScanners {
    static let cacheNote = "Apps rebuild caches automatically. Quit the app first; it may be a little slower the first time afterwards."

    /// Readable names for well-known cache folders that aren't named after an app.
    static let knownNames: [String: String] = [
        "go-build": "Go build cache", "pip": "pip (Python) downloads", "pypoetry": "Poetry (Python) cache",
        "Yarn": "Yarn packages", "CocoaPods": "CocoaPods cache", "Homebrew": "Homebrew downloads",
        "ms-playwright": "Playwright browsers", "node-gyp": "node-gyp headers", "org.swift.swiftpm": "Swift Package Manager",
        "JetBrains": "JetBrains IDEs", "Google": "Google apps (Chrome etc.)", "Firefox": "Firefox",
        "deno": "Deno", "electron": "Electron downloads", "electron-builder": "electron-builder",
        "Coursier": "Coursier (Scala/JVM)", "bazelisk": "Bazelisk", "bazel": "Bazel", "ccache": "ccache",
        "lima": "Lima VM images", "mise": "mise downloads", "Mozilla.sccache": "sccache (Rust/C)",
        "typescript": "TypeScript", "pnpm": "pnpm", "com.apple.Safari": "Safari", "SiriTTS": "Siri voices",
        "com.apple.amsengagementd": "App Store engagement", "GeoServices": "Maps tiles",
        "com.apple.python": "Python bytecode (Apple)", "puppeteer": "Puppeteer browsers", "huggingface": "Hugging Face",
        "Cypress": "Cypress test runner", "composer": "Composer (PHP)", "uv": "uv (Python)",
        "esbuild": "esbuild", "prisma": "Prisma engines", "turbo": "Turborepo", "vscode-cpptools": "VS Code C++ tools",
        "spotify": "Spotify",
    ]

    static func title(_ name: String, names: [String: String]) -> String {
        if let known = knownNames[name] { return "\(known) (\(name))" }
        if let app = names[name.lowercased()] { return "\(app) (\(name))" }
        return name
    }

    static func userCaches(_ ctx: ScanContext) async -> ScanResult {
        await cacheFolder(ctx.p("~/Library/Caches"), category: "userCaches", ctx: ctx)
    }

    static func systemCaches(_ ctx: ScanContext) async -> ScanResult {
        await cacheFolder("/Library/Caches", category: "systemCaches", ctx: ctx)
    }

    static func cacheFolder(_ root: String, category: String, ctx: ScanContext) async -> ScanResult {
        let names = await ctx.appNamesByID()
        var candidates: [PathCandidate] = []
        for name in FS.list(root) where !Locations.ignorable.contains(name) {
            let apple = name.hasPrefix("com.apple.")
            candidates.append(PathCandidate(
                path: root + "/" + name, title: title(name, names: names), risk: apple ? .review : .safe,
                note: apple ? "A macOS cache. It's rebuilt automatically, though some system features may need a moment (or a restart) to recover." : cacheNote,
                bundleID: name.contains(".") ? name : nil
            ))
        }
        let notes = FS.isBlocked(root) ? ["Couldn't read \(ctx.display(root)). Give MacSweep Full Disk Access to see everything."] : []
        return ScanResult(await Build.items(candidates, category: category, ctx: ctx).bySize(), notes: notes)
    }

    /// Chromium/Electron cache folders that apps keep in Application Support instead of Caches.
    static let chromiumCacheNames: Set<String> = [
        "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache",
        "GraphiteDawnCache", "ShaderCache", "component_crx_cache", "extensions_crx_cache",
    ]

    static func hiddenAppCaches(_ ctx: ScanContext) async -> ScanResult {
        let id = "appCaches"
        let names = await ctx.appNamesByID()
        var candidates: [PathCandidate] = []

        // Sandboxed apps keep their caches inside their containers.
        let containers = ctx.p("~/Library/Containers")
        for name in FS.list(containers) {
            let path = containers + "/" + name + "/Data/Library/Caches"
            guard FS.isDir(path) else { continue }
            candidates.append(PathCandidate(path: path, title: "\(title(name, names: names)) · sandbox cache",
                                            risk: name.hasPrefix("com.apple.") ? .review : .safe, note: cacheNote,
                                            bundleID: name))
        }
        let groups = ctx.p("~/Library/Group Containers")
        for name in FS.list(groups) {
            let path = groups + "/" + name + "/Library/Caches"
            guard FS.isDir(path) else { continue }
            candidates.append(PathCandidate(path: path, title: "\(name) · shared cache",
                                            risk: name.contains("com.apple.") ? .review : .safe, note: cacheNote))
        }

        // Electron and Chromium apps (Slack, Discord, Teams, Chrome, VS Code…).
        let support = ctx.p("~/Library/Application Support")
        var stack: [(path: String, depth: Int)] = [(support, 0)]
        while let entry = stack.popLast() {
            let (dir, depth) = entry
            if ctx.isCancelled { break }
            let children = FS.list(dir)
            let childSet = Set(children)
            for name in children {
                let path = dir + "/" + name
                guard let info = FS.info(path), info.isDirectory else { continue }
                if depth == 0 && (name == "MobileSync" || name.hasPrefix("com.apple.")) { continue }
                let relative = String(path.dropFirst(support.count + 1)).replacingOccurrences(of: "/", with: " › ")
                var matched = false
                if chromiumCacheNames.contains(name) {
                    matched = true
                } else if name == "Cache" && (childSet.contains("Code Cache") || childSet.contains("GPUCache")) {
                    matched = true
                } else if (name == "CacheStorage" || name == "ScriptCache") && FS.name(dir) == "Service Worker" {
                    matched = true
                }
                if matched {
                    candidates.append(PathCandidate(path: path, title: relative, risk: .safe,
                                                    note: "Web/Electron cache. " + cacheNote))
                } else if depth < 5 && !HomeWalker.packageExtensions.contains(FS.ext(name)) {
                    stack.append((path, depth + 1))
                }
            }
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize())
    }

    static func xdgCache(_ ctx: ScanContext) async -> ScanResult {
        let locs: [Loc] = [
            .children("~/.cache", nil, .safe, "Command-line tool cache, recreated automatically.",
                      skip: ["huggingface", "lm-studio", "torch", "whisper", "clip"]),
        ]
        return ScanResult(await Locations.scan(locs, category: "xdgCache", ctx: ctx).bySize())
    }

    /// Log folders smaller than this aren't listed. Running apps and system extensions (Malwarebytes, for one)
    /// recreate their tiny log files the moment they're deleted, so offering them only brings them straight back.
    static let minLogFolderSize: Int64 = 256 * 1024

    static func logs(_ ctx: ScanContext) async -> ScanResult {
        let id = "logs"
        let names = await ctx.appNamesByID()
        var candidates: [PathCandidate] = []
        for root in [ctx.p("~/Library/Logs"), "/Library/Logs"] {
            for name in FS.list(root) where !Locations.ignorable.contains(name) {
                let path = root + "/" + name
                if name != "DiagnosticReports", DiskUsage.allocatedSize(path, cancel: ctx.cancel) < minLogFolderSize { continue }
                let label = name == "DiagnosticReports" ? "Crash & diagnostic reports" : title(name, names: names)
                candidates.append(PathCandidate(path: path,
                                                title: root.hasPrefix("/Library") ? "\(label) (all users)" : label,
                                                risk: .safe,
                                                note: "Log files are only useful when troubleshooting. New ones are written as needed."))
            }
        }
        // Rotated (old) system logs.
        for name in FS.list("/private/var/log") {
            let ext = FS.ext(name)
            if ext == "gz" || ext == "bz2" || ext == "xz" || Int(ext) != nil {
                candidates.append(PathCandidate(path: "/private/var/log/" + name, title: "Old system log \(name)",
                                                risk: .safe, note: "An archived system log."))
            }
        }
        for name in FS.list("/cores") where name.hasPrefix("core") {
            candidates.append(PathCandidate(path: "/cores/" + name, title: "Crash core dump \(name)", risk: .safe,
                                            note: "A memory dump from a crashed program. Only useful to developers debugging that crash."))
        }
        let crashReporter = ctx.p("~/Library/Application Support/CrashReporter")
        if FS.exists(crashReporter) {
            candidates.append(PathCandidate(path: crashReporter, title: "Crash reporter data", risk: .safe,
                                            note: "Old crash report bookkeeping."))
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize())
    }

    static func userCacheDir() -> String? {
        #if os(macOS)
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
        #else
        return nil
        #endif
    }

    static func temporaryFiles(_ ctx: ScanContext) async -> ScanResult {
        let id = "temp"
        var candidates: [PathCandidate] = []
        let threeDays: TimeInterval = 3 * 86_400
        func add(_ path: String, title: String, appleReview: Bool = false) {
            let modified = FS.modified(path) ?? Date()
            let old = Date().timeIntervalSince(modified) > threeDays
            candidates.append(PathCandidate(
                path: path, title: title, risk: old && !appleReview ? .safe : .review,
                note: old ? "Temporary data that hasn't changed in days." : "Recently changed, so a running app may still be using it. Quit apps first.",
                date: modified
            ))
        }
        var temp = NSTemporaryDirectory()
        if temp.hasSuffix("/") { temp.removeLast() }
        for name in FS.list(temp) where !name.hasPrefix("macsweep-") && !Locations.ignorable.contains(name) {
            add(temp + "/" + name, title: name)
        }
        if let cache = userCacheDir(), cache != temp {
            for name in FS.list(cache) {
                let path = cache + "/" + name
                if name == "com.apple.QuickLook.thumbnailcache" {
                    candidates.append(PathCandidate(path: path, title: "Quick Look thumbnails", risk: .safe,
                                                    note: "Finder and Quick Look previews, regenerated as you browse."))
                } else {
                    add(path, title: "\(name) (per-user system cache)", appleReview: name.hasPrefix("com.apple."))
                }
            }
        }
        let uid = ctx.uid
        let sensitive = ["tmux-", "ssh-", "launch-", "com.apple.launchd", "powerlog", ".X11", ".ICE"]
        for root in ["/private/tmp", "/private/var/tmp"] {
            for name in FS.list(root) where !sensitive.contains(where: { name.hasPrefix($0) }) && !name.hasPrefix("macsweep-") {
                let path = root + "/" + name
                guard let info = FS.info(path), info.uid == uid, info.isRegular || info.isDirectory else { continue }
                if name.hasPrefix("_bazel_") { continue }
                add(path, title: "\(name) (\(root))")
            }
        }
        var items = await Build.items(candidates, category: id, ctx: ctx)
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/atsutil") {
            items.append(Item(id: "\(id)|fontcache", categoryID: id, title: "Font caches", detail: "atsutil databases -removeUser",
                              risk: .safe, note: "Rebuilt automatically. Fixes garbled fonts too. Log out and back in afterwards.",
                              steps: [.run(ShellCommand("/usr/bin/atsutil", ["databases", "-removeUser"]))]))
        }
        return ScanResult(items.bySize())
    }

    static func savedState(_ ctx: ScanContext) async -> ScanResult {
        let names = await ctx.appNamesByID()
        var candidates: [PathCandidate] = []
        let root = ctx.p("~/Library/Saved Application State")
        for name in FS.list(root) where FS.ext(name) == "savedstate" {
            let bundle = FS.stripExt(name)
            candidates.append(PathCandidate(path: root + "/" + name, title: title(bundle, names: names), risk: .safe,
                                            note: "Remembers which windows were open. The app just opens fresh next time.",
                                            bundleID: bundle))
        }
        return ScanResult(await Build.items(candidates, category: "savedState", ctx: ctx).bySize())
    }

    static func trash(_ ctx: ScanContext) async -> ScanResult {
        let id = "trash"
        var candidates: [PathCandidate] = []
        var notes: [String] = []
        let userTrash = ctx.p("~/.Trash")
        if FS.isBlocked(userTrash) {
            notes.append("macOS doesn't let MacSweep look inside the Trash yet. Give it Full Disk Access in System Settings › Privacy & Security, then scan again.")
        }
        var roots = [userTrash]
        // "/Volumes/Macintosh HD" is a link back to the startup disk, whose Trash is ~/.Trash.
        for volume in FS.list("/Volumes") where FS.info("/Volumes/" + volume)?.isSymlink == false {
            roots.append("/Volumes/\(volume)/.Trashes/\(ctx.uid)")
        }
        for root in roots {
            for name in FS.list(root) where !Locations.ignorable.contains(name) {
                let path = root + "/" + name
                candidates.append(PathCandidate(path: path, title: name,
                                                detail: root == userTrash ? "In the Trash" : "In the Trash on \(root.split(separator: "/")[1])",
                                                risk: .safe, note: "Already in the Trash. Removing it here deletes it permanently.",
                                                steps: [.deleteForever([path])]))
            }
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx, keepEmpty: true).bySize(), notes: notes)
    }

    public static func parseSnapshots(_ text: String) -> [(name: String, date: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let prefix = "com.apple.TimeMachine."
            guard line.hasPrefix(prefix) else { return nil }
            var date = String(line.dropFirst(prefix.count))
            if date.hasSuffix(".local") { date = String(date.dropLast(6)) }
            return (line, date)
        }
    }

    static func timeMachineSnapshots(_ ctx: ScanContext) async -> ScanResult {
        let id = "tmSnapshots"
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tmutil") else { return ScanResult() }
        let result = await ctx.shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let items = parseSnapshots(result.stdout).map { snapshot in
            Item(id: "\(id)|\(snapshot.name)", categoryID: id, title: "Local snapshot \(snapshot.date)",
                 detail: snapshot.name, risk: .review,
                 note: "Time Machine keeps hourly snapshots on your startup disk while the backup disk is away. macOS removes them when space runs low, but deleting frees the space right now.",
                 date: formatter.date(from: snapshot.date), dateKind: .created,
                 steps: [.runAsAdmin(ShellCommand("/usr/bin/tmutil", ["deletelocalsnapshots", snapshot.date]))])
        }
        return ScanResult(items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
    }
}
