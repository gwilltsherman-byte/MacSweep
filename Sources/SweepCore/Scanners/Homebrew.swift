import Foundation

public struct BrewFormula: Sendable, Hashable {
    public var name: String
    public var fullName: String
    public var tap: String?
    public var desc: String
    public var version: String
    public var onRequest: Bool
    public var asDependency: Bool
    public var runtimeDependencies: [String]
    public var installedTime: Date?
    public var pinned: Bool
    public var outdated: Bool
}

public struct BrewCask: Sendable, Hashable {
    public var token: String
    public var fullToken: String
    public var tap: String?
    public var name: String
    public var desc: String
    public var version: String
    public var apps: [String]
    public var installedTime: Date?
    public var autoUpdates: Bool
}

public struct BrewTap: Sendable, Hashable {
    public var name: String
    public var path: String
    public var formulaCount: Int
    public var caskCount: Int
}

public struct BrewSnapshot: Sendable {
    public var brew: String
    public var cellar: String
    public var caskroom: String
    public var formulae: [BrewFormula]
    public var casks: [BrewCask]
    public var taps: [BrewTap]
    public var cleanupBytes: Int64?
    public var cleanupCount: Int
    public var problems: [String]
}

public enum Homebrew {
    static func locate(shell: Shell) -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return shell.which("brew")
    }

    static func snapshot(shell: Shell) async -> BrewSnapshot? {
        guard let brew = locate(shell: shell) else { return nil }
        async let prefixResult = shell.run(brew, ["--prefix"], timeout: 30)
        async let infoResult = shell.run(brew, ["info", "--json=v2", "--installed"], timeout: 300)
        async let tapResult = shell.run(brew, ["tap-info", "--json", "--installed"], timeout: 120)
        async let cleanupResult = shell.run(brew, ["cleanup", "--dry-run", "--prune=all"], timeout: 300)

        let prefixOut = await prefixResult
        let prefix = prefixOut.ok ? prefixOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                                  : FS.parent(FS.parent(brew))
        var problems: [String] = []
        let info = await infoResult
        var formulae: [BrewFormula] = []
        var casks: [BrewCask] = []
        if info.ok, let parsed = parseInfo(Data(info.stdout.utf8)) {
            formulae = parsed.formulae
            casks = parsed.casks
        } else {
            problems.append("Couldn't read the list of Homebrew packages: \(info.errorSummary)")
        }
        let tapsOut = await tapResult
        let taps = tapsOut.ok ? parseTaps(Data(tapsOut.stdout.utf8)) : []
        let cleanup = await cleanupResult
        let (cleanupBytes, cleanupCount) = cleanup.ok ? parseCleanup(cleanup.stdout + "\n" + cleanup.stderr) : (nil, 0)

        return BrewSnapshot(brew: brew, cellar: prefix + "/Cellar", caskroom: prefix + "/Caskroom", formulae: formulae, casks: casks,
                            taps: taps, cleanupBytes: cleanupBytes, cleanupCount: cleanupCount, problems: problems)
    }

    public static func parseInfo(_ data: Data) -> (formulae: [BrewFormula], casks: [BrewCask])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var formulae: [BrewFormula] = []
        for entry in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            let installs = entry["installed"] as? [[String: Any]] ?? []
            let latest = installs.last ?? [:]
            let deps = (latest["runtime_dependencies"] as? [[String: Any]] ?? []).compactMap { $0["full_name"] as? String }
            let time = (latest["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            formulae.append(BrewFormula(
                name: name,
                fullName: entry["full_name"] as? String ?? name,
                tap: entry["tap"] as? String,
                desc: entry["desc"] as? String ?? "",
                version: installs.compactMap { $0["version"] as? String }.joined(separator: ", "),
                onRequest: installs.contains { ($0["installed_on_request"] as? Bool) == true },
                asDependency: installs.contains { ($0["installed_as_dependency"] as? Bool) == true },
                runtimeDependencies: deps,
                installedTime: time,
                pinned: entry["pinned"] as? Bool ?? false,
                outdated: entry["outdated"] as? Bool ?? false
            ))
        }
        var casks: [BrewCask] = []
        for entry in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = entry["token"] as? String else { continue }
            var apps: [String] = []
            for artifact in entry["artifacts"] as? [[String: Any]] ?? [] {
                guard let list = artifact["app"] as? [Any] else { continue }
                var lastApp: String?
                for element in list {
                    if let app = element as? String {
                        lastApp = app
                        apps.append(app)
                    } else if let options = element as? [String: Any], let target = options["target"] as? String {
                        if let previous = lastApp, let index = apps.lastIndex(of: previous) { apps.remove(at: index) }
                        apps.append(target)
                    }
                }
            }
            let names = entry["name"] as? [String] ?? []
            let time = (entry["installed_time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            casks.append(BrewCask(
                token: token,
                fullToken: entry["full_token"] as? String ?? token,
                tap: entry["tap"] as? String,
                name: names.first ?? token,
                desc: entry["desc"] as? String ?? "",
                version: entry["installed"] as? String ?? entry["version"] as? String ?? "",
                apps: apps,
                installedTime: time,
                autoUpdates: entry["auto_updates"] as? Bool ?? false
            ))
        }
        return (formulae, casks)
    }

    public static func parseTaps(_ data: Data) -> [BrewTap] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, let path = entry["path"] as? String else { return nil }
            if (entry["installed"] as? Bool) == false { return nil }
            return BrewTap(name: name, path: path,
                           formulaCount: (entry["formula_names"] as? [Any])?.count ?? 0,
                           caskCount: (entry["cask_tokens"] as? [Any])?.count ?? 0)
        }
    }

    /// Reads `brew cleanup --dry-run` output: how much it would free and how many things it would remove.
    public static func parseCleanup(_ text: String) -> (Int64?, Int) {
        var bytes: Int64?
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Would remove") { count += 1 }
            if let range = line.range(of: "approximately ") {
                let rest = line[range.upperBound...]
                let sizeText = rest.split(separator: " ").first.map(String.init) ?? ""
                bytes = SizeParser.parse(sizeText)
            }
        }
        return (bytes, count)
    }

    /// Which installed formulae each formula is needed by.
    public static func dependents(_ formulae: [BrewFormula]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for formula in formulae {
            for dep in formula.runtimeDependencies {
                result[dep, default: []].append(formula.name)
                let short = FS.name(dep)
                if short != dep { result[short, default: []].append(formula.name) }
            }
        }
        return result
    }

    // MARK: Scanners

    static func formulaeScan(_ ctx: ScanContext) async -> ScanResult {
        let id = "brewFormulae"
        guard let brew = await ctx.brew() else { return ScanResult(notes: ["Homebrew isn't installed."]) }
        let dependents = dependents(brew.formulae)
        let paths = brew.formulae.map { brew.cellar + "/" + $0.name }
        let sizes = await ctx.sizes(paths)
        var items: [Item] = []
        for (formula, size) in zip(brew.formulae, sizes) {
            let neededBy = Array(Set((dependents[formula.fullName] ?? []) + (dependents[formula.name] ?? []))).sorted()
            var badges = [formula.onRequest ? "You installed it" : "Dependency"]
            let risk: Risk
            var note: String
            if neededBy.isEmpty && !formula.onRequest {
                risk = .safe
                badges.append("Unused dependency")
                note = "Installed only because another package needed it, and nothing installed needs it any more."
            } else if neededBy.isEmpty {
                risk = .review
                note = "Nothing else depends on this. Remove it if you no longer use the \(formula.name) command."
            } else {
                risk = .caution
                note = "Needed by \(neededBy.joined(separator: ", ")). Homebrew won't remove it unless you remove those too (select them together)."
            }
            if formula.pinned { badges.append("Pinned") }
            if formula.outdated { badges.append("Outdated") }
            let command = ShellCommand(brew.brew, ["uninstall", "--formula"], targets: [formula.fullName], batchable: true)
            items.append(Item(
                id: "\(id)|\(formula.fullName)", categoryID: id, title: formula.name,
                detail: [formula.version, formula.desc].filter { !$0.isEmpty }.joined(separator: " · "),
                size: size, risk: risk, note: note, paths: [brew.cellar + "/" + formula.name],
                date: formula.installedTime, dateKind: .installed, badges: badges, steps: [.run(command)]
            ))
        }
        return ScanResult(items.bySize(), notes: brew.problems)
    }

    static func casksScan(_ ctx: ScanContext) async -> ScanResult {
        let id = "brewCasks"
        guard let brew = await ctx.brew() else { return ScanResult(notes: ["Homebrew isn't installed."]) }
        var groups: [[String]] = []
        for cask in brew.casks {
            var paths = [brew.caskroom + "/" + cask.token]
            for app in cask.apps {
                for root in ["/Applications", ctx.home + "/Applications"] where FS.exists(root + "/" + app) {
                    paths.append(root + "/" + app)
                }
            }
            groups.append(paths)
        }
        let token = ctx.cancel
        let sizes = await Background.map(groups) { $0.reduce(Int64(0)) { $0 + DiskUsage.allocatedSize($1, cancel: token) } }
        var items: [Item] = []
        for ((cask, paths), size) in zip(zip(brew.casks, groups), sizes) {
            let appPath = paths.dropFirst().first
            let lastUsed = appPath.flatMap(AppCatalog.lastUsed)
            var badges = Badges.age(lastUsed)
            if cask.autoUpdates { badges.append("Auto-updates") }
            let command = ShellCommand(brew.brew, ["uninstall", "--cask"], targets: [cask.fullToken], batchable: true)
            items.append(Item(
                id: "\(id)|\(cask.fullToken)", categoryID: id, title: cask.name,
                detail: [cask.token, cask.version, cask.desc].filter { !$0.isEmpty }.joined(separator: " · "),
                size: size, risk: .review,
                note: "Uninstalls the app with Homebrew. Its settings stay behind; they'll show up under App Leftovers after the next scan.",
                paths: paths, date: lastUsed ?? cask.installedTime, dateKind: lastUsed == nil ? .installed : .lastUsed,
                badges: badges, bundleID: appPath.flatMap(FS.bundleID), steps: [.run(command)]
            ))
        }
        return ScanResult(items.bySize(), notes: brew.problems)
    }

    static func maintenanceScan(_ ctx: ScanContext) async -> ScanResult {
        let id = "brewMaintenance"
        guard let brew = await ctx.brew() else { return ScanResult(notes: ["Homebrew isn't installed."]) }
        var items: [Item] = []
        if brew.cleanupCount > 0 || (brew.cleanupBytes ?? 0) > 0 {
            items.append(Item(
                id: "\(id)|cleanup", categoryID: id, title: "Old versions & stale downloads",
                detail: "brew cleanup --prune=all · \(brew.cleanupCount) things to remove", size: brew.cleanupBytes,
                risk: .safe, note: "Older versions of upgraded packages, outdated downloads and stale lock files. Homebrew keeps them only so you could switch back.",
                steps: [.run(ShellCommand(brew.brew, ["cleanup", "--prune=all"]))]
            ))
        }
        let installedTaps = Set(brew.formulae.compactMap(\.tap) + brew.casks.compactMap(\.tap))
        let sizes = await ctx.sizes(brew.taps.map(\.path))
        for (tap, size) in zip(brew.taps, sizes) where size > 0 {
            let core = tap.name == "homebrew/core" || tap.name == "homebrew/cask"
            let inUse = installedTaps.contains(tap.name) && !core
            let note: String
            if core {
                note = "Since Homebrew 4 these package lists are downloaded on demand, so this local copy is no longer needed (unless you write formulae or set HOMEBREW_NO_INSTALL_FROM_API)."
            } else if inUse {
                note = "Some of your installed packages come from this tap. Untapping fails until they're removed."
            } else {
                note = "None of your installed packages come from this tap. Untap it to drop its \(tap.formulaCount + tap.caskCount) package definitions."
            }
            items.append(Item(
                id: "\(id)|tap|\(tap.name)", categoryID: id, title: "Tap \(tap.name)", detail: ctx.display(tap.path),
                size: size, risk: core ? .safe : (inUse ? .caution : .review), note: note, paths: [tap.path],
                badges: inUse ? ["In use"] : ["Unused tap"],
                steps: [.run(ShellCommand(brew.brew, ["untap"], targets: [tap.name], batchable: true))]
            ))
        }
        return ScanResult(items.bySize(), notes: brew.problems)
    }
}

