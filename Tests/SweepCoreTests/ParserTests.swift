import XCTest
@testable import SweepCore

final class ParserTests: XCTestCase {
    func testHomebrewInfo() throws {
        let json = """
        {"formulae":[
          {"name":"wget","full_name":"wget","tap":"homebrew/core","desc":"Internet file retriever","pinned":false,"outdated":true,
           "installed":[{"version":"1.24.5","installed_on_request":true,"installed_as_dependency":false,"time":1700000000,
                         "runtime_dependencies":[{"full_name":"openssl@3"},{"full_name":"libidn2"}]}]},
          {"name":"openssl@3","full_name":"openssl@3","desc":"TLS","installed":[{"version":"3.3.0","installed_on_request":false,"installed_as_dependency":true,"runtime_dependencies":[]}]},
          {"name":"libunused","full_name":"libunused","desc":"","installed":[{"version":"1","installed_on_request":false,"installed_as_dependency":true}]}
        ],
        "casks":[{"token":"firefox","full_token":"firefox","tap":"homebrew/cask","name":["Mozilla Firefox"],"desc":"Browser",
                  "installed":"125.0","installed_time":1700000000,"auto_updates":true,
                  "artifacts":[{"app":["Firefox.app"]},{"zap":[{"trash":["~/Library/x"]}]}]},
                 {"token":"renamed","name":["Renamed"],"artifacts":[{"app":["Orig.app",{"target":"Nice Name.app"}]}]}]}
        """
        let parsed = try XCTUnwrap(Homebrew.parseInfo(Data(json.utf8)))
        XCTAssertEqual(parsed.formulae.map(\.name), ["wget", "openssl@3", "libunused"])
        XCTAssertTrue(parsed.formulae[0].onRequest)
        XCTAssertTrue(parsed.formulae[0].outdated)
        XCTAssertEqual(parsed.formulae[0].runtimeDependencies, ["openssl@3", "libidn2"])
        XCTAssertEqual(parsed.casks.first?.apps, ["Firefox.app"])
        XCTAssertEqual(parsed.casks.first?.name, "Mozilla Firefox")
        XCTAssertEqual(parsed.casks.last?.apps, ["Nice Name.app"])
        let dependents = Homebrew.dependents(parsed.formulae)
        XCTAssertEqual(dependents["openssl@3"], ["wget"])
        XCTAssertNil(dependents["libunused"])
    }

    func testHomebrewCleanupAndTaps() {
        let text = """
        Would remove: /opt/homebrew/Cellar/node/20.1.0 (2,000 files, 60MB)
        Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--x.tar.gz (12MB)
        ==> This operation would free approximately 72.5MB of disk space.
        """
        let (bytes, count) = Homebrew.parseCleanup(text)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(bytes, 72_500_000)
        let taps = Homebrew.parseTaps(Data(#"[{"name":"homebrew/core","path":"/opt/homebrew/Library/Taps/homebrew/homebrew-core","installed":true,"formula_names":["a","b"],"cask_tokens":[]},{"name":"x/y","path":"/p","installed":false}]"#.utf8))
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0].formulaCount, 2)
    }

