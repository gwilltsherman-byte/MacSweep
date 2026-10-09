import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FileHit: Sendable, Hashable {
    public var path: String
    public var size: Int64
    public var modified: Date
}

public struct ArtifactKind: Sendable, Hashable {
    public var label: String
    public var risk: Risk
    public var note: String
    /// Many tiny folders (like __pycache__) are shown as one item.
    public var aggregate: Bool = false
}

public struct ArtifactHit: Sendable, Hashable {
    public var path: String
    public var kind: ArtifactKind
}

public struct HomeWalkResult: Sendable {
    public var dsStores: [String] = []
    public var appleDoubles: [String] = []
    public var windowsJunk: [String] = []
    public var brokenLinks: [String] = []
    public var largeFiles: [FileHit] = []
    public var installers: [FileHit] = []
    public var artifacts: [ArtifactHit] = []
    public var sizeBuckets: [Int64: [String]] = [:]
    public var filesSeen = 0
}

/// One pass over the home folder (minus ~/Library) that feeds several categories:
/// project build folders, large files, installers, duplicates and Finder clutter.
public struct HomeWalker {
    let settings: ScanSettings
    let cancel: CancelToken

    public init(settings: ScanSettings, cancel: CancelToken) {
        self.settings = settings
        self.cancel = cancel
    }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "ipsw", "cdr"]

    /// Bundles and libraries that are opaque documents, not folders to look inside.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "theater", "fcpbundle", "logicx", "band", "xcarchive", "framework", "bundle", "plugin",
        "kext", "appex", "xpc", "sparsebundle", "sparseimage", "pages", "numbers", "key", "rtfd", "playground",
        "xcodeproj", "xcworkspace", "utm", "pvm", "vmwarevm", "vbox", "docarchive", "mlmodelc", "lrlibrary",
        "lrdata", "cocatalog", "dtbase2", "garageband", "scriv", "sketch", "bear", "noindex",
        "abbu", "abcddb", "mbox", "imovieproject", "dvdproj", "swiftpm", "photoboothlibrary", "fcpxbundle",
    ]

    func homeSkips() -> Set<String> {
        let home = settings.home
        return [
            home + "/Library", home + "/.Trash", home + "/Applications",
            home + "/VirtualBox VMs", home + "/Parallels", home + "/Virtual Machines.localized",
            home + "/Documents/Virtual Machines.localized", home + "/Documents/Parallels",
        ]
    }

    public func walk() -> HomeWalkResult {
        var result = HomeWalkResult()
        var seenInodes = Set<String>()
        let skips = homeSkips()
        var roots = [settings.home]
        roots += settings.extraRoots.filter { root in !roots.contains { root.hasPrefix($0 + "/") || root == $0 } }

        for root in roots {
            guard let rootInfo = FS.info(root), rootInfo.isDirectory else { continue }
            var stack = [root]
            while let dir = stack.popLast() {
                if cancel.isCancelled { return result }
                // FS.list returns autoreleased arrays on macOS; drain them per folder, not once at the end.
                autoreleasepool {
                    visit(dir, device: rootInfo.device, skips: skips, stack: &stack, result: &result, seenInodes: &seenInodes)
                }
            }
        }
        result.sizeBuckets = result.sizeBuckets.filter { $0.value.count > 1 }
        return result
    }

    private func visit(_ dir: String, device: UInt64, skips: Set<String>, stack: inout [String],
                       result: inout HomeWalkResult, seenInodes: inout Set<String>) {
        for name in FS.list(dir) {
            let path = dir + "/" + name
            guard let info = FS.info(path) else { continue }

            if info.isSymlink {
                if FS.targetInfo(path) == nil { result.brokenLinks.append(path) }
                continue
            }

            if info.isDirectory {
                if info.device != device || skips.contains(path) { continue }
                if let kind = ArtifactRules.match(name: name, parent: dir) {
                    result.artifacts.append(ArtifactHit(path: path, kind: kind))
                    continue
                }
                // Never look inside node_modules: everything in there belongs to its packages, e.g. npm's own
                // files inside a Node.js installation (whose lib/node_modules isn't offered for removal).
                if name == "node_modules" { continue }
                if name.hasPrefix(".") { continue }
                if HomeWalker.packageExtensions.contains(FS.ext(name)) { continue }
                stack.append(path)
                continue
            }

            guard info.isRegular else { continue }
            result.filesSeen += 1
            if name == ".DS_Store" { result.dsStores.append(path); continue }
            if name.hasPrefix("._") { result.appleDoubles.append(path); continue }
            if name == "Thumbs.db" || name == "desktop.ini" || name == "ehthumbs.db" {
                result.windowsJunk.append(path)
                continue
            }
            if info.isDataless { continue }

            let ext = FS.ext(name)
            if HomeWalker.installerExtensions.contains(ext) {
                result.installers.append(FileHit(path: path, size: info.allocated, modified: info.modified))
            } else if info.allocated >= settings.largeFileThreshold {
                result.largeFiles.append(FileHit(path: path, size: info.allocated, modified: info.modified))
            }
            if info.size >= settings.duplicateMinSize {
                if info.linkCount > 1 && !seenInodes.insert("\(info.device):\(info.inode)").inserted { continue }
                result.sizeBuckets[info.size, default: []].append(path)
            }
        }
    }
}

