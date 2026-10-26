import Foundation

/// Administrator execution accepts only the system operations used by our scanners.
/// Executables and their ancestors must be root-owned and not writable by other users.
enum PrivilegedCommands {
    static func validate(_ command: ShellCommand, home: String) throws {
        let args = command.fullArguments
        func token(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 200 && value.first != "-" &&
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.+@:/-]*$", options: .regularExpression) != nil
        }
        let allowed: Bool
        switch command.tool {
        case "/usr/bin/tmutil":
            allowed = args.count == 2 && args[0] == "deletelocalsnapshots" &&
                args[1].range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$", options: .regularExpression) != nil
        case "/usr/sbin/pkgutil":
            allowed = args.count == 2 && args[0] == "--forget" && token(args[1])
        case "/bin/launchctl":
            allowed = args.count == 3 && args[0] == "bootout" && args[1] == "system" &&
                args[2].hasPrefix("/Library/LaunchDaemons/") && args[2].hasSuffix(".plist") &&
                FS.parent(args[2]) == "/Library/LaunchDaemons" && Safety.refusal(for: args[2], home: home) == nil
        case "/opt/local/bin/port":
            allowed = args == ["-N", "reclaim"] || (args.count == 3 && args[0] == "uninstall" &&
                token(args[1]) && args[2].hasPrefix("@") && token(String(args[2].dropFirst())))
        default: allowed = false
        }
        guard allowed, !args.contains(where: { $0.utf8.contains(0) }) else {
            throw GuardedFiles.Failure.unsafe("Unsupported administrator command")
        }
        try checkTrustedExecutable(command.tool)
    }

    static func checkTrustedExecutable(_ path: String) throws {
        var current = path
        while true {
            guard let info = FS.info(current), !info.isSymlink, info.uid == 0,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: current),
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else {
                throw GuardedFiles.Failure.unsafe("Administrator tools must be root-owned and not writable by other users")
            }
            if current == "/" { break }
            current = FS.parent(current)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw GuardedFiles.Failure.unsafe("The administrator tool is not executable")
        }
    }
}
