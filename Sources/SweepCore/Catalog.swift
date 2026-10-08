import Foundation

/// Every category MacSweep knows about, in sidebar order.
public enum Catalog {
    static func category(_ id: String, _ title: String, _ section: SweepSection, _ symbol: String, _ summary: String,
                         _ scan: @escaping @Sendable (ScanContext) async -> ScanResult) -> CategoryScanner {
        CategoryScanner(SweepCategory(id: id, title: title, section: section, symbol: symbol, summary: summary)) { ctx in
            var result = await scan(ctx)
            // Item ids must be unique within a category (the UI relies on it).
            var seen = Set<String>()
            result.items = result.items.filter { seen.insert($0.id).inserted }
            return result
        }
    }

    public static let all: [CategoryScanner] = [
        // System junk
        category("userCaches", "User Caches", .junk, "archivebox",
                 "Everything apps keep in ~/Library/Caches. Rebuilt automatically when needed.", { await JunkScanners.userCaches($0) }),
        category("systemCaches", "System Caches", .junk, "archivebox.fill",
                 "Shared caches in /Library/Caches. Some need your administrator password to remove.", { await JunkScanners.systemCaches($0) }),
        category("appCaches", "Hidden App Caches", .junk, "eye.slash",
                 "Caches that sandboxed, Electron and Chromium apps (Slack, Discord, Chrome, Teams…) keep outside ~/Library/Caches.",
                 { await JunkScanners.hiddenAppCaches($0) }),
        category("xdgCache", "Command-line Tool Caches", .junk, "terminal",
                 "~/.cache, where command-line tools (pip, uv, pre-commit, Puppeteer…) keep downloads.", { await JunkScanners.xdgCache($0) }),
        category("logs", "Logs & Crash Reports", .junk, "doc.text.magnifyingglass",
                 "Log files, crash reports, old system logs and core dumps.", { await JunkScanners.logs($0) }),
        category("temp", "Temporary Files", .junk, "clock.arrow.circlepath",
                 "Your temporary folders, per-user system caches and the font cache.", { await JunkScanners.temporaryFiles($0) }),
        category("savedState", "Saved Window State", .junk, "macwindow.on.rectangle",
                 "Which windows each app had open, used to restore them on relaunch.", { await JunkScanners.savedState($0) }),
        category("trash", "Trash", .junk, "trash",
                 "Items already in the Trash on every drive.", { await JunkScanners.trash($0) }),
        category("tmSnapshots", "Time Machine Snapshots", .junk, "clock.badge.checkmark",
                 "Local Time Machine snapshots stored on your startup disk.", { await JunkScanners.timeMachineSnapshots($0) }),

        // Apps & add-ons
        category("apps", "Applications", .apps, "square.grid.2x2",
                 "Every app in /Applications and ~/Applications, with how long since you used it. Removing one also removes its settings and support files.",
                 { await AppScanners.applications($0) }),
        category("leftovers", "App Leftovers", .apps, "shippingbox",
                 "Settings, containers and support folders whose app is no longer installed.", { await AppScanners.leftovers($0) }),
        category("launchItems", "Login & Background Items", .apps, "power",
                 "Launch agents, launch daemons and login items that start automatically, including broken ones.",
                 { await AppScanners.launchItems($0) }),
        category("helpers", "Privileged Helpers", .apps, "lock.shield",
                 "Helper tools that run as root on behalf of apps.", { await AppScanners.helpers($0) }),
        category("plugins", "Plug-ins & Drivers", .apps, "puzzlepiece.extension",
                 "Audio plug-ins, Quick Look and Spotlight plug-ins, settings panes, screen savers, kernel extensions, printer drivers and more.",
                 { await AppScanners.plugins($0) }),
        category("fonts", "Fonts", .apps, "textformat",
                 "Fonts you or your apps installed.", { await AppScanners.fonts($0) }),
        category("receipts", "Installer Packages", .apps, "shippingbox.circle",
                 "Software installed with .pkg installers, removable file by file using the installer's own receipt.",
                 { await AppScanners.receipts($0) }),
        category("appleExtras", "Optional Apple Content", .apps, "music.note.list",
                 "GarageBand and Logic sound libraries, upgrade leftovers and extra dictionaries.", { await AppScanners.appleExtras($0) }),
        category("games", "Games", .apps, "gamecontroller",
                 "Installed Steam and Epic games, plus Steam caches.", { await AppScanners.games($0) }),

        // Developer
        category("brewFormulae", "Homebrew Packages", .developer, "mug",
                 "Command-line packages installed with Homebrew. Unused dependencies are marked Safe.", { await Homebrew.formulaeScan($0) }),
        category("brewCasks", "Homebrew Apps", .developer, "mug.fill",
                 "Apps installed with brew install --cask.", { await Homebrew.casksScan($0) }),
        category("brewMaintenance", "Homebrew Cleanup", .developer, "wrench.and.screwdriver",
                 "Old package versions, stale downloads and taps you don't need.", { await Homebrew.maintenanceScan($0) }),
        category("macports", "MacPorts", .developer, "ferry",
                 "Ports installed with MacPorts, inactive versions and build leftovers.", { await MacPorts.scan($0) }),
        category("projects", "Project Build Folders", .developer, "folder.badge.gearshape",
                 "node_modules, Rust target, Swift .build, Gradle build, Python venvs and other folders inside your projects that can be rebuilt.",
                 { await DevScanners.projects($0) }),
        category("xcode", "Xcode & Simulators", .developer, "hammer",
                 "DerivedData, archives, device support files, simulators and simulator runtimes.", { await DevScanners.xcode($0) }),
        category("node", "Node.js", .developer, "curlybraces",
                 "Global npm packages, Node versions from version managers, and npm/pnpm/Yarn/Bun caches.", { await DevScanners.node($0) }),
        category("python", "Python", .developer, "chevron.left.forwardslash.chevron.right",
                 "pyenv/uv/python.org versions, virtualenvs, conda environments and caches, pipx tools.", { await DevScanners.python($0) }),
        category("ruby", "Ruby", .developer, "diamond",
                 "rbenv/RVM/chruby rubies, gems and CocoaPods specs.", { await DevScanners.ruby($0) }),
        category("rust", "Rust", .developer, "gearshape.2",
                 "rustup toolchains, Cargo caches and tools installed with cargo install.", { await DevScanners.rust($0) }),
        category("go", "Go", .developer, "hare",
                 "Go module cache, installed Go tools and extra Go versions.", { await DevScanners.go($0) }),
        category("jvm", "Java, Kotlin & Android", .developer, "cup.and.saucer",
                 "Gradle and Maven caches, JDKs, Android SDK components, system images and emulators.", { await DevScanners.jvm($0) }),
        category("otherToolchains", "Other Toolchains", .developer, "wrench.adjustable",
                 "asdf/mise installs, Flutter, Haskell, Elixir, PHP, .NET, Julia, Terraform, Bazel, Nix and more.",
                 { await DevScanners.otherToolchains($0) }),
        category("docker", "Docker & Virtual Machines", .developer, "cube.box",
                 "Docker images, stopped containers, unused volumes, build cache, and virtual machines from Parallels, UTM, VirtualBox, Colima and others.",
                 { await Docker.scan($0) }),
        category("ide", "Editors & IDEs", .developer, "chevron.left.slash.chevron.right",
                 "VS Code/Cursor extensions and caches, state for deleted folders, and settings of old JetBrains and Android Studio versions.",
                 { await DevScanners.ide($0) }),
        category("ai", "AI Models", .developer, "brain.head.profile",
                 "Downloaded models from Ollama, LM Studio, Hugging Face, GPT4All, Whisper, Chrome and others.", { await DevScanners.ai($0) }),

        // Your files
        category("largeFiles", "Large Files", .files, "externaldrive",
                 "The biggest files in your home folder.", { await FileScanners.largeFiles($0) }),
        category("duplicates", "Duplicate Files", .files, "doc.on.doc",
                 "Files with exactly the same contents. One copy of each is always kept.", { await FileScanners.duplicates($0) }),
        category("oldDownloads", "Old Downloads", .files, "arrow.down.circle",
                 "Things in Downloads you haven't touched in a while.", { await FileScanners.oldDownloads($0) }),
        category("installers", "Installers & Disk Images", .files, "opticaldiscdrive",
                 ".dmg, .pkg, .iso and .ipsw files, macOS installers and device firmware.", { await FileScanners.installers($0) }),
        category("backups", "iPhone & iPad Backups", .files, "iphone",
                 "Local device backups made by Finder or iTunes.", { await FileScanners.backups($0) }),
        category("attachments", "Mail & Chat Attachments", .files, "paperclip",
                 "Attachments saved by Mail, Messages, WhatsApp, Slack, Teams and Zoom.", { await FileScanners.attachments($0) }),
        category("clutter", "Clutter", .files, "sparkles",
                 ".DS_Store files, AppleDouble files, Windows leftovers and broken shortcuts.", { await FileScanners.clutter($0) }),
    ]

    public static func scanner(_ id: String) -> CategoryScanner? { all.first { $0.category.id == id } }
}
