import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RemovalOptions: Sendable {
    /// Move files to the Trash (recoverable) instead of deleting them straight away.
    public var useTrash: Bool

    public init(useTrash: Bool) { self.useTrash = useTrash }
}

public struct RemovalOutcome: Sendable {
    public var removed: [String] = []
    public var failures: [String: String] = [:]
    public var freedEstimate: Int64 = 0

    public init() {}
}

/// Carries out removals: commands first, then files as the user, then one batched
/// administrator script (a single password prompt) for everything that needs root.
public final class Remover: @unchecked Sendable {
    public typealias Progress = @Sendable (String) -> Void

    let home: String
    let shell: Shell
    let progress: Progress

    public init(home: String = NSHomeDirectory(), shell: Shell = .shared, progress: @escaping Progress = { _ in }) {
        self.home = home
        self.shell = shell
        self.progress = progress
    }

    private struct AdminOp {
        var itemIDs: [String]
        var allowFailure: Bool
        var lines: [String]
    }

    private final class Ledger {
        var errors: [String: [String]] = [:]
        func fail(_ ids: [String], _ message: String) {
            for id in ids { errors[id, default: []].append(message) }
        }
    }

    public func remove(_ items: [Item], options: RemovalOptions) async -> RemovalOutcome {
        await Background.run { self.removeSync(items, options: options) }
    }

    func removeSync(_ items: [Item], options: RemovalOptions) -> RemovalOutcome {
        let ledger = Ledger()
        var adminOps: [AdminOp] = []
        var queuedAdminPaths: [(ids: [String], path: String)] = []

        // 0. Refuse anything the safety rules don't allow.
        var runnable: [Item] = []
        for item in items {
            let refused = item.steps.flatMap(\.paths).compactMap { path in
                Safety.refusal(for: path, home: home).map { "\(path): \($0)" }
            }
            if refused.isEmpty { runnable.append(item) } else { ledger.fail([item.id], "Refused for safety. " + refused.joined(separator: "; ")) }
        }

        // 1. Commands that run as the user, merged where possible.
        var groups: [(command: ShellCommand, owners: [String: [String]])] = []
        var groupIndex: [String: Int] = [:]
        var singles: [(command: ShellCommand, ids: [String])] = []
        var singleIndex: [ShellCommand: Int] = [:]
        for item in runnable {
            for step in item.steps {
                guard case .run(let command) = step else { continue }
                if command.batchable && !command.targets.isEmpty {
                    let key = command.batchKey
                    if groupIndex[key] == nil {
                        groupIndex[key] = groups.count
                        var base = command
                        base.targets = []
                        groups.append((base, [:]))
                    }
                    for target in command.targets {
                        groups[groupIndex[key]!].owners[target, default: []].append(item.id)
                    }
                } else if let existing = singleIndex[command] {
                    singles[existing].ids.append(item.id)
                } else {
                    singleIndex[command] = singles.count
                    singles.append((command, [item.id]))
                }
            }
        }
        for group in groups {
            runBatch(group.command, owners: group.owners, ledger: ledger)
        }
        for single in singles {
            progress("Running \(single.command.display)…")
            let result = shell.runSync(single.command.tool, single.command.fullArguments, timeout: single.command.timeout)
            if !result.ok && !single.command.allowFailure {
                ledger.fail(single.ids, "\(single.command.display): \(result.errorSummary)")
            }
        }

        // Don't touch files of items whose uninstall command failed (e.g. Homebrew refused).
        let commandFailures = Set(ledger.errors.keys)
        runnable = runnable.filter { !commandFailures.contains($0.id) }

        // 2. Files, as the user.
        var fileJobs: [(path: String, forever: Bool, ids: [String])] = []
        var jobIndex: [String: Int] = [:]
        for item in runnable {
            for step in item.steps {
                let (paths, forever): ([String], Bool)
                switch step {
                case .files(let p): (paths, forever) = (p, false)
                case .deleteForever(let p): (paths, forever) = (p, true)
                default: continue
                }
                for path in paths {
                    if let index = jobIndex[path] {
                        fileJobs[index].ids.append(item.id)
                    } else {
                        jobIndex[path] = fileJobs.count
                        fileJobs.append((path, forever, [item.id]))
                    }
                }
            }
        }
        let verb = options.useTrash ? "Moving" : "Deleting"
        for (index, job) in fileJobs.enumerated() {
            if index % 25 == 0 { progress("\(verb) files… \(index + 1) of \(fileJobs.count)") }
            guard FS.exists(job.path) else { continue }
            do {
                if options.useTrash && !job.forever {
                    try trash(job.path)
                } else {
                    try deletePermanently(job.path)
                }
            } catch {
                if Remover.isPermissionError(error) || !FS.isWritable(FS.parent(job.path)) {
                    queuedAdminPaths.append((job.ids, job.path))
                } else {
                    ledger.fail(job.ids, "\(display(job.path)): \(error.localizedDescription)")
                }
            }
        }

        // 3. Everything that needs an administrator, in one script.
        for item in runnable {
            for step in item.steps {
                switch step {
                case .runAsAdmin(let command):
                    guard let tool = shell.which(command.tool) else {
                        ledger.fail([item.id], "\(command.tool) isn't installed")
                        continue
                    }
                    let line = ([tool] + command.fullArguments).map(Shell.quote).joined(separator: " ")
                    adminOps.append(AdminOp(itemIDs: [item.id], allowFailure: command.allowFailure, lines: [line]))
                case .adminScript(let script):
                    adminOps.append(AdminOp(itemIDs: [item.id], allowFailure: false, lines: [script.body]))
                default:
                    continue
                }
            }
        }
        for queued in queuedAdminPaths {
            adminOps.append(AdminOp(itemIDs: queued.ids, allowFailure: false, lines: ["/bin/rm -rf -- \(Shell.quote(queued.path))"]))
        }
        if !adminOps.isEmpty {
            progress("Waiting for administrator approval…")
            runAdmin(mergeAdminBatches(adminOps), ledger: ledger)
        }

        var outcome = RemovalOutcome()
        var removedItems: [Item] = []
        for item in items {
            if let errors = ledger.errors[item.id] {
                outcome.failures[item.id] = errors.joined(separator: "\n")
            } else {
                outcome.removed.append(item.id)
                removedItems.append(item)
            }
        }
        outcome.freedEstimate = SizeMath.uniqueTotal(removedItems)
        progress("Done")
        return outcome
    }

