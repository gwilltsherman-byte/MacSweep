import XCTest
@testable import SweepCore

final class ScannerTests: XCTestCase {
    func makeHome() -> Sandbox {
        let box = Sandbox()
        // Projects
        box.text("home/code/web/package.json", "{}")
        box.file("home/code/web/node_modules/left-pad/index.js", bytes: 8192)
        box.file("home/code/web/.next/cache/x", bytes: 4096)
        box.text("home/code/rusty/Cargo.toml", "[package]")
        box.file("home/code/rusty/target/debug/rusty", bytes: 20_000)
        box.file("home/code/py/pkg/__pycache__/a.pyc", bytes: 2048)
        box.file("home/code/py/__pycache__/b.pyc", bytes: 2048)
        box.text("home/code/py/.venv/pyvenv.cfg", "home = /usr/bin")
        box.file("home/code/py/.venv/lib/site.py", bytes: 4096)
        // Files
        box.file("home/Movies/big.mov", bytes: 300_000)
        box.file("home/Downloads/setup.dmg", bytes: 10_000)
        box.file("home/Documents/report.pdf", bytes: 50_000, fill: 0x42)
        box.file("home/Desktop/report copy.pdf", bytes: 50_000, fill: 0x42)
        box.file("home/Documents/other.pdf", bytes: 50_000, fill: 0x43)
        box.file("home/Documents/.DS_Store", bytes: 6148)
        box.file("home/.DS_Store", bytes: 6148)
        box.file("home/Library/Caches/huge-in-library.bin", bytes: 400_000)
        box.file("home/.hidden/big-hidden.bin", bytes: 400_000)
        try? FileManager.default.createSymbolicLink(atPath: box.path("home/Documents/dangling"),
                                                    withDestinationPath: box.path("home/nowhere"))
        // Library
        box.file("home/Library/Caches/com.example.app/cache.db", bytes: 10_000)
        box.file("home/Library/Logs/ExampleApp/log.txt", bytes: 1000)
        box.file("home/Library/Saved Application State/com.example.app.savedState/data", bytes: 1000)
        box.plist("home/Library/Preferences/com.gone.app.plist", ["a": 1])
        box.file("home/Library/Containers/com.gone.app/Data/Library/Caches/x", bytes: 5000)
        box.plist("home/Library/LaunchAgents/com.gone.agent.plist",
                  ["Label": "com.gone.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/agent"]])
        box.file("home/Library/Developer/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyz/Build/x", bytes: 9000)
        box.file("home/Library/Developer/Xcode/iOS DeviceSupport/17.2 (21C62)/Symbols/x", bytes: 9000)
        box.text("home/Library/Application Support/Code/User/workspaceStorage/abc123/workspace.json",
                 #"{"folder":"file:///definitely/not/here/proj"}"#)
        box.file("home/Library/Application Support/Code/User/workspaceStorage/abc123/state.vscdb", bytes: 3000)
        box.file("home/Library/Application Support/Slack/Code Cache/js/x", bytes: 3000)
        box.file("home/Library/Application Support/Slack/Cache/data", bytes: 3000)
        box.file("home/Library/Application Support/Slack/GPUCache/data", bytes: 3000)
        // Developer tools
        box.file("home/.nvm/versions/node/v18.17.0/bin/node", bytes: 5000)
        box.file("home/.nvm/versions/node/v20.11.0/bin/node", bytes: 5000)
        box.file("home/.npm/_cacache/index", bytes: 5000)
        box.file("home/.vscode/extensions/ms-python.python-2024.1.0/package.json", bytes: 1000)
        box.file("home/.vscode/extensions/ms-python.python-2024.2.0/package.json", bytes: 1000)
        box.file("home/.cargo/registry/cache/x.crate", bytes: 4000)
        box.file("home/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc", bytes: 4000)
        box.file("home/.rustup/toolchains/nightly-aarch64-apple-darwin/bin/rustc", bytes: 4000)
        box.text("home/.rustup/settings.toml", "default_toolchain = \"stable-aarch64-apple-darwin\"\n")
        box.file("home/.gradle/caches/x", bytes: 4000)
        box.file("home/.cache/pip/http/x", bytes: 4000)
        box.file("home/.cache/huggingface/hub/models--meta--llama/blobs/x", bytes: 4000)
        box.file("home/.Trash/old thing.txt", bytes: 4000)
        box.file("home/.android/avd/Pixel.avd/userdata.img", bytes: 4000)
        box.text("home/.android/avd/Pixel.ini", "path=...")
        box.file("home/Library/Fonts/Roboto-Regular.ttf", bytes: 4000)
        box.file("home/Library/Fonts/Roboto-Bold.ttf", bytes: 4000)
        box.file("home/Library/Application Support/MobileSync/Backup/abc/Manifest.db", bytes: 4000)
        box.plist("home/Library/Application Support/MobileSync/Backup/abc/Info.plist",
                  ["Device Name": "Test iPhone", "Product Name": "iPhone 15", "Product Version": "17.4"])
        return box
    }

    func context(_ box: Sandbox) -> ScanContext {
        ScanContext(settings: ScanSettings(home: box.path("home"), largeFileThreshold: 200_000, oldDownloadDays: 90,
                                           duplicateMinSize: 10_000, selfBundleID: nil),
                    shell: Shell(home: box.path("home")))
    }

    func run(_ id: String, _ ctx: ScanContext) async -> ScanResult {
        await Catalog.scanner(id)!.scan(ctx)
    }

    func titles(_ result: ScanResult) -> [String] { result.items.map(\.title) }

