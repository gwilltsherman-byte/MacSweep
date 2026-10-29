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
    /// Removed items Finder moved to the Trash instead of deleting them, because macOS lets only Finder remove
    /// them (apps from other developers, for example). They're gone for good once the Trash is emptied.
    public var movedToTrash: Set<String> = []

    public init() {}
}

/// Who MacSweep asks when macOS won't let it remove something itself: an administrator, through one script
/// and so one password prompt, and Finder, which moves things to the Trash as you would by hand. Tests
/// replace both.
public struct RemovalHelpers: Sendable {
    /// Runs a shell script as root and returns what it printed.
    public var administrator: @Sendable (String) -> ShellResult
    /// Asks Finder to move these paths to the Trash; prints MSALL, MSCANCEL or one MSOK/MSFAIL line per path.
    public var finder: @Sendable ([String]) -> ShellResult

    public init(administrator: @escaping @Sendable (String) -> ShellResult,
                finder: @escaping @Sendable ([String]) -> ShellResult) {
        self.administrator = administrator
        self.finder = finder
    }

    public static let system = RemovalHelpers(administrator: Remover.runAsAdministrator, finder: Remover.askFinder)
}

/// Carries out removals: commands first, then files as the user. Whatever macOS doesn't let the user remove
/// goes to Finder (moves to the Trash) or into one batched administrator script with a single password prompt
/// (permanent deletions and system tools).
public final class Remover: @unchecked Sendable {
    public typealias Progress = @Sendable (String) -> Void

    let home: String
    let shell: Shell
    let helpers: RemovalHelpers
    let progress: Progress

    public init(home: String = NSHomeDirectory(), shell: Shell = .shared, helpers: RemovalHelpers = .system,
                progress: @escaping Progress = { _ in }) {
        self.home = home
        self.shell = shell
        self.helpers = helpers
        self.progress = progress
    }

    private struct FileJob {
        var path: String
        var forever: Bool
        var ids: [String]
        var expected: PathIdentity?
    }

    private struct AdminOp {
        var itemIDs: [String]
        var allowFailure: Bool
        var lines: [String]
        /// Earlier operations that must have succeeded before this one runs.
        var after: [Int] = []
        /// The file jobs this operation deletes, if it deletes any.
        var jobs: [Int] = []
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

        // 0. Refuse anything the safety rules don't allow.
        var runnable: [Item] = []
        for item in items {
            let refused = item.steps.flatMap(\.paths).compactMap { path in
                Safety.refusal(for: path, home: home).map { "\(path): \($0)" }
            }
            if refused.isEmpty { runnable.append(item) } else { ledger.fail([item.id], "Refused for safety. " + refused.joined(separator: "; ")) }
        }

