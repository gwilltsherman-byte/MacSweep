import Foundation

enum FileScanners {
    static func largeFiles(_ ctx: ScanContext) async -> ScanResult {
        let id = "largeFiles"
        let walk = await ctx.homeWalk()
        let items = walk.largeFiles.map { hit -> Item in
            let used = AppCatalog.lastUsed(hit.path)
            let date = used ?? hit.modified
            var badges = Badges.age(date, unusedLabel: used == nil ? "Not changed" : "Not opened")
            badges.insert(FS.ext(hit.path).uppercased(), at: 0)
            return Item(categoryID: id, title: FS.name(hit.path), detail: ctx.display(FS.parent(hit.path)), size: hit.size,
                        risk: .review, note: "A big file in your home folder. Only you can tell whether you still need it.",
                        paths: [hit.path], date: date, dateKind: used == nil ? .modified : .lastUsed,
                        badges: badges.filter { !$0.isEmpty })
        }
        let threshold = ByteCountFormatter.string(fromByteCount: ctx.settings.largeFileThreshold, countStyle: .file)
        return ScanResult(items.bySize(), notes: ["Files of \(threshold) or more outside ~/Library. Change the size in Settings."])
    }

    static func duplicates(_ ctx: ScanContext) async -> ScanResult {
        let id = "duplicates"
        let walk = await ctx.homeWalk()
        let token = ctx.cancel
        let buckets = walk.sizeBuckets
        let groups = await Background.run { DuplicateFinder.find(buckets: buckets, cancel: token) }
        let downloads = ctx.p("~/Downloads/")
        var items: [Item] = []
        for group in groups {
            // Keep the copy that looks most "original": not in Downloads, oldest, shortest path.
            let ordered = group.paths.sorted { a, b in
                let aDownload = a.hasPrefix(downloads), bDownload = b.hasPrefix(downloads)
                if aDownload != bDownload { return !aDownload }
                let aDate = FS.modified(a) ?? .distantFuture, bDate = FS.modified(b) ?? .distantFuture
                if aDate != bDate { return aDate < bDate }
                return a.count < b.count
            }
            let keep = ordered[0]
            let keepClone = contentIdentifier(keep)
            for (index, path) in ordered.dropFirst().enumerated() {
                let clone = keepClone != nil && contentIdentifier(path) == keepClone
                var badges = ["Copy \(index + 2) of \(ordered.count)"]
                if clone { badges.append("APFS clone") }
                items.append(Item(
                    categoryID: id, title: FS.name(path), detail: ctx.display(FS.parent(path)),
                    size: clone ? 0 : FS.info(path)?.allocated ?? group.size, risk: .review,
                    note: "Byte-for-byte identical to \(ctx.display(keep)), which is kept. MacSweep never lists every copy of a file."
                        + (clone ? " This copy is an APFS clone that shares storage with the original, so removing it frees almost nothing." : ""),
                    paths: [path], date: FS.modified(path), badges: badges, keepPath: keep
                ))
            }
        }
        let minimum = ByteCountFormatter.string(fromByteCount: ctx.settings.duplicateMinSize, countStyle: .file)
        return ScanResult(items.bySize(), notes: ["Compares files of \(minimum) or more outside ~/Library by their full contents. One copy of each is always kept off the list."])
    }

