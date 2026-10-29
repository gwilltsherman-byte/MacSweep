import XCTest
@testable import SweepCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ImportanceTests: XCTestCase {
    func context(_ box: Sandbox) -> ScanContext {
        ScanContext(settings: ScanSettings(home: box.path("home"), largeFileThreshold: 200_000, oldDownloadDays: 90,
                                           duplicateMinSize: 10_000, selfBundleID: nil),
                    shell: Shell(home: box.path("home")))
    }

    func run(_ id: String, _ ctx: ScanContext) async -> ScanResult {
        await Catalog.scanner(id)!.scan(ctx)
    }

    // MARK: Files in use

    func testParsesLsofAndNamesProgramsAfterTheirApp() {
        let output = """
        p100
        cXCBBuildService
        fcwd
        n/Users/me/code/app
        ftxt
        n/Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService
        f12
        n/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build/x.o
        fmem
        n/usr/lib/dyld
        p200
        cmdworker_shared
        f3
        n/Users/me/Documents/report.pdf
        p300
        csleep
        f4
        n/private/var/folders/xx/T/busy/file
        f5
        npipe
        p400
        cMacSweep
        f6
        n/Users/me/Library/Caches/x
        """
        let parsed = OpenFiles.parse(output, excludingPID: 400)
        XCTAssertEqual(parsed.map { $0.path }, ["/Users/me/code/app", "/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build/x.o",
                                                "/private/var/folders/xx/T/busy/file"],
                       "Spotlight, MacSweep itself, libraries and pipes are left out")
        XCTAssertEqual(parsed.first?.user, "Xcode")
        XCTAssertEqual(parsed.last?.user, "sleep")
    }

    func testOpenFilesMatchFoldersAndTheirContentsOnly() {
        let open = OpenFiles([(path: "/Users/me/Library/Caches/com.app/data.db", user: "App"),
                              (path: "/var/folders/xx/T/thing", user: "Tool")])
        XCTAssertEqual(open.user(of: "/Users/me/Library/Caches/com.app"), "App")
        XCTAssertEqual(open.user(of: "/Users/me/Library/Caches/com.app/data.db"), "App")
        XCTAssertNil(open.user(of: "/Users/me/Library/Caches/com.ap"))
        XCTAssertNil(open.user(of: "/Users/me/Library/Caches/com.app2"))
        XCTAssertNil(open.user(of: "/Users/me/Library/Caches/com.app/data.db-wal"))
        XCTAssertEqual(open.user(of: "/private/var/folders/xx/T"), "Tool", "/var and /private/var are the same place")
    }

    func testItemsInUseAreNeverSafe() {
        let open = OpenFiles([(path: "/Users/me/Library/Caches/com.app/data.db", user: "App")])
        var cache = Item(categoryID: "userCaches", title: "com.app", risk: .safe, note: "", paths: ["/Users/me/Library/Caches/com.app"])
        Importance.markInUse(&cache, category: "userCaches", open: open)
        XCTAssertEqual(cache.risk, .review)
        XCTAssertTrue(cache.isInUse)
        XCTAssertFalse(cache.reasons.isEmpty)

        var leftover = Item(categoryID: "leftovers", title: "com.app", risk: .review, note: "", paths: ["/Users/me/Library/Caches/com.app"])
        Importance.markInUse(&leftover, category: "leftovers", open: open)
        XCTAssertEqual(leftover.risk, .caution, "something a program is using isn't left over")

        var other = Item(categoryID: "userCaches", title: "other", risk: .safe, note: "", paths: ["/Users/me/Library/Caches/com.other"])
        Importance.markInUse(&other, category: "userCaches", open: open)
        XCTAssertEqual(other.risk, .safe)
        XCTAssertTrue(other.reasons.isEmpty)

        var careful = Item(categoryID: "backups", title: "phone", risk: .caution, note: "", paths: ["/Users/me/Library/Caches/com.app"])
        Importance.markInUse(&careful, category: "backups", open: open)
        XCTAssertEqual(careful.risk, .caution, "evidence never lowers a rating")
    }

    #if os(macOS)
    func testSnapshotSeesAProgramWorkingInAFolder() async throws {
        let box = Sandbox()
        let busy = box.dir("busy")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = URL(fileURLWithPath: busy)
        try sleeper.run()
        defer { sleeper.terminate() }
        let open = await OpenFiles.snapshot(shell: Shell(home: box.root))
        XCTAssertEqual(open.user(of: busy), "sleep")
        XCTAssertNil(open.user(of: box.dir("idle")))
    }
    #endif

    // MARK: Your data inside app folders

    func testAppDataAndUnsavedWorkMakeLeftoversCareful() async {
        let box = Sandbox()
        box.plist("home/Library/Preferences/com.gone.notes.plist", ["a": 1])
        box.file("home/Library/Containers/com.gone.notes/Data/Documents/Plan.txt", bytes: 2000)
        box.file("home/Library/Containers/com.gone.cache/Data/Library/Caches/blob", bytes: 50_000)
        box.file("home/Library/Group Containers/ABCDE12345.com.gone.tasks/Things Database.thingsdatabase/main.sqlite", bytes: 300_000)
        box.file("home/Library/Application Support/com.gone.editor/Autosave Information/Unsaved Document.rtf", bytes: 2000)
        box.file("home/Library/Application Support/com.gone.http/Cache.db", bytes: 300_000)
        let leftovers = await run("leftovers", context(box))
        func risk(_ title: String) -> Risk? { leftovers.items.first { $0.title == title }?.risk }
        XCTAssertEqual(risk("com.gone.notes"), .caution, "documents saved in the app's container")
        XCTAssertEqual(risk("com.gone.tasks"), .caution, "the app's database")
        XCTAssertEqual(risk("com.gone.editor"), .caution, "unsaved documents")
        XCTAssertEqual(risk("com.gone.cache"), .review, "caches alone are not your data")
        XCTAssertEqual(risk("com.gone.http"), .review, "an HTTP cache database is not your data")
    }

    func testUninstallingAnAppThatHoldsYourDataIsCareful() {
        let box = Sandbox()
        let app = box.path("home/Applications/Notes Pro.app")
        box.file("home/Applications/Notes Pro.app/Contents/Resources/sample.sqlite", bytes: 200_000)
        let prefs = box.text("home/Library/Preferences/com.example.notespro.plist", "<plist/>")
        let cache = box.path("home/Library/Caches/com.example.notespro")
        box.file("home/Library/Caches/com.example.notespro/offline.sqlite", bytes: 200_000)
        let ctx = context(box)

        let paths = [app, prefs, cache]
        var settingsOnly = Item(categoryID: "apps", title: "Notes Pro", risk: .review, note: "", paths: paths)
        Importance.probeContents(&settingsOnly, paths: paths, category: "apps", ctx: ctx)
        XCTAssertEqual(settingsOnly.risk, .review, "databases inside the app itself or its caches aren't yours")

        let container = box.path("home/Library/Containers/com.example.notespro")
        box.file("home/Library/Containers/com.example.notespro/Data/Documents/Shopping.md", bytes: 2000)
        var withData = Item(categoryID: "apps", title: "Notes Pro", risk: .review, note: "", paths: paths + [container])
        Importance.probeContents(&withData, paths: paths + [container], category: "apps", ctx: ctx)
        XCTAssertEqual(withData.risk, .caution)
        XCTAssertTrue(withData.reasons.contains { $0.contains("Documents folder") })
    }

    func testLocalOnlyGitProjectsAreCareful() {
        let box = Sandbox()
        box.text("home/Downloads/experiment/.git/config", "[core]\n")
        box.text("home/Downloads/clone/.git/config", "[remote \"origin\"]\n\turl = https://example.com/x.git\n")
        let ctx = context(box)
        let local = box.path("home/Downloads/experiment")
        var experiment = Item(categoryID: "oldDownloads", title: "experiment", risk: .review, note: "", paths: [local])
        Importance.probeContents(&experiment, paths: [local], category: "oldDownloads", ctx: ctx)
        XCTAssertEqual(experiment.risk, .caution)
        XCTAssertTrue(experiment.badges.contains("Git project"))

        let clone = box.path("home/Downloads/clone")
        var scratch = Item(categoryID: "temp", title: "clone", risk: .safe, note: "", paths: [clone])
        Importance.probeContents(&scratch, paths: [clone], category: "temp", ctx: ctx)
        XCTAssertEqual(scratch.risk, .review, "a clone with a remote in a temporary folder is worth a look")
    }

    // MARK: Your own files

    func testLargeFilesAreRatedByWhatTheyAreAndWhereTheyLive() async {
        let box = Sandbox()
        box.file("home/Movies/holiday.mov", bytes: 300_000)
        box.file("home/Downloads/dataset.zip", bytes: 300_000, fill: 0x51)
        box.file("home/Documents/Vault.kdbx", bytes: 300_000, fill: 0x52)
        box.text("home/code/game/.git/config", "[core]\n")
        box.file("home/code/game/assets/level.bin", bytes: 300_000, fill: 0x53)
        box.file("home/Dropbox/clip.bin", bytes: 300_000, fill: 0x54)
        box.file("home/Desktop/notes.bin", bytes: 300_000, fill: 0x55)
        let large = await run("largeFiles", context(box))
        func item(_ title: String) -> Item? { large.items.first { $0.title == title } }
        XCTAssertEqual(item("holiday.mov")?.risk, .caution, "a video nobody downloaded is probably yours")
        XCTAssertEqual(item("dataset.zip")?.risk, .review)
        XCTAssertEqual(item("Vault.kdbx")?.risk, .caution)
        XCTAssertEqual(item("level.bin")?.risk, .caution)
        XCTAssertTrue(item("level.bin")?.badges.contains("In a project") ?? false)
        XCTAssertEqual(item("clip.bin")?.risk, .caution)
        XCTAssertTrue(item("clip.bin")?.badges.contains("Dropbox") ?? false)
        XCTAssertEqual(item("notes.bin")?.risk, .review)
    }

    func testDuplicatesKeepTheCopyThatMattersMost() async {
        let box = Sandbox()
        box.text("home/code/site/.git/config", "[core]\n")
        box.file("home/code/site/images/logo.psd", bytes: 50_000, fill: 0x61)
        box.file("home/Downloads/logo.psd", bytes: 50_000, fill: 0x61)
        box.text("home/code/other/.git/config", "[core]\n")
        box.file("home/code/other/logo.psd", bytes: 50_000, fill: 0x61)
        box.file("home/Documents/photo.heic", bytes: 50_000, fill: 0x62)
        box.file("home/Documents/photo copy.heic", bytes: 50_000, fill: 0x62)
        let duplicates = await run("duplicates", context(box))
        let logos = duplicates.items.filter { $0.title == "logo.psd" }
        XCTAssertEqual(logos.count, 2)
        XCTAssertTrue(logos.allSatisfy { $0.keepPath?.contains("/code/") == true }, "a copy a project uses is the one kept")
        XCTAssertEqual(logos.first { $0.paths[0].contains("/Downloads/") }?.risk, .review)
        XCTAssertEqual(logos.first { $0.paths[0].contains("/code/") }?.risk, .caution, "removing it breaks the other project")
        let photo = duplicates.items.first { $0.title.hasPrefix("photo") }
        XCTAssertEqual(photo?.title, "photo copy.heic", "the file named like a copy is the one offered")
        XCTAssertEqual(photo?.risk, .review)
    }

    func testEncryptedDiskImagesAreNotInstallers() async {
        let box = Sandbox()
        box.text("home/Documents/Private.dmg", "encrcdsa" + String(repeating: "x", count: 5000))
        box.file("home/Downloads/Setup.dmg", bytes: 5000)
        let installers = await run("installers", context(box))
        XCTAssertEqual(installers.items.first { $0.title == "Private.dmg" }?.risk, .caution)
        XCTAssertEqual(installers.items.first { $0.title == "Setup.dmg" }?.risk, .review)
    }

    func testBrokenLinksThatMayMatter() async throws {
        let box = Sandbox()
        box.dir("home")
        try FileManager.default.createSymbolicLink(atPath: box.path("home/.zshrc"), withDestinationPath: box.path("home/dotfiles/zshrc"))
        box.text("home/code/app/.git/config", "[core]\n")
        try FileManager.default.createSymbolicLink(atPath: box.path("home/code/app/current"), withDestinationPath: "build/output")
        try FileManager.default.createSymbolicLink(atPath: box.path("home/old-shortcut"), withDestinationPath: box.path("home/gone"))
        let clutter = await run("clutter", context(box))
        func risk(_ title: String) -> Risk? { clutter.items.first { $0.title == title }?.risk }
        XCTAssertEqual(risk(".zshrc"), .review, "a settings link")
        XCTAssertEqual(risk("current"), .review, "a project's link to something a build makes")
        XCTAssertEqual(risk("old-shortcut"), .safe)
    }

    func testBuildFolderRulesNeedRealBuildOutput() {
        let box = Sandbox()
        box.dir("research/DerivedData/tables")
        XCTAssertNil(ArtifactRules.match(name: "DerivedData", parent: box.path("research")), "your own folder with Xcode's folder name")
        box.dir("App/App.xcodeproj")
        box.dir("App/DerivedData")
        XCTAssertEqual(ArtifactRules.match(name: "DerivedData", parent: box.path("App"))?.risk, .safe)
        box.text("lib/CMakeLists.txt", "project(x)")
        box.file("lib/build/build.sh")
        XCTAssertNil(ArtifactRules.match(name: "build", parent: box.path("lib")), "build scripts, not build output")
        box.text("lib/build/CMakeCache.txt", "")
        XCTAssertEqual(ArtifactRules.match(name: "build", parent: box.path("lib"))?.label, "CMake/Meson build folder")
        box.dir("nb/.ipynb_checkpoints")
        XCTAssertEqual(ArtifactRules.match(name: ".ipynb_checkpoints", parent: box.path("nb"))?.risk, .review)
    }

    func testRecoveredFilesInTheTrashAreCareful() async {
        let box = Sandbox()
        box.file("home/.Trash/Recovered files/Untitled.rtf", bytes: 2000)
        box.file("home/.Trash/old.txt", bytes: 2000)
        let trash = await run("trash", context(box))
        XCTAssertEqual(trash.items.first { $0.title == "Recovered files" }?.risk, .caution)
        XCTAssertEqual(trash.items.first { $0.title == "old.txt" }?.risk, .safe)
    }

    func testTestBrowsersDoNotComeBackByThemselves() async {
        let box = Sandbox()
        box.file("home/Library/Caches/ms-playwright/chromium-1100/x", bytes: 5000)
        box.file("home/Library/Caches/com.example.app/x", bytes: 5000)
        let caches = await run("userCaches", context(box))
        XCTAssertEqual(caches.items.first { $0.paths[0].hasSuffix("/ms-playwright") }?.risk, .review)
        XCTAssertEqual(caches.items.first { $0.paths[0].hasSuffix("/com.example.app") }?.risk, .safe)
    }

    // MARK: Building blocks

    func testFindsGitProjectsAndRemotes() {
        let box = Sandbox()
        box.text("home/code/app/.git/config", "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://example.com/app.git\n")
        box.file("home/code/app/assets/big.bin")
        box.text("home/notes/.git/config", "[core]\n")
        box.text("home/.git/config", "[core]\n")
        box.file("home/loose.bin")
        let projects = GitProjects(home: box.path("home"))
        XCTAssertEqual(projects.root(containing: box.path("home/code/app/assets/big.bin")), box.path("home/code/app"))
        XCTAssertEqual(projects.root(containing: box.path("home/code/app")), box.path("home/code/app"))
        XCTAssertEqual(projects.root(containing: box.path("home/code/app/assets")), box.path("home/code/app"), "remembered answer")
        XCTAssertNil(projects.root(containing: box.path("home/loose.bin")), "the home folder itself is never a project")
        XCTAssertTrue(GitProjects.hasRemote(box.path("home/code/app")))
        XCTAssertFalse(GitProjects.hasRemote(box.path("home/notes")))
    }

    func testCloudFolders() {
        let box = Sandbox()
        box.dir("home/Library/CloudStorage/GoogleDrive-me@example.com/My Drive")
        box.dir("home/Library/CloudStorage/OneDrive-Personal")
        box.dir("home/Library/Mobile Documents/com~apple~CloudDocs/Documents")
        box.dir("home/Dropbox (Acme)")
        box.dir("home/Boxing")
        let clouds = CloudFolders.find(home: box.path("home"))
        XCTAssertEqual(clouds.service(for: box.path("home/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/a.doc")), "Google Drive")
        XCTAssertEqual(clouds.service(for: box.path("home/Library/CloudStorage/OneDrive-Personal/x")), "OneDrive")
        XCTAssertEqual(clouds.service(for: box.path("home/Documents/report.pages")), "iCloud Drive", "Desktop & Documents sync is on")
        XCTAssertNil(clouds.service(for: box.path("home/Desktop/x")))
        XCTAssertEqual(clouds.service(for: box.path("home/Dropbox (Acme)/plan.key")), "Dropbox")
        XCTAssertNil(clouds.service(for: box.path("home/Boxing/match.mov")))
    }

    func testMissingMeansCertainlyGone() {
        let box = Sandbox()
        XCTAssertTrue(FS.isMissing(box.path("nothing/here")))
        XCTAssertFalse(FS.isMissing(box.file("there")))
        XCTAssertFalse(FS.isMissing("/Volumes/MacSweep Test Drive That Is Not Plugged In/app/run"), "an unplugged drive isn't proof")
        let locked = box.dir("locked")
        box.file("locked/inside")
        chmod(locked, 0o000)
        defer { chmod(locked, 0o755) }
        // Root can read everything, so the check only means something for ordinary users.
        if getuid() != 0 {
            XCTAssertFalse(FS.isMissing(box.path("locked/inside")), "an unreadable folder isn't proof either")
            XCTAssertFalse(FS.isMissing(box.path("locked/absent")))
        }
    }

    func testDanglingLinks() throws {
        let box = Sandbox()
        let gone = box.path("gone-link")
        try FileManager.default.createSymbolicLink(atPath: gone, withDestinationPath: box.path("nowhere"))
        XCTAssertTrue(FS.isDangling(gone))
        let fine = box.path("fine-link")
        try FileManager.default.createSymbolicLink(atPath: fine, withDestinationPath: box.file("target"))
        XCTAssertFalse(FS.isDangling(fine))
    }

    func testLaunchItemsOnAnUnpluggedDriveAreNotBroken() async {
        let box = Sandbox()
        box.plist("home/Library/LaunchAgents/com.example.backup.plist",
                  ["Label": "com.example.backup", "ProgramArguments": ["/Volumes/MacSweep Test Drive/Backup.app/Contents/MacOS/backup"]])
        let launch = await run("launchItems", context(box))
        let agent = launch.items.first { $0.title == "com.example.backup" }
        XCTAssertEqual(agent?.risk, .review)
        XCTAssertTrue(agent?.badges.contains("Drive not connected") ?? false)
        XCTAssertFalse(agent?.badges.contains("Broken") ?? true)
    }

    func testReadsIPhoneAppsInstalledOnAMac() {
        let box = Sandbox()
        box.plist("Applications/Game.app/Wrapper/Game.app/Info.plist", ["CFBundleIdentifier": "com.example.game"])
        XCTAssertEqual(FS.bundleID(box.path("Applications/Game.app")), "com.example.game")
        XCTAssertEqual(AppCatalog.readApp(box.path("Applications/Game.app"))?.isAppStore, true)
    }

    func testFileKinds() {
        XCTAssertEqual(FileKinds.kind(of: "Holiday.MOV")?.group, .personal)
        XCTAssertEqual(FileKinds.kind(of: "passwords.kdbx")?.group, .critical)
        XCTAssertEqual(FileKinds.kind(of: "wallet.dat")?.group, .critical)
        XCTAssertEqual(FileKinds.kind(of: "release.zip")?.group, .replaceable)
        XCTAssertEqual(FileKinds.kind(of: "photos-backup.zip")?.group, .personal)
        XCTAssertEqual(FileKinds.kind(of: "takeout-2024.tgz")?.label, "Backup archive")
        XCTAssertNil(FileKinds.kind(of: "blob.bin"))
    }

    func testReadsWhereAFileCameFrom() {
        XCTAssertNil(Provenance.parse(sources: nil, quarantine: nil))
        XCTAssertEqual(Provenance.parse(sources: ["https://github.com/x/y/releases/a.zip", "https://github.com/x/y"],
                                        quarantine: "0083;65f1c2a0;Safari;4E1C")?.sentence, "Downloaded from github.com")
        XCTAssertEqual(Provenance.parse(sources: nil, quarantine: "0083;65f1c2a0;sharingd;")?.sentence, "Received with AirDrop")
        XCTAssertEqual(Provenance.parse(sources: [], quarantine: "0083;65f1c2a0;Mail;")?.sentence, "Saved from Mail")
        XCTAssertEqual(Provenance.parse(sources: nil, quarantine: "0083;65f1c2a0;Google Chrome;")?.sentence, "Downloaded with Google Chrome")
    }

    func testShellHistory() {
        XCTAssertEqual(ShellHistory.commandNames(in: "sudo FOO=1 /opt/homebrew/bin/ffmpeg -i in.mov out.mp4 | grep x && make"),
                       ["ffmpeg", "grep", "make"])
        let box = Sandbox()
        box.text("home/.zsh_history", ": 1700000000:0;rg TODO\n: 1700000001:0;git status\n")
        box.text("home/.bash_history", "jq . data.json\n")
        XCTAssertTrue(ShellHistory.commands(home: box.path("home")).isSuperset(of: ["rg", "git", "jq"]))
    }

    func testHomebrewDependenciesYourOwnToolsUse() {
        XCTAssertEqual(Homebrew.baseName("python@3.12"), "python")
        XCTAssertTrue(Homebrew.linkedOutsideHomebrew.contains(Homebrew.baseName("openssl@3")))
        XCTAssertFalse(Homebrew.linkedOutsideHomebrew.contains("libnghttp2"))
        let box = Sandbox()
        box.file("Cellar/ffmpeg/7.0/bin/ffmpeg")
        box.file("Cellar/ffmpeg/7.0/bin/ffprobe")
        XCTAssertEqual(Set(Homebrew.executables("ffmpeg", cellar: box.path("Cellar"))), ["ffmpeg", "ffprobe"])
    }

    func testDockerImagesBuiltHere() {
        let text = #"{"ID":"abc","Repository":"myapp","Tag":"latest","Size":"1.2GB","CreatedSince":"2 days ago","Digest":"<none>"}"#
            + "\n" + #"{"ID":"def","Repository":"postgres","Tag":"16","Size":"400MB","CreatedSince":"3 weeks ago","Digest":"sha256:0123"}"#
        XCTAssertEqual(Docker.parseImages(text).map(\.builtLocally), [true, false])
    }

    func testTemporaryFolderActivityLooksInside() throws {
        let box = Sandbox()
        let folder = box.dir("job")
        box.file("job/deep/inner/output.log")
        let old = Date().addingTimeInterval(-10 * 86_400)
        for path in [folder, box.path("job/deep"), box.path("job/deep/inner")] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        let activity = JunkScanners.latestActivity([folder])
        XCTAssertEqual(activity?.complete, true)
        XCTAssertGreaterThan(activity?.date ?? .distantPast, Date().addingTimeInterval(-3600), "a fresh file deep inside counts")
    }

    func testOldJetBrainsSettingsWithScratchFilesAreNotSafe() async {
        let box = Sandbox()
        box.file("home/Library/Application Support/JetBrains/IntelliJIdea2023.2/options/x.xml")
        box.file("home/Library/Application Support/JetBrains/IntelliJIdea2023.2/scratches/scratch.kts")
        box.file("home/Library/Application Support/JetBrains/IntelliJIdea2024.1/options/x.xml")
        box.file("home/Library/Application Support/JetBrains/PyCharm2023.1/options/x.xml")
        box.file("home/Library/Application Support/JetBrains/PyCharm2024.2/options/x.xml")
        let ide = await run("ide", context(box))
        XCTAssertEqual(ide.items.first { $0.title == "IntelliJIdea 2023.2 settings" }?.risk, .review)
        XCTAssertEqual(ide.items.first { $0.title == "PyCharm 2023.1 settings" }?.risk, .safe)
    }

    #if os(macOS)
    func testEditedMailAttachmentsAreNoticed() throws {
        let box = Sandbox()
        let edited = box.dir("Mail Downloads/7B1F")
        box.file("Mail Downloads/7B1F/Contract.docx")
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: edited)
        box.file("Mail Downloads/9C2D/Invoice.pdf")
        XCTAssertEqual(FileScanners.editedAttachments(box.path("Mail Downloads")), ["Contract.docx"])
    }
    #endif

    // MARK: Removal

    func testRemoverNeverRemovesTheLastCopy() async {
        let box = Sandbox()
        let keep = box.file("home/Documents/a.bin", bytes: 4096)
        let copy = box.file("home/Downloads/a.bin", bytes: 4096)
        let remover = Remover(home: box.path("home"), shell: Shell(home: box.path("home")))
        let duplicate = Item(categoryID: "duplicates", title: "a.bin", risk: .review, note: "", paths: [copy], keepPath: keep)
        let original = Item(categoryID: "largeFiles", title: "a.bin", risk: .review, note: "", paths: [keep])
        let both = await remover.remove([duplicate, original], options: RemovalOptions(useTrash: false))
        XCTAssertNotNil(both.failures[duplicate.id])
        XCTAssertTrue(FS.exists(copy), "one copy always stays")

        let alone = Item(categoryID: "duplicates", title: "a.bin", risk: .review, note: "", paths: [copy], keepPath: keep)
        let afterwards = await remover.remove([alone], options: RemovalOptions(useTrash: false))
        XCTAssertNotNil(afterwards.failures[alone.id], "its kept copy is gone, so this is the only copy now")
        XCTAssertTrue(FS.exists(copy))

        let kept = box.file("home/Documents/b.bin", bytes: 4096)
        let extra = box.file("home/Downloads/b.bin", bytes: 4096)
        let fine = Item(categoryID: "duplicates", title: "b.bin", risk: .review, note: "", paths: [extra], keepPath: kept)
        let done = await remover.remove([fine], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(done.removed, [fine.id])
        XCTAssertFalse(FS.exists(extra))
        XCTAssertTrue(FS.exists(kept))
    }
}
