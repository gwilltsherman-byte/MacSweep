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
        /// The drive has no Trash MacSweep can use (a network share, for example). Finder knows what to do there.
        case noTrash
        var errorDescription: String? {
            switch self {
            case .unsafe(let message): return message
            case .noTrash: return "The drive it's on has no Trash"
            }
        }
    }

    static func posixFailure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    /// Where an item really is.
    struct Location: Equatable {
        /// Its folder, with symlinks resolved.
        var parent: String
        var name: String
        var path: String { FS.join(parent, name) }
    }

    /// Finds the folder an item is really in, so a folder reached through a symlink (an extra folder you
    /// scan, say) can still be removed. The safety rules must allow both the path as given and the real one.
    static func locate(_ rawPath: String, home: String) throws -> Location {
        if let why = Safety.refusal(for: rawPath, home: home) { throw Failure.unsafe(why) }
        let path = Safety.canonical(rawPath)
        var location = Location(parent: FS.parent(path), name: FS.name(path))
        if let real = FS.realPath(location.parent).map(Safety.canonical), real != location.parent {
            location.parent = real
            if let why = Safety.refusal(for: location.path, home: home) { throw Failure.unsafe(why) }
        }
        return location
    }

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
        let location = try locate(rawPath, home: home)
        let parent = try directory(location.parent)
        defer { close(parent) }
        let name = location.name
        let current = try info(parent, name)
        guard matches(current, expected) else { throw Failure.unsafe("The item changed since scanning. Scan again.") }
        if trash {
            // Atomic rename into the Trash on the item's own drive. A Trash that isn't private fails closed;
            // it must never silently turn a recoverable action into permanent deletion.
            let trashFD = try trashFolder(for: current, at: location.path, home: home)
            defer { close(trashFD) }
            unlock(parent, name, current)
            guard matches(try info(parent, name), expected) else { throw Failure.unsafe("The item changed. Scan again.") }
            guard renameat(parent, name, trashFD, trashName(for: name)) == 0 else { throw posixFailure() }
        } else {
            try removeEntry(parent, name, expected: expected, device: current.device)
        }
    }

    /// A name no other item in the Trash has, short enough for any drive.
    static func trashName(for name: String) -> String {
        var base = ""
        for character in name {
            if base.utf8.count + String(character).utf8.count > 200 { break }
            base.append(character)
        }
        return base + "-" + UUID().uuidString
    }

    /// The Trash on the item's own drive, where Finder would put it too: ~/.Trash on the drive your home
    /// folder is on, <drive>/.Trashes/<your user ID> on any other. It must be a folder you own.
    static func trashFolder(for item: FileInfo, at path: String, home: String) throws -> Int32 {
        let homeFD = try directory(home)
        defer { close(homeFD) }
        var st = stat()
        guard fstat(homeFD, &st) == 0 else { throw posixFailure() }
        if FileInfo(st).device == item.device {
            if mkdirat(homeFD, ".Trash", 0o700) != 0 && errno != EEXIST { throw posixFailure() }
            return try ownFolder(openat(homeFD, ".Trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), onlyYou: true)
        }
        guard let volume = mountPoint(of: path, device: item.device) else { throw Failure.noTrash }
        let volumeFD = try directory(volume)
        defer { close(volumeFD) }
        if mkdirat(volumeFD, ".Trashes", 0o1333) == 0 {
            // Like Finder's: anyone may add a Trash of their own to it, and nobody may touch anyone else's.
            let made = openat(volumeFD, ".Trashes", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if made >= 0 { _ = fchmod(made, 0o1333); close(made) }
        } else if errno != EEXIST {
            throw Failure.noTrash
        }
        let trashes = openat(volumeFD, ".Trashes", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard trashes >= 0 else { throw Failure.noTrash }
        defer { close(trashes) }
        let mine = String(getuid())
        if mkdirat(trashes, mine, 0o700) != 0 && errno != EEXIST { throw Failure.noTrash }
        // Drives formatted for Windows have no real permissions, so only ownership is checked there.
        return try ownFolder(openat(trashes, mine, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), onlyYou: false)
    }

    /// Hands back a folder descriptor that belongs to you (and, if `onlyYou`, that nobody else can open), else fails.
    private static func ownFolder(_ fd: Int32, onlyYou: Bool) throws -> Int32 {
        guard fd >= 0 else { throw posixFailure() }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), !onlyYou || st.st_mode & 0o077 == 0 else {
            close(fd)
            throw Failure.unsafe("Your Trash is not a private folder owned by you")
        }
        return fd
    }

    /// The top folder of the drive a path is on: the last folder, going up, that is still on `device`.
    static func mountPoint(of path: String, device: UInt64) -> String? {
        var current = FS.parent(path)
        var top: String?
        while let info = FS.info(current), info.device == device {
            top = current
            if current == "/" { break }
            current = FS.parent(current)
        }
        return top
    }

    /// Clears the Locked flag (and append-only) of an item you own. Otherwise nobody can remove or move it.
    static func unlock(_ parent: Int32, _ name: String, _ entry: FileInfo) {
        #if os(macOS)
        let locks: UInt32 = 0x0000_0002 | 0x0000_0004 // UF_IMMUTABLE, UF_APPEND
        guard entry.flags & locks != 0, entry.uid == FS.currentUID else { return }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, matches(FileInfo(st), PathIdentity(entry)) else { return }
        _ = fchflags(fd, UInt32(st.st_flags) & ~locks)
        #endif
    }

    private static func removeEntry(_ parent: Int32, _ name: String, expected: PathIdentity, device: UInt64) throws {
        let entry = try info(parent, name)
        guard matches(entry, expected), entry.device == device else {
            throw Failure.unsafe("A file changed or another volume was found. Scan again.")
        }
        unlock(parent, name, entry)
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
