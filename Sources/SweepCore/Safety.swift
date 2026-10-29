import Foundation

/// The last line of defence: paths MacSweep will never delete, whatever a scanner says.
public enum Safety {
    /// Returns why a path must not be deleted, or nil if it's allowed.
    public static func refusal(for rawPath: String, home: String) -> String? {
        guard !rawPath.utf8.contains(0) else { return "Path contains a null character" }
        guard rawPath.hasPrefix("/") else { return "Not an absolute path" }
        let rawParts = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        if rawParts.contains("..") { return "Path contains \"..\"" }
        // macOS volumes commonly ignore case. The deny list must do so too.
        let path = canonical(rawPath).lowercased()
        let homePath = canonical(home).lowercased()
        func inHome(_ relative: String) -> Bool {
            let full = homePath + "/" + relative.lowercased()
            return path == full || path.hasPrefix(full + "/")
        }
        if credentials.contains(where: inHome) && !credentialCaches.contains(where: inHome) {
            return "Credentials or account configuration"
        }
        let parts = path.split(separator: "/").map(String.init)

        if parts.isEmpty { return "That's the whole disk" }
        if path == homePath || homePath.hasPrefix(path + "/") { return "That would remove your home folder" }
        if parts.count == 1 { return "Top-level system folder" }
        if parts[0] == "system" { return "Protected by macOS" }

        // These folders themselves (and their immediate children where noted) are off limits.
        let protectedFolders = Set([
            "/Applications", "/Library", "/Users", "/Users/Shared", "/Volumes", "/cores",
            "/usr", "/usr/local", "/usr/local/bin", "/usr/local/lib", "/usr/local/share", "/usr/local/include",
            "/opt", "/opt/homebrew", "/opt/local", "/nix",
            "/private", "/private/var", "/private/tmp", "/private/etc", "/private/var/tmp",
            "/private/var/folders", "/private/var/db", "/private/var/log", "/private/var/root",
            "/Library/Developer",
        ].map { $0.lowercased() })
        if protectedFolders.contains(path) { return "Protected system location" }

        let protectedParents: [String] = [
            "/Library", "/usr", "/usr/local", "/opt", "/opt/homebrew", "/private", "/private/var",
            "/Volumes", "/Users", "/System/Volumes/Data",
            homePath, homePath + "/Library",
        ].map { $0.lowercased() }
        let parent = FS.parent(path)
        if protectedParents.contains(parent) && !allowedDirectChildren.map({ $0.lowercased() }).contains(path) {
            // e.g. ~/Documents, ~/Library/Caches, /Library/Fonts, /usr/bin – never the folder itself.
            let name = FS.name(path)
            let allowed = (parent == homePath && isRemovableHomeEntry(name, at: canonical(rawPath)))
                || (parent == homePath + "/library" && removableLibraryEntries.contains(name))
            if !allowed { return "Protected folder" }
        }

        let forbiddenPrefixes = [
            "/bin/", "/sbin/", "/dev/", "/private/etc/", "/private/var/db/", "/private/var/root/", "/private/var/vm/",
            "/Library/Apple/", "/Library/Keychains/", "/Library/Security/",
            homePath + "/Library/Keychains/", homePath + "/.ssh/", homePath + "/.gnupg/",
        ].map { $0.lowercased() }
        if forbiddenPrefixes.contains(where: { path.hasPrefix($0) }) { return "Protected location" }

        // Per-user temporary folders live at /private/var/folders/xx/yyyy/{T,C,0}/…
        if path.hasPrefix("/private/var/folders/") && parts.count < 7 { return "System temporary folder" }
        if path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/") { return "Protected by macOS" }
        return nil
    }

    /// Folders directly inside a protected parent that are still fine to remove as a whole.
    static let allowedDirectChildren: Set<String> = [
        "/private/var/log/DiagnosticMessages",
    ]

