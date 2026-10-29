import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A second, independent look at every item a scanner offers. Scanners rate things by what they usually
/// are; this checks what is actually on disk and in use right now. Evidence can only make a rating more
/// careful, never less careful, and every change comes with a plain-language reason.
public enum Importance {
    public static let inUseBadge = "In use"

    /// Folders an app keeps for you, where your own work can hide among settings and caches.
    static let dataProbe: Set<String> = ["leftovers", "apps"]
    static let unsavedProbe: Set<String> = ["temp", "leftovers", "apps"]
    static let gitProbe: Set<String> = ["temp", "oldDownloads", "leftovers"]
    /// Categories that list your own files, where location, type and origin decide how much they matter.
    static let personalFiles: Set<String> = ["largeFiles", "duplicates", "oldDownloads", "installers"]
    /// Categories that claim nothing uses an item. A program using it proves otherwise.
    static let claimsUnused: Set<String> = ["leftovers"]

    static func assess(_ items: [Item], category: String, ctx: ScanContext) async -> [Item] {
        guard !items.isEmpty else { return items }
        let open = await ctx.openFiles()
        let clouds = await ctx.cloudFolders()
        let token = ctx.cancel
        let probes = dataProbe.contains(category) || unsavedProbe.contains(category) || gitProbe.contains(category)
        let personal = personalFiles.contains(category)
        let assessed: [Item] = await Background.map(items) { (original: Item) -> Item in
            var item = original
            if token.isCancelled { return item }
            Importance.markInUse(&item, category: category, open: open)
            let removable = Array(Set(item.steps.flatMap(\.paths))).sorted()
            if probes { Importance.probeContents(&item, paths: removable, category: category, ctx: ctx) }
            if personal {
                for path in removable {
                    Importance.judgePersonalFile(&item, path: path, category: category, clouds: clouds, ctx: ctx)
                }
            }
            return item
        }
        return assessed
    }

    // MARK: Rules