    func testEveryScannerRunsOnAFakeHome() async {
        let box = makeHome()
        let ctx = context(box)
        for scanner in Catalog.all {
            let result = await scanner.scan(ctx)
            for item in result.items {
                XCTAssertEqual(item.categoryID, scanner.category.id)
                for path in item.steps.flatMap(\.paths) {
                    XCTAssertNil(Safety.refusal(for: path, home: ctx.home), "\(scanner.category.id) offered a protected path \(path)")
                }
            }
            let ids = result.items.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate item ids in \(scanner.category.id)")
        }
    }

    func testHomeWalkFindings() async {
        let box = makeHome()
        let ctx = context(box)
        let projects = await run("projects", ctx)
        XCTAssertEqual(Set(titles(projects)), ["web › node_modules", "web › .next", "rusty › target", "py › .venv",
                                               "Python bytecode caches (2 folders)"])
        XCTAssertEqual(projects.items.first { $0.title == "rusty › target" }?.risk, .safe)

        let large = await run("largeFiles", ctx)
        XCTAssertEqual(titles(large), ["big.mov"], "Library and hidden folders are skipped")

        let installers = await run("installers", ctx)
        XCTAssertEqual(titles(installers), ["setup.dmg"])

        let duplicates = await run("duplicates", ctx)
        XCTAssertEqual(duplicates.items.count, 1)
        XCTAssertNotNil(duplicates.items.first?.keepPath)
        XCTAssertNotEqual(duplicates.items.first?.keepPath, duplicates.items.first?.paths.first)

        let clutter = await run("clutter", ctx)
        XCTAssertTrue(titles(clutter).contains(".DS_Store files (2)"))
        XCTAssertTrue(titles(clutter).contains("dangling"))
        XCTAssertTrue(clutter.items.allSatisfy { item in item.steps.allSatisfy { if case .deleteForever = $0 { return true } else { return false } } })
    }

    func testNodeInstallationsAreLeftAlone() async {
        let box = Sandbox()
        box.file("home/tools/node-v20/bin/node", bytes: 5000)
        box.file("home/tools/node-v20/lib/node_modules/npm/node_modules/abbrev/index.js", bytes: 5000)
        box.file("home/tools/node-v20/lib/node_modules/npm/package.json", bytes: 100)
        box.text("home/code/app/package.json", "{}")
        box.file("home/code/app/node_modules/left-pad/index.js", bytes: 5000)
        box.file("home/code/app/node_modules/left-pad/node_modules/inner/index.js", bytes: 5000)
        let projects = await run("projects", context(box))
        XCTAssertEqual(titles(projects), ["app › node_modules"], "npm's own files and nested node_modules must not be listed")
    }

    func testLibraryScanners() async {
        let box = makeHome()
        let ctx = context(box)
        let caches = await run("userCaches", ctx)
        XCTAssertTrue(titles(caches).contains("com.example.app"))

        let hidden = await run("appCaches", ctx)
        let hiddenTitles = Set(titles(hidden))
        XCTAssertTrue(hiddenTitles.contains("Slack › Code Cache"))
        XCTAssertTrue(hiddenTitles.contains("Slack › Cache"))
        XCTAssertTrue(hiddenTitles.contains("com.gone.app · sandbox cache"))

        let leftovers = await run("leftovers", ctx)
        let gone = leftovers.items.first { $0.title == "com.gone.app" }
        XCTAssertNotNil(gone)
        XCTAssertEqual(gone?.paths.count, 2, "prefs and container are grouped into one item")

        let launch = await run("launchItems", ctx)
        let agent = launch.items.first { $0.title == "com.gone.agent" }
        XCTAssertEqual(agent?.risk, .safe)
        XCTAssertTrue(agent?.badges.contains("Broken") ?? false)

        let xcode = await run("xcode", ctx)
        XCTAssertTrue(titles(xcode).contains("MyApp build data"))
        XCTAssertTrue(titles(xcode).contains("iOS device support 17.2 (21C62)"))

        let ide = await run("ide", ctx)
        XCTAssertTrue(titles(ide).contains("VS Code state for proj"))
        XCTAssertEqual(ide.items.first { $0.title == "ms-python.python 2024.1.0" }?.risk, .safe)
        XCTAssertEqual(ide.items.first { $0.title == "ms-python.python 2024.2.0" }?.risk, .review)

        let trash = await run("trash", ctx)
        XCTAssertEqual(titles(trash), ["old thing.txt"])

        let fonts = await run("fonts", ctx)
        XCTAssertEqual(fonts.items.first?.title, "Roboto")
        XCTAssertEqual(fonts.items.first?.paths.count, 2)

        let backups = await run("backups", ctx)
        XCTAssertEqual(titles(backups), ["Test iPhone backup"])
    }

    func testDeveloperScanners() async {
        let box = makeHome()
        let ctx = context(box)
        let node = await run("node", ctx)
        XCTAssertTrue(titles(node).contains("Node.js v18.17.0"))
        XCTAssertTrue(titles(node).contains("npm cache"))

        let rust = await run("rust", ctx)
        XCTAssertEqual(rust.items.first { $0.title == "Rust toolchain stable-aarch64-apple-darwin" }?.risk, .caution)
        XCTAssertEqual(rust.items.first { $0.title == "Rust toolchain nightly-aarch64-apple-darwin" }?.risk, .review)

        let jvm = await run("jvm", ctx)
        XCTAssertTrue(titles(jvm).contains("Gradle caches"))
        let avd = jvm.items.first { $0.title == "Emulator Pixel" }
        XCTAssertEqual(avd?.paths.count, 2)

        let xdg = await run("xdgCache", ctx)
        XCTAssertEqual(titles(xdg), ["pip"], "AI model caches are left to the AI category")

        let ai = await run("ai", ctx)
        XCTAssertTrue(titles(ai).contains("Hugging Face model: meta/llama"))
    }
}