    // MARK: Commands

    private func runBatch(_ base: ShellCommand, owners: [String: [String]], ledger: Ledger) {
        let targets = Array(owners.keys).sorted()
        var all = base
        all.targets = targets
        progress("Running \(all.display)…")
        let result = shell.runSync(all.tool, all.fullArguments, timeout: base.timeout)
        if result.ok || base.allowFailure { return }
        if targets.count == 1 {
            ledger.fail(owners[targets[0]] ?? [], "\(all.display): \(result.errorSummary)")
            return
        }
        // Retry one at a time; repeat while progress is made (dependents may need to go first).
        var remaining = targets
        var lastErrors: [String: String] = [:]
        while !remaining.isEmpty {
            var stillFailing: [String] = []
            for target in remaining {
                var one = base
                one.targets = [target]
                progress("Running \(one.display)…")
                let single = shell.runSync(one.tool, one.fullArguments, timeout: base.timeout)
                if !single.ok {
                    stillFailing.append(target)
                    lastErrors[target] = "\(one.display): \(single.errorSummary)"
                }
            }
            if stillFailing.count == remaining.count { break }
            remaining = stillFailing
        }
        for target in remaining {
            ledger.fail(owners[target] ?? [], lastErrors[target] ?? "Failed")
        }
    }

    // MARK: Files