    /// A shell working in a folder is a Terminal window, not an app to quit.
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "dash", "nu", "login"]

    static func markInUse(_ item: inout Item, category: String, open: OpenFiles) {
        guard !open.isEmpty else { return }
        for path in Set(item.paths + item.steps.flatMap(\.paths)) {
            guard let user = open.user(of: path) else { continue }
            let terminal = shells.contains(user)
            let who = terminal ? "A Terminal window" : user
            if claimsUnused.contains(category) {
                item.raise(atLeast: .caution, because: "\(who) is using it right now, so something on this Mac still needs it.",
                           badge: inUseBadge)
            } else if terminal {
                item.raise(atLeast: .review, because: "A Terminal window is working in it right now. Close that window before removing it.",
                           badge: inUseBadge)
            } else {
                item.raise(atLeast: .review, because: "\(user) has it open right now. Quit \(user) before removing it, or it may lose data or crash.",
                           badge: inUseBadge)
            }
            return
        }
    }

    static func probeContents(_ item: inout Item, paths: [String], category: String, ctx: ScanContext) {
        let git = gitProbe.contains(category)
        let unsaved = unsavedProbe.contains(category)
        let data = dataProbe.contains(category)
        for path in paths {
            // An app's own bundle is code, not something you made.
            if category == "apps" && FS.ext(path) == "app" { continue }
            if ctx.isCancelled { return }
            let found = ContentProbe.inspect(path, git: git, unsaved: unsaved, data: data, cancel: ctx.cancel)
            let place = ctx.display(path)
            if let repo = found.gitRepos.first {
                let name = FS.name(repo)
                if !GitProjects.hasRemote(repo) {
                    item.raise(atLeast: .caution,
                               because: "Contains the Git project “\(name)”, which has no remote, so it and its history exist only on this Mac.",
                               badge: "Git project")
                } else if category == "temp" {
                    item.raise(atLeast: .review,
                               because: "Contains a Git working copy of “\(name)”. Anything you haven't committed and pushed would be lost.",
                               badge: "Git project")
                } else {
                    item.raise(atLeast: .caution,
                               because: "Contains the Git project “\(name)”. Anything you haven't committed and pushed would be lost.",
                               badge: "Git project")
                }
            }
            if let marker = found.unsaved.first {
                item.raise(atLeast: .caution,
                           because: "Contains unsaved or recovered documents (\(FS.name(marker))). If an app quit while saving, this may be the only copy.",
                           badge: "Unsaved work")
            }
            if let first = found.containerDocuments.first {
                let count = found.containerDocuments.count
                item.raise(atLeast: .caution,
                           because: "\(place) has \(count) item\(count == 1 ? "" : "s") in the app's own Documents folder, such as “\(first)”. Many Mac apps save your work there by default.",
                           badge: "Your documents")
            }
            if let database = found.databases.max(by: { $0.bytes < $1.bytes }) {
                item.raise(atLeast: .caution,
                           because: "\(place) holds a database (“\(database.name)”, \(bytes(database.bytes))). Apps keep what you create in them, such as notes, tasks or messages, in files like this unless they sync it elsewhere.",
                           badge: "App data")
            }
            if let first = found.documents.first {
                let count = found.documents.count
                item.raise(atLeast: .caution,
                           because: "\(place) contains \(count) document\(count == 1 ? "" : "s") you may have made, such as “\(first)”.",
                           badge: "Your documents")
            }
        }
    }

    static func judgePersonalFile(_ item: inout Item, path: String, category: String, clouds: CloudFolders, ctx: ScanContext) {
        if let service = clouds.service(for: path) {
            item.raise(atLeast: .caution,
                       because: "It's in your \(service) folder, so deleting it here also deletes it from \(service) and from every device that syncs with it.",
                       badge: service)
        }
        if let project = ctx.projects.root(containing: path) {
            let kept = category == "duplicates" ? ", even though another copy is kept" : ""
            item.raise(atLeast: .caution,
                       because: "It's part of the Git project “\(FS.name(project))” (\(ctx.display(project))). Removing it changes that project\(kept).",
                       badge: "In a project")
        }
        // A kept copy exists for duplicates, so what the file is doesn't change how risky removing one copy is.
        guard category != "duplicates", let info = FS.info(path) else { return }
        let name = FS.name(path)
        let identified = FileKinds.kind(of: name)
        guard info.isRegular || identified != nil else { return }
        let origin = Provenance.of(path)
        if category == "installers" && FileKinds.isEncryptedDiskImage(path) {
            item.raise(atLeast: .caution,
                       because: "It's an encrypted disk image. Those usually hold private files someone locked away, not an installer.",
                       badge: "Encrypted")
            return
        }
        if let origin {
            item.raise(atLeast: .safe, because: origin.reason)
        }
        guard let kind = identified else { return }
        switch kind.group {
        case .critical:
            item.raise(atLeast: .caution,
                       because: "\(kind.label): losing it can lock you out of accounts or data, and it can't be downloaded again.",
                       badge: kind.label)
        case .personal:
            if origin == nil {
                item.raise(atLeast: .caution,
                           because: "\(kind.label), not downloaded from the internet: probably something you made, captured or saved yourself, so this may be the only copy.",
                           badge: kind.label)
            }
        case .replaceable:
            if origin == nil && FileKinds.soundsLikeBackup(name) {
                item.raise(atLeast: .caution,
                           because: "Its name suggests a backup, and it wasn't downloaded from the internet, so it may be the only copy of what's inside.",
                           badge: "Backup")
            }
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Open files

/// Files that running programs have open, from one `lsof` listing taken during the scan.
public struct OpenFiles: Sendable {
    struct Entry: Sendable {
        var path: [UInt8]
        var user: String
    }

    /// Sorted by path bytes, so everything inside a folder sits together.
    private let entries: [Entry]

    public init(_ list: [(path: String, user: String)]) {
        entries = list.map { Entry(path: Array(Safety.canonical($0.path).utf8), user: $0.user) }
            .sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The program that has this file, or anything inside this folder, open.
    public func user(of rawPath: String) -> String? {
        let path = Array(Safety.canonical(rawPath).utf8)
        guard path.count > 1 else { return nil }
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].path.lexicographicallyPrecedes(path) { low = middle + 1 } else { high = middle }
        }
        let slash = UInt8(ascii: "/")
        var index = low
        while index < entries.count && entries[index].path.starts(with: path) {
            let entry = entries[index].path
            if entry.count == path.count || entry[path.count] == slash { return entries[index].user }
            index += 1
        }
        return nil
    }

    /// Indexing, backup and sync services glance at files all the time; that isn't "in use".
    static let backgroundServices: Set<String> = [
        "mdworker", "mdworker_shared", "mds", "mds_stores", "lsof", "fileproviderd", "bird", "cloudd", "revisiond",
        "backupd", "mediaanalysisd", "photoanalysisd", "corespotlightd", "QuickLookUIService", "quicklookd",
    ]

    /// Reads `lsof -F pcfn` output into (path, program) pairs. The program is named after the app it
    /// belongs to when its executable is inside one ("Xcode" rather than "XCBBuildService").
    public static func parse(_ text: String, excludingPID ownPID: Int32? = nil) -> [(path: String, user: String)] {
        var found: [(path: String, user: String)] = []
        var pid: Int32 = -1
        var command = ""
        var app: String?
        var fd = ""
        var pending: [String] = []
        func flush() {
            if pid != ownPID && !backgroundServices.contains(command) {
                let user = app ?? (command.isEmpty ? "Another program" : command)
                for path in pending { found.append((path: path, user: user)) }
            }
            pending = []
        }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value) ?? -1
                command = ""
                app = nil
                fd = ""
            case "c":
                command = value
            case "f":
                fd = value
            case "n":
                guard value.hasPrefix("/") else { continue }
                if fd == "txt" {
                    // The program's own executable and libraries: only used to name it.
                    if app == nil { app = appName(fromExecutable: value) }
                } else if fd != "mem" && fd != "rtd" {
                    pending.append(value)
                }
            default:
                continue
            }
        }
        flush()
        return found
    }

    /// "/Applications/Xcode.app/Contents/SharedFrameworks/…/XCBBuildService" → "Xcode"
    static func appName(fromExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = path[..<range.lowerBound]
        guard let slash = bundle.lastIndex(of: "/") else { return nil }
        let name = String(bundle[bundle.index(after: slash)...])
        return name.isEmpty ? nil : name
    }

    static func snapshot(shell: Shell) async -> OpenFiles {
        let lsof = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsof) else { return OpenFiles([]) }
        let result = await shell.run(lsof, ["-w", "-n", "-P", "+c", "0", "-u", String(getuid()), "-F", "pcfn"], timeout: 30)
        // lsof exits with 1 when it couldn't look at some files; what it did list is still right.
        guard !result.timedOut, !result.stdout.isEmpty else { return OpenFiles([]) }
        return OpenFiles(parse(result.stdout, excludingPID: ProcessInfo.processInfo.processIdentifier))
    }
}