    func testDockerParsing() {
        let images = """
        {"Containers":"N/A","CreatedSince":"3 months ago","ID":"abc123","Repository":"node","Size":"1.1GB","Tag":"20"}
        {"ID":"def456","Repository":"<none>","Size":"512MB","Tag":"<none>","CreatedSince":"1 year ago"}
        not json
        """
        let parsed = Docker.parseImages(images)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].size, 1_100_000_000)
        XCTAssertTrue(parsed[1].dangling)
        let containers = Docker.parseContainers(#"{"ID":"c1","Names":"web","Image":"nginx","Status":"Exited (0) 2 days ago","Size":"12.3kB (virtual 1.2GB)"}"#)
        XCTAssertEqual(containers.first?.size, 12_300)
        let df = """
        {"Active":"1","Reclaimable":"10MB (5%)","Size":"200MB","TotalCount":"3","Type":"Images"}
        {"Active":"0","Reclaimable":"2.5GB","Size":"2.5GB","TotalCount":"40","Type":"Build Cache"}
        """
        XCTAssertEqual(Docker.parseBuildCache(df), 2_500_000_000)
    }

    func testMiscParsers() {
        let ollama = """
        NAME              ID              SIZE      MODIFIED
        llama3:latest     365c0bd3c000    4.7 GB    3 weeks ago
        qwen2.5:7b        845dbda0ea48    4.7 GB    2 days ago
        """
        let models = DevScanners.parseOllamaList(ollama)
        XCTAssertEqual(models.map(\.name), ["llama3:latest", "qwen2.5:7b"])
        XCTAssertEqual(models[0].size, 4_700_000_000)

        let snaps = JunkScanners.parseSnapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2024-05-01-101010.local\ncom.apple.os.update-ABC\n")
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].date, "2024-05-01-101010")

        let ports = MacPorts.parseInstalled("The following ports are currently installed:\n  zlib @1.3.1_0 (active)\n  zlib @1.2.13_0\n  python312 @3.12.2_0+lto+optimizations (active)\n")
        XCTAssertEqual(ports.count, 3)
        XCTAssertTrue(ports[0].active)
        XCTAssertFalse(ports[1].active)
        XCTAssertEqual(ports[2].version, "3.12.2_0+lto+optimizations")

        XCTAssertEqual(DevScanners.parseExtensionFolder("ms-python.python-2024.2.1")?.id, "ms-python.python")
        XCTAssertEqual(DevScanners.parseExtensionFolder("ms-vscode.cpptools-1.19.9-darwin-arm64")?.version, "1.19.9-darwin-arm64")
        XCTAssertEqual(DevScanners.parseExtensionFolder("dbaeumer.vscode-eslint-3.0.10")?.id, "dbaeumer.vscode-eslint")
        XCTAssertNil(DevScanners.parseExtensionFolder("extensions.json"))

        XCTAssertEqual(DevScanners.parseJetBrainsFolder("IntelliJIdea2023.2")?.product, "IntelliJIdea")
        XCTAssertEqual(DevScanners.parseJetBrainsFolder("PyCharmCE2024.1")?.version, "2024.1")
        XCTAssertNil(DevScanners.parseJetBrainsFolder("Toolbox"))
        XCTAssertNil(DevScanners.parseJetBrainsFolder("consentOptions"))

        XCTAssertEqual(DevScanners.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-17-2"), "iOS 17.2")
        XCTAssertEqual(DevScanners.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-10-0"), "watchOS 10.0")

        let devices = DevScanners.parseSimDevices(Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[{"udid":"U1","name":"iPhone 15","state":"Shutdown","isAvailable":false,"lastBootedAt":"2024-01-05T12:34:56Z"}]}}"#.utf8))
        XCTAssertEqual(devices.first?.runtime, "iOS 17.0")
        XCTAssertEqual(devices.first?.available, false)
        XCTAssertNotNil(devices.first?.lastBooted)

        let crates = DevScanners.parseCrates(Data(#"{"installs":{"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)":{"bins":["rg"]}}}"#.utf8))
        XCTAssertEqual(crates.first?.name, "ripgrep")
        XCTAssertEqual(crates.first?.bins, ["rg"])

        let vdf = AppScanners.parseVDF("\"AppState\"\n{\n\t\"appid\"\t\t\"570\"\n\t\"name\"\t\t\"Dota 2\"\n\t\"installdir\"\t\t\"dota 2 beta\"\n}\n")
        XCTAssertEqual(vdf.first { $0.0 == "name" }?.1, "Dota 2")
        XCTAssertEqual(vdf.first { $0.0 == "installdir" }?.1, "dota 2 beta")
    }

    func testKnownSoftwareMatching() {
        let known = KnownSoftware(bundleIDs: ["com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.vendor.app"],
                                  names: ["Visual Studio Code", "Slack"])
        XCTAssertTrue(known.matches(bundleLike: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(known.matches(bundleLike: "com.tinyspeck.slackmacgap.helper"))
        XCTAssertTrue(known.matches(bundleLike: "com.vendor.app-helper"))
        XCTAssertTrue(known.matches(bundleLike: "com.microsoft.vscode.ShipIt"))
        XCTAssertFalse(known.matches(bundleLike: "com.gone.app"))
        XCTAssertFalse(known.matches(bundleLike: "com.vendor.otherapp"))
        XCTAssertTrue(known.vendorInstalled("com.vendor.otherapp"))
        XCTAssertTrue(known.matches(name: "Code"))
        XCTAssertTrue(known.matches(name: "Slack"))
        XCTAssertFalse(known.matches(name: "Zoombinis"))
    }

    func testLeftoverOwnerIDs() {
        XCTAssertEqual(AppScanners.ownerID(for: "com.foo.bar.plist", in: "Preferences"), "com.foo.bar")
        XCTAssertNil(AppScanners.ownerID(for: "com.foo.bar.lockfile", in: "Preferences"))
        XCTAssertEqual(AppScanners.ownerID(for: "com.foo.bar.0A1B2C3D-1111-2222-3333-444455556666.plist", in: "ByHost"), "com.foo.bar")
        XCTAssertEqual(AppScanners.ownerID(for: "group.com.foo.shared", in: "Group Containers"), "com.foo.shared")
        XCTAssertEqual(AppScanners.ownerID(for: "ABCDE12345.com.foo.app", in: "Group Containers"), "com.foo.app")
        XCTAssertEqual(AppScanners.ownerID(for: "com.foo.app.binarycookies", in: "Cookies"), "com.foo.app")
        XCTAssertTrue(AppScanners.isAppleOwned("com.apple.Safari"))
        XCTAssertTrue(AppScanners.isAppleOwned("group.com.apple.notes"))
        XCTAssertFalse(AppScanners.isAppleOwned("com.spotify.client"))
        XCTAssertTrue(AppScanners.looksLikeBundleID("com.spotify.client"))
        XCTAssertFalse(AppScanners.looksLikeBundleID("Google Chrome"))
        XCTAssertEqual(AppScanners.installRoot("/Applications/Foo.app/Contents/MacOS/foo"), "/Applications/Foo.app")
        XCTAssertEqual(AppScanners.installRoot("/usr/local/bin/foo"), "/usr/local/bin")
    }

    func testArtifactRules() {
        let box = Sandbox()
        box.text("rusty/Cargo.toml", "[package]")
        box.text("web/package.json", "{}")
        XCTAssertEqual(ArtifactRules.match(name: "target", parent: box.path("rusty"))?.label, "Rust build output")
        XCTAssertNil(ArtifactRules.match(name: "target", parent: box.path("web")))
        XCTAssertNotNil(ArtifactRules.match(name: ".next", parent: box.path("web")))
        XCTAssertNil(ArtifactRules.match(name: "build", parent: box.path("web")))
        XCTAssertEqual(ArtifactRules.match(name: "node_modules", parent: box.path("web"))?.risk, .review)
        XCTAssertNil(ArtifactRules.match(name: "src", parent: box.path("web")))
        box.file("node-v20/bin/node")
        box.dir("node-v20/lib/node_modules/npm")
        XCTAssertNil(ArtifactRules.match(name: "node_modules", parent: box.path("node-v20/lib")), "a Node install's npm is not a project folder")
    }
}
