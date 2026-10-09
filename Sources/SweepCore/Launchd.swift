import Foundation

/// Launch agents and daemons: reading their plists, and stopping them before their files are removed.
///
/// launchd keeps a job loaded after its plist is deleted, so a background helper whose files are removed
/// keeps running and puts its folders straight back. Unloading it first stops that.
enum Launchd {
    struct Job: Sendable, Hashable {
        var plist: String
        var label: String
        var program: String?
        var disabled: Bool
        /// A launch daemon, which runs as root for the whole Mac rather than in the user's session.
        var isDaemon: Bool
    }

    static func folders(home: String) -> [String] {
        [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
    }

    static func isJobPlist(_ path: String) -> Bool {
        FS.ext(path) == "plist" && ["LaunchAgents", "LaunchDaemons"].contains(FS.name(FS.parent(path)))
    }

    static func read(_ path: String) -> Job? {
        guard let plist = FS.readPlist(path) else { return nil }
        let label = plist["Label"] as? String ?? FS.stripExt(FS.name(path))
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        return Job(plist: path, label: label, program: program, disabled: plist["Disabled"] as? Bool ?? false,
                   isDaemon: FS.name(FS.parent(path)) == "LaunchDaemons")
    }

    /// Every job except Apple's own, from your launch agents and the ones for all users.
    static func jobs(home: String) -> [Job] {
        folders(home: home).flatMap { dir in
            FS.list(dir).filter { FS.ext($0) == "plist" && !$0.hasPrefix("com.apple.") }.compactMap { read(dir + "/" + $0) }
        }
    }

    /// Jobs an app registers from inside its own bundle (SMAppService); launchd runs them from there.
    static func bundledJobs(in app: String) -> [Job] {
        ["LaunchAgents", "LaunchDaemons"].flatMap { kind -> [Job] in
            let dir = app + "/Contents/Library/" + kind
            return FS.list(dir).filter { FS.ext($0) == "plist" }.compactMap { name -> Job? in
                guard var job = read(dir + "/" + name) else { return nil }
                if job.program == nil, let relative = FS.readPlist(job.plist)?["BundleProgram"] as? String {
                    job.program = FS.join(app, relative)
                }
                return job
            }
        }
    }

    /// Unloads a job so it stops running. Agents run in your session; daemons need an administrator.
    /// It's fine if the job isn't loaded.
    static func stop(_ job: Job, uid: UInt32) -> RemovalStep {
        if job.isDaemon {
            return .runAsAdmin(ShellCommand("/bin/launchctl", ["bootout", "system/" + job.label], allowFailure: true))
        }
        return .run(ShellCommand("/bin/launchctl", ["bootout", "gui/\(uid)/" + job.label], allowFailure: true))
    }

    static func stopSteps(_ jobs: [Job], uid: UInt32) -> [RemovalStep] {
        var seen = Set<String>()
        return jobs.filter { seen.insert(($0.isDaemon ? "d|" : "a|") + $0.label).inserted }.map { stop($0, uid: uid) }
    }
}