// MARK: - Cloud folders

/// Folders a cloud service keeps in sync. Deleting something there deletes it on every synced device too.
public struct CloudFolders: Sendable {
    public struct Root: Sendable, Hashable {
        public var path: String
        public var service: String

        public init(path: String, service: String) {
            self.path = path
            self.service = service
        }
    }

    public var roots: [Root]

    public init(roots: [Root]) { self.roots = roots }

    public func service(for rawPath: String) -> String? {
        let path = Safety.canonical(rawPath)
        return roots.first { path == $0.path || path.hasPrefix($0.path + "/") }?.service
    }

    public static func find(home rawHome: String) -> CloudFolders {
        let home = Safety.canonical(rawHome)
        var roots: [Root] = []
        let storage = home + "/Library/CloudStorage"
        for name in FS.list(storage) where FS.isDir(storage + "/" + name) {
            roots.append(Root(path: storage + "/" + name, service: storageService(name)))
        }
        let mobile = home + "/Library/Mobile Documents"
        if FS.isDir(mobile) { roots.append(Root(path: mobile, service: "iCloud Drive")) }
        // With "Desktop & Documents Folders" turned on, iCloud Drive keeps these two in sync as well.
        for folder in ["Desktop", "Documents"] where FS.exists(mobile + "/com~apple~CloudDocs/" + folder) {
            roots.append(Root(path: home + "/" + folder, service: "iCloud Drive"))
        }
        // Older sync apps put their folder straight into the home folder.
        for name in FS.list(home) where FS.isDir(home + "/" + name) {
            if let service = homeFolderService(name) { roots.append(Root(path: home + "/" + name, service: service)) }
        }
        return CloudFolders(roots: roots)
    }

