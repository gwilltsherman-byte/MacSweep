import Foundation

enum DevScanners {
    static let redownload = "Downloaded again automatically when a build needs it."
    static let toolchain = "An installed toolchain/runtime version. Projects pinned to it will ask you to reinstall it."

    // MARK: Project build folders

    static func projects(_ ctx: ScanContext) async -> ScanResult {
        let id = "projects"
        let walk = await ctx.homeWalk()
        var candidates: [PathCandidate] = []
        var aggregates: [String: (kind: ArtifactKind, paths: [String])] = [:]
        for hit in walk.artifacts {
            if hit.kind.aggregate {
                aggregates[hit.kind.label, default: (hit.kind, [])].paths.append(hit.path)
                continue
            }
            let project = FS.parent(hit.path)
            let touched = FS.modified(project)
            var badges = [hit.kind.label]
            badges += Badges.age(touched, unusedLabel: "Not touched")
            candidates.append(PathCandidate(path: hit.path, title: "\(FS.name(project)) › \(FS.name(hit.path))",
                                            risk: hit.kind.risk, note: hit.kind.note, badges: badges, date: touched))
        }
        var items = await Build.items(candidates, category: id, ctx: ctx)
        for (label, group) in aggregates {
            let size = await ctx.sizes(group.paths).reduce(0, +)
            guard size > 0 else { continue }
            items.append(Item(id: "\(id)|aggregate|\(label)", categoryID: id, title: "\(label) (\(group.paths.count) folders)",
                              detail: "Spread across your projects", size: size, risk: group.kind.risk, note: group.kind.note,
                              paths: group.paths))
        }
        return ScanResult(items.bySize())
    }

    // MARK: Xcode & simulators

    public struct SimDevice: Sendable {
        public var udid: String
        public var name: String
        public var runtime: String
        public var state: String
        public var available: Bool
        public var lastBooted: Date?
    }

    public static func parseSimDevices(_ data: Data) -> [SimDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [] }
        let iso = ISO8601DateFormatter()
        var result: [SimDevice] = []
        for (runtime, list) in devices {
            let shortRuntime = runtimeName(runtime)
            for device in list {
                guard let udid = device["udid"] as? String else { continue }
                result.append(SimDevice(udid: udid, name: device["name"] as? String ?? udid, runtime: shortRuntime,
                                        state: device["state"] as? String ?? "", available: device["isAvailable"] as? Bool ?? true,
                                        lastBooted: (device["lastBootedAt"] as? String).flatMap { iso.date(from: $0) }))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-2" → "iOS 17.2"
    public static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return identifier }
        return parts.count > 1 ? "\(platform) \(parts.dropFirst().joined(separator: "."))" : String(platform)
    }

    static func xcode(_ ctx: ScanContext) async -> ScanResult {
        let id = "xcode"
        var items: [Item] = []
        var notes: [String] = []
        let dev = ctx.p("~/Library/Developer")

        // DerivedData, one item per project.
        var candidates: [PathCandidate] = []
        let derived = dev + "/Xcode/DerivedData"
        for name in FS.list(derived) where !Locations.ignorable.contains(name) {
            let path = derived + "/" + name
            var title = name
            var badges: [String] = []
            if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) > 20 {
                title = String(name[..<dash])
            }
            if let workspace = FS.readPlist(path + "/info.plist")?["WorkspacePath"] as? String, !FS.exists(workspace) {
                badges.append("Project no longer exists")
            }
            candidates.append(PathCandidate(path: path, title: "\(title) build data", risk: .safe,
                                            note: "Build products and indexes, recreated the next time you build. Deleting it also fixes many odd Xcode build problems.",
                                            badges: badges))
        }

        // Archives.
        let archives = dev + "/Xcode/Archives"
        for day in FS.list(archives) where FS.isDir(archives + "/" + day) {
            for name in FS.list(archives + "/" + day) where FS.ext(name) == "xcarchive" {
                let path = archives + "/" + day + "/" + name
                let info = FS.readPlist(path + "/Info.plist")
                let appProps = info?["ApplicationProperties"] as? [String: Any]
                let version = appProps?["CFBundleShortVersionString"] as? String
                let title = (info?["Name"] as? String ?? FS.stripExt(name)) + (version.map { " \($0)" } ?? "")
                candidates.append(PathCandidate(path: path, title: "Archive: \(title)", risk: .caution,
                                                note: "Needed to symbolicate crash reports from that build or upload it again. Safe to remove for builds you no longer support.",
                                                date: info?["CreationDate"] as? Date, dateKind: .created))
            }
        }

