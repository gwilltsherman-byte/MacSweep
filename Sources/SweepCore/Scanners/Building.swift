import Foundation

/// A path that may become an item once it's been measured.
struct PathCandidate: Sendable {
    var path: String
    var title: String
    var detail: String? = nil
    var risk: Risk
    var note: String
    var badges: [String] = []
    var bundleID: String? = nil
    var steps: [RemovalStep]? = nil
    var date: Date? = nil
    var dateKind: DateKind = .modified
    var extraPaths: [String] = []
    var keepPath: String? = nil
    var id: String? = nil
}

enum Build {
    /// Measures candidates in parallel and turns them into items, skipping ones that take no space.
    static func items(_ candidates: [PathCandidate], category: String, ctx: ScanContext,
                      keepEmpty: Bool = false) async -> [Item] {
        let token = ctx.cancel
        let sizes = await Background.map(candidates) { candidate in
            ([candidate.path] + candidate.extraPaths).reduce(Int64(0)) { $0 + DiskUsage.allocatedSize($1, cancel: token) }
        }
        var items: [Item] = []
        for (candidate, size) in zip(candidates, sizes) {
            if size == 0 && !keepEmpty { continue }
            items.append(item(candidate, size: size, category: category, ctx: ctx))
        }
        return items
    }

    static func item(_ c: PathCandidate, size: Int64?, category: String, ctx: ScanContext) -> Item {
        let paths = [c.path] + c.extraPaths
        return Item(id: c.id, categoryID: category, title: c.title, detail: c.detail ?? ctx.display(c.path), size: size,
                    risk: c.risk, note: c.note, paths: paths, date: c.date ?? FS.modified(c.path), dateKind: c.dateKind,
                    badges: c.badges, bundleID: c.bundleID, keepPath: c.keepPath, steps: c.steps)
    }
}

/// Declarative description of where to look for one kind of thing.
public struct Loc: Sendable {
    public enum Mode: Sendable { case whole, children, grandchildren }

    public var path: String
    public var mode: Mode
    public var title: String?
    public var risk: Risk
    public var note: String
    public var skip: Set<String> = []
    public var extensions: Set<String>? = nil
    public var dirsOnly = false
    /// For folders of versions: the newest one is marked Caution so it isn't removed by accident.
    public var protectNewest = false
    public var badges: [String] = []

    public static func whole(_ path: String, _ title: String, _ risk: Risk, _ note: String) -> Loc {
        Loc(path: path, mode: .whole, title: title, risk: risk, note: note)
    }

    public static func children(_ path: String, _ title: String? = nil, _ risk: Risk, _ note: String,
                                skip: Set<String> = [], extensions: Set<String>? = nil, dirsOnly: Bool = false,
                                protectNewest: Bool = false) -> Loc {
        Loc(path: path, mode: .children, title: title, risk: risk, note: note, skip: skip, extensions: extensions,
            dirsOnly: dirsOnly, protectNewest: protectNewest)
    }

    public static func grandchildren(_ path: String, _ title: String? = nil, _ risk: Risk, _ note: String,
                                     skip: Set<String> = [], dirsOnly: Bool = true) -> Loc {
        Loc(path: path, mode: .grandchildren, title: title, risk: risk, note: note, skip: skip, dirsOnly: dirsOnly)
    }
}

enum Locations {
    static let ignorable: Set<String> = [".DS_Store", ".localized", ".com.apple.timemachine.supported", "Icon\r"]

    static func candidates(_ locs: [Loc], ctx: ScanContext) -> [PathCandidate] {
        var all: [PathCandidate] = []
        for loc in locs {
            let base = ctx.p(loc.path)
            switch loc.mode {
            case .whole:
                guard FS.exists(base) else { continue }
                all.append(PathCandidate(path: base, title: loc.title ?? FS.name(base), risk: loc.risk, note: loc.note,
                                         badges: loc.badges))
            case .children:
                var group: [PathCandidate] = []
                for name in FS.list(base) where include(name, in: base, loc) {
                    let title = loc.title.map { "\($0) \(name)" } ?? name
                    group.append(PathCandidate(path: base + "/" + name, title: title, risk: loc.risk, note: loc.note,
                                               badges: loc.badges))
                }
                if loc.protectNewest { protectNewest(&group) }
                all += group
            case .grandchildren:
                for first in FS.list(base) where !ignorable.contains(first) && !loc.skip.contains(first) {
                    let middle = base + "/" + first
                    guard FS.isDir(middle) else { continue }
                    for second in FS.list(middle) where include(second, in: middle, loc) {
                        let title = [loc.title, first, second].compactMap { $0 }.joined(separator: " ")
                        all.append(PathCandidate(path: middle + "/" + second, title: title, risk: loc.risk,
                                                 note: loc.note, badges: loc.badges))
                    }
                }
            }
        }
        return all
    }

    static func include(_ name: String, in dir: String, _ loc: Loc) -> Bool {
        if ignorable.contains(name) || loc.skip.contains(name) { return false }
        if let extensions = loc.extensions, !extensions.contains(FS.ext(name)) { return false }
        if loc.dirsOnly && !FS.isDir(dir + "/" + name) { return false }
        return true
    }

    static func protectNewest(_ group: inout [PathCandidate]) {
        guard group.count > 0 else { return }
        var newest = 0
        for index in group.indices where FS.versionLess(FS.name(group[newest].path), FS.name(group[index].path)) {
            newest = index
        }
        if group.count == 1 {
            group[0].risk = max(group[0].risk, .caution)
            group[0].badges.append("Only version")
        } else {
            group[newest].risk = .caution
            group[newest].badges.append("Newest")
            for index in group.indices where index != newest { group[index].badges.append("Older version") }
        }
    }

    static func scan(_ locs: [Loc], category: String, ctx: ScanContext) async -> [Item] {
        await Build.items(candidates(locs, ctx: ctx), category: category, ctx: ctx)
    }
}

extension Array where Element == Item {
    /// Sorted largest first, which is how every category is shown initially.
    func bySize() -> [Item] { sorted { ($0.size ?? -1) > ($1.size ?? -1) } }
}

extension Date {
    var daysAgo: Int { Int(Date().timeIntervalSince(self) / 86_400) }
}

enum Badges {
    static func age(_ date: Date?, unusedLabel: String = "Not used") -> [String] {
        guard let date else { return [] }
        let days = date.daysAgo
        if days >= 730 { return ["\(unusedLabel) in 2+ years"] }
        if days >= 365 { return ["\(unusedLabel) in 1+ year"] }
        if days >= 180 { return ["\(unusedLabel) in 6+ months"] }
        return []
    }
}

enum SizeParser {
    /// Parses sizes printed by Docker, Ollama, Homebrew etc. ("1.2GB", "512 MB", "3.4kB", "12GiB").
    static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var number = ""
        var unit = ""
        for char in trimmed {
            if unit.isEmpty && (char.isNumber || char == ".") {
                number.append(char)
            } else if !char.isWhitespace {
                unit.append(char)
            }
        }
        guard let value = Double(number) else { return nil }
        let multipliers: [String: Double] = [
            "": 1, "b": 1,
            "k": 1e3, "kb": 1e3, "m": 1e6, "mb": 1e6, "g": 1e9, "gb": 1e9, "t": 1e12, "tb": 1e12,
            "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776,
        ]
        guard let multiplier = multipliers[unit.lowercased()] else { return nil }
        return Int64(value * multiplier)
    }
}
