import Foundation

/// How confident MacSweep is that removing something is harmless.
public enum Risk: Int, Comparable, CaseIterable, Sendable, Hashable {
    case safe = 0
    case review = 1
    case caution = 2

    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .caution: return "Caution"
        }
    }

    public var explanation: String {
        switch self {
        case .safe:
            return "Rebuilt or re-downloaded automatically when it's needed again."
        case .review:
            return "Probably unnecessary, but take a look first. You might still want it."
        case .caution:
            return "May hold your own data or be hard to get back. Remove it only if you're sure."
        }
    }
}

public enum SweepSection: String, CaseIterable, Identifiable, Sendable {
    case junk = "System Junk"
    case apps = "Apps & Add-ons"
    case developer = "Developer"
    case files = "Your Files"

    public var id: String { rawValue }
}

public struct SweepCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let section: SweepSection
    public let symbol: String
    public let summary: String

    public init(id: String, title: String, section: SweepSection, symbol: String, summary: String) {
        self.id = id
        self.title = title
        self.section = section
        self.symbol = symbol
        self.summary = summary
    }
}

public enum DateKind: String, Sendable, Hashable {
    case modified = "Modified"
    case lastUsed = "Last used"
    case installed = "Installed"
    case created = "Created"
    case lastBackup = "Last backup"
}

/// A command-line program to run as part of removing an item.
///
/// Commands with the same tool and arguments that are marked `batchable` are merged
/// into one invocation with all of their `targets` (e.g. `brew uninstall a b c`).
public struct ShellCommand: Hashable, Sendable {
    public var tool: String
    public var arguments: [String]
    public var targets: [String]
    public var batchable: Bool
    public var allowFailure: Bool
    public var timeout: TimeInterval

    public init(_ tool: String, _ arguments: [String], targets: [String] = [], batchable: Bool = false,
                allowFailure: Bool = false, timeout: TimeInterval = 900) {
        self.tool = tool
        self.arguments = arguments
        self.targets = targets
        self.batchable = batchable
        self.allowFailure = allowFailure
        self.timeout = timeout
    }

    public var fullArguments: [String] { arguments + targets }

    public var display: String {
        ([FS.name(tool)] + fullArguments).map(Shell.quote).joined(separator: " ")
    }

    var batchKey: String { ([tool] + arguments).joined(separator: "\u{1F}") + (allowFailure ? "\u{1F}af" : "") }
}

/// A block of shell script that runs with administrator privileges.
public struct AdminScript: Hashable, Sendable {
    public var summary: String
    public var body: String

    public init(summary: String, body: String) {
        self.summary = summary
        self.body = body
    }
}

public enum RemovalStep: Hashable, Sendable {
    /// Move to the Trash or delete, depending on the user's choice. Escalates to an
    /// administrator password prompt when the files aren't writable by the user.
    case files([String])
    /// Always delete permanently (for things already in the Trash, .DS_Store files and the like).
    case deleteForever([String])
    case run(ShellCommand)
    case runAsAdmin(ShellCommand)
    case adminScript(AdminScript)

    public var paths: [String] {
        switch self {
        case .files(let p), .deleteForever(let p): return p
        default: return []
        }
    }
}

/// One thing MacSweep found that might be unnecessary.
public struct Item: Identifiable, Hashable, Sendable {
    public var id: String
    public var categoryID: String
    public var title: String
    public var detail: String
    /// Bytes on disk, or nil when it can't be measured.
    public var size: Int64?
    public var risk: Risk
    /// Why this might be unnecessary and what happens if it's removed.
    public var note: String
    public var paths: [String]
    public var date: Date?
    public var dateKind: DateKind
    public var badges: [String]
    public var bundleID: String?
    /// A file that must survive for this item to be safe to remove (the original of a duplicate).
    public var keepPath: String?
    public var steps: [RemovalStep]
    /// Shown instead of a checkbox when MacSweep can't remove the item itself.
    public var manualRemoval: String?

    public init(id: String? = nil, categoryID: String, title: String, detail: String = "", size: Int64? = nil,
                risk: Risk, note: String, paths: [String] = [], date: Date? = nil, dateKind: DateKind = .modified,
                badges: [String] = [], bundleID: String? = nil, keepPath: String? = nil,
                steps: [RemovalStep]? = nil, manualRemoval: String? = nil) {
        self.id = id ?? "\(categoryID)|\(paths.first ?? title)"
        self.categoryID = categoryID
        self.title = title
        self.detail = detail
        self.size = size
        self.risk = risk
        self.note = note
        self.paths = paths
        self.date = date
        self.dateKind = dateKind
        self.badges = badges
        self.bundleID = bundleID
        self.keepPath = keepPath
        self.steps = steps ?? (paths.isEmpty ? [] : [.files(paths)])
        self.manualRemoval = manualRemoval
    }

    public var isRemovable: Bool { !steps.isEmpty }

    public var needsAdmin: Bool {
        steps.contains {
            switch $0 {
            case .runAsAdmin, .adminScript: return true
            default: return false
            }
        }
    }
}

public struct ScanResult: Sendable {
    public var items: [Item]
    public var notes: [String]

    public init(_ items: [Item] = [], notes: [String] = []) {
        self.items = items
        self.notes = notes
    }
}

public struct CategoryScanner: Sendable {
    public let category: SweepCategory
    public let scan: @Sendable (ScanContext) async -> ScanResult

    public init(_ category: SweepCategory, scan: @escaping @Sendable (ScanContext) async -> ScanResult) {
        self.category = category
        self.scan = scan
    }
}

public enum SizeMath {
    /// Adds up item sizes without counting the same bytes twice when one item's
    /// paths sit inside another's (e.g. a cache folder that is also inside a bigger one).
    public static func uniqueTotal<S: Sequence>(_ items: S) -> Int64 where S.Element == Item {
        var total: Int64 = 0
        var counted = Set<String>()
        let ordered = items.sorted { shallowest($0) < shallowest($1) }
        for item in ordered {
            guard let size = item.size, size > 0 else { continue }
            if item.paths.isEmpty {
                total += size
                continue
            }
            if item.paths.allSatisfy({ isCovered($0, by: counted) }) { continue }
            total += size
            counted.formUnion(item.paths)
        }
        return total
    }

    static func shallowest(_ item: Item) -> Int {
        item.paths.map { $0.split(separator: "/").count }.min() ?? 0
    }

    static func isCovered(_ path: String, by set: Set<String>) -> Bool {
        var current = path
        while true {
            if set.contains(current) { return true }
            guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else { return false }
            current = String(current[..<slash])
        }
    }
}