        // Device support files, per OS version.
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "xrOS", "macOS"] {
            let root = dev + "/Xcode/\(platform) DeviceSupport"
            for name in FS.list(root) where FS.isDir(root + "/" + name) {
                candidates.append(PathCandidate(path: root + "/" + name, title: "\(platform) device support \(name)", risk: .safe,
                                                note: "Debug symbols copied from a device. Xcode copies them again when you connect a device running that version."))
            }
        }

        let fixed: [Loc] = [
            .whole("~/Library/Developer/Xcode/Products", "Xcode products", .safe, "Built products, recreated by building."),
            .whole("~/Library/Developer/Xcode/DocumentationCache", "Xcode documentation cache", .safe, redownload),
            .whole("~/Library/Developer/Xcode/UserData/Previews", "SwiftUI preview simulators", .safe, "Recreated when you use previews."),
            .whole("~/Library/Developer/Xcode/iOS Device Logs", "Device logs", .safe, "Old logs from connected devices."),
            .whole("~/Library/Developer/Xcode/UserData/IB Support", "Interface Builder support", .safe, "Recreated automatically."),
            .whole("~/Library/Developer/CoreSimulator/Caches", "Simulator caches", .safe, "Recreated automatically."),
            .whole("~/Library/Developer/XCTestDevices", "Test simulator clones", .safe, "Created for parallel testing; recreated as needed."),
            .whole("~/Library/Developer/Xcode/XCPGDevices", "Playground simulators", .safe, "Recreated when you run playgrounds."),
            .whole("~/Library/Developer/DeveloperDiskImages", "Developer disk images", .safe, redownload),
            .whole("~/Library/Developer/Xcode/Snapshots", "Xcode snapshots", .review, "Project snapshots from old Xcode versions."),
            .children("~/Library/Developer/Toolchains", "Toolchain", .review, toolchain, extensions: ["xctoolchain"]),
            .children("/Library/Developer/Toolchains", "Toolchain", .review, toolchain, extensions: ["xctoolchain"]),
            .whole("~/Library/Developer/CoreSimulator/Profiles/Runtimes", "Old simulator runtimes", .review, "Simulator runtimes from older Xcode versions."),
        ]
        candidates += Locations.candidates(fixed, ctx: ctx)
        if FS.exists("/Library/Developer/CommandLineTools") && FS.exists("/Applications/Xcode.app") {
            candidates.append(PathCandidate(path: "/Library/Developer/CommandLineTools", title: "Command Line Tools", risk: .caution,
                                            note: "Xcode already contains these tools. Some tools (like Homebrew) prefer the standalone package and will ask to reinstall it (xcode-select --install).",
                                            badges: ["Duplicate of Xcode"]))
        }
        items += await Build.items(candidates, category: id, ctx: ctx)

        // Simulators and simulator runtimes need Xcode itself.
        let xcrun = "/usr/bin/xcrun"
        let devices = await ctx.shell.run(xcrun, ["simctl", "list", "devices", "--json"], timeout: 60)
        if devices.ok {
            let parsed = parseSimDevices(Data(devices.stdout.utf8))
            let paths = parsed.map { dev + "/CoreSimulator/Devices/" + $0.udid }
            let sizes = await ctx.sizes(paths)
            for (device, (path, size)) in zip(parsed, zip(paths, sizes)) {
                var badges: [String] = []
                if !device.available { badges.append("Unavailable") }
                if device.state == "Booted" { badges.append("Running") }
                if device.lastBooted == nil { badges.append("Never used") }
                items.append(Item(
                    id: "\(id)|sim|\(device.udid)", categoryID: id, title: "\(device.name) (\(device.runtime))",
                    detail: "Simulator · \(device.udid)", size: size, risk: device.available ? .review : .safe,
                    note: device.available
                        ? "A simulated device with its installed apps and data. Xcode can create a new one at any time."
                        : "This simulator's runtime is no longer installed, so it can't run.",
                    paths: [path], date: device.lastBooted, dateKind: .lastUsed, badges: badges,
                    steps: [.run(ShellCommand(xcrun, ["simctl", "delete"], targets: [device.udid], batchable: true))]
                ))
            }
            let runtimes = await ctx.shell.run(xcrun, ["simctl", "runtime", "list", "--json"], timeout: 60)
            if runtimes.ok, let root = (try? JSONSerialization.jsonObject(with: Data(runtimes.stdout.utf8))) as? [String: [String: Any]] {
                let iso = ISO8601DateFormatter()
                for (uuid, runtime) in root where (runtime["deletable"] as? Bool) ?? false {
                    let name = runtimeName(runtime["runtimeIdentifier"] as? String ?? "")
                    let build = runtime["build"] as? String ?? ""
                    items.append(Item(
                        id: "\(id)|runtime|\(uuid)", categoryID: id, title: "\(name) simulator runtime",
                        detail: "Build \(build) · \(runtime["kind"] as? String ?? "")",
                        size: (runtime["sizeBytes"] as? NSNumber)?.int64Value, risk: .review,
                        note: "Lets you run simulators of this OS version. Download it again from Xcode › Settings › Platforms.",
                        date: (runtime["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }, dateKind: .lastUsed,
                        steps: [.run(ShellCommand(xcrun, ["simctl", "runtime", "delete", uuid]))]
                    ))
                }
            }
        } else if FS.exists(dev + "/CoreSimulator/Devices") {
            notes.append("Simulators couldn't be listed (Xcode isn't selected or installed). Their data is still counted under other entries.")
        }
        return ScanResult(items.bySize(), notes: notes)
    }

    // MARK: Node.js

    static func node(_ ctx: ScanContext) async -> ScanResult {
        let id = "node"
        var items: [Item] = []
        let nodeVersion = await ctx.shell.run("node", ["--version"], timeout: 20)
        let active = nodeVersion.ok ? nodeVersion.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        let rootResult = await ctx.shell.run("npm", ["root", "-g"], timeout: 60)
        let listResult = await ctx.shell.run("npm", ["ls", "-g", "--depth=0", "--json"], timeout: 120)
        if rootResult.ok, let data = listResult.stdout.data(using: .utf8),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let deps = root["dependencies"] as? [String: Any] {
            let globalRoot = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let names = deps.keys.filter { $0 != "npm" && $0 != "corepack" }.sorted()
            let sizes = await ctx.sizes(names.map { globalRoot + "/" + $0 })
            for (name, size) in zip(names, sizes) {
                let version = (deps[name] as? [String: Any])?["version"] as? String ?? ""
                items.append(Item(id: "\(id)|global|\(name)", categoryID: id, title: name,
                                  detail: "Global npm package \(version)", size: size, risk: .review,
                                  note: "A command-line tool installed with npm install -g.",
                                  paths: [globalRoot + "/" + name], badges: ["npm -g"],
                                  steps: [.run(ShellCommand("npm", ["uninstall", "-g"], targets: [name], batchable: true))]))
            }
        }

        var versionLocs: [Loc] = [
            .children("~/.nvm/versions/node", "Node.js", .review, toolchain, dirsOnly: true),
            .children("~/.local/share/fnm/node-versions", "Node.js", .review, toolchain, dirsOnly: true),
            .children("~/Library/Application Support/fnm/node-versions", "Node.js", .review, toolchain, dirsOnly: true),
            .children("~/.volta/tools/image/node", "Node.js", .review, toolchain, dirsOnly: true),
            .children("~/.nodenv/versions", "Node.js", .review, toolchain, dirsOnly: true),
            .children("/usr/local/n/versions/node", "Node.js", .review, toolchain, dirsOnly: true),
            .children("~/.n/n/versions/node", "Node.js", .review, toolchain, dirsOnly: true),
        ]
        versionLocs += [
            .whole("~/.npm/_cacache", "npm cache", .safe, redownload),
            .whole("~/.npm/_npx", "npx cache", .safe, "Packages fetched by npx, downloaded again when used."),
            .whole("~/.npm/_logs", "npm logs", .safe, "Debug logs."),
            .whole("~/.npm/_prebuilds", "npm prebuilt binaries", .safe, redownload),
            .whole("~/.pnpm-store", "pnpm store", .review, "pnpm's shared package store. Projects re-download what they need on the next install."),
            .whole("~/Library/pnpm/store", "pnpm store", .review, "pnpm's shared package store. Projects re-download what they need on the next install."),
            .whole("~/.local/share/pnpm/store", "pnpm store", .review, "pnpm's shared package store. Projects re-download what they need on the next install."),
            .whole("~/.yarn/berry/cache", "Yarn cache", .safe, redownload),
            .whole("~/.bun/install/cache", "Bun cache", .safe, redownload),
            .whole("~/.node-gyp", "node-gyp headers", .safe, redownload),
            .whole("~/.nvm/.cache", "nvm download cache", .safe, "Downloaded Node.js archives."),
            .whole("~/.volta/tools/inventory", "Volta download cache", .safe, "Downloaded archives."),
            .whole("~/.electron", "Electron downloads", .safe, redownload),
            .whole("~/.expo", "Expo cache", .review, "Expo CLI state and caches."),
        ]
        var found = await Locations.scan(versionLocs, category: id, ctx: ctx)
        if let active {
            let bare = active.hasPrefix("v") ? String(active.dropFirst()) : active
            for index in found.indices where found[index].title.hasPrefix("Node.js") &&
                (found[index].title.hasSuffix(" " + active) || found[index].title.hasSuffix(" " + bare)) {
                found[index].risk = .caution
                found[index].badges.append("Active")
                found[index].note = "The version your terminal uses right now. " + toolchain
            }
        }
        items += found
        return ScanResult(items.bySize())
    }

    // MARK: Python

    static func python(_ ctx: ScanContext) async -> ScanResult {
        let id = "python"
        let env = "A Python environment with its own packages. Recreate it from the project's requirements if you need it again."
        let condaRoots = ["~/miniconda3", "~/anaconda3", "~/miniforge3", "~/mambaforge", "~/opt/anaconda3", "~/opt/miniconda3",
                          "/opt/anaconda3", "/opt/miniconda3", "/opt/homebrew/Caskroom/miniconda/base",
                          "/opt/homebrew/Caskroom/miniforge/base", "/usr/local/Caskroom/miniconda/base"]
        var locs: [Loc] = [
            .children("~/.pyenv/versions", "Python", .review, toolchain, dirsOnly: true),
            .children("~/.virtualenvs", "virtualenv", .review, env, dirsOnly: true),
            .children("~/.local/share/virtualenvs", "pipenv", .review, env, dirsOnly: true),
            .children("~/.conda/envs", "conda env", .review, env, dirsOnly: true),
            .children("~/.local/share/uv/python", "uv Python", .review, toolchain, dirsOnly: true),
            .children("~/.local/share/uv/tools", "uv tool", .review, "A command-line tool installed with uv tool install.", dirsOnly: true),
            .children("~/Library/Python", "pip --user packages for Python", .review,
                      "Packages installed with pip install --user for this Python version.", dirsOnly: true),
            .children("/Library/Frameworks/Python.framework/Versions", "Python.org Python", .review,
                      toolchain + " Installed from python.org.", skip: ["Current"], dirsOnly: true, protectNewest: true),
            .whole("~/Library/Jupyter/runtime", "Jupyter runtime files", .safe, "Connection files from old notebook sessions."),
            .whole("~/.ipython/profile_default/history.sqlite", "IPython history", .review, "Your IPython command history."),
            .whole("~/.matplotlib", "Matplotlib cache", .safe, "Font cache, rebuilt automatically."),
            .whole("~/.keras/datasets", "Keras datasets", .review, "Downloaded sample datasets."),
        ]
        for root in condaRoots {
            locs.append(.children(root + "/envs", "conda env", .review, env, dirsOnly: true))
        }
        var items = await Locations.scan(locs, category: id, ctx: ctx)
        let pythonApps = FS.list("/Applications").filter { $0.hasPrefix("Python ") && FS.isDir("/Applications/" + $0) }.map {
            PathCandidate(path: "/Applications/" + $0, title: $0, risk: .review,
                          note: "The python.org app folder (IDLE, docs) for an installed Python version.")
        }
        items += await Build.items(pythonApps, category: id, ctx: ctx)
        for root in condaRoots.map(ctx.p) where FS.isDir(root + "/pkgs") {
            let size = ctx.size(root + "/pkgs")
            let conda = root + "/bin/conda"
            let steps: [RemovalStep] = FileManager.default.isExecutableFile(atPath: conda)
                ? [.run(ShellCommand(conda, ["clean", "--all", "--yes"]))] : [.files([root + "/pkgs"])]
            items.append(Item(id: "\(id)|condapkgs|\(root)", categoryID: id, title: "conda package cache",
                              detail: ctx.display(root + "/pkgs"), size: size, risk: .safe,
                              note: "Downloaded packages and tarballs (conda clean --all). Environments keep working.",
                              paths: [root + "/pkgs"], steps: steps))
        }
        for root in ["~/.local/pipx/venvs", "~/.local/share/pipx/venvs"].map(ctx.p) {
            let names = FS.list(root).filter { FS.isDir(root + "/" + $0) }
            let sizes = await ctx.sizes(names.map { root + "/" + $0 })
            for (name, size) in zip(names, sizes) {
                let pipx = ctx.shell.which("pipx")
                items.append(Item(id: "\(id)|pipx|\(name)", categoryID: id, title: "pipx \(name)",
                                  detail: ctx.display(root + "/" + name), size: size, risk: .review,
                                  note: "A command-line tool installed with pipx.", paths: [root + "/" + name],
                                  steps: pipx.map { [.run(ShellCommand($0, ["uninstall", name]))] } ?? [.files([root + "/" + name])]))
            }
        }
        return ScanResult(items.bySize())
    }

    // MARK: Ruby

    static func ruby(_ ctx: ScanContext) async -> ScanResult {
        let locs: [Loc] = [
            .children("~/.rbenv/versions", "Ruby", .review, toolchain, dirsOnly: true),
            .children("~/.rvm/rubies", "Ruby", .review, toolchain, dirsOnly: true),
            .children("~/.rvm/gems", "RVM gemset", .review, "Gems installed for one Ruby version/gemset.", dirsOnly: true),
            .whole("~/.rvm/archives", "RVM downloads", .safe, "Downloaded Ruby archives."),
            .whole("~/.rvm/src", "RVM sources", .safe, "Source code used to build Ruby."),
            .children("~/.rubies", "Ruby", .review, toolchain, dirsOnly: true),
            .children("/opt/rubies", "Ruby", .review, toolchain, dirsOnly: true),
            .children("~/.local/share/rtx/installs/ruby", "Ruby", .review, toolchain, dirsOnly: true),
            .children("~/.gem/ruby", "Gems for Ruby", .review, "Gems installed with gem install --user-install.", dirsOnly: true),
            .children("~/.local/share/gem/ruby", "Gems for Ruby", .review, "Gems installed for your user.", dirsOnly: true),
            .whole("~/.gem/specs", "RubyGems spec cache", .safe, redownload),
            .whole("~/.bundle/cache", "Bundler cache", .safe, redownload),
            .children("~/.cocoapods/repos", "CocoaPods spec repo", .safe, "CocoaPods now uses a CDN; this local copy of the specs is downloaded again only if a project asks for it.", dirsOnly: true),
        ]
        var items = await Locations.scan(locs, category: "ruby", ctx: ctx)
        if let version = FS.readText(ctx.p("~/.rbenv/version"))?.trimmingCharacters(in: .whitespacesAndNewlines) {
            for index in items.indices where items[index].title == "Ruby \(version)" {
                items[index].risk = .caution
                items[index].badges.append("Default")
            }
        }
        return ScanResult(items.bySize())
    }

    // MARK: Rust

    public struct Crate: Sendable {
        public var name: String
        public var version: String
        public var bins: [String]
    }

    public static func parseCrates(_ data: Data) -> [Crate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installs = root["installs"] as? [String: Any] else { return [] }
        return installs.compactMap { (key, value) -> Crate? in
            let parts = key.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            let bins = (value as? [String: Any])?["bins"] as? [String] ?? []
            return Crate(name: String(parts[0]), version: String(parts[1]), bins: bins)
        }.sorted { $0.name < $1.name }
    }

    static func rust(_ ctx: ScanContext) async -> ScanResult {
        let id = "rust"
        let locs: [Loc] = [
            .children("~/.rustup/toolchains", "Rust toolchain", .review, toolchain, dirsOnly: true),
            .whole("~/.rustup/downloads", "rustup downloads", .safe, "Leftover downloads."),
            .whole("~/.rustup/tmp", "rustup temporary files", .safe, "Leftovers from interrupted installs."),
            .whole("~/.cargo/registry/cache", "Cargo crate archives", .safe, redownload),
            .whole("~/.cargo/registry/src", "Cargo crate sources", .safe, "Unpacked crate sources, re-extracted when needed."),
            .whole("~/.cargo/registry/index", "Cargo registry index", .safe, redownload),
            .whole("~/.cargo/git/checkouts", "Cargo git checkouts", .safe, redownload),
            .whole("~/.cargo/git/db", "Cargo git database", .safe, redownload),
        ]
        var items = await Locations.scan(locs, category: id, ctx: ctx)
        if let settings = FS.readText(ctx.p("~/.rustup/settings.toml")),
           let line = settings.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("default_toolchain") }) {
            let value = line.split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? ""
            for index in items.indices where items[index].title == "Rust toolchain \(value)" {
                items[index].risk = .caution
                items[index].badges.append("Default")
            }
        }
        if let data = FS.readData(ctx.p("~/.cargo/.crates2.json")) {
            let cargo = ctx.shell.which("cargo")
            for crate in parseCrates(data) {
                let bins = crate.bins.map { ctx.p("~/.cargo/bin/") + $0 }.filter(FS.exists)
                guard !bins.isEmpty else { continue }
                let size = bins.reduce(Int64(0)) { $0 + (FS.info($1)?.allocated ?? 0) }
                items.append(Item(id: "\(id)|crate|\(crate.name)", categoryID: id, title: crate.name,
                                  detail: "cargo install · \(crate.version) · \(crate.bins.joined(separator: ", "))",
                                  size: size, risk: .review, note: "A command-line tool installed with cargo install.",
                                  paths: bins, badges: ["cargo install"],
                                  steps: cargo.map { [.run(ShellCommand($0, ["uninstall", crate.name]))] } ?? [.files(bins)]))
            }
        }
        return ScanResult(items.bySize())
    }

    // MARK: Go

    static func go(_ ctx: ScanContext) async -> ScanResult {
        let id = "go"
        var modCache = ctx.p("~/go/pkg/mod")
        var gopath = ctx.p("~/go")
        let goTool = ctx.shell.which("go")
        if let goTool {
            let env = await ctx.shell.run(goTool, ["env", "GOMODCACHE", "GOPATH"], timeout: 30)
            let lines = env.lines
            if env.ok, lines.count >= 2 {
                if !lines[0].isEmpty { modCache = lines[0] }
                if !lines[1].isEmpty { gopath = lines[1].split(separator: ":").first.map(String.init) ?? gopath }
            }
        }
        var items: [Item] = []
        if FS.isDir(modCache) {
            let size = ctx.size(modCache)
            if size > 0 {
                items.append(Item(id: "\(id)|modcache", categoryID: id, title: "Go module cache", detail: ctx.display(modCache),
                                  size: size, risk: .safe, note: redownload + " (go clean -modcache)", paths: [modCache],
                                  steps: goTool.map { [.run(ShellCommand($0, ["clean", "-modcache"]))] } ?? [.files([modCache])]))
            }
        }
        let locs: [Loc] = [
            .children(gopath + "/bin", "Go tool", .review, "A command-line tool installed with go install."),
            .whole(gopath + "/pkg/sumdb", "Go checksum database cache", .safe, redownload),
            .children("~/sdk", nil, .review, "A Go version downloaded with golang.org/dl.", dirsOnly: true),
            .children("~/.gvm/gos", "Go", .review, toolchain, dirsOnly: true),
            .whole("~/.gvm/archive", "gvm downloads", .safe, "Downloaded archives."),
        ]
        items += await Locations.scan(locs, category: id, ctx: ctx)
        return ScanResult(items.bySize())
    }

    // MARK: Java, Kotlin & Android

    static func jvm(_ ctx: ScanContext) async -> ScanResult {
        let id = "jvm"
        let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? ctx.p("~/Library/Android/sdk")
        let androidNote = "An Android SDK component. Android Studio's SDK Manager can download it again."
        var locs: [Loc] = [
            .whole("~/.gradle/caches", "Gradle caches", .safe, redownload),
            .children("~/.gradle/wrapper/dists", "Gradle", .safe, "A Gradle version downloaded by a project's wrapper. Downloaded again by projects that need it.", dirsOnly: true),
            .whole("~/.gradle/daemon", "Gradle daemon logs", .safe, "Logs and state of old Gradle daemons."),
            .whole("~/.gradle/native", "Gradle native libraries", .safe, redownload),
            .children("~/.gradle/jdks", "Gradle-provisioned JDK", .review, toolchain, dirsOnly: true),
            .whole("~/.m2/repository", "Maven repository", .safe, redownload),
            .whole("~/.ivy2/cache", "Ivy cache", .safe, redownload),
            .whole("~/.sbt/boot", "sbt boot files", .safe, redownload),
            .whole("~/.konan/dependencies", "Kotlin/Native dependencies", .safe, redownload),
            .children("~/.konan", "Kotlin/Native", .review, toolchain, skip: ["dependencies", "cache"], dirsOnly: true),
            .children("/Library/Java/JavaVirtualMachines", "JDK", .review, toolchain, dirsOnly: true),
            .children("~/Library/Java/JavaVirtualMachines", "JDK", .review, toolchain, dirsOnly: true),
            .children("~/.jdks", "JDK", .review, toolchain, dirsOnly: true),
            .whole("~/.sdkman/archives", "SDKMAN downloads", .safe, "Downloaded archives."),
            .whole("~/.sdkman/tmp", "SDKMAN temporary files", .safe, "Leftovers."),
            .grandchildren("~/.sdkman/candidates", nil, .review, toolchain, skip: ["current"]),
            .whole("~/.android/cache", "Android cache", .safe, redownload),
            .whole("~/.android/build-cache", "Android build cache", .safe, "Recreated by builds."),
            .children(sdk + "/platforms", "Android platform", .review, androidNote, dirsOnly: true, protectNewest: true),
            .children(sdk + "/build-tools", "Android build-tools", .review, androidNote, dirsOnly: true, protectNewest: true),
            .children(sdk + "/ndk", "Android NDK", .review, androidNote, dirsOnly: true, protectNewest: true),
            .children(sdk + "/cmake", "Android CMake", .review, androidNote, dirsOnly: true),
            .children(sdk + "/sources", "Android sources", .review, androidNote, dirsOnly: true),
            .whole(sdk + "/ndk-bundle", "Old Android NDK bundle", .review, androidNote),
            .whole(sdk + "/emulator", "Android emulator", .review, androidNote),
            .whole(sdk + "/temp", "Android SDK temporary files", .safe, "Leftover downloads."),
            .whole(sdk + "/.temp", "Android SDK temporary files", .safe, "Leftover downloads."),
        ]
        // System images: system-images/android-34/google_apis/arm64-v8a
        let images = sdk + "/system-images"
        for api in FS.list(images) where FS.isDir(images + "/" + api) {
            locs.append(.grandchildren(images + "/" + api, "System image \(api)", .review,
                                       "An emulator system image. Emulators using it stop working until it's downloaded again."))
        }
        var items = await Locations.scan(locs, category: id, ctx: ctx)

        let avd = ctx.p("~/.android/avd")
        var avdCandidates: [PathCandidate] = []
        for name in FS.list(avd) where FS.ext(name) == "avd" {
            let ini = avd + "/" + FS.stripExt(name) + ".ini"
            avdCandidates.append(PathCandidate(path: avd + "/" + name, title: "Emulator \(FS.stripExt(name))", risk: .review,
                                               note: "An Android emulator with its installed apps and data.",
                                               extraPaths: FS.exists(ini) ? [ini] : []))
        }
        items += await Build.items(avdCandidates, category: id, ctx: ctx)
        return ScanResult(items.bySize())
    }

    // MARK: Other toolchains

    static func otherToolchains(_ ctx: ScanContext) async -> ScanResult {
        let id = "otherToolchains"
        let locs: [Loc] = [
            .grandchildren("~/.asdf/installs", "asdf", .review, toolchain),
            .whole("~/.asdf/downloads", "asdf downloads", .safe, "Downloaded archives."),
            .grandchildren("~/.local/share/mise/installs", "mise", .review, toolchain),
            .whole("~/.local/share/mise/downloads", "mise downloads", .safe, "Downloaded archives."),
            .grandchildren("~/.local/share/rtx/installs", "rtx", .review, toolchain, skip: ["ruby"]),
            .grandchildren("~/.proto/tools", "proto", .review, toolchain),
            .whole("~/.pub-cache/hosted", "Dart/Flutter package cache", .safe, redownload),
            .whole("~/.pub-cache/git", "Dart/Flutter git packages", .safe, redownload),
            .children("~/fvm/versions", "Flutter", .review, toolchain, dirsOnly: true),
            .children("~/.fvm/versions", "Flutter", .review, toolchain, dirsOnly: true),
            .children("~/.ghcup/ghc", "GHC", .review, toolchain, dirsOnly: true),
            .whole("~/.ghcup/cache", "GHCup downloads", .safe, "Downloaded archives."),
            .whole("~/.ghcup/tmp", "GHCup temporary files", .safe, "Leftovers."),
            .whole("~/.stack/programs", "Stack-installed GHC versions", .review, toolchain),
            .whole("~/.stack/pantry", "Stack package index", .safe, redownload),
            .whole("~/.cabal/packages", "Cabal package downloads", .safe, redownload),
            .whole("~/.cabal/store", "Cabal package store", .safe, "Compiled packages, rebuilt when needed."),
            .whole("~/.opam/download-cache", "opam download cache", .safe, redownload),
            .whole("~/.hex/packages", "Hex package cache", .safe, redownload),
            .whole("~/.kerl/builds", "kerl Erlang builds", .safe, "Build folders."),
            .whole("~/.kerl/archives", "kerl downloads", .safe, "Downloaded archives."),
            .whole("~/.composer/cache", "Composer cache", .safe, redownload),
            .whole("~/.nuget/packages", "NuGet packages", .safe, redownload),
            .children("/usr/local/share/dotnet/sdk", ".NET SDK", .review, toolchain, dirsOnly: true, protectNewest: true),
            .children("/usr/local/share/dotnet/shared/Microsoft.NETCore.App", ".NET runtime", .review, toolchain, dirsOnly: true, protectNewest: true),
            .children("~/.dotnet/sdk", ".NET SDK", .review, toolchain, dirsOnly: true, protectNewest: true),
            .whole("~/.templateengine", ".NET template cache", .safe, redownload),
            .whole("~/.julia/compiled", "Julia precompiled packages", .safe, "Recompiled when packages load."),
            .whole("~/.julia/artifacts", "Julia artifacts", .review, redownload),
            .whole("~/.julia/packages", "Julia packages", .review, redownload),
            .children("~/.julia/juliaup", "Julia", .review, toolchain, dirsOnly: true),
            .whole("~/.terraform.d/plugin-cache", "Terraform provider cache", .safe, redownload),
            .whole("~/.conan/data", "Conan packages", .safe, redownload),
            .whole("~/.conan2/p", "Conan 2 packages", .safe, redownload),
            .children("~/.swiftly/toolchains", "Swift", .review, toolchain, dirsOnly: true),
            .children("~/.local/share/swiftly/toolchains", "Swift", .review, toolchain, dirsOnly: true),
            .whole("~/.swiftpm/cache", "Swift Package Manager cache", .safe, redownload),
            .whole("~/.deno/gen", "Deno compiled cache", .safe, "Recreated automatically."),
            .whole("~/.platformio/packages", "PlatformIO packages", .review, redownload),
            .whole("~/.arduino15/staging", "Arduino downloads", .safe, "Downloaded archives."),
            .whole("~/.espressif/dist", "ESP-IDF downloads", .safe, "Downloaded archives."),
        ]
        var items = await Locations.scan(locs, category: id, ctx: ctx)
        let bazel = FS.list("/private/var/tmp").filter { $0.hasPrefix("_bazel_") }.map {
            PathCandidate(path: "/private/var/tmp/" + $0, title: "Bazel output (\($0))", risk: .safe,
                          note: "Bazel's build outputs and caches, rebuilt by the next build.")
        }
        items += await Build.items(bazel, category: id, ctx: ctx)
        if FS.isDir("/nix/store"), let collector = ctx.shell.which("nix-collect-garbage") {
            items.append(Item(id: "\(id)|nixgc", categoryID: id, title: "Unreferenced Nix store paths",
                              detail: "nix-collect-garbage", risk: .review,
                              note: "Removes store paths no profile or running program uses. Old profile generations are kept, so rollback still works.",
                              steps: [.run(ShellCommand(collector, []))]))
        }
        return ScanResult(items.bySize())
    }

    // MARK: Editors & IDEs

    /// Splits a VS Code extension folder name like "ms-python.python-2024.2.1-darwin-arm64".
    public static func parseExtensionFolder(_ name: String) -> (id: String, version: String)? {
        var index = name.startIndex
        while let dash = name[index...].firstIndex(of: "-") {
            let next = name.index(after: dash)
            if next < name.endIndex, name[next].isNumber, name[..<dash].contains(".") {
                return (String(name[..<dash]).lowercased(), String(name[next...]))
            }
            index = next
        }
        return nil
    }

    /// Splits a JetBrains settings folder like "IntelliJIdea2023.2" into ("IntelliJIdea", "2023.2").
    public static func parseJetBrainsFolder(_ name: String) -> (product: String, version: String)? {
        guard let start = name.firstIndex(where: { $0.isNumber }) else { return nil }
        let product = String(name[..<start])
        let version = String(name[start...])
        guard !product.isEmpty, version.first?.isNumber == true, version.contains("."),
              version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return (product, version)
    }

    static func ide(_ ctx: ScanContext) async -> ScanResult {
        let id = "ide"
        var candidates: [PathCandidate] = []
        let support = ctx.p("~/Library/Application Support")

        let editors: [(dir: String, label: String, extensions: String, cli: String)] = [
            ("Code", "VS Code", "~/.vscode/extensions", "code"),
            ("Code - Insiders", "VS Code Insiders", "~/.vscode-insiders/extensions", "code-insiders"),
            ("Cursor", "Cursor", "~/.cursor/extensions", "cursor"),
            ("VSCodium", "VSCodium", "~/.vscode-oss/extensions", "codium"),
            ("Windsurf", "Windsurf", "~/.windsurf/extensions", "windsurf"),
            ("Positron", "Positron", "~/.positron/extensions", "positron"),
            ("Kiro", "Kiro", "~/.kiro/extensions", "kiro"),
        ]
        for editor in editors {
            let root = support + "/" + editor.dir
            if FS.isDir(root) {
                let fixed: [(String, String, Risk, String)] = [
                    ("logs", "logs", .safe, "Log files."),
                    ("CachedExtensionVSIXs", "downloaded extension installers", .safe, "Extension packages kept after installing."),
                    ("CachedData", "code cache", .safe, "Compiled JavaScript cache, rebuilt at launch."),
                    ("CachedProfilesData", "profile cache", .safe, "Rebuilt automatically."),
                    ("User/History", "local file history", .review, "Timeline snapshots of files you edited."),
                ]
                for (sub, label, risk, note) in fixed where FS.exists(root + "/" + sub) {
                    candidates.append(PathCandidate(path: root + "/" + sub, title: "\(editor.label) \(label)", risk: risk, note: note))
                }
                // Per-workspace state for folders that no longer exist.
                let storage = root + "/User/workspaceStorage"
                for hash in FS.list(storage) {
                    let dir = storage + "/" + hash
                    guard let json = FS.readJSON(dir + "/workspace.json") as? [String: Any],
                          let uri = (json["folder"] as? String) ?? (json["workspace"] as? String),
                          uri.hasPrefix("file://"), let url = URL(string: uri) else { continue }
                    if !FS.exists(url.path) {
                        candidates.append(PathCandidate(path: dir, title: "\(editor.label) state for \(FS.name(url.path))",
                                                        detail: "\(ctx.display(url.path)) no longer exists", risk: .safe,
                                                        note: "Editor state (open tabs, extension data) for a folder that's been deleted or moved.",
                                                        badges: ["Folder gone"]))
                    }
                }
            }

            // Extensions: obsolete leftovers, older duplicate versions, and the rest for review.
            let extRoot = ctx.p(editor.extensions)
            guard FS.isDir(extRoot) else { continue }
            let obsolete = Set(((FS.readJSON(extRoot + "/.obsolete") as? [String: Any]) ?? [:]).keys)
            var byID: [String: [(folder: String, version: String)]] = [:]
            for folder in FS.list(extRoot) where FS.isDir(extRoot + "/" + folder) && !folder.hasPrefix(".") {
                guard let parsed = parseExtensionFolder(folder) else { continue }
                byID[parsed.id, default: []].append((folder, parsed.version))
            }
            let cli = ctx.shell.which(editor.cli)
            for (extID, versions) in byID {
                let newest = versions.max { FS.versionLess($0.version, $1.version) }!
                for entry in versions {
                    let path = extRoot + "/" + entry.folder
                    if obsolete.contains(entry.folder) {
                        candidates.append(PathCandidate(path: path, title: "\(extID) \(entry.version)", detail: "\(editor.label) extension",
                                                        risk: .safe, note: "Marked obsolete by the editor (left behind after an update or uninstall).",
                                                        badges: ["Obsolete"]))
                    } else if entry.folder != newest.folder {
                        candidates.append(PathCandidate(path: path, title: "\(extID) \(entry.version)", detail: "\(editor.label) extension",
                                                        risk: .safe, note: "An older copy; \(newest.version) is also installed.",
                                                        badges: ["Older version"]))
                    } else {
                        let steps: [RemovalStep] = cli.map { [.run(ShellCommand($0, ["--uninstall-extension", extID]))] } ?? [.files([path])]
                        candidates.append(PathCandidate(path: path, title: "\(extID) \(entry.version)", detail: "\(editor.label) extension",
                                                        risk: .review, note: "An installed extension. Remove it if you no longer use it.",
                                                        badges: ["Installed"], steps: steps))
                    }
                }
            }
        }

        // JetBrains (and Android Studio): settings folders of versions you've upgraded from.
        for (root, vendor) in [(support + "/JetBrains", "JetBrains"), (support + "/Google", "Google")] {
            var products: [String: [(name: String, version: String)]] = [:]
            for name in FS.list(root) where FS.isDir(root + "/" + name) {
                guard let parsed = parseJetBrainsFolder(name) else { continue }
                if vendor == "Google" && parsed.product != "AndroidStudio" { continue }
                products[parsed.product, default: []].append((name, parsed.version))
            }
            for (product, versions) in products where versions.count > 1 {
                let newest = versions.max { FS.versionLess($0.version, $1.version) }!
                for entry in versions where entry.name != newest.name {
                    candidates.append(PathCandidate(path: root + "/" + entry.name, title: "\(product) \(entry.version) settings",
                                                    risk: .safe, note: "Settings and plug-ins for an older version. \(product) \(newest.version) already copied what it needed.",
                                                    badges: ["Older version"]))
                    for extra in [ctx.p("~/Library/Caches/\(vendor)/\(entry.name)"), ctx.p("~/Library/Logs/\(vendor)/\(entry.name)")] where FS.exists(extra) {
                        candidates[candidates.count - 1].extraPaths.append(extra)
                    }
                }
            }
        }

        // JetBrains Toolbox (v1) keeps old builds for rollback.
        let toolbox = support + "/JetBrains/Toolbox/apps"
        for app in FS.list(toolbox) {
            for channel in FS.list(toolbox + "/" + app) where channel.hasPrefix("ch-") {
                let dir = toolbox + "/" + app + "/" + channel
                let builds = FS.list(dir).filter { $0.first?.isNumber == true && !$0.hasSuffix(".plugins") && !$0.hasSuffix(".vmoptions") && FS.isDir(dir + "/" + $0) }
                guard builds.count > 1, let newest = builds.max(by: FS.versionLess) else { continue }
                for build in builds where build != newest {
                    candidates.append(PathCandidate(path: dir + "/" + build, title: "\(app) build \(build)", risk: .safe,
                                                    note: "An older build Toolbox keeps for rollback.", badges: ["Older version"]))
                }
            }
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize())
    }

    // MARK: AI models

    public struct OllamaModel: Sendable {
        public var name: String
        public var size: Int64?
        public var modified: String
    }

    public static func parseOllamaList(_ text: String) -> [OllamaModel] {
        var rows: [OllamaModel] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard columns.count >= 3 else { continue }
            rows.append(OllamaModel(name: columns[0], size: SizeParser.parse(columns[2]), modified: columns.count > 3 ? columns[3] : ""))
        }
        return rows
    }

    static func ai(_ ctx: ScanContext) async -> ScanResult {
        let id = "ai"
        let model = "A downloaded AI model. It can be downloaded again, but these are large."
        var items: [Item] = []
        var ollamaListed = false
        if let ollama = ctx.shell.which("ollama") {
            let list = await ctx.shell.run(ollama, ["list"], timeout: 30)
            if list.ok {
                ollamaListed = true
                for row in parseOllamaList(list.stdout) {
                    items.append(Item(id: "\(id)|ollama|\(row.name)", categoryID: id, title: row.name,
                                      detail: "Ollama model · modified \(row.modified)", size: row.size, risk: .review,
                                      note: model, badges: ["Ollama"],
                                      steps: [.run(ShellCommand(ollama, ["rm"], targets: [row.name], batchable: true))]))
                }
            }
        }
        var locs: [Loc] = [
            .children("~/.lmstudio/models", "LM Studio", .review, model, dirsOnly: true),
            .children("~/.cache/lm-studio/models", "LM Studio", .review, model, dirsOnly: true),
            .children("~/Library/Application Support/nomic.ai/GPT4All", "GPT4All", .review, model, extensions: ["gguf", "bin"]),
            .children("~/Library/Application Support/Jan/data/models", "Jan", .review, model, dirsOnly: true),
            .children("~/jan/models", "Jan", .review, model, dirsOnly: true),
            .whole("~/.cache/torch", "PyTorch hub cache", .review, model),
            .children("~/.cache/whisper", "Whisper", .review, model),
            .whole("~/.cache/clip", "CLIP models", .review, model),
            .whole("~/.keras/models", "Keras models", .review, model),
            .whole("~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", "Chrome on-device AI model", .review,
                   "Gemini Nano for Chrome's built-in AI features. Chrome downloads it again if those features are on."),
            .whole("~/.diffusionbee", "DiffusionBee models", .review, model),
            .children("~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models", "Draw Things", .review, model),
            .children("~/.cache/huggingface/hub", nil, .review, model, dirsOnly: true),
            .whole("~/.cache/huggingface/xet", "Hugging Face download cache", .safe, "Chunk cache used while downloading."),
        ]
        if !ollamaListed { locs.append(.whole("~/.ollama/models", "Ollama models", .review, model)) }
        var found = await Locations.scan(locs, category: id, ctx: ctx)
        for index in found.indices {
            // models--org--name → org/name
            let name = FS.name(found[index].paths[0])
            for prefix in ["models--", "datasets--", "spaces--"] where name.hasPrefix(prefix) {
                let kind = prefix.dropLast(3)
                found[index].title = "Hugging Face \(kind): " + name.dropFirst(prefix.count).replacingOccurrences(of: "--", with: "/")
            }
        }
        items += found
        return ScanResult(items.bySize())
    }
}
