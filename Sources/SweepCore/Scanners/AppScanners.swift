import Foundation

enum AppScanners {
    // MARK: Applications

    /// Library folders where apps leave settings, caches and data behind.
    struct LibraryIndex: Sendable {
        var entries: [String: [String]] = [:]
        var jobs: [Launchd.Job] = []

        static let userDirs = [
            "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
            "Saved Application State", "HTTPStorages", "WebKit", "Logs", "Cookies", "Application Scripts", "LaunchAgents",
        ]
        static let systemDirs = [
            "/Library/Application Support", "/Library/Preferences", "/Library/LaunchAgents", "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools", "/Library/Caches", "/Library/Logs",
        ]

        init(home: String) {
            for dir in LibraryIndex.userDirs {
                let path = home + "/Library/" + dir
                entries[path] = FS.list(path)
            }
            for path in LibraryIndex.systemDirs { entries[path] = FS.list(path) }
            jobs = Launchd.jobs(home: home)
        }

        /// Support files that belong to an app with this bundle id, name and location.
        func leftovers(bundleID: String?, appName: String, appPath: String) -> [String] {
            var found: [String] = []
            let name = appName.lowercased()
            let id = bundleID?.lowercased()
            for (dir, names) in entries {
                let base = FS.name(dir)
                for entry in names {
                    let lower = entry.lowercased()
                    var match = false
                    if let id {
                        switch base {
                        case "Preferences", "ByHost":
                            match = lower == id + ".plist" || (lower.hasPrefix(id + ".") && lower.hasSuffix(".plist"))
                        case "Containers", "Application Scripts":
                            match = lower == id || lower.hasPrefix(id + ".")
                        case "Group Containers":
                            match = lower == "group." + id || lower.hasSuffix("." + id)
                        case "Saved Application State":
                            match = lower == id + ".savedstate"
                        case "Cookies":
                            match = lower == id + ".binarycookies"
                        case "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools":
                            match = lower.hasPrefix(id + ".") || lower == id
                        default:
                            match = lower == id
                        }
                    }
                    if !match, ["Application Support", "Caches", "Logs"].contains(base), lower == name {
                        match = true
                    }
                    if match { found.append(dir + "/" + entry) }
                }
            }
            // Launch agents and daemons whose labels don't follow the app's id but that run a program
            // from inside the app or its support folders.
            let roots = [appPath] + found.filter { !Launchd.isJobPlist($0) }
            for job in jobs where !found.contains(job.plist) {
                if let program = job.program, roots.contains(where: { program == $0 || program.hasPrefix($0 + "/") }) {
                    found.append(job.plist)
                }
            }
            return found.sorted()
        }
    }