public enum MacPorts {
    public struct Port: Sendable, Hashable {
        public var name: String
        public var version: String
        public var active: Bool
    }

    public static func parseInstalled(_ text: String) -> [Port] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1].hasPrefix("@") else { return nil }
            return Port(name: String(parts[0]), version: String(parts[1].dropFirst()), active: line.contains("(active)"))
        }
    }

    static func scan(_ ctx: ScanContext) async -> ScanResult {
        let id = "macports"
        let port = "/opt/local/bin/port"
        guard FileManager.default.isExecutableFile(atPath: port) else { return ScanResult(notes: ["MacPorts isn't installed."]) }
        async let installedResult = ctx.shell.run(port, ["-q", "installed"], timeout: 120)
        async let leavesResult = ctx.shell.run(port, ["-q", "echo", "leaves"], timeout: 120)
        async let requestedResult = ctx.shell.run(port, ["-q", "echo", "requested"], timeout: 120)
        let installed = parseInstalled(await installedResult.stdout)
        let leaves = Set(await leavesResult.lines.compactMap { $0.split(separator: " ").first.map(String.init) })
        let requested = Set(await requestedResult.lines.compactMap { $0.split(separator: " ").first.map(String.init) })

        var items: [Item] = []
        for entry in installed {
            let risk: Risk
            let note: String
            var badges: [String] = []
            if !entry.active {
                risk = .safe
                note = "An inactive older version. MacPorts keeps it only so you could switch back."
                badges.append("Inactive")
            } else if leaves.contains(entry.name) && !requested.contains(entry.name) {
                risk = .safe
                note = "Installed as a dependency and nothing needs it any more."
                badges.append("Unused dependency")
            } else if leaves.contains(entry.name) {
                risk = .review
                note = "Nothing depends on this port. Remove it if you no longer use it."
            } else {
                risk = .caution
                note = "Other installed ports depend on this one."
            }
            let command = ShellCommand(port, ["uninstall", entry.name, "@" + entry.version])
            items.append(Item(id: "\(id)|\(entry.name)@\(entry.version)", categoryID: id, title: entry.name,
                              detail: entry.version, risk: risk, note: note, badges: badges, steps: [.runAsAdmin(command)]))
        }
        let reclaimPaths = ["/opt/local/var/macports/distfiles", "/opt/local/var/macports/build"].filter(FS.exists)
        if !reclaimPaths.isEmpty {
            let size = await ctx.sizes(reclaimPaths).reduce(0, +)
            if size > 0 {
                items.append(Item(id: "\(id)|reclaim", categoryID: id, title: "Downloaded sources & build leftovers",
                                  detail: "port reclaim", size: size, risk: .safe,
                                  note: "Source archives and build folders MacPorts no longer needs.", paths: reclaimPaths,
                                  steps: [.runAsAdmin(ShellCommand(port, ["-N", "reclaim"]))]))
            }
        }
        return ScanResult(items.bySize())
    }
}