    static func contentIdentifier(_ path: String) -> Int64? {
        #if os(macOS)
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileContentIdentifierKey])
        return values?.fileContentIdentifier
        #else
        return nil
        #endif
    }

    static func oldDownloads(_ ctx: ScanContext) async -> ScanResult {
        let id = "oldDownloads"
        let root = ctx.p("~/Downloads")
        let days = ctx.settings.oldDownloadDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var candidates: [PathCandidate] = []
        for name in FS.list(root) where !Locations.ignorable.contains(name) {
            if HomeWalker.installerExtensions.contains(FS.ext(name)) { continue } // shown under Installers
            let path = root + "/" + name
            let dates = [FS.modified(path), AppCatalog.dateAdded(path), AppCatalog.lastUsed(path)].compactMap { $0 }
            guard let latest = dates.max(), latest < cutoff else { continue }
            candidates.append(PathCandidate(path: path, title: name, risk: .review,
                                            note: "Downloaded or last touched more than \(days) days ago.",
                                            badges: Badges.age(latest, unusedLabel: "Not touched"), date: latest))
        }
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize(),
                          notes: FS.isBlocked(root) ? ["MacSweep needs permission to read your Downloads folder."] : [])
    }

    static func installers(_ ctx: ScanContext) async -> ScanResult {
        let id = "installers"
        let walk = await ctx.homeWalk()
        var items = walk.installers.map { hit in
            Item(categoryID: id, title: FS.name(hit.path), detail: ctx.display(FS.parent(hit.path)), size: hit.size, risk: .review,
                 note: "An installer or disk image. Once the software is installed you rarely need it again, and it can usually be downloaded again.",
                 paths: [hit.path], date: hit.modified, badges: [FS.ext(hit.path).uppercased()])
        }
        var candidates: [PathCandidate] = []
        for name in FS.list("/Applications") where name.hasPrefix("Install macOS") || name.hasPrefix("Install OS X") {
            candidates.append(PathCandidate(path: "/Applications/" + name, title: FS.stripExt(name), risk: .review,
                                            note: "A full macOS installer. Download it again from the App Store or System Settings if you ever need it.",
                                            badges: ["macOS installer"]))
        }
        let locs: [Loc] = [
            .children("~/Library/iTunes/iPhone Software Updates", nil, .safe, "An iPhone software update. Finder downloads it again when needed.", extensions: ["ipsw"]),
            .children("~/Library/iTunes/iPad Software Updates", nil, .safe, "An iPad software update. Finder downloads it again when needed.", extensions: ["ipsw"]),
            .children("~/Library/iTunes/iPod Software Updates", nil, .safe, "An iPod software update.", extensions: ["ipsw"]),
            .whole("~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware", "Apple Configurator firmware", .safe,
                   "Downloaded device firmware."),
            .children("~/Library/Application Support/Apple/Configurator/Firmware", nil, .safe, "Downloaded device firmware.", extensions: ["ipsw"]),
        ]
        candidates += Locations.candidates(locs, ctx: ctx)
        items += await Build.items(candidates, category: id, ctx: ctx)
        return ScanResult(items.bySize())
    }

    static func backups(_ ctx: ScanContext) async -> ScanResult {
        let id = "backups"
        let root = ctx.p("~/Library/Application Support/MobileSync/Backup")
        var candidates: [PathCandidate] = []
        for name in FS.list(root) where FS.isDir(root + "/" + name) {
            let path = root + "/" + name
            let info = FS.readPlist(path + "/Info.plist")
            let device = info?["Device Name"] as? String ?? info?["Display Name"] as? String ?? name
            let product = info?["Product Name"] as? String ?? info?["Product Type"] as? String ?? "Device"
            let version = info?["Product Version"] as? String
            let date = info?["Last Backup Date"] as? Date
            candidates.append(PathCandidate(
                path: path, title: "\(device) backup",
                detail: [product, version.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " · "), risk: .caution,
                note: "A local backup of an iPhone or iPad. If the device also backs up to iCloud, or you no longer have it, you may not need this. It can't be restored once deleted.",
                badges: Badges.age(date, unusedLabel: "Not updated"), date: date, dateKind: .lastBackup
            ))
        }
        let notes = FS.isBlocked(root) ? ["Give MacSweep Full Disk Access to see device backups."] : []
        return ScanResult(await Build.items(candidates, category: id, ctx: ctx).bySize(), notes: notes)
    }

    static func attachments(_ ctx: ScanContext) async -> ScanResult {
        let locs: [Loc] = [
            .whole("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Mail attachments you opened", .safe,
                   "Copies Mail made when you opened attachments. The originals stay in your email."),
            .whole("~/Library/Mail Downloads", "Mail attachments you opened (older Mail)", .safe,
                   "Copies Mail made when you opened attachments. The originals stay in your email."),
            .whole("~/Library/Messages/Attachments", "Messages photos & attachments", .caution,
                   "Every photo, video and file in your Messages history on this Mac. With Messages in iCloud they can download again; otherwise they're gone, and old conversations show missing attachments."),
            .whole("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media", "WhatsApp media", .caution,
                   "Photos and videos from WhatsApp chats on this Mac."),
            .whole("~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache", "Slack cache", .safe,
                   "Cached images and files from Slack."),
            .whole("~/Library/Application Support/Microsoft/Teams/Cache", "Microsoft Teams cache", .safe, "Cached files from Teams."),
            .whole("~/Library/Containers/com.microsoft.teams2/Data/Library/Caches", "Microsoft Teams cache", .safe, "Cached files from Teams."),
            .whole("~/Library/Application Support/zoom.us/data", "Zoom data", .review, "Zoom's local data, including chat file caches."),
            .whole("~/Documents/Zoom", "Zoom recordings", .caution, "Meetings you recorded locally."),
        ]
        var notes: [String] = []
        if FS.isBlocked(ctx.p("~/Library/Messages")) || FS.isBlocked(ctx.p("~/Library/Mail")) {
            notes.append("Give MacSweep Full Disk Access to see Mail and Messages attachments.")
        }
        return ScanResult(await Locations.scan(locs, category: "attachments", ctx: ctx).bySize(), notes: notes)
    }

    static func clutter(_ ctx: ScanContext) async -> ScanResult {
        let id = "clutter"
        let walk = await ctx.homeWalk()
        var items: [Item] = []
        func aggregate(_ paths: [String], key: String, title: String, note: String) {
            guard !paths.isEmpty else { return }
            let size = paths.reduce(Int64(0)) { $0 + (FS.info($1)?.allocated ?? 0) }
            items.append(Item(id: "\(id)|\(key)", categoryID: id, title: "\(title) (\(paths.count))",
                              detail: "Spread across your home folder", size: size, risk: .safe, note: note,
                              paths: paths, steps: [.deleteForever(paths)]))
        }
        aggregate(walk.dsStores, key: "dsstore", title: ".DS_Store files",
                  note: "Finder's per-folder view settings (icon positions, sort order). Finder recreates them; folders may forget their custom view.")
        aggregate(walk.appleDoubles, key: "appledouble", title: "AppleDouble \"._\" files",
                  note: "Metadata shadows created when files were copied to or from non-Mac drives.")
        aggregate(walk.windowsJunk, key: "windows", title: "Windows thumbnail & settings files",
                  note: "Thumbs.db and desktop.ini files that Windows leaves on shared drives.")
        for link in walk.brokenLinks {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? "?"
            let offline = target.hasPrefix("/Volumes/")
            items.append(Item(categoryID: id, title: FS.name(link), detail: "\(ctx.display(link)) → \(target)", size: nil,
                              risk: offline ? .review : .safe,
                              note: offline ? "Points to a drive that isn't connected right now." : "A shortcut (symlink) whose target no longer exists.",
                              paths: [link], badges: ["Broken link"], steps: [.deleteForever([link])]))
        }
        return ScanResult(items.sorted { ($0.size ?? 0) > ($1.size ?? 0) },
                          notes: ["Searched \(walk.filesSeen) files outside ~/Library."])
    }
}