    /// ~/Library/CloudStorage names: "Dropbox", "GoogleDrive-me@example.com", "OneDrive-Personal", "Box-Box"…
    static func storageService(_ name: String) -> String {
        let vendor = name.split(separator: "-").first.map(String.init) ?? name
        switch vendor.lowercased() {
        case "googledrive": return "Google Drive"
        case "onedrive": return "OneDrive"
        case "dropbox": return "Dropbox"
        case "box": return "Box"
        case "icloud", "iclouddrive": return "iCloud Drive"
        default: return vendor
        }
    }

    static func homeFolderService(_ name: String) -> String? {
        let exact: [String: String] = [
            "Box": "Box", "Box Sync": "Box", "My Drive": "Google Drive", "MEGA": "MEGA", "MEGAsync": "MEGA",
            "pCloud Drive": "pCloud", "Seafile": "Seafile", "SynologyDrive": "Synology Drive", "Tresorit": "Tresorit",
            "Sync": "Sync.com",
        ]
        if let service = exact[name] { return service }
        let prefixes: [(String, String)] = [
            ("Dropbox", "Dropbox"), ("OneDrive", "OneDrive"), ("Google Drive", "Google Drive"),
            ("Nextcloud", "Nextcloud"), ("ownCloud", "ownCloud"), ("Proton Drive", "Proton Drive"),
        ]
        for (prefix, service) in prefixes where name == prefix || name.hasPrefix(prefix + " ") || name.hasPrefix(prefix + "-") {
            return service
        }
        return nil
    }
}

// MARK: - Git projects

/// Finds the Git working copy a path belongs to, remembering answers per folder for the whole scan.
public final class GitProjects: @unchecked Sendable {
    private let known = Locked([String: String]())
    private let stops: Set<String>

    /// The home folder itself never counts as a project: some people keep their settings files in Git there.
    public init(home: String) {
        stops = ["/", "/Users", "/Volumes", FS.collapse(home)]
    }

    /// The working copy's root folder when `path` (a file or folder) is inside one, or is one.
    public func root(containing path: String) -> String? {
        var dir = FS.collapse(path)
        var visited: [String] = []
        var found: String?
        while dir.count > 1 && !stops.contains(dir) {
            if let answer = known.withLock({ $0[dir] }) {
                found = answer.isEmpty ? nil : answer
                break
            }
            visited.append(dir)
            if FS.exists(dir + "/.git") {
                found = dir
                break
            }
            dir = FS.parent(dir)
        }
        let answer = found ?? ""
        known.withLock { cache in
            for folder in visited { cache[folder] = answer }
        }
        return found
    }

    /// True when the repository has a remote it can be fetched from again.
    public static func hasRemote(_ root: String) -> Bool {
        var gitDir = root + "/.git"
        // Worktrees and submodules have a .git file pointing at the real repository.
        if let info = FS.info(gitDir), !info.isDirectory, let pointer = FS.readText(gitDir), pointer.hasPrefix("gitdir:") {
            let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? target : root + "/" + target
            if let common = FS.readText(gitDir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
                gitDir = common.hasPrefix("/") ? common : gitDir + "/" + common
            }
        }
        guard let config = FS.readText(gitDir + "/config") else { return false }
        return config.contains("[remote \"")
    }
}

// MARK: - Looking inside folders

enum TreeProbe {
    /// Visits what's under `root` without following symlinks or entering other volumes, and stops after
    /// `limit` entries so one huge folder can't stall a scan. `visit` returns whether to enter a folder.
    static func walk(_ root: String, limit: Int = 10_000, maxDepth: Int = 10, cancel: CancelToken? = nil,
                     _ visit: (_ path: String, _ name: String, _ isDirectory: Bool) -> Bool) {
        guard let rootInfo = FS.info(root), rootInfo.isDirectory else { return }
        var stack: [(path: String, depth: Int)] = [(root, 0)]
        var seen = 0
        while let folder = stack.popLast() {
            guard let handle = opendir(folder.path) else { continue }
            defer { closedir(handle) }
            while let record = readdir(handle) {
                let name = DiskUsage.entryName(record)
                if name == "." || name == ".." { continue }
                seen += 1
                if seen > limit { return }
                if seen & 0x3FF == 0, cancel?.isCancelled == true { return }
                let path = folder.path + "/" + name
                let type = record.pointee.d_type
                var isDirectory = type == 4 // DT_DIR
                if isDirectory || type == 0 { // DT_UNKNOWN: ask the file system
                    guard let info = FS.info(path) else { continue }
                    isDirectory = info.isDirectory
                    if isDirectory && info.device != rootInfo.device { continue }
                }
                if visit(path, name, isDirectory) && isDirectory && folder.depth + 1 < maxDepth {
                    stack.append((path, folder.depth + 1))
                }
            }
        }
    }
}

