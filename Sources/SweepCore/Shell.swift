import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var ok: Bool { status == 0 && !timedOut }

    /// The most useful line(s) to show when the command failed.
    public var errorSummary: String {
        if timedOut { return "Timed out" }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = err.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let tail = lines.suffix(4).joined(separator: " ")
        return tail.isEmpty ? "Exited with status \(status)" : String(tail.prefix(600))
    }

    public var lines: [String] {
        stdout.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// Runs command-line tools the way the user's Terminal would find them.
///
/// Apps launched from Finder get a bare-bones PATH, so the first time a tool is
/// needed MacSweep asks the user's login shell for its PATH and adds the usual
/// install locations (Homebrew, MacPorts, Cargo, Go, …).
public final class Shell: @unchecked Sendable {
    public static let shared = Shell()

    private struct State {
        var path: String?
        var which: [String: String?] = [:]
    }

    private let state = Locked(State())
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    static let quietEnvironment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_COLOR": "1",
        "HOMEBREW_NO_EMOJI": "1",
        "NONINTERACTIVE": "1",
        "NO_COLOR": "1",
        "TERM": "dumb",
        "PAGER": "cat",
        "DOCKER_CLI_HINTS": "false",
        "npm_config_fund": "false",
        "npm_config_update_notifier": "false",
    ]

    public var searchPath: String {
        if let cached = state.withLock({ $0.path }) { return cached }
        let resolved = resolveSearchPath()
        state.withLock { $0.path = resolved }
        return resolved
    }

    public func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        for (key, value) in Shell.quietEnvironment { env[key] = value }
        if env["HOME"] == nil { env["HOME"] = home }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// Absolute path of a tool, or nil if it isn't installed.
    public func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        if let cached = state.withLock({ $0.which[tool] }) { return cached }
        let found = searchPath.split(separator: ":")
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) && !FS.isDir($0) }
        state.withLock { $0.which.updateValue(found, forKey: tool) }
        return found
    }

    public func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) async -> ShellResult {
        guard let executable = which(tool) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(tool): command not found")
        }
        let env = environment()
        return await Background.run {
            Shell.execute(executable, arguments, environment: env, timeout: timeout)
        }
    }

    public func runSync(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) -> ShellResult {
        guard let executable = which(tool) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(tool): command not found")
        }
        return Shell.execute(executable, arguments, environment: environment(), timeout: timeout)
    }

    /// Starts a process, collects its output and kills it if it runs past the timeout.
    public static func execute(_ executable: String, _ arguments: [String], environment: [String: String]?,
                               timeout: TimeInterval) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = Locked(Data())
        let errData = Locked(Data())
        let readers = DispatchGroup()
        for (pipe, sink) in [(outPipe, outData), (errPipe, errData)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                sink.withLock { $0 = data }
                readers.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // A child that leaves a grandchild holding the pipe open must not hang us.
        _ = readers.wait(timeout: .now() + 5)

        let status: Int32 = process.isRunning ? -9 : process.terminationStatus
        return ShellResult(
            status: status,
            stdout: String(decoding: outData.current, as: UTF8.self),
            stderr: String(decoding: errData.current, as: UTF8.self),
            timedOut: timedOut
        )
    }

    /// Quotes a word for display or for a /bin/sh script.
    public static func quote(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_./=:@%+,".unicodeScalars.contains(scalar))
        }
        if plain { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func resolveSearchPath() -> String {
        var dirs: [String] = []
        if let shell = Shell.loginShell() {
            let result = Shell.execute(shell, ["-l", "-i", "-c", "echo __MACSWEEP_PATH__; /usr/bin/printenv PATH"],
                                       environment: ProcessInfo.processInfo.environment, timeout: 8)
            if let marker = result.stdout.range(of: "__MACSWEEP_PATH__") {
                let rest = result.stdout[marker.upperBound...]
                if let line = rest.split(whereSeparator: \.isNewline).first {
                    dirs += line.split(separator: ":").map(String.init)
                }
            }
        }
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            dirs += inherited.split(separator: ":").map(String.init)
        }
        dirs += [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
            "/opt/local/bin", "/opt/local/sbin",
            home + "/.cargo/bin", home + "/go/bin", home + "/.local/bin", home + "/.volta/bin",
            home + "/.bun/bin", home + "/.deno/bin", home + "/.orbstack/bin", home + "/.docker/bin",
            home + "/.rd/bin", home + "/.pyenv/shims", home + "/.rbenv/shims", home + "/.asdf/shims",
            home + "/.local/share/mise/shims", home + "/.nix-profile/bin",
            "/Applications/Docker.app/Contents/Resources/bin", "/usr/local/go/bin",
            "/nix/var/nix/profiles/default/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    static func loginShell() -> String? {
        if let entry = getpwuid(getuid()), let shellPointer = entry.pointee.pw_shell {
            let shell = String(cString: shellPointer)
            if FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        for fallback in ["/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return nil
    }
}