    private func trash(_ path: String) throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        #else
        try deletePermanently(path)
        #endif
    }

    private func deletePermanently(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            guard FS.exists(path) else { return }
            // Read-only trees (Go module cache, some installers) need write permission first.
            _ = Shell.execute("/bin/chmod", ["-R", "u+w", path], environment: nil, timeout: 300)
            #if os(macOS)
            _ = Shell.execute("/usr/bin/chflags", ["-R", "nouchg,noschg", path], environment: nil, timeout: 300)
            #endif
            try FileManager.default.removeItem(atPath: path)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    private func display(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    // MARK: Administrator script

    /// Drops exact repeats (two items that both need the same root command) so it runs once.
    private func mergeAdminBatches(_ ops: [AdminOp]) -> [AdminOp] {
        var merged: [AdminOp] = []
        var index: [[String]: Int] = [:]
        for op in ops {
            if let existing = index[op.lines] {
                merged[existing].itemIDs += op.itemIDs
            } else {
                index[op.lines] = merged.count
                merged.append(op)
            }
        }
        return merged
    }

    /// Builds the script that runs under `do shell script … with administrator privileges`.
    static func adminScript(for ops: [[String]]) -> String {
        var script = """
        #!/bin/sh
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH

        """
        for (number, lines) in ops.enumerated() {
            script += "op_\(number)() {\n"
            for line in lines { script += line + "\n" }
            script += "}\n"
            script += "if out=$(op_\(number) 2>&1); then echo \"MSOK \(number)\"; "
            script += "else echo \"MSFAIL \(number) $(printf '%s' \"$out\" | tr '\\n' ' ' | cut -c1-400)\"; fi\n"
        }
        script += "exit 0\n"
        return script
    }

    static func parseAdminOutput(_ output: String) -> [Int: String?] {
        var results: [Int: String?] = [:]
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let number = Int(parts[1]) else { continue }
            if parts[0] == "MSOK" {
                results[number] = .some(nil)
            } else if parts[0] == "MSFAIL" {
                let message = parts.count > 2 ? String(parts[2]) : "Failed"
                results[number] = .some(message)
            }
        }
        return results
    }

    private func runAdmin(_ ops: [AdminOp], ledger: Ledger) {
        #if os(macOS)
        let script = Remover.adminScript(for: ops.map(\.lines))
        let scriptPath = NSTemporaryDirectory() + "macsweep-admin-\(UUID().uuidString).sh"
        let created = FileManager.default.createFile(atPath: scriptPath, contents: Data(script.utf8),
                                                     attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        guard created else {
            for op in ops { ledger.fail(op.itemIDs, "Couldn't write the administrator script") }
            return
        }
        let appleScript = "do shell script \"/bin/sh \" & quoted form of \"\(scriptPath)\" with administrator privileges without altering line endings"
        let result = Shell.execute("/usr/bin/osascript", ["-e", appleScript], environment: nil, timeout: 3600)
        if !result.ok {
            let cancelled = result.stderr.contains("-128") || result.stderr.lowercased().contains("cancel")
            let message = cancelled ? "Administrator password prompt was cancelled" : "Administrator step failed: \(result.errorSummary)"
            for op in ops where !op.allowFailure { ledger.fail(op.itemIDs, message) }
            return
        }
        let parsed = Remover.parseAdminOutput(result.stdout)
        for (number, op) in ops.enumerated() where !op.allowFailure {
            switch parsed[number] {
            case .some(.none): continue
            case .some(.some(let message)): ledger.fail(op.itemIDs, message)
            case .none: ledger.fail(op.itemIDs, "No result from the administrator step")
            }
        }
        #else
        for op in ops where !op.allowFailure { ledger.fail(op.itemIDs, "Administrator actions are only available on macOS") }
        #endif
    }
}

/// Human-readable list of exactly what removing some items will do.
public enum RemovalPlan {
    public static func describe(_ items: [Item], useTrash: Bool, home: String) -> [String] {
        func show(_ path: String) -> String {
            path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
        }
        var lines: [String] = []
        var seen = Set<String>()
        func add(_ line: String) { if seen.insert(line).inserted { lines.append(line) } }
        for item in items {
            for step in item.steps {
                switch step {
                case .files(let paths):
                    let verb = useTrash ? "Move to Trash" : "Delete"
                    for path in paths.prefix(200) { add("\(verb): \(show(path))") }
                    if paths.count > 200 { add("\(verb): …and \(paths.count - 200) more from \(item.title)") }
                case .deleteForever(let paths):
                    for path in paths.prefix(200) { add("Delete permanently: \(show(path))") }
                    if paths.count > 200 { add("Delete permanently: …and \(paths.count - 200) more from \(item.title)") }
                case .run(let command):
                    add("Run: \(command.display)")
                case .runAsAdmin(let command):
                    add("Run as administrator: \(command.display)")
                case .adminScript(let script):
                    add("As administrator: \(script.summary)")
                }
            }
        }
        return lines
    }
}