/// Recognises regenerable folders inside software projects.
public enum ArtifactRules {
    static func build(_ label: String, _ note: String) -> ArtifactKind {
        ArtifactKind(label: label, risk: .safe, note: note)
    }

    static func deps(_ label: String, _ note: String) -> ArtifactKind {
        ArtifactKind(label: label, risk: .review, note: note)
    }

    public static func match(name: String, parent: String) -> ArtifactKind? {
        func has(_ file: String) -> Bool { FS.exists(parent + "/" + file) }
        func hasAny(_ files: [String]) -> Bool { files.contains(where: has) }
        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

        switch name {
        case "node_modules":
            // <prefix>/lib/node_modules next to <prefix>/bin/node is a Node.js install's global packages (npm itself).
            if FS.name(parent) == "lib" && FS.exists(FS.parent(parent) + "/bin/node") { return nil }
            return deps("node_modules", "Installed JavaScript packages. Run npm/yarn/pnpm install to get them back (old projects may not reinstall cleanly).")
        case ".next":
            return has("package.json") ? build("Next.js build cache", "Recreated by the next build or dev run.") : nil
        case ".nuxt", ".svelte-kit", ".docusaurus", ".parcel-cache", ".turbo", ".vite", ".astro", ".angular":
            return hasAny(["package.json", "angular.json"]) ? build("\(name) build cache", "Recreated by the next build.") : nil
        case "target":
            if has("Cargo.toml") { return build("Rust build output", "Recreated by cargo build. These folders often grow to many gigabytes.") }
            if has("pom.xml") || has("build.sbt") { return build("JVM build output", "Recreated by the next Maven/sbt build.") }
            return nil
        case ".build":
            return has("Package.swift") ? build("Swift build output", "Recreated by swift build.") : nil
        case "build":
            if hasAny(gradle) { return build("Gradle build output", "Recreated by the next Gradle build.") }
            if has("CMakeLists.txt") || has("meson.build") { return build("CMake/Meson build folder", "Recreated by the next build.") }
            if has("pubspec.yaml") { return build("Flutter build output", "Recreated by flutter build.") }
            return nil
        case ".gradle":
            return hasAny(gradle) ? build("Gradle project cache", "Recreated by the next Gradle build.") : nil
        case ".cxx", ".externalNativeBuild":
            return hasAny(gradle) ? build("Android native build cache", "Recreated by the next Gradle build.") : nil
        case "Pods":
            return has("Podfile") ? deps("CocoaPods packages", "Run pod install to get them back.") : nil
        case "DerivedData":
            return build("Xcode DerivedData", "Recreated the next time you build in Xcode.")
        case "__pycache__":
            return ArtifactKind(label: "Python bytecode caches", risk: .safe, note: "Python recreates these automatically.", aggregate: true)
        case ".venv", "venv", ".virtualenv", "env":
            return has(name + "/pyvenv.cfg") ? deps("Python virtual environment", "Recreate it with python -m venv and reinstall the project's packages.") : nil
        case ".tox", ".nox":
            return build("\(name) test environments", "Recreated the next time the tests run.")
        case ".mypy_cache", ".pytest_cache", ".ruff_cache", ".hypothesis", ".ipynb_checkpoints":
            return build("\(name)", "Tool cache, recreated automatically.")
        case ".dart_tool":
            return has("pubspec.yaml") ? build("Dart tool cache", "Recreated by dart/flutter pub get.") : nil
        case ".stack-work", "dist-newstyle":
            return build("Haskell build output", "Recreated by the next build.")
        case "_build":
            return has("mix.exs") || has("rebar.config") ? build("Elixir/Erlang build output", "Recreated by mix compile.") : nil
        case "deps":
            return has("mix.exs") ? deps("Elixir dependencies", "Run mix deps.get to get them back.") : nil
        case "zig-cache", ".zig-cache", "zig-out":
            return build("Zig build output", "Recreated by zig build.")
        case ".terraform":
            return build("Terraform providers & modules", "Run terraform init to download them again.")
        case "vendor":
            return has("composer.json") ? deps("PHP Composer packages", "Run composer install to get them back.") : nil
        case "elm-stuff":
            return build("Elm build cache", "Recreated by the next build.")
        case "cmake-build-debug", "cmake-build-release", "cmake-build-relwithdebinfo":
            return build("CLion build folder", "Recreated by the next build.")
        case "bower_components":
            return deps("Bower packages", "Run bower install to get them back.")
        case ".serverless", ".aws-sam":
            return build("\(name) build output", "Recreated by the next deploy.")
        default:
            if name.hasSuffix(" Previews.lrdata") {
                return name.hasSuffix(" Smart Previews.lrdata")
                    ? deps("Lightroom Smart Previews", "Lightroom can rebuild these only while the original photos are available.")
                    : build("Lightroom previews", "Lightroom rebuilds previews when it needs them.")
            }
            return nil
        }
    }
}

