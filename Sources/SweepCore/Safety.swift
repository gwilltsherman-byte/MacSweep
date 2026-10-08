import Foundation

/// The last line of defence: paths MacSweep will never delete, whatever a scanner says.
public enum Safety {
    /// Returns why a path must not be deleted, or nil if it's allowed.
    public static func refusal(for rawPath: String, home: String) -> String? {
        guard rawPath.hasPrefix("/") else { return "Not an absolute path" }
        let rawParts = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        if rawParts.contains("..") { return "Path contains \"..\"" }
        let path = canonical(rawPath)
        let homePath = canonical(home)
        let parts = path.split(separator: "/").map(String.init)

        if parts.isEmpty { return "That's the whole disk" }
        if path == homePath || homePath.hasPrefix(path + "/") { return "That would remove your home folder" }
        if parts.count == 1 { return "Top-level system folder" }
        if parts[0] == "System" && !path.hasPrefix("/System/Volumes/Data/") { return "Protected by macOS" }
        if parts[0] == "System" && parts.count <= 4 { return "Protected system location" }

        // These folders themselves (and their immediate children where noted) are off limits.
        let protectedFolders: Set<String> = [
            "/Applications", "/Library", "/Users", "/Users/Shared", "/Volumes", "/cores",
            "/usr", "/usr/local", "/usr/local/bin", "/usr/local/lib", "/usr/local/share", "/usr/local/include",
            "/opt", "/opt/homebrew", "/opt/local", "/nix",
            "/private", "/private/var", "/private/tmp", "/private/etc", "/private/var/tmp",
            "/private/var/folders", "/private/var/db", "/private/var/log", "/private/var/root",
            "/Library/Developer",
        ]
        if protectedFolders.contains(path) { return "Protected system location" }

        let protectedParents: [String] = [
            "/Library", "/usr", "/usr/local", "/opt", "/opt/homebrew", "/private", "/private/var",
            "/Volumes", "/Users", "/System/Volumes/Data",
            homePath, homePath + "/Library",
        ]
        let parent = FS.parent(path)
        if protectedParents.contains(parent) && !allowedDirectChildren.contains(path) {
            // e.g. ~/Documents, ~/Library/Caches, /Library/Fonts, /usr/bin – never the folder itself.
            if !(parent == homePath && isDisposableHomeEntry(FS.name(path))) {
                return "Protected folder"
            }
        }

        let forbiddenPrefixes = [
            "/bin/", "/sbin/", "/dev/", "/private/etc/", "/private/var/db/", "/private/var/root/", "/private/var/vm/",
            "/Library/Apple/", "/Library/Keychains/", "/Library/Security/",
            homePath + "/Library/Keychains/", homePath + "/.ssh/", homePath + "/.gnupg/",
        ]
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

    /// Items directly in the home folder that are tool caches/state rather than user folders.
    static func isDisposableHomeEntry(_ name: String) -> Bool {
        let keep: Set<String> = [
            "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
            "Applications", "Sites", "Developer", "Projects", "Dropbox", "Google Drive", "OneDrive",
            "iCloud Drive (Archive)", "Creative Cloud Files", ".ssh", ".gnupg", ".config", ".local",
            ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile", ".gitconfig",
            ".Trash", ".cache", ".npm", ".cargo", ".rustup", ".m2", ".gradle", "go",
        ]
        return name.hasPrefix(".") ? !keep.contains(name) && name.count > 1 : false
    }

    /// Resolves the /var, /tmp and /etc symlinks to /private/… and tidies slashes.
    public static func canonical(_ path: String) -> String {
        let tidy = FS.collapse(path)
        for link in ["/var", "/tmp", "/etc"] {
            if tidy == link || tidy.hasPrefix(link + "/") { return "/private" + tidy }
        }
        return tidy
    }
}