/// Looks inside a folder for things that matter more than its name suggests.
enum ContentProbe {
    struct Findings {
        var gitRepos: [String] = []
        var unsaved: [String] = []
        var databases: [(name: String, bytes: Int64)] = []
        var documents: [String] = []
        var containerDocuments: [String] = []
    }

    /// Folders that only ever hold disposable copies; nothing found inside them changes a rating.
    static let disposableFolders: Set<String> = [
        "Caches", "Cache", "cache", "caches", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "ShaderCache",
        "CachedData", "Logs", "logs", "Crashpad", "Service Worker", "blob_storage", "HTTPStorages", "WebKit",
        "Local Storage", "Session Storage", "IndexedDB", "Saved Application State", "DerivedData", "node_modules",
    ]

    /// Code bundles are the app's own files, not something you made.
    static let codeBundles: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "systemextension", "prefpane", "qlgenerator",
        "mdimporter", "saver", "component", "vst", "vst3", "clap",
    ]

    static func isUnsavedMarker(_ name: String) -> Bool {
        name == "Autosave Information" || name == "AutoRecovery" || name.hasPrefix("(A Document Being Saved By")
            || name.hasPrefix("NSIRD_")
    }

    static func hasContent(_ dir: String) -> Bool {
        FS.list(dir).contains { !$0.hasPrefix(".") && !Locations.ignorable.contains($0) }
    }

    /// Library locations that only ever hold disposable copies, wherever the item itself sits inside them.
    static let disposableLocations = [
        "/Library/Caches/", "/Library/Logs/", "/Library/WebKit/", "/Library/HTTPStorages/", "/Library/Saved Application State/",
        "/Library/Cookies/",
    ]

    static func inspect(_ root: String, git: Bool, unsaved: Bool, data: Bool, cancel: CancelToken?) -> Findings {
        var found = Findings()
        guard FS.info(root)?.isDirectory == true else { return found }
        if disposableLocations.contains(where: { (root + "/").contains($0) }) { return found }
        if data {
            // A sandboxed app's container: where it saves your documents unless you pick another folder.
            found.containerDocuments = FS.list(root + "/Data/Documents").filter {
                !$0.hasPrefix(".") && !Locations.ignorable.contains($0)
            }
        }
        TreeProbe.walk(root, cancel: cancel) { path, name, isDirectory in
            if name == ".git" {
                if git { found.gitRepos.append(FS.parent(path)) }
                return false
            }
            if isDirectory {
                if unsaved && isUnsavedMarker(name) && hasContent(path) {
                    found.unsaved.append(path)
                    return false
                }
                if disposableFolders.contains(name) { return false }
                let ext = FS.ext(name)
                if data && FileKinds.documentPackages.contains(ext) {
                    found.documents.append(name)
                    return false
                }
                return !codeBundles.contains(ext)
            }
            guard data else { return false }
            let ext = FS.ext(name)
            if FileKinds.databaseExtensions.contains(ext) {
                if !FileKinds.looksLikeCache(name), let size = FS.info(path)?.allocated, size >= 100_000 {
                    found.databases.append((name: name, bytes: size))
                }
            } else if FileKinds.documentExtensions.contains(ext) {
                found.documents.append(name)
            }
            return false
        }
        return found
    }
}

// MARK: - What a file is

public struct FileKind: Sendable, Hashable {
    public enum Group: Sendable, Hashable {
        /// Secrets such as password vaults and private keys: losing them can lock you out.
        case critical
        /// Usually something you made, captured or collected.
        case personal
        /// Usually a copy of something that can be downloaded or rebuilt.
        case replaceable
    }

    public var label: String
    public var group: Group

    public init(label: String, group: Group) {
        self.label = label
        self.group = group
    }
}

