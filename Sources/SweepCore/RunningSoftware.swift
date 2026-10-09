import Foundation

public struct RunningProcess: Hashable, Sendable {
    public var pid: Int32
    /// The program's full path.
    public var path: String
}

/// One row of `systemextensionsctl list`.
public struct SystemExtensionInfo: Hashable, Sendable {
    public var teamID: String
    public var bundleID: String
    public var name: String
    public var state: String
    public var isRunning: Bool

    /// macOS has already scheduled it to be removed at the next restart.
    public var removedOnRestart: Bool { state.contains("uninstall") }
}

/// What's running right now, used to spot software that would put files back as soon as they're removed.
public struct RunningSoftware: Sendable {
    public var processes: [RunningProcess]
    public var systemExtensions: [SystemExtensionInfo]

    public init(processes: [RunningProcess] = [], systemExtensions: [SystemExtensionInfo] = []) {
        self.processes = processes
        self.systemExtensions = systemExtensions
    }

    public static func snapshot(shell: Shell = .shared) -> RunningSoftware {
        let ps = shell.runSync("/bin/ps", ["-axww", "-o", "pid=,comm="], timeout: 20)
        var extensions: [SystemExtensionInfo] = []
        let control = "/usr/bin/systemextensionsctl"
        if FileManager.default.isExecutableFile(atPath: control) {
            extensions = parseSystemExtensions(shell.runSync(control, ["list"], timeout: 20).stdout)
        }
        return RunningSoftware(processes: ps.ok ? parseProcesses(ps.stdout) : [], systemExtensions: extensions)
    }

    /// Parses `ps -o pid=,comm=`. On macOS `comm` is the program's full path, which may contain spaces.
    public static func parseProcesses(_ text: String) -> [RunningProcess] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.drop { $0 == " " }
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { return nil }
            let path = String(line[line.index(after: space)...].drop { $0 == " " })
            return path.hasPrefix("/") ? RunningProcess(pid: pid, path: path) : nil
        }
    }

    /// Parses `systemextensionsctl list`, whose rows are tab-separated:
    /// enabled, active, team ID, "bundle ID (version)", name, [state].
    public static func parseSystemExtensions(_ text: String) -> [SystemExtensionInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 6, fields[0] != "enabled" else { return nil }
            let bundleID = fields[3].components(separatedBy: " (")[0]
            guard !bundleID.isEmpty, !bundleID.contains(" ") else { return nil }
            let state = fields[5...].joined(separator: " ")
            return SystemExtensionInfo(teamID: fields[2], bundleID: bundleID, name: fields[4].isEmpty ? bundleID : fields[4],
                                       state: state, isRunning: fields[1] == "*" || state.contains("activated enabled"))
        }
    }

    /// Programs running from inside any of these files or folders, except the ones listed.
    func programs(inside roots: [String], except skip: Set<String> = []) -> [Recreator] {
        var seen = Set<String>()
        return processes.filter { process in
            !skip.contains(process.path) && roots.contains { process.path == $0 || process.path.hasPrefix($0 + "/") }
                && seen.insert(process.path).inserted
        }.map { Recreator(.program, name: FS.name($0.path), identifier: $0.path) }
    }

    /// Running system extensions whose bundle identifier passes the test.
    func extensions(where belongs: (String) -> Bool) -> [Recreator] {
        var seen = Set<String>()
        return systemExtensions.filter { $0.isRunning && belongs($0.bundleID) && seen.insert($0.bundleID).inserted }.map {
            Recreator(.systemExtension, name: $0.name, identifier: $0.bundleID, removedOnRestart: $0.removedOnRestart)
        }
    }

    /// Whether something found during the scan is still running now.
    public func isActive(_ recreator: Recreator) -> Bool {
        switch recreator.kind {
        case .program: return processes.contains { $0.path == recreator.identifier }
        case .systemExtension: return systemExtensions.contains { $0.isRunning && $0.bundleID == recreator.identifier }
        }
    }
}