        // A duplicate goes only while the copy MacSweep keeps is still there, the same size, and staying.
        let leaving = Set(runnable.flatMap { $0.steps.flatMap(\.paths) })
        runnable = runnable.filter { item in
            guard let keep = item.keepPath else { return true }
            if SizeMath.isCovered(keep, by: leaving) {
                ledger.fail([item.id], "Left in place: the copy MacSweep keeps (\(display(keep))) is being removed too, and one copy always stays.")
                return false
            }
            guard let kept = FS.info(keep), let own = item.paths.first.flatMap({ FS.info($0) }),
                  kept.isRegular, kept.size == own.size else {
                ledger.fail([item.id], "Left in place: the copy MacSweep keeps (\(display(keep))) is gone or has changed. Scan again.")
                return false
            }
            return true
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
        var jobs: [FileJob] = []
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
                        if jobs[index].expected != item.pathIdentities[path] {
                            ledger.fail([item.id] + jobs[index].ids, "The item changed between scans. Scan again.")
                        }
                        jobs[index].ids.append(item.id)
                    } else {
                        jobIndex[path] = jobs.count
                        jobs.append(FileJob(path: path, forever: forever, ids: [item.id], expected: item.pathIdentities[path]))
                    }
                }
            }
        }
        let verb = options.useTrash ? "Moving" : "Deleting"
        // What macOS didn't let MacSweep remove itself: Finder moves these to the Trash, and an administrator
        // deletes what is meant to go for good.
        var forFinder: [Int] = []
        var forAdmin: [Int] = []
        for (index, job) in jobs.enumerated() {
            if index % 25 == 0 { progress("\(verb) files… \(index + 1) of \(jobs.count)") }
            if job.ids.contains(where: { ledger.errors[$0] != nil }) { continue }
            guard let expected = job.expected else {
                if FS.exists(job.path) { ledger.fail(job.ids, "A new item appeared after scanning. Scan again.") }
                continue
            }
            let toTrash = options.useTrash && !job.forever
            do {
                try GuardedFiles.remove(job.path, expected: expected, home: home, trash: toTrash)
            } catch {
                if Remover.isGone(error) && !FS.exists(job.path) { continue }
                if Remover.needsHelp(error) {
                    if toTrash { forFinder.append(index) } else { forAdmin.append(index) }
                    continue
                }
                ledger.fail(job.ids, "\(display(job.path)): \(error.localizedDescription)")
            }
        }

        // 3. Moves to the Trash that only Finder may make. Finder asks for an administrator password itself.
        for (index, message) in moveWithFinder(forFinder, jobs) { ledger.fail(jobs[index].ids, message) }

        // 4. Everything that needs an administrator, in one script and so one password prompt: deletions first,
        //    then system tools, each of which runs only once its own item's files are gone.
        var commands: [(id: String, command: ShellCommand)] = []
        for item in runnable where ledger.errors[item.id] == nil {
            for step in item.steps {
                guard case .runAsAdmin(let command) = step else { continue }
                do {
                    try PrivilegedCommands.validate(command, home: home)
                    commands.append((item.id, command))
                } catch {
                    // An extra that may fail anyway (stopping a background task, say) never holds up the removal.
                    if !command.allowFailure { ledger.fail([item.id], error.localizedDescription) }
                }
            }
        }
        var ops: [AdminOp] = []
        var deletions: [String: [Int]] = [:]
        if !forAdmin.isEmpty {
            do {
                for tool in ["/usr/bin/stat", "/usr/bin/find", "/usr/bin/chflags"] { try PrivilegedCommands.checkTrustedExecutable(tool) }
            } catch {
                for index in forAdmin { ledger.fail(jobs[index].ids, error.localizedDescription) }
                forAdmin = []
            }
        }
        var folders: [(parent: String, ids: [String], entries: [(name: String, inode: UInt64)], jobs: [Int])] = []
        var folderIndex: [String: Int] = [:]
        for index in forAdmin {
            let job = jobs[index]
            guard let expected = job.expected, !job.ids.contains(where: { ledger.errors[$0] != nil }) else { continue }
            do {
                let location = try GuardedFiles.locate(job.path, home: home)
                let key = ([location.parent] + job.ids).joined(separator: "\u{1F}")
                if folderIndex[key] == nil {
                    folderIndex[key] = folders.count
                    folders.append((location.parent, job.ids, [], []))
                }
                folders[folderIndex[key]!].entries.append((location.name, expected.inode))
                folders[folderIndex[key]!].jobs.append(index)
            } catch {
                ledger.fail(job.ids, "\(display(job.path)): \(error.localizedDescription)")
            }
        }
        for folder in folders where !folder.ids.contains(where: { ledger.errors[$0] != nil }) {
            for id in folder.ids { deletions[id, default: []].append(ops.count) }
            ops.append(AdminOp(itemIDs: folder.ids, allowFailure: false,
                               lines: Remover.adminDeletion(in: folder.parent, folder.entries), jobs: folder.jobs))
        }
        for (id, command) in commands where ledger.errors[id] == nil {
            let line = ([command.tool] + command.fullArguments).map(Shell.quote).joined(separator: " ")
            ops.append(AdminOp(itemIDs: [id], allowFailure: command.allowFailure, lines: [line], after: deletions[id] ?? []))
        }
        ops = mergeAdminBatches(ops)
        let adminFailures = ops.isEmpty ? [:] : runAdmin(ops)

        // 5. Deletions macOS forbids even an administrator, such as apps from other developers: Finder may still
        //    move those to the Trash.
        var lastResort: [Int] = []
        for (number, op) in ops.enumerated() where !op.jobs.isEmpty {
            guard let message = adminFailures[number] else { continue }
            if message.contains("Operation not permitted") { lastResort += op.jobs } else { ledger.fail(op.itemIDs, message) }
        }
        var movedByFinder = Set<String>()
        let lastResortFailures = moveWithFinder(lastResort, jobs)
        for index in lastResort {
            if let message = lastResortFailures[index] { ledger.fail(jobs[index].ids, message) } else { movedByFinder.formUnion(jobs[index].ids) }
        }
        for (number, op) in ops.enumerated() where op.jobs.isEmpty && !op.allowFailure {
            guard let message = adminFailures[number] else { continue }
            // It waited for files Finder then moved to the Trash: the item is out of the way all the same.
            if message == Remover.waitedMessage && op.itemIDs.allSatisfy(movedByFinder.contains) { continue }
            ledger.fail(op.itemIDs, message)
        }

        var outcome = RemovalOutcome()
        var removedItems: [Item] = []
        for item in items {
            if let errors = ledger.errors[item.id] {
                outcome.failures[item.id] = errors.joined(separator: "\n")
            } else {
                outcome.removed.append(item.id)
                removedItems.append(item)
                if movedByFinder.contains(item.id) { outcome.movedToTrash.insert(item.id) }
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

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    /// The item (or the folder it was in) no longer exists.
    static func isGone(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOENT) || ns.code == Int(ENOTDIR))
    }

    /// macOS didn't let MacSweep do it, but Finder or an administrator may: the item belongs to the system or
    /// another user, is protected, or is on a drive without a Trash MacSweep can use.
    static func needsHelp(_ error: Error) -> Bool {
        if let failure = error as? GuardedFiles.Failure, case .noTrash = failure { return true }
        if isPermissionError(error) { return true }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EXDEV) || ns.code == Int(ENOTSUP))
    }

    private func display(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    // MARK: Finder

    /// Asks Finder to move items to the Trash, as you would by hand: Finder asks for an administrator password
    /// itself when an item belongs to the system. Each item is checked first to still be the one scanned.
    /// Returns why each item that stayed couldn't be moved.
    private func moveWithFinder(_ indices: [Int], _ jobs: [FileJob]) -> [Int: String] {
        var failures: [Int: String] = [:]
        var sent: [Int] = []
        for index in indices {
            guard let info = FS.info(jobs[index].path) else { continue } // already gone
            if PathIdentity(info) == jobs[index].expected {
                sent.append(index)
            } else {
                failures[index] = "\(display(jobs[index].path)): It changed since scanning. Scan again."
            }
        }
        guard !sent.isEmpty else { return failures }
        progress(sent.count == 1 ? "Asking Finder to move an item to the Trash…" : "Asking Finder to move \(sent.count) items to the Trash…")
        let result = helpers.finder(sent.map { jobs[$0].path })
        let answer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Remover.parseAdminOutput(result.stdout)
        for (number, index) in sent.enumerated() {
            let job = jobs[index]
            // Gone from where it was, or something else there now: Finder moved it.
            guard let info = FS.info(job.path), PathIdentity(info) == job.expected else { continue }
            let reason: String
            if answer == "MSCANCEL" {
                reason = "You cancelled Finder's request for your password."
            } else if case .some(.some(let text)) = parsed[number] {
                reason = Remover.finderFailure(text)
            } else if !result.ok {
                reason = "Finder couldn't be asked: \(result.errorSummary)"
            } else {
                reason = "Finder didn't move it to the Trash."
            }
            failures[index] = "\(display(job.path)): \(reason)"
        }
        return failures
    }

    /// Plain words for an error Finder reported as "<number> <message>".
    static func finderFailure(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1)
        let message = parts.count > 1 ? String(parts[1]) : text
        switch parts.first.flatMap({ Int($0) }) {
        case -1743:
            return "MacSweep isn't allowed to use Finder. Allow it in System Settings › Privacy & Security › Automation, then try again."
        case -128:
            return "You cancelled Finder's request for your password."
        default:
            return "Finder couldn't move it to the Trash: \(message)"
        }
    }

    /// Takes the paths as arguments, so none of them is ever pasted into the script. Asks for everything at once
    /// (one password prompt at most), then item by item if that fails, to find out which can't be moved.
    static let finderScript = """
    on run argv
    	set theFiles to {}
    	repeat with thePath in argv
    		set end of theFiles to POSIX file (contents of thePath)
    	end repeat
    	try
    		tell application "Finder" to delete theFiles
    		return "MSALL"
    	on error number errNum
    		if errNum is -128 then return "MSCANCEL"
    	end try
    	set theReport to ""
    	repeat with i from 1 to count of theFiles
    		set theFile to item i of theFiles
    		try
    			tell application "Finder" to delete theFile
    			set theReport to theReport & "MSOK " & (i - 1) & linefeed
    		on error errText number errNum
    			set theReport to theReport & "MSFAIL " & (i - 1) & " " & errNum & " " & errText & linefeed
    		end try
    	end repeat
    	return theReport
    end run
    """

    public static func askFinder(_ paths: [String]) -> ShellResult {
        #if os(macOS)
        return Shell.execute("/usr/bin/osascript", ["-e", finderScript] + paths,
                             environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 3600)
        #else
        return ShellResult(status: 1, stdout: "", stderr: "Finder is only available on macOS")
        #endif
    }

    // MARK: Administrator script

    /// Drops exact repeats (two items that both need the same root command) so it runs once.
    private func mergeAdminBatches(_ ops: [AdminOp]) -> [AdminOp] {
        var merged: [AdminOp] = []
        var index: [[String]: Int] = [:]
        for op in ops {
            if let existing = index[op.lines] {
                merged[existing].itemIDs += op.itemIDs
                merged[existing].after = Array(Set(merged[existing].after + op.after)).sorted()
            } else {
                index[op.lines] = merged.count
                merged.append(op)
            }
        }
        return merged
    }

    /// Why a system tool didn't run: it waits for its item's files, and they couldn't be deleted.
    static let waitedMessage = "Its files are still there, so this step was skipped."

    /// Deletes one item as root if it is still the one MacSweep scanned (same inode, same volume as its folder),
    /// first clearing Locked flags inside it. Nothing follows symlinks or crosses into another volume, and an
    /// item that is already gone counts as deleted. Files with other hard links keep their flags, since those
    /// links live on elsewhere.
    static let deletionHelper = """
    gone() {
    	if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 0; fi
    	if [ "$(/usr/bin/stat -f '%d %i' -- "$1")" != "$(/usr/bin/stat -f %d -- .) $2" ]; then
    		echo "$1 changed since MacSweep scanned it. Scan again."
    		return 1
    	fi
    	/usr/bin/find "$1" -xdev \\( -type d -o -links 1 \\) -exec /usr/bin/chflags -h nouchg,noschg {} + 2>/dev/null
    	/usr/bin/find "$1" -xdev -delete
    }
    """

    /// Shell lines that delete items in one folder as root. The folder becomes the working directory first and
    /// must really be where MacSweep expects, so every later step names items relative to it: a symlink swapped in
    /// above the folder can't redirect anything.
    static func adminDeletion(in parent: String, _ entries: [(name: String, inode: UInt64)]) -> [String] {
        let folder = Shell.quote(parent)
        var lines = [
            "cd -P -- \(folder) || exit 1",
            "[ \"$(pwd -P)\" = \(folder) ] || { echo 'The folder it was in has moved. Scan again.'; exit 1; }",
            "failed=",
        ]
        for entry in entries { lines.append("gone \(Shell.quote("./" + entry.name)) \(entry.inode) || failed=1") }
        lines.append("[ -z \"$failed\" ]")
        return lines
    }

    /// Builds the script that runs under `do shell script … with administrator privileges`. An operation that
    /// waits for earlier ones (`after`) runs only if all of them succeeded.
    static func adminScript(for ops: [[String]], after: [[Int]] = []) -> String {
        var script = """
        #!/bin/sh
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        \(deletionHelper)

        """
        for (number, lines) in ops.enumerated() {
            script += "op_\(number)() {\n"
            let waits = number < after.count ? after[number] : []
            if !waits.isEmpty {
                let checks = waits.map { "[ \"${ok_\($0):-}\" = 1 ]" }.joined(separator: " && ")
                script += "\(checks) || { echo \(Shell.quote(waitedMessage)); exit 1; }\n"
            }
            for line in lines { script += line + "\n" }
            script += "}\n"
            script += "if out=$(op_\(number) 2>&1); then ok_\(number)=1; echo \"MSOK \(number)\"; "
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

    /// Runs the script and returns why each operation that failed did.
    private func runAdmin(_ ops: [AdminOp]) -> [Int: String] {
        var failures: [Int: String] = [:]
        let script = Remover.adminScript(for: ops.map(\.lines), after: ops.map(\.after))
        guard script.utf8.count < 400_000 else {
            for number in ops.indices { failures[number] = "Too many administrator actions at once. Remove the rest in a second pass." }
            return failures
        }
        progress("Waiting for administrator approval…")
        let result = helpers.administrator(script)
        if !result.ok {
            let cancelled = result.stderr.contains("-128") || result.stderr.lowercased().contains("cancel")
            let message = cancelled ? "Administrator password prompt was cancelled" : "Administrator step failed: \(result.errorSummary)"
            for number in ops.indices { failures[number] = message }
            return failures
        }
        let parsed = Remover.parseAdminOutput(result.stdout)
        for number in ops.indices {
            switch parsed[number] {
            case .some(.none): continue
            case .some(.some(let message)): failures[number] = message
            case .none: failures[number] = "No result from the administrator step"
            }
        }
        return failures
    }

    /// Runs a script as root after one administrator password prompt. The script travels inside the command
    /// itself: a temporary file someone could change in the meantime is never elevated.
    public static func runAsAdministrator(_ script: String) -> ShellResult {
        #if os(macOS)
        let literal = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let appleScript = "do shell script \"\(literal)\" with administrator privileges without altering line endings"
        return Shell.execute("/usr/bin/osascript", ["-e", appleScript],
                             environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 3600)
        #else
        return ShellResult(status: 1, stdout: "", stderr: "Administrator actions are only available on macOS")
        #endif
    }
}

/// How an item's removal can (or can't) be undone, for plain-language summaries.
public enum RecoveryKind: Int, CaseIterable, Sendable, Hashable {
    case trash, uninstall, permanent, admin
}

/// Human-readable list of exactly what removing some items will do.
public enum RemovalPlan {
    public static func kinds(for item: Item, useTrash: Bool) -> Set<RecoveryKind> {
        var kinds = Set<RecoveryKind>()
        for step in item.steps {
            switch step {
            case .files: kinds.insert(useTrash ? .trash : .permanent)
            case .deleteForever: kinds.insert(.permanent)
            case .run(let command): if !command.allowFailure { kinds.insert(.uninstall) }
            case .runAsAdmin(let command): if !command.allowFailure { kinds.insert(.admin) }
            }
        }
        return kinds
    }

    /// One or two plain sentences answering "Can I undo this?".
    public static func recovery(for item: Item, useTrash: Bool, home: String) -> String {
        var sentences: [String] = []
        var toTrash = false
        var forever = false
        var outsideHome = false
        for step in item.steps {
            switch step {
            case .files(let paths):
                if useTrash { toTrash = true } else { forever = true }
                if paths.contains(where: { !$0.hasPrefix(home + "/") }) { outsideHome = true }
            case .deleteForever(let paths):
                forever = true
                if paths.contains(where: { !$0.hasPrefix(home + "/") }) { outsideHome = true }
            case .run(let command):
                if !command.allowFailure { sentences.append(commandRecovery(command)) }
            case .runAsAdmin(let command):
                if !command.allowFailure { sentences.append(commandRecovery(command) + " This needs an administrator password.") }
            }
        }
        if toTrash {
            var text = "It goes to the Trash, so you can put it back until you empty the Trash."
            if outsideHome {
                text += " If macOS doesn't let MacSweep move something itself, Finder moves it and may ask for your password."
            }
            sentences.insert(text, at: 0)
        } else if forever {
            var text = "It's deleted for good straight away and can't be undone."
            if outsideHome {
                text += " If it belongs to the system, macOS asks for your administrator password first."
            }
            sentences.insert(text, at: 0)
        }
        var seen = Set<String>()
        return sentences.filter { seen.insert($0).inserted }.joined(separator: " ")
    }

    static func commandRecovery(_ command: ShellCommand) -> String {
        let tool = FS.name(command.tool)
        let first = command.arguments.first ?? ""
        switch tool {
        case "brew":
            if first == "untap" { return "Homebrew removes this software list. You can add it back later with brew tap." }
            if first == "cleanup" { return "Homebrew deletes the old versions and downloads. They can't be restored." }
            return "Homebrew uninstalls it. You can install it again with Homebrew whenever you like."
        case "port":
            if first == "-N" { return "MacPorts deletes its leftover downloads. They can't be restored, but aren't needed." }
            return "MacPorts uninstalls it. You can install it again with MacPorts."
        case "npm": return "npm uninstalls it. You can install it again with npm."
        case "cargo": return "cargo uninstalls it. You can install it again with cargo."
        case "pipx": return "pipx uninstalls it. You can install it again with pipx."
        case "go": return "Go deletes its download cache and downloads what it needs again later."
        case "conda": return "Conda deletes its cached downloads. Your environments keep working."
        case "docker":
            switch first {
            case "image": return "Docker deletes the image. It can be downloaded again."
            case "volume": return "Docker deletes the volume and the data in it for good."
            case "builder": return "Docker deletes its build cache. Builds are slower the first time afterwards."
            default: return "Docker deletes the stopped container. Anything saved inside it is lost."
            }
        case "xcrun":
            if command.arguments.contains("runtime") {
                return "Xcode deletes the simulator system. You can download it again in Xcode's settings."
            }
            return "Xcode deletes the simulator and the apps in it. You can create a new one in Xcode."
        case "ollama": return "Ollama deletes the model. You can download it again with Ollama."
        case "osascript": return "It's removed from your login items. The app itself stays installed."
        case "open": return "Steam opens and asks you to confirm before it uninstalls the game."
        case "tmutil": return "Time Machine deletes this snapshot. It can't be restored."
        case "atsutil": return "macOS rebuilds the font caches by itself."
        case "nix-collect-garbage": return "Nix deletes packages nothing uses. They're downloaded again if needed."
        case "code", "code-insiders", "cursor", "codium", "windsurf", "positron", "kiro":
            return "The editor uninstalls the extension. You can install it again from the editor."
        default: return "It's removed by running \(tool) and can't be put back from the Trash."
        }
    }

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
                }
            }
        }
        return lines
    }
}
