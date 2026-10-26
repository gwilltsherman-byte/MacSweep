import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// File identities captured when a scanner offers an item. Descriptor-relative operations
/// never follow symlink parents, even when a directory is renamed during removal.
public struct PathIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(_ info: FileInfo) { device = info.device; inode = info.inode }
}

enum GuardedFiles {
    enum Failure: Error, LocalizedError {
        case unsafe(String)
        var errorDescription: String? {
            switch self { case .unsafe(let message): return message }
        }
    }

    static func posixFailure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    /// The caller owns the returned descriptor. Only macOS's standard aliases are canonicalized.
    static func directory(_ rawPath: String) throws -> Int32 {
        let path = Safety.canonical(rawPath)
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.utf8.contains(0) else {
            throw Failure.unsafe("Invalid directory path")
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = posixFailure()
            close(fd)
            guard next >= 0 else { throw error }
            fd = next
        }
        return fd
    }

    static func info(_ parent: Int32, _ name: String) throws -> FileInfo {
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        return FileInfo(st)
    }

    static func matches(_ info: FileInfo, _ expected: PathIdentity) -> Bool {
        PathIdentity(info) == expected
    }

    static func remove(_ rawPath: String, expected: PathIdentity, home: String, trash: Bool) throws {
        if let why = Safety.refusal(for: rawPath, home: home) { throw Failure.unsafe(why) }
        let path = Safety.canonical(rawPath)
        let parent = try directory(FS.parent(path))
        defer { close(parent) }
        let name = FS.name(path)
        let current = try info(parent, name)
        guard matches(current, expected) else { throw Failure.unsafe("The item changed since scanning. Scan again.") }
        if trash {
            // Atomic rename on the same volume. A cross-volume or inaccessible Trash fails closed;
            // it must never silently turn a recoverable action into permanent deletion.
            let trashPath = Safety.canonical(home) + "/.Trash"
            let homeFD = try directory(home)
            defer { close(homeFD) }
            if mkdirat(homeFD, ".Trash", 0o700) != 0 && errno != EEXIST { throw posixFailure() }
            let trashFD = try directory(trashPath)
            defer { close(trashFD) }
            var st = stat()
            guard fstat(trashFD, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
                throw Failure.unsafe("Your Trash is not a private folder owned by you")
            }
            guard matches(try info(parent, name), expected) else { throw Failure.unsafe("The item changed. Scan again.") }
            let destination = name + "-" + UUID().uuidString
            guard renameat(parent, name, trashFD, destination) == 0 else { throw posixFailure() }
        } else {
            try removeEntry(parent, name, expected: expected, device: current.device)
        }
    }

    private static func removeEntry(_ parent: Int32, _ name: String, expected: PathIdentity, device: UInt64) throws {
        let entry = try info(parent, name)
        guard matches(entry, expected), entry.device == device else {
            throw Failure.unsafe("A file changed or another volume was found. Scan again.")
        }
        if entry.isDirectory {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, matches(FileInfo(st), expected) else {
                throw Failure.unsafe("A directory changed. Scan again.")
            }
            // Change only this pinned, owned directory, never recursively chmod a pathname.
            if st.st_uid == getuid(), st.st_mode & 0o700 != 0o700 {
                guard fchmod(fd, st.st_mode | 0o700) == 0 else { throw posixFailure() }
            }
            let copy = dup(fd)
            guard copy >= 0 else { throw posixFailure() }
            guard let stream = fdopendir(copy) else { close(copy); throw posixFailure() }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let ent = readdir(stream) else {
                    if errno != 0 { throw posixFailure() }
                    break
                }
                let child = withUnsafePointer(to: &ent.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ent.pointee.d_name)) {
                        String(cString: $0)
                    }
                }
                if child == "." || child == ".." { continue }
                let childInfo = try info(fd, child)
                try removeEntry(fd, child, expected: PathIdentity(childInfo), device: device)
            }
        }
        guard matches(try info(parent, name), expected) else { throw Failure.unsafe("The item changed. Scan again.") }
        guard unlinkat(parent, name, entry.isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw posixFailure() }
    }
}