public enum FileKinds {
    static let byExtension: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        func add(_ label: String, _ group: FileKind.Group, _ extensions: String) {
            for ext in extensions.split(separator: " ") { table[String(ext)] = FileKind(label: label, group: group) }
        }
        add("Video", .personal, "mov mp4 m4v avi mkv mts m2ts 3gp braw r3d insv mxf webm wmv mpg mpeg vob")
        add("Photo", .personal, "jpg jpeg heic heif png tif tiff gif bmp webp")
        add("RAW photo", .personal, "dng cr2 cr3 crw nef nrw arw srf sr2 raf orf rw2 pef srw x3f 3fr iiq erf")
        add("Audio file", .personal, "m4a wav aif aiff caf flac mp3 aac ogg opus wma")
        add("Document", .personal, "pages doc docx odt rtf pdf tex epub")
        add("Spreadsheet", .personal, "numbers xls xlsx xlsm ods csv tsv")
        add("Presentation", .personal, "key ppt pptx odp")
        add("Design file", .personal, "psd psb ai indd idml sketch fig xd afphoto afdesign afpub kra clip procreate xcf eps")
        add("3D or CAD file", .personal, "blend c4d ma mb max fbx obj stl step stp iges igs dwg dxf skp f3d sldprt sldasm 3dm fcstd usdz")
        add("Video project", .personal, "prproj aep drp fcpxml motn")
        add("Audio project", .personal, "logicx band als ptx rpp flp cpr aup3 sesx")
        add("Database", .personal, "sqlite sqlite3 db mdb accdb fmp12 realm sql dump bson")
        add("Virtual machine disk", .personal, "vmdk vdi vhd vhdx qcow2 qcow hdd hds")
        add("Disk image", .personal, "sparseimage img toast")
        add("Backup", .personal, "bak backup bkp abbu")
        add("Data file", .personal, "parquet feather arrow h5 hdf5 nc npy npz mat sav dta rds rdata pkl pickle jsonl ndjson avro orc tfrecord txt")
        add("Email archive", .personal, "mbox eml emlx pst ost olm")
        add("Archive", .replaceable, "zip tar gz tgz bz2 tbz tbz2 xz txz 7z rar zst lz4 lzma cab sit sitx cpio xar")
        add("Installer", .replaceable, "dmg pkg mpkg iso xip ipsw cdr exe msi deb rpm appimage")
        add("App package", .replaceable, "ipa apk aab xapk")
        add("AI model", .replaceable, "gguf ggml safetensors ckpt pt pth onnx mlmodel tflite")
        add("Log or debug dump", .replaceable, "log trace hprof dmp core crash ips memgraph heapsnapshot cpuprofile pcap pcapng")
        add("Password vault", .critical, "kdbx kdb 1pif psafe3 opvault agilekeychain")
        add("Keychain", .critical, "keychain keychain-db")
        add("Key or certificate", .critical, "p12 pfx pem ppk gpg pgp ovpn")
        return table
    }()

    public static func kind(of name: String) -> FileKind? {
        let lower = name.lowercased()
        if lower == "wallet.dat" { return FileKind(label: "Cryptocurrency wallet", group: .critical) }
        guard let kind = byExtension[FS.ext(name)] else { return nil }
        if kind.label == "Archive" && soundsLikeBackup(name) { return FileKind(label: "Backup archive", group: .personal) }
        return kind
    }

    static func soundsLikeBackup(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["backup", "takeout", ".bak", "-bak", "_bak"].contains { lower.contains($0) }
    }

    /// Single-file databases. What an app keeps in them is often the only copy of your notes, tasks or messages.
    static let databaseExtensions: Set<String> = ["sqlite", "sqlite3", "sqlitedb", "db", "realm", "storedata", "fmp12", "mdb", "accdb"]

    /// Document formats saved as folders.
    static let documentPackages: Set<String> = [
        "pages", "numbers", "key", "rtfd", "logicx", "band", "fcpbundle", "scriv", "textbundle", "sketch", "graffle",
        "mindnode", "ooutline", "photoslibrary", "imovielibrary", "dtbase2",
    ]

    /// File types people make themselves rather than ones apps ship or cache.
    static let documentExtensions: Set<String> = [
        "pages", "numbers", "key", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "psd", "psb", "ai",
        "indd", "sketch", "fig", "afphoto", "afdesign", "afpub", "blend", "kra", "procreate", "xcf", "heic", "dng", "cr2",
        "cr3", "nef", "arw", "raf", "orf", "rw2", "als", "ptx", "rpp", "flp", "aup3", "prproj", "aep", "drp", "kdbx",
        "fountain", "graffle", "dwg", "skp", "f3d",
    ]

    static func looksLikeCache(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["cache", "cookie", "analytic", "crashlytics", "telemetry", "metrics", "sentry", "tracking"].contains { lower.contains($0) }
    }

    /// Encrypted disk images start with "encrcdsa"; ordinary installers never are.
    static func isEncryptedDiskImage(_ path: String) -> Bool {
        guard ["dmg", "sparseimage", "img"].contains(FS.ext(path)), FS.info(path)?.isRegular == true else { return false }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 8)
        return read(fd, &header, 8) == 8 && header == Array("encrcdsa".utf8)
    }
}

