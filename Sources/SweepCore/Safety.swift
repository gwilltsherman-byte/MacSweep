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
        let credentials = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".codex", ".config", ".local/share/keyrings",
                           ".netrc", ".npmrc", ".pypirc", "Library/Keychains", "Library/Application Support/gcloud"].map { $0.lowercased() }
        if credentials.contains(where: { path == homePath + "/" + $0 || path.hasPrefix(homePath + "/" + $0 + "/") }) {
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
            if !(parent == homePath && isDisposableHomeEntry(FS.name(path))) {
                return "Protected folder"
            }
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

    /// Items directly in the home folder that are tool caches/state rather than user folders.
    static func isDisposableHomeEntry(_ name: String) -> Bool {
        let keep: Set<String> = [
            "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
            "Applications", "Sites", "Developer", "Projects", "Dropbox", "Google Drive", "OneDrive",
            "iCloud Drive (Archive)", "Creative Cloud Files", ".ssh", ".gnupg", ".config", ".local",
            ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile", ".gitconfig",
            ".Trash", ".cache", ".npm", ".cargo", ".rustup", ".m2", ".gradle", "go",
        ]
        // Unknown dot-folders may hold credentials, databases or application state.
        // Only known disposable entries can bypass the protected home-folder rule.
        let disposable: Set<String> = [".diffusionbee", ".ollama", ".lmstudio", ".gpt4all", ".keras", ".torch"]
        // Finder metadata is also disposable; this does not allow unknown dot-folders.
        if [".ds_store", ".localized"].contains(name.lowercased()) || name.hasPrefix("._") { return true }
        return disposable.contains(name.lowercased()) && !keep.map({ $0.lowercased() }).contains(name.lowercased())
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
