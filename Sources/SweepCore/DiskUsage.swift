import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DiskUsage {
    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// Space actually used on disk by a file or folder tree. Symlinks are not followed,
    /// other volumes are not entered and hard-linked files are counted once.
    public static func allocatedSize(_ path: String, cancel: CancelToken? = nil) -> Int64 {
        guard let root = FS.info(path) else { return 0 }
        guard root.isDirectory else { return root.allocated }

        var total = root.allocated
        var seen = Set<InodeKey>()
        var stack = [path]
        var visited = 0

        while let dir = stack.popLast() {
            guard let handle = opendir(dir) else { continue }
            defer { closedir(handle) }
            while let entry = readdir(handle) {
                let name = entryName(entry)
                if name == "." || name == ".." { continue }
                let child = dir.hasSuffix("/") ? dir + name : dir + "/" + name
                guard let info = FS.info(child) else { continue }
                if info.isDirectory {
                    if info.device != root.device { continue }
                    total = saturatingAdd(total, info.allocated)
                    stack.append(child)
                } else {
                    if info.linkCount > 1 && !seen.insert(InodeKey(device: info.device, inode: info.inode)).inserted {
                        continue
                    }
                    total = saturatingAdd(total, info.allocated)
                }
                visited += 1
                if visited & 0x3FF == 0, cancel?.isCancelled == true { return total }
            }
        }
        return total
    }

    static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : sum
    }

    /// The entry's name, read in place. readdir's records are only as long as their name, so copying the
    /// fixed-size d_name field (1024 bytes on macOS) would read past the end of readdir's buffer.
    static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        if let offset = MemoryLayout<dirent>.offset(of: \dirent.d_name) {
            return String(cString: UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: CChar.self))
        }
        // Accessing the field through the pointer's pointee also works in place (no copy).
        return withUnsafeMutablePointer(to: &entry.pointee.d_name) { field in
            String(cString: UnsafeRawPointer(field).assumingMemoryBound(to: CChar.self))
        }
    }
}