public struct DuplicateGroup: Sendable {
    public var size: Int64
    public var paths: [String]
}

public enum DuplicateFinder {
    /// Groups files with byte-for-byte identical content (same size, same SHA-256).
    public static func find(buckets: [Int64: [String]], cancel: CancelToken) -> [DuplicateGroup] {
        let candidates = buckets.filter { $0.value.count > 1 }.map { (size: $0.key, paths: $0.value) }
        let found = Locked([DuplicateGroup]())
        let headBytes = 64 * 1024
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            autoreleasepool { findGroups(in: candidates[index], headBytes: headBytes, cancel: cancel, into: found) }
        }
        return found.current.sorted { wasted($0) > wasted($1) }
    }

    /// Bytes taken by the extra copies, saturating instead of trapping on absurd sizes.
    static func wasted(_ group: DuplicateGroup) -> Int64 {
        let (bytes, overflow) = group.size.multipliedReportingOverflow(by: Int64(group.paths.count - 1))
        return overflow ? Int64.max : bytes
    }

    private static func findGroups(in candidate: (size: Int64, paths: [String]), headBytes: Int, cancel: CancelToken,
                                   into found: Locked<[DuplicateGroup]>) {
        if cancel.isCancelled { return }
        var byHead: [String: [String]] = [:]
        for path in candidate.paths {
            if let hash = ContentHash.hash(path, limit: headBytes) { byHead[hash, default: []].append(path) }
        }
        for group in byHead.values where group.count > 1 {
            if candidate.size <= Int64(headBytes) {
                found.withLock { $0.append(DuplicateGroup(size: candidate.size, paths: group.sorted())) }
                continue
            }
            var byFull: [String: [String]] = [:]
            for path in group {
                if cancel.isCancelled { return }
                if let hash = ContentHash.hash(path, limit: nil) { byFull[hash, default: []].append(path) }
            }
            for same in byFull.values where same.count > 1 {
                found.withLock { $0.append(DuplicateGroup(size: candidate.size, paths: same.sorted())) }
            }
        }
    }
}

public enum ContentHash {
    /// Hex digest of the first `limit` bytes (or the whole file), or nil if it can't be read completely.
    ///
    /// Reads with read(2) into one reused buffer: FileHandle returns autoreleased Data on macOS, and on
    /// GCD worker threads nothing drains those until the whole duplicate search ends, so hashing tens of
    /// gigabytes of duplicates would keep all of it in memory.
    public static func hash(_ path: String, limit: Int?) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let chunkSize = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var remaining = limit ?? Int.max
        #if canImport(CryptoKit)
        var hasher = SHA256()
        #else
        var hasher = FNV128()
        #endif
        while remaining > 0 {
            let count = read(fd, buffer.baseAddress, min(chunkSize, remaining))
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            remaining -= count
        }
        return hex(hasher.finalize())
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

#if !canImport(CryptoKit)
/// Fallback used only where CryptoKit isn't available (Linux test runs).
struct FNV128 {
    private var a: UInt64 = 0xcbf29ce484222325
    private var b: UInt64 = 0x84222325cbf29ce4

    mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        for byte in bufferPointer {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b ^ UInt64(byte ^ 0x5a)) &* 0x100000001b3
        }
    }

    func finalize() -> [UInt8] {
        withUnsafeBytes(of: a.bigEndian, Array.init) + withUnsafeBytes(of: b.bigEndian, Array.init)
    }
}
#endif