    static func applications(_ ctx: ScanContext) async -> ScanResult {
        let id = "apps"
        let apps = await ctx.apps().filter { app in
            guard let bundle = app.bundleID else { return true }
            return bundle != "com.apple.Safari" && !bundle.hasPrefix("com.apple.InstallAssistant")
        }
        let brew = await ctx.brew()
        var caskByApp: [String: (token: String, brew: String)] = [:]
        for cask in brew?.casks ?? [] {
            for app in cask.apps { caskByApp[app] = (cask.fullToken, brew!.brew) }
        }
        let home = ctx.home
        let index = await Background.run { LibraryIndex(home: home) }
        let running = await ctx.running()
        let token = ctx.cancel

        struct Measured: Sendable {
            var leftovers: [String]
            var appSize: Int64
            var leftoverSize: Int64
            var lastUsed: Date?
            /// Launch agents and daemons to stop before anything is deleted.
            var jobs: [Launchd.Job]
            var systemExtensions: [String]
        }
        let measured: [Measured] = await Background.map(apps) { app in
            let leftovers = index.leftovers(bundleID: app.bundleID, appName: app.name, appPath: app.path)
            let extensionsDir = app.path + "/Contents/Library/SystemExtensions"
            return Measured(
                leftovers: leftovers,
                appSize: DiskUsage.allocatedSize(app.path, cancel: token),
                leftoverSize: leftovers.reduce(Int64(0)) { $0 + DiskUsage.allocatedSize($1, cancel: token) },
                lastUsed: AppCatalog.lastUsed(app.path),
                jobs: leftovers.filter(Launchd.isJobPlist).compactMap(Launchd.read) + Launchd.bundledJobs(in: app.path),
                systemExtensions: FS.list(extensionsDir).compactMap { FS.bundleID(extensionsDir + "/" + $0)?.lowercased() }
            )
        }

        var items: [Item] = []
        for (app, info) in zip(apps, measured) {
            var badges: [String] = []
            if app.isAppStore { badges.append("App Store") }
            if app.isApple { badges.append("Apple") }
            let cask = caskByApp[FS.name(app.path)]
            if cask != nil { badges.append("Homebrew") }
            if info.lastUsed == nil {
                badges.append("No record of use")
            } else {
                badges += Badges.age(info.lastUsed)
            }
            // Background helpers keep running after their files are deleted and recreate them, so stop them first.
            var steps = Launchd.stopSteps(info.jobs, uid: ctx.uid)
            if let cask {
                steps.append(.run(ShellCommand(cask.brew, ["uninstall", "--cask"], targets: [cask.token], batchable: true)))
                if !info.leftovers.isEmpty { steps.append(.files(info.leftovers)) }
            } else {
                steps.append(.files([app.path] + info.leftovers))
            }
            var note = "Uninstalls the app completely. " + (info.leftovers.isEmpty
                ? "No settings or support files were found for it."
                : "Also removes \(info.leftovers.count) settings/support item\(info.leftovers.count == 1 ? "" : "s") it left in your Library (\(ByteCountFormatter.string(fromByteCount: info.leftoverSize, countStyle: .file))).")
            if cask != nil { note += " Installed with Homebrew, so Homebrew does the uninstall." }
            if !info.jobs.isEmpty { note += " Its background helpers are stopped first so they can't put files back." }
            // While the app is open, it and the helpers inside it are covered by "Quit these apps first". A helper
            // that runs from the app on its own (a menu-bar or login item) isn't, nor is anything in its leftovers.
            let stopped = Set(info.jobs.compactMap(\.program))
            let fromBundle = running.programs(inside: [app.path], except: stopped)
            let appIsOpen = fromBundle.contains { $0.identifier.hasPrefix(app.path + "/Contents/MacOS/") }
            var recreators = appIsOpen ? [] : fromBundle
            recreators += running.programs(inside: info.leftovers, except: stopped)
            recreators += running.extensions(where: { info.systemExtensions.contains($0.lowercased()) })
            if !recreators.isEmpty {
                badges.append("Still running")
                note += " " + RemovalPlan.comesBack(recreators)
            }
            items.append(Item(
                id: "\(id)|\(app.path)", categoryID: id, title: app.name,
                detail: [app.version.map { "Version \($0)" }, ctx.display(FS.parent(app.path))].compactMap { $0 }.joined(separator: " · "),
                size: info.appSize + info.leftoverSize, risk: .review, note: note,
                paths: [app.path] + info.leftovers, date: info.lastUsed, dateKind: .lastUsed, badges: badges,
                bundleID: app.bundleID, steps: steps, recreators: recreators
            ))
        }
        return ScanResult(items.bySize())
    }

    // MARK: Leftovers

    static let appleSupportNames: Set<String> = [
        "addressbook", "animoji", "appstore", "callhistorydb", "callhistorytransactions", "clouddocs", "crashreporter",
        "diskimages", "dock", "facetime", "fileprovider", "icloud", "icdd", "knowledge", "mobilesync", "quicklook",
        "syncservices", "ubiquity", "accounts", "networkserviceproxy", "coreparsec", "configurationprofiles",
        "homeenergyd", "photos", "maps", "siri", "spotlight", "contacts", "calendars", "mail", "messages", "notes",
        "reminders", "stocks", "weather", "screentime", "familycircle", "identityservices", "translation", "voicememos",
        "music", "tv", "podcasts", "books", "news", "freeform", "journal", "shortcuts", "safari", "gamekit",
        "applemediaservices", "audiocomponentcache", "cloudkit", "corefollowup", "dmd", "defaultstore", "assistant",
        "assistantservices", "bluetoothd", "callservices", "carplay", "commcenter", "privacypreferences", "sharedfilelist",
        "telephonyutilities", "videoconference", "wallpaper", "watchlistd", "locationaccessstored", "sesame",
        "proactive", "biome", "persona", "passkit", "managedsettings", "launchservices", "suggestions", "trial",
        "mediaanalysis", "homekit", "findmy", "remotemanagement", "coreduet", "intelligenceplatform", "studentdisplay",
        "dictionaries", "smartcard", "printing", "nanoprefs", "systemextensions", "colorsync",
        "differentialprivacy", "trustedpeershelper", "askpermission", "authkit", "photobooth", "siritts",
        "geoservices", "corespeech", "mediaremote", "imagecapture", "keychains", "screensharing", "remotedesktop",
        "networkextension", "safariservices", "webkit", "accessibility", "storeassets", "appleaccount",
    ]

