import AppKit
import SwiftUI
import SweepCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case idle, scanning, done
    }

    struct CategoryState {
        var phase: Phase = .idle
        var items: [Item] = []
        var notes: [String] = []
        var total: Int64 = 0
        var seconds: Double = 0
    }

    enum Sheet: Identifiable {
        case confirm, progress, results
        var id: Self { self }
    }

    @Published private(set) var states: [String: CategoryState] = [:]
    @Published var checked: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var grandTotal: Int64 = 0
    @Published var sheet: Sheet?
    @Published private(set) var progressMessage = ""
    @Published private(set) var outcome: RemovalOutcome?
    @Published private(set) var outcomeItems: [Item] = []
    @Published private(set) var lastRemovalUsedTrash = true
    @Published private(set) var runningBundleIDs: Set<String> = []
    @Published private(set) var hasFullDiskAccess = true
    @Published private(set) var ignored: Set<String> = []

    let scanners = Catalog.all
    private var itemIndex: [String: Item] = [:]
    private var context: ScanContext?
    private var scanTask: Task<Void, Never>?

    init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredItems") ?? [])
        refreshEnvironment()
    }

    // MARK: Lookups

    var categories: [SweepCategory] { scanners.map(\.category) }

    func categories(in section: SweepSection) -> [SweepCategory] {
        categories.filter { $0.section == section }
    }

    func category(_ id: String) -> SweepCategory? { categories.first { $0.id == id } }

    func state(_ id: String) -> CategoryState { states[id] ?? CategoryState() }

    func item(_ id: String) -> Item? { itemIndex[id] }

    func visibleItems(_ categoryID: String) -> [Item] {
        state(categoryID).items.filter { !ignored.contains($0.id) }
    }

    var selectedItems: [Item] {
        let order = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
        return checked.compactMap { itemIndex[$0] }.sorted {
            let a = order[$0.categoryID] ?? 0, b = order[$1.categoryID] ?? 0
            return a != b ? a < b : ($0.size ?? 0) > ($1.size ?? 0)
        }
    }

    var hasScanned: Bool { lastScan != nil || states.values.contains { $0.phase != .idle } }

    func isRunning(_ item: Item) -> Bool {
        guard let id = item.bundleID?.lowercased() else { return false }
        return runningBundleIDs.contains(id)
    }

    // MARK: Scanning

    func currentSettings() -> ScanSettings {
        let defaults = UserDefaults.standard
        let largeMB = defaults.object(forKey: "largeFileMB") as? Int ?? 500
        let days = defaults.object(forKey: "oldDownloadDays") as? Int ?? 90
        let duplicateKB = defaults.object(forKey: "duplicateMinKB") as? Int ?? 1000
        let extra = (defaults.string(forKey: "extraFolders") ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return ScanSettings(home: NSHomeDirectory(), largeFileThreshold: Int64(largeMB) * 1_000_000,
                            oldDownloadDays: days, duplicateMinSize: Int64(duplicateKB) * 1_000, extraRoots: extra,
                            selfBundleID: Bundle.main.bundleIdentifier)
    }

    func scanAll() { scan(categories.map(\.id)) }

    func scan(_ ids: [String]) {
        guard !isScanning else { return }
        refreshEnvironment()
        let ctx = ScanContext(settings: currentSettings())
        context = ctx
        isScanning = true
        for id in ids {
            for item in states[id]?.items ?? [] { itemIndex[item.id] = nil }
            states[id] = CategoryState(phase: .scanning)
        }
        checked = checked.filter { itemIndex[$0] != nil }
        recomputeGrandTotal()

        let selected = scanners.filter { ids.contains($0.category.id) }
        scanTask = Task { [weak self] in
            await withTaskGroup(of: (String, ScanResult, Double).self) { group in
                var pending = selected[...]
                for _ in 0..<6 {
                    guard let next = pending.popFirst() else { break }
                    group.addTask { await AppModel.run(next, ctx) }
                }
                while let finished = await group.next() {
                    self?.apply(finished.0, finished.1, seconds: finished.2)
                    if let next = pending.popFirst(), !ctx.isCancelled {
                        group.addTask { await AppModel.run(next, ctx) }
                    }
                }
            }
            self?.finishScan()
        }
    }

    nonisolated static func run(_ scanner: CategoryScanner, _ ctx: ScanContext) async -> (String, ScanResult, Double) {
        let start = Date()
        let result = await scanner.scan(ctx)
        return (scanner.category.id, result, Date().timeIntervalSince(start))
    }

    func cancelScan() {
        context?.cancel.cancel()
    }

    private func apply(_ id: String, _ result: ScanResult, seconds: Double) {
        var state = CategoryState(phase: .done, items: result.items, notes: result.notes, seconds: seconds)
        if context?.isCancelled == true {
            state.notes.insert("The scan was stopped, so this list may be incomplete.", at: 0)
        }
        for item in result.items { itemIndex[item.id] = item }
        state.total = SizeMath.uniqueTotal(state.items.filter { !ignored.contains($0.id) })
        states[id] = state
        recomputeGrandTotal()
    }

    private func finishScan() {
        for (id, state) in states where state.phase == .scanning {
            states[id] = CategoryState()
        }
        isScanning = false
        lastScan = Date()
        scanTask = nil
    }

    private func recomputeGrandTotal() {
        grandTotal = SizeMath.uniqueTotal(states.values.flatMap { $0.items }.filter { !ignored.contains($0.id) })
    }

    private func recomputeTotals() {
        for (id, var state) in states {
            state.total = SizeMath.uniqueTotal(state.items.filter { !ignored.contains($0.id) })
            states[id] = state
        }
        recomputeGrandTotal()
    }

    // MARK: Selection

    func isChecked(_ id: String) -> Bool { checked.contains(id) }

    func setChecked(_ id: String, _ on: Bool) {
        guard let item = itemIndex[id], item.isRemovable else { return }
        if on { checked.insert(id) } else { checked.remove(id) }
    }

    func check<S: Sequence>(_ ids: S, _ on: Bool) where S.Element == String {
        var updated = checked
        for id in ids {
            guard let item = itemIndex[id], item.isRemovable else { continue }
            if on { updated.insert(id) } else { updated.remove(id) }
        }
        checked = updated
    }

    func toggle(_ ids: Set<String>) {
        let allChecked = ids.allSatisfy { checked.contains($0) }
        check(ids, !allChecked)
    }

    func checkAllSafe() {
        let safe = states.values.flatMap { $0.items }.filter { $0.risk == .safe && !ignored.contains($0.id) }.map(\.id)
        check(safe, true)
    }

    func ignore<S: Sequence>(_ ids: S) where S.Element == String {
        ignored.formUnion(ids)
        checked.subtract(ids)
        saveIgnored()
        recomputeTotals()
    }

    func clearIgnored() {
        ignored = []
        saveIgnored()
        recomputeTotals()
    }

    private func saveIgnored() {
        UserDefaults.standard.set(Array(ignored), forKey: "ignoredItems")
    }

    // MARK: Removal

    func requestRemoval() {
        guard !checked.isEmpty, !isScanning else { return }
        refreshEnvironment()
        sheet = .confirm
    }

    func warnings(for items: [Item], useTrash: Bool) -> [String] {
        var warnings: [String] = []
        let running = items.filter(isRunning).map(\.title)
        if !running.isEmpty {
            warnings.append("Quit these apps first: \(running.prefix(6).joined(separator: ", "))\(running.count > 6 ? "…" : "").")
        }
        let selectedPaths = Set(items.flatMap(\.paths))
        let lastCopies = items.filter { item in
            guard let keep = item.keepPath else { return false }
            return covered(keep, by: selectedPaths)
        }
        if !lastCopies.isEmpty {
            warnings.append("You've also selected the copy MacSweep would keep for \(lastCopies.prefix(3).map(\.title).joined(separator: ", ")). Every copy of those files would be removed.")
        }
        let caution = items.filter { $0.risk == .caution }.count
        if caution > 0 {
            warnings.append("\(caution) item\(caution == 1 ? " is" : "s are") rated Careful and may contain your own data.")
        }
        if items.contains(where: \.needsAdmin) || items.contains(where: { $0.paths.contains { $0.hasPrefix("/Library/") || $0.hasPrefix("/Applications/") || $0.hasPrefix("/usr/") || $0.hasPrefix("/private/") } }) {
            warnings.append("Some items may need your administrator password. Anything removed as administrator is deleted immediately, not moved to the Trash.")
        }
        let commands = items.filter { $0.steps.contains { if case .run = $0 { return true } else { return false } } }.count
        if commands > 0 {
            warnings.append("\(commands) item\(commands == 1 ? " is" : "s are") removed by running a command (Homebrew, npm, Docker, Xcode…). These can't be restored from the Trash.")
        }
        if !useTrash {
            warnings.append("Files will be deleted immediately and can't be recovered.")
        }
        return warnings
    }

    private func covered(_ path: String, by set: Set<String>) -> Bool {
        var current = path
        while true {
            if set.contains(current) { return true }
            guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else { return false }
            current = String(current[..<slash])
        }
    }

    func performRemoval(useTrash: Bool) {
        let items = selectedItems
        guard !items.isEmpty else { return }
        lastRemovalUsedTrash = useTrash
        progressMessage = "Starting…"
        sheet = .progress
        let remover = Remover(home: NSHomeDirectory()) { message in
            Task { @MainActor in self.progressMessage = message }
        }
        Task {
            let outcome = await remover.remove(items, options: RemovalOptions(useTrash: useTrash))
            self.finishRemoval(outcome, items)
        }
    }

    private func finishRemoval(_ outcome: RemovalOutcome, _ items: [Item]) {
        self.outcome = outcome
        outcomeItems = items
        let removed = Set(outcome.removed)
        for (id, var state) in states {
            let before = state.items.count
            // Drop removed items, plus items in other categories whose files are now gone too.
            state.items.removeAll { item in
                removed.contains(item.id) || (!item.paths.isEmpty && item.paths.allSatisfy { !FS.exists($0) })
            }
            if state.items.count != before {
                state.total = SizeMath.uniqueTotal(state.items.filter { !ignored.contains($0.id) })
                states[id] = state
            }
        }
        itemIndex = Dictionary(states.values.flatMap { $0.items }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        checked = checked.filter { itemIndex[$0] != nil }
        recomputeGrandTotal()
        refreshEnvironment()
        sheet = .results
    }

    func emptyTrash() {
        Task.detached {
            _ = Shell.execute("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], environment: nil, timeout: 600)
        }
    }

    // MARK: Environment

    func refreshEnvironment() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        hasFullDiskAccess = AppModel.checkFullDiskAccess()
    }

    /// macOS gives no API for this, so try to read a folder that's only readable with Full Disk Access.
    static func checkFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        for probe in [home + "/Library/Safari", home + "/Library/Containers/com.apple.stocks", home + "/Library/Mail"]
        where FileManager.default.fileExists(atPath: probe) {
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }
        return true
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