    /// Places in your home folder that hold keys, tokens or account settings.
    static let credentials = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".codex", ".config", ".local/share/keyrings",
                              ".netrc", ".npmrc", ".pypirc", "Library/Keychains", "Library/Application Support/gcloud"]

    /// Caches kept inside those places, which hold no secrets themselves.
    static let credentialCaches = [".kube/cache", ".kube/http-cache"]

    /// Folders directly in ~/Library that are copies an app made rather than part of the Library itself (lower case).
    static let removableLibraryEntries: Set<String> = ["mail downloads"]

    /// Your own folders directly in the home folder, and the tools' folders everything else lives in (lower case).
    static let homeFolders: Set<String> = [
        "library", "documents", "desktop", "downloads", "pictures", "movies", "music", "public",
        "applications", "sites", "developer", "projects", "dropbox", "google drive", "onedrive",
        "icloud drive (archive)", "creative cloud files", ".ssh", ".gnupg", ".config", ".local",
        ".trash", ".cache", ".npm", ".cargo", ".rustup", ".m2", ".gradle", "go",
    ]

    /// Your folders and settings directly in the home folder (lower case).
    static let homeKeep = homeFolders.union([".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile", ".gitconfig"])

    /// Tool caches and downloads directly in the home folder that MacSweep offers as a whole (lower case).
    static let disposableHomeEntries: Set<String> = [
        ".diffusionbee", ".ollama", ".lmstudio", ".gpt4all", ".keras", ".torch",
        ".pnpm-store", ".node-gyp", ".electron", ".expo", ".templateengine",
    ]

    /// Items directly in the home folder that are tool caches/state rather than user folders.
    static func isDisposableHomeEntry(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Finder metadata is also disposable; this does not allow unknown dot-folders.
        if [".ds_store", ".localized"].contains(lower) || lower.hasPrefix("._") { return true }
        // Unknown dot-folders may hold credentials, databases or application state.
        // Only known disposable entries can bypass the protected home-folder rule.
        return disposableHomeEntries.contains(lower) && !homeKeep.contains(lower)
    }

    /// What may go from directly inside the home folder: known disposable entries, ordinary files such as a big
    /// download or a duplicate, and shortcuts (symlinks), which are only pointers: removing one never touches
    /// what it points to. Your folders, even as shortcuts, and your hidden settings stay protected.
    static func isRemovableHomeEntry(_ name: String, at path: String) -> Bool {
        if isDisposableHomeEntry(name) { return true }
        let lower = name.lowercased()
        let info = FS.info(path)
        if info?.isSymlink == true { return !homeFolders.contains(lower) }
        if lower.hasPrefix(".") || homeKeep.contains(lower) { return false }
        return info?.isDirectory != true
    }

    /// System Integrity Protection's flags: SF_RESTRICTED (only Apple may change it) and SF_NOUNLINK (it may not
    /// be removed, as on /Applications itself, which says nothing about what's inside).
    static let restrictedFlag: UInt32 = 0x0008_0000
    static let noUnlinkFlag: UInt32 = 0x0010_0000

    /// Not even an administrator can remove an item macOS protects this way, or anything in a restricted folder.
    static func isSealed(_ path: String) -> Bool {
        if let info = FS.info(path), info.flags & (restrictedFlag | noUnlinkFlag) != 0 { return true }
        if let folder = FS.info(FS.parent(path)), folder.flags & restrictedFlag != 0 { return true }
        return false
    }

    /// Whether MacSweep can remove an item at all: it has a way to, these rules allow every path it would
    /// touch, and macOS hasn't sealed any of them. Scans only ever list items that pass.
    public static func canRemove(_ item: Item, home: String) -> Bool {
        item.isRemovable && item.steps.flatMap(\.paths).allSatisfy { refusal(for: $0, home: home) == nil && !isSealed($0) }
    }

    /// Resolves the /var, /tmp and /etc symlinks to /private/… and tidies slashes.
    public static func canonical(_ path: String) -> String {
        var tidy = FS.collapse(path)
        let data = "/System/Volumes/Data"
        if tidy.lowercased() == data.lowercased() { return "/" }
        if tidy.lowercased().hasPrefix(data.lowercased() + "/") { tidy = String(tidy.dropFirst(data.count)) }
        for link in ["/var", "/tmp", "/etc"] {
            if tidy == link || tidy.hasPrefix(link + "/") { return "/private" + tidy }
        }
        return tidy
    }
}