    /// A bundle-id-shaped name: three or more dot-separated parts without spaces.
    static func looksLikeBundleID(_ name: String) -> Bool {
        !name.contains(" ") && name.split(separator: ".").count >= 3
    }

    /// True when two reverse-DNS identifiers belong to the same product: they share their first three parts
    /// (com.malwarebytes.mbam.frontend and com.malwarebytes.mbam.rtprotection.daemon, but not com.google.Chrome
    /// and com.google.keystone).
    static func sameProduct(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(separator: "."), y = b.lowercased().split(separator: ".")
        return zip(x, y).prefix { $0 == $1 }.count >= 3
    }

    /// True when a part of a reverse-DNS identifier after the first is this (normalized) name, e.g.
    /// com.malwarebytes.mbam.sysext for a folder called Malwarebytes.
    static func identifier(_ id: String, isNamed name: String) -> Bool {
        name.count >= 4 && id.split(separator: ".").dropFirst().contains { KnownSoftware.normalize(String($0)) == name }
    }

    static func ownerID(for entry: String, in dirName: String) -> String? {
        var name = entry
        switch dirName {
        case "Preferences":
            guard FS.ext(name) == "plist" else { return nil }
            name = FS.stripExt(name)
        case "ByHost":
            guard FS.ext(name) == "plist" else { return nil }
            var parts = FS.stripExt(name).split(separator: ".")
            if let last = parts.last, last.count >= 12, last.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
                parts.removeLast() // trailing hardware UUID
            }
            name = parts.joined(separator: ".")
        case "Cookies":
            guard FS.ext(name) == "binarycookies" else { return nil }
            name = FS.stripExt(name)
        case "Group Containers":
            if name.hasPrefix("group.") {
                name = String(name.dropFirst(6))
            } else if let dot = name.firstIndex(of: "."), name[..<dot].count == 10,
                      name[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
                name = String(name[name.index(after: dot)...]) // TEAMID.com.vendor.app
            }
        default:
            break
        }
        return name
    }

    static func isAppleOwned(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.hasPrefix("com.apple") || lower.hasPrefix("apple") || lower.hasPrefix("systemgroup.com.apple")
            || lower.hasPrefix("group.com.apple") || lower.hasPrefix(".") || lower.contains(".apple.")
            || lower.hasPrefix("org.cups.") || lower.hasPrefix("is.workflow.") || lower.hasPrefix("group.is.workflow.")
    }

    static func leftovers(_ ctx: ScanContext) async -> ScanResult {
        let id = "leftovers"
        let known = await ctx.known()
        let dirs: [String] = [
            "~/Library/Application Support", "~/Library/Preferences", "~/Library/Preferences/ByHost", "~/Library/Containers",
            "~/Library/Group Containers", "~/Library/HTTPStorages", "~/Library/WebKit", "~/Library/Cookies",
            "~/Library/Application Scripts", "/Library/Application Support", "/Library/Preferences",
        ].map(ctx.p)

        var groups: [String: (title: String, paths: [String], plainName: Bool)] = [:]
        for dir in dirs {
            let dirName = FS.name(dir)
            for entry in FS.list(dir) where !Locations.ignorable.contains(entry) {
                guard let owner = ownerID(for: entry, in: dirName), !owner.isEmpty, !isAppleOwned(owner) else { continue }
                let path = dir + "/" + entry
                if looksLikeBundleID(owner) {
                    if known.matches(bundleLike: owner) { continue }
                    let key = owner.lowercased()
                    groups[key, default: (owner, [], false)].paths.append(path)
                } else if dirName == "Application Support" {
                    let normalized = KnownSoftware.normalize(owner)
                    if appleSupportNames.contains(normalized) || known.matches(name: owner) { continue }
                    // Apple's own daemons use short lower-case names ending in "d".
                    if owner == owner.lowercased() && owner.hasSuffix("d") && !owner.contains(" ") { continue }
                    guard FS.isDir(path) else { continue }
                    let key = "name:" + normalized
                    groups[key, default: (owner, [], true)].paths.append(path)
                }
            }
        }

        /// Whether an identifier (a launch job's label, a system extension's) belongs to the software of a group.
        func belongs(_ identifier: String, to key: String, plainName: Bool) -> Bool {
            plainName ? AppScanners.identifier(identifier, isNamed: String(key.dropFirst(5))) : sameProduct(identifier, key)
        }

        // A deleted app's launch agents and daemons keep running and put its folders straight back,
        // so they're stopped and removed along with them. Jobs of installed software are never touched.
        var jobsByGroup: [String: [Launchd.Job]] = [:]
        let keys = groups.keys.sorted()
        for job in Launchd.jobs(home: ctx.home) where !known.matches(bundleLike: job.label) {
            let runsFromGroup = keys.first { key in
                guard let program = job.program else { return false }
                return groups[key]!.paths.contains { program.hasPrefix($0 + "/") }
            }
            let owner = runsFromGroup ?? keys.first { belongs(job.label, to: $0, plainName: groups[$0]!.plainName) }
            if let owner { jobsByGroup[owner, default: []].append(job) }
        }

        let running = await ctx.running()
        var candidates: [PathCandidate] = []
        for (key, group) in groups {
            let jobs = jobsByGroup[key] ?? []
            var paths = group.paths + jobs.map(\.plist)
            for case let program? in jobs.map(\.program)
            where program.hasPrefix("/Library/PrivilegedHelperTools/") && FS.exists(program) && !paths.contains(program) {
                paths.append(program)
            }
            let vendor = !group.plainName && known.vendorInstalled(group.title)
            var note: String
            if group.plainName {
                note = "No installed app matches this folder's name. It may belong to an app you removed, or to a command-line tool or plug-in, so check before deleting."
            } else if vendor {
                note = "No installed app uses this identifier, but another app from the same developer is installed and might share it."
            } else {
                note = "No installed app uses this identifier. It's most likely left over from an app you deleted."
            }
            var badges = group.plainName ? ["Name match"] : ["No matching app"]
            if paths.contains(where: { $0.hasPrefix("/Library/") }) { badges.append("All users") }
            if !jobs.isEmpty {
                note += " Its background \(jobs.count == 1 ? "helper is" : "helpers are") stopped and removed too (\(jobs.map(\.label).joined(separator: ", "))), so \(jobs.count == 1 ? "it" : "they") can't put these files back."
            }
            var recreators = running.programs(inside: paths, except: Set(jobs.compactMap(\.program)))
            recreators += running.extensions(where: { belongs($0, to: key, plainName: group.plainName) })
            if !recreators.isEmpty {
                badges.append("Still running")
                note += " " + RemovalPlan.comesBack(recreators)
            }
            candidates.append(PathCandidate(
                path: paths[0], title: group.title,
                detail: paths.count == 1 ? ctx.display(paths[0]) : "\(paths.count) locations",
                risk: .review, note: note, badges: badges,
                steps: Launchd.stopSteps(jobs, uid: ctx.uid) + [.files(paths)],
                extraPaths: Array(paths.dropFirst()), id: "\(id)|\(key)", recreators: recreators
            ))
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize())
    }

    // MARK: Launch agents, daemons & login items

    static func launchItems(_ ctx: ScanContext) async -> ScanResult {
        let id = "launchItems"
        let known = await ctx.known()
        var candidates: [PathCandidate] = []
        let uid = ctx.uid
        let places: [(dir: String, scope: String)] = [
            (ctx.p("~/Library/LaunchAgents"), "user"),
            ("/Library/LaunchAgents", "agent"),
            ("/Library/LaunchDaemons", "daemon"),
        ]
        for place in places {
            for name in FS.list(place.dir) where FS.ext(name) == "plist" && !name.hasPrefix("com.apple.") {
                let path = place.dir + "/" + name
                let job = Launchd.read(path) ?? Launchd.Job(plist: path, label: FS.stripExt(name), program: nil, disabled: false,
                                                            isDaemon: place.scope == "daemon")
                var badges: [String] = []
                var risk: Risk = .review
                var note: String
                if let program = job.program, program.hasPrefix("/"), !FS.exists(program) {
                    badges.append("Broken")
                    risk = .safe
                    note = "Starts \(program), which no longer exists, so it does nothing except log errors."
                } else if !known.matches(bundleLike: job.label) && looksLikeBundleID(job.label) {
                    badges.append("No matching app")
                    note = "Runs \(job.program.map { ctx.display($0) } ?? "a background task") automatically. No installed app matches it."
                } else {
                    note = "Runs \(job.program.map { ctx.display($0) } ?? "a background task") automatically\(place.scope == "daemon" ? " as root" : "") whenever you log in or start up. Removing it stops it from starting, but the app that installed it may add it back."
                }
                if job.disabled { badges.append("Disabled") }
                badges.append(place.scope == "user" ? "Your account" : place.scope == "agent" ? "All users" : "System daemon")
                let steps: [RemovalStep] = [Launchd.stop(job, uid: uid), .files([path])]
                candidates.append(PathCandidate(path: path, title: job.label, detail: job.program.map { ctx.display($0) },
                                                risk: risk, note: note, badges: badges, steps: steps))
            }
        }
        var items = await Build.items(candidates, category: id, ctx: ctx)
        var notes: [String] = []

        // Classic login items, via System Events (macOS asks for permission the first time).
        let script = """
        var se = Application("System Events");
        JSON.stringify(se.loginItems().map(function (i) { return { name: i.name(), path: i.path() }; }));
        """
        let result = await ctx.shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script], timeout: 60)
        if result.ok, let data = result.stdout.data(using: .utf8),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for entry in list {
                guard let name = entry["name"] as? String else { continue }
                let path = entry["path"] as? String ?? ""
                let missing = !path.isEmpty && !FS.exists(path)
                let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let delete = "Application(\"System Events\").loginItems.byName(\"\(escaped)\").delete()"
                items.append(Item(
                    id: "\(id)|login|\(name)", categoryID: id, title: name, detail: path.isEmpty ? "Login item" : ctx.display(path),
                    risk: missing ? .safe : .review,
                    note: missing ? "Opens an app that no longer exists." : "Opens automatically when you log in. Removing it only stops that; the app stays installed.",
                    badges: missing ? ["Login item", "Broken"] : ["Login item"],
                    steps: [.run(ShellCommand("/usr/bin/osascript", ["-l", "JavaScript", "-e", delete]))]
                ))
            }
        } else if result.stderr.contains("-1743") || result.stderr.lowercased().contains("not allowed") {
            notes.append("To list login items, allow MacSweep to control System Events in System Settings › Privacy & Security › Automation. Newer background items are listed under System Settings › General › Login Items & Extensions.")
        }
        return ScanResult(items.sorted { $0.risk < $1.risk || ($0.risk == $1.risk && $0.title < $1.title) }, notes: notes)
    }

    static func helpers(_ ctx: ScanContext) async -> ScanResult {
        let id = "helpers"
        let known = await ctx.known()
        var candidates: [PathCandidate] = []
        for name in FS.list("/Library/PrivilegedHelperTools") where !Locations.ignorable.contains(name) {
            let path = "/Library/PrivilegedHelperTools/" + name
            let orphan = looksLikeBundleID(name) && !known.matches(bundleLike: name)
            let daemon = "/Library/LaunchDaemons/\(name).plist"
            let paths = [path] + (orphan && FS.exists(daemon) ? [daemon] : [])
            // A running helper outlives its deleted file, so its daemon is stopped first.
            let stop = Launchd.read(daemon).map { [Launchd.stop($0, uid: ctx.uid)] } ?? []
            candidates.append(PathCandidate(
                path: path, title: name,
                risk: orphan ? .review : .caution,
                note: orphan
                    ? "A tool that runs as root on behalf of an app, and no installed app matches it. Its launch daemon (if any) is under Launch Agents & Daemons."
                    : "A tool that runs as root for an installed app. Removing it can break that app's features until it's reinstalled.",
                badges: orphan ? ["No matching app", "Runs as root"] : ["Runs as root"],
                steps: stop + [.files(paths)], extraPaths: Array(paths.dropFirst())
            ))
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize())
    }

    // MARK: Plug-ins, extensions, fonts

    static let pluginKinds: [(dir: String, label: String, systemOnly: Bool)] = [
        ("Internet Plug-Ins", "Browser plug-in", false),
        ("Audio/Plug-Ins/Components", "Audio Unit", false),
        ("Audio/Plug-Ins/VST", "VST plug-in", false),
        ("Audio/Plug-Ins/VST3", "VST3 plug-in", false),
        ("Audio/Plug-Ins/CLAP", "CLAP plug-in", false),
        ("Audio/Plug-Ins/HAL", "Audio driver", false),
        ("Audio/Plug-Ins/MAS", "MAS plug-in", false),
        ("Application Support/Avid/Audio/Plug-Ins", "AAX plug-in", false),
        ("QuickLook", "Quick Look plug-in", false),
        ("Spotlight", "Spotlight importer", false),
        ("PreferencePanes", "Settings pane", false),
        ("Screen Savers", "Screen saver", false),
        ("Input Methods", "Input method", false),
        ("Keyboard Layouts", "Keyboard layout", false),
        ("Services", "Service", false),
        ("ColorPickers", "Color picker", false),
        ("Contextual Menu Items", "Contextual menu item", false),
        ("Address Book Plug-Ins", "Contacts plug-in", false),
        ("iTunes/iTunes Plug-ins", "iTunes plug-in", false),
        ("Mail/Bundles", "Mail plug-in", false),
        ("Widgets", "Dashboard widget", false),
        ("Automator", "Automator action", false),
        ("Extensions", "Kernel extension", true),
        ("Filesystems", "File system driver", true),
        ("Frameworks", "Shared framework", true),
        ("Printers", "Printer driver", true),
        ("Image Capture/Devices", "Scanner/camera driver", true),
        ("Image Capture/TWAIN Data Sources", "Scanner driver", true),
    ]

    static func plugins(_ ctx: ScanContext) async -> ScanResult {
        let id = "plugins"
        var candidates: [PathCandidate] = []
        for kind in pluginKinds {
            var roots = ["/Library/" + kind.dir]
            if !kind.systemOnly { roots.insert(ctx.p("~/Library/") + kind.dir, at: 0) }
            for root in roots {
                for name in FS.list(root) where !Locations.ignorable.contains(name) {
                    let path = root + "/" + name
                    if let bundle = FS.bundleID(path), bundle.hasPrefix("com.apple.") { continue }
                    if kind.dir == "Frameworks" && name == "Python.framework" { continue }
                    if kind.dir == "Printers" && ["PPDs", "InstalledPrinters.plist", "PPD Plugins"].contains(name) { continue }
                    var note = "Adds a \(kind.label.lowercased()) to macOS. Remove it if you no longer use the software it came with."
                    if kind.dir == "Extensions" { note += " Restart afterwards." }
                    if kind.dir == "Printers" { note = "Drivers for a brand of printer or scanner. Remove them if you no longer use one of their devices." }
                    candidates.append(PathCandidate(path: path, title: FS.stripExt(name),
                                                    detail: "\(kind.label) · \(ctx.display(root))", risk: .review, note: note,
                                                    badges: root.hasPrefix("/Library") ? [kind.label, "All users"] : [kind.label]))
                }
            }
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize())
    }

    static func fonts(_ ctx: ScanContext) async -> ScanResult {
        let id = "fonts"
        let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "suit", "pfb", "pfm", "woff", "woff2"]
        var candidates: [PathCandidate] = []
        for root in [ctx.p("~/Library/Fonts"), "/Library/Fonts"] {
            var families: [String: [String]] = [:]
            for name in FS.list(root) where fontExtensions.contains(FS.ext(name)) || FS.ext(name).isEmpty && !name.hasPrefix(".") {
                if root == "/Library/Fonts" && name == "Arial Unicode.ttf" { continue } // ships with macOS
                let base = FS.stripExt(name)
                let family = base.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? base
                families[family, default: []].append(root + "/" + name)
            }
            for (family, paths) in families {
                let sorted = paths.sorted()
                candidates.append(PathCandidate(
                    path: sorted[0], title: family,
                    detail: "\(sorted.count) file\(sorted.count == 1 ? "" : "s") · \(ctx.display(root))",
                    risk: .review,
                    note: "An installed font family. Documents that use it will show a substitute font instead.",
                    badges: root.hasPrefix("/Library") ? ["All users"] : [], extraPaths: Array(sorted.dropFirst()),
                    id: "\(id)|\(root)|\(family)"
                ))
            }
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize())
    }

    // MARK: Installer receipts

    struct Receipt: Sendable {
        var id: String
        var version: String
        var installTime: Date?
        var files: [String]
        var dirs: [String]
        var recordedCount: Int
    }

    /// The app bundle a file belongs to, or its folder.
    static func installRoot(_ path: String) -> String {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return FS.parent(path)
    }

    static func receiptPaths(volume: String, location: String, relative: [String]) -> [String] {
        relative.map { FS.join([volume.isEmpty ? "/" : volume, location, $0]) }
    }

    static func receipts(_ ctx: ScanContext) async -> ScanResult {
        let id = "receipts"
        let pkgutil = "/usr/sbin/pkgutil"
        guard FileManager.default.isExecutableFile(atPath: pkgutil) else { return ScanResult() }
        let list = await ctx.shell.run(pkgutil, ["--pkgs"], timeout: 60)
        let ids = list.lines.filter { !$0.isEmpty && !$0.hasPrefix("com.apple.") }
        let shell = ctx.shell
        let home = ctx.home
        let receipts: [Receipt?] = await Background.map(ids) { pkg in
            let infoResult = shell.runSync(pkgutil, ["--pkg-info-plist", pkg], timeout: 30)
            guard let info = (try? PropertyListSerialization.propertyList(from: Data(infoResult.stdout.utf8), format: nil)) as? [String: Any]
            else { return nil }
            let volume = info["volume"] as? String ?? "/"
            let location = info["install-location"] as? String ?? ""
            let filesResult = shell.runSync(pkgutil, ["--files", pkg], timeout: 120)
            let relative = filesResult.lines.filter { !$0.isEmpty }
            var files: [String] = []
            var dirs: [String] = []
            for path in receiptPaths(volume: volume, location: location, relative: relative) {
                guard let item = FS.info(path) else { continue }
                if Safety.refusal(for: path, home: home) != nil { continue }
                if item.isDirectory { dirs.append(path) } else { files.append(path) }
            }
            let time = (info["install-time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Receipt(id: pkg, version: info["pkg-version"] as? String ?? "", installTime: time, files: files,
                           dirs: dirs, recordedCount: relative.count)
        }
        let found = receipts.compactMap { $0 }

        // Files that more than one package claims are left alone.
        var claims: [String: Int] = [:]
        for receipt in found { for file in receipt.files { claims[file, default: 0] += 1 } }

        var items: [Item] = []
        for receipt in found {
            let ownFiles = receipt.files.filter { (claims[$0] ?? 0) <= 1 }
            let size = ownFiles.reduce(Int64(0)) { $0 + (FS.info($1)?.allocated ?? 0) }
            let forget = "/usr/sbin/pkgutil --forget \(Shell.quote(receipt.id)) >/dev/null"
            if ownFiles.isEmpty {
                items.append(Item(
                    id: "\(id)|\(receipt.id)", categoryID: id, title: receipt.id, detail: "Version \(receipt.version) · files already gone",
                    risk: .safe, note: "The software this installer added has already been removed; only its record remains.",
                    date: receipt.installTime, dateKind: .installed, badges: ["Receipt only"],
                    steps: [.adminScript(AdminScript(summary: "Forget installer receipt \(receipt.id)", body: forget))]
                ))
                continue
            }
            var body = ownFiles.map { "/bin/rm -f -- \(Shell.quote($0)) || true" }
            body += receipt.dirs.sorted { $0.count > $1.count }.map { "/bin/rmdir -- \(Shell.quote($0)) 2>/dev/null || true" }
            body.append(forget)
            let tops = Array(Set(ownFiles.map(installRoot))).sorted()
            items.append(Item(
                id: "\(id)|\(receipt.id)", categoryID: id, title: receipt.id,
                detail: "Version \(receipt.version) · \(ownFiles.count) of \(receipt.recordedCount) files still present",
                size: size, risk: .caution,
                note: "Removes the files this .pkg installer put on your Mac (in \(tops.prefix(4).map { ctx.display($0) }.joined(separator: ", "))\(tops.count > 4 ? " and more" : "")) and forgets its receipt. Use this for software that has no uninstaller of its own. Files other packages also installed are kept.",
                paths: tops,
                date: receipt.installTime, dateKind: .installed,
                steps: [.adminScript(AdminScript(summary: "Delete \(ownFiles.count) files installed by \(receipt.id) and forget its receipt",
                                                 body: body.joined(separator: "\n")))]
            ))
        }
        return ScanResult(items.bySize())
    }

    // MARK: Optional Apple content & games

    static func appleExtras(_ ctx: ScanContext) async -> ScanResult {
        let note = "Sound libraries for GarageBand and Logic Pro. They offer to download them again if you open them."
        let locs: [Loc] = [
            .whole("/Library/Application Support/GarageBand", "GarageBand instruments & loops", .caution, note),
            .whole("/Library/Application Support/Logic", "Logic Pro sound library", .caution, note),
            .whole("/Library/Audio/Apple Loops/Apple", "Apple Loops", .caution, note),
            .whole("/Library/Audio/Apple Loops Index", "Apple Loops index", .safe, "Rebuilt automatically."),
            .whole("/Library/Audio/Impulse Responses/Apple", "Apple impulse responses", .caution, note),
            .whole("/Library/Application Support/MainStage", "MainStage content", .caution, note),
            .whole("~/Music/Audio Music Apps/Databases", "Audio Music Apps databases", .safe, "Search indexes for GarageBand/Logic, rebuilt automatically."),
            .whole("/Users/Shared/Relocated Items", "Relocated Items", .review, "Files macOS moved aside during an upgrade because they didn't fit the new system. Usually old configuration files."),
            .whole("/Users/Shared/Previously Relocated Items", "Previously Relocated Items", .review, "Files moved aside during an older macOS upgrade."),
            .children("/Library/Dictionaries", "Dictionary", .review, "An extra dictionary installed by an app.", extensions: ["dictionary"]),
            .children("~/Library/Dictionaries", "Dictionary", .review, "An extra dictionary you installed.", extensions: ["dictionary"]),
            .children("~/Library/Mobile Documents/com~apple~CloudDocs/.Trash", nil, .safe, "Already deleted from iCloud Drive."),
        ]
        return ScanResult(await Locations.scan(locs, category: "appleExtras", ctx: ctx).bySize())
    }

    /// Parses Valve's KeyValues text (appmanifest_*.acf, libraryfolders.vdf) into flat key/value pairs.
    public static func parseVDF(_ text: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            // "key"<tab><tab>"value" → ["", key, "\t\t", value, ""]
            if quoted.count >= 5 { pairs.append((String(quoted[1]), String(quoted[3]))) }
        }
        return pairs
    }

    static func games(_ ctx: ScanContext) async -> ScanResult {
        let id = "games"
        var candidates: [PathCandidate] = []
        let steam = ctx.p("~/Library/Application Support/Steam")
        var libraries = [steam + "/steamapps"]
        if let vdf = FS.readText(steam + "/steamapps/libraryfolders.vdf") {
            libraries += parseVDF(vdf).filter { $0.0 == "path" }.map { $0.1 + "/steamapps" }
        }
        for library in Set(libraries) {
            for name in FS.list(library) where name.hasPrefix("appmanifest_") {
                guard let text = FS.readText(library + "/" + name) else { continue }
                let pairs = parseVDF(text)
                func value(_ key: String) -> String? { pairs.first { $0.0 == key }?.1 }
                guard let appID = value("appid"), let dir = value("installdir") else { continue }
                let path = library + "/common/" + dir
                guard FS.exists(path) else { continue }
                candidates.append(PathCandidate(
                    path: path, title: value("name") ?? dir, detail: "Steam game", risk: .review,
                    note: "Opens Steam to uninstall the game. Your progress is usually kept in Steam Cloud.",
                    badges: ["Steam"], steps: [.run(ShellCommand("/usr/bin/open", ["steam://uninstall/\(appID)"]))],
                    date: (try? FileManager.default.attributesOfItem(atPath: library + "/" + name)[.modificationDate]) as? Date
                ))
            }
        }
        for name in FS.list("/Users/Shared/Epic Games") where !["Launcher", "UE_Engine"].contains(name) && !Locations.ignorable.contains(name) {
            candidates.append(PathCandidate(path: "/Users/Shared/Epic Games/" + name, title: name, detail: "Epic Games",
                                            risk: .review, note: "An installed Epic Games title. The launcher will offer to reinstall it.",
                                            badges: ["Epic Games"]))
        }
        let locs: [Loc] = [
            .children("~/Library/Application Support/Steam/steamapps/workshop/content", "Steam Workshop", .review,
                      "Mods and Workshop items, downloaded again when needed.", dirsOnly: true),
            .whole("~/Library/Application Support/Steam/steamapps/shadercache", "Steam shader cache", .safe, "Rebuilt by games as you play."),
            .whole("~/Library/Application Support/Steam/steamapps/downloading", "Unfinished Steam downloads", .safe, "Partial downloads."),
            .whole("~/Library/Application Support/Steam/appcache", "Steam app cache", .safe, "Rebuilt automatically."),
            .whole("~/Library/Application Support/Steam/logs", "Steam logs", .safe, "Log files."),
        ]
        var items = await Build.items(candidates, category: id, ctx: ctx)
        items += await Locations.scan(locs, category: id, ctx: ctx)
        return ScanResult(items.bySize())
    }
}