// MARK: - Where a file came from

/// What macOS recorded when a file arrived from the internet, by AirDrop or as a mail attachment.
public struct Provenance: Sendable, Hashable {
    public var host: String?
    public var agent: String?

    public init(host: String?, agent: String?) {
        self.host = host
        self.agent = agent
    }

    public var sentence: String {
        if let host { return "Downloaded from \(host)" }
        if agent == "sharingd" { return "Received with AirDrop" }
        if agent == "Mail" { return "Saved from Mail" }
        if let agent { return "Downloaded with \(agent)" }
        return "Downloaded from the internet"
    }

    /// The sentence plus where the original probably still is.
    public var reason: String {
        if host != nil { return sentence + ", so you can probably download it again there." }
        if agent == "sharingd" { return sentence + ", so whoever sent it may still have it." }
        if agent == "Mail" { return sentence + ", so the original is probably still in your email." }
        return sentence + ", so the original probably still exists where it came from."
    }

    public static func of(_ path: String) -> Provenance? {
        let sources = FS.extendedAttribute(path, "com.apple.metadata:kMDItemWhereFroms").flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String]
        }
        let quarantine = FS.extendedAttribute(path, "com.apple.quarantine").map { String(decoding: $0, as: UTF8.self) }
        return parse(sources: sources, quarantine: quarantine)
    }

    /// `quarantine` looks like "0083;65f1c2a0;Safari;4E1C…"; its third field is the app that saved the file.
    public static func parse(sources: [String]?, quarantine: String?) -> Provenance? {
        guard sources != nil || quarantine != nil else { return nil }
        let host = sources?.lazy.compactMap { URL(string: $0)?.host }.first { !$0.isEmpty }
        var agent: String?
        if let fields = quarantine?.split(separator: ";", omittingEmptySubsequences: false), fields.count >= 3 {
            let name = fields[2].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            if !name.isEmpty { agent = name }
        }
        return Provenance(host: host, agent: agent)
    }
}

// MARK: - Shell history

/// Commands you've typed in Terminal, read from your shell history so tools you use are never called unused.
public enum ShellHistory {
    public static func commands(home: String) -> Set<String> {
        var names = Set<String>()
        for file in [".zsh_history", ".bash_history", ".local/share/fish/fish_history"] {
            guard let data = FS.readData(home + "/" + file) else { continue }
            // zsh stores some bytes in its own escaped form; lossy decoding keeps ordinary command names intact.
            let text = String(decoding: data.suffix(4_000_000), as: UTF8.self)
            for raw in text.split(whereSeparator: \.isNewline).suffix(50_000) {
                var line = raw
                // zsh extended history: ": 1700000000:0;git status". fish: "- cmd: git status".
                if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") { line = line[line.index(after: semicolon)...] }
                if line.hasPrefix("- cmd: ") { line = line.dropFirst("- cmd: ".count) }
                names.formUnion(commandNames(in: String(line)))
            }
        }
        return names
    }

    static let prefixWords: Set<String> = [
        "sudo", "time", "nohup", "exec", "command", "builtin", "env", "noglob", "nice", "caffeinate", "then", "do",
        "else", "!", "xargs",
    ]

    /// The programs one command line runs: "sudo FOO=1 ffmpeg -i x | grep y" → ["ffmpeg", "grep"].
    public static func commandNames(in line: String) -> [String] {
        var names: [String] = []
        for segment in line.split(whereSeparator: { "|;&(){}`".contains($0) }) {
            var words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)[...]
            while let first = words.first, prefixWords.contains(first) || first.hasPrefix("-") || (first.contains("=") && !first.hasPrefix("=")) {
                words = words.dropFirst()
            }
            guard let word = words.first else { continue }
            let name = FS.name(word)
            if !name.isEmpty && name.count <= 64 { names.append(name) }
        }
        return names
    }
}
