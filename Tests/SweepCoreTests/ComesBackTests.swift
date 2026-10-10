import XCTest
@testable import SweepCore

/// Files that something still running puts straight back after they're removed.
final class ComesBackTests: XCTestCase {
    func testParsesProcessList() {
        let text = """
            1 /sbin/launchd
          512 /Applications/Foo Bar.app/Contents/MacOS/Foo Bar
           77 kernel_task
        """
        let processes = RunningSoftware.parseProcesses(text)
        XCTAssertEqual(processes, [RunningProcess(pid: 1, path: "/sbin/launchd"),
                                   RunningProcess(pid: 512, path: "/Applications/Foo Bar.app/Contents/MacOS/Foo Bar")])
    }

    func testParsesSystemExtensions() {
        // Real output from a Mac whose Malwarebytes and AVG apps had been deleted.
        let text = """
        4 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tXSJ59WMJBM\tcom.avg.Antivirus.SystemExtension (16.2.674/16.2.674)\tAVG Antivirus\t[terminated waiting to uninstall on reboot]
        *\t*\tJ6S6Q257EK\tch.protonvpn.mac.WireGuard-Extension (6.5.1/3106797.2605011144)\tProton VPN WireGuard\t[activated enabled]
        *\t*\tJ6S6Q257EK\tch.protonvpn.mac.Transparent-Proxy (6.5.1/3106797.2605011144)\tProton VPN Split Tunneling (experimental)\t[activated enabled]
        --- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions > Endpoint Security Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tGVZRY6KDKR\tcom.malwarebytes.mbam.engine.sys.ext (5.27.1/5.27.1.4191)\tMalwarebytes Engine\t[terminated waiting to uninstall on reboot]
        """
        let extensions = RunningSoftware.parseSystemExtensions(text)
        XCTAssertEqual(extensions.map(\.bundleID), ["com.avg.Antivirus.SystemExtension", "ch.protonvpn.mac.WireGuard-Extension",
                                                    "ch.protonvpn.mac.Transparent-Proxy", "com.malwarebytes.mbam.engine.sys.ext"])
        XCTAssertEqual(extensions.map(\.isRunning), [false, true, true, false])
        XCTAssertEqual(extensions.map(\.removedOnRestart), [true, false, false, true])
        XCTAssertEqual(extensions[2].name, "Proton VPN Split Tunneling (experimental)")
        XCTAssertEqual(extensions[3].teamID, "GVZRY6KDKR")

        // Extensions macOS has already stopped can't put files back, so they aren't blamed for them.
        let running = RunningSoftware(systemExtensions: extensions)
        XCTAssertTrue(running.extensions { AppScanners.identifier($0, isNamed: "malwarebytes") }.isEmpty)
        XCTAssertEqual(running.extensions { AppScanners.identifier($0, isNamed: "protonvpn") }.count, 2)
    }

    func testFindsWhatIsStillRunning() {
        let running = RunningSoftware(
            processes: [RunningProcess(pid: 10, path: "/Library/Application Support/Zap/Helper.app/Contents/MacOS/Helper"),
                        RunningProcess(pid: 11, path: "/Library/Application Support/Zapper/agent")],
            systemExtensions: [SystemExtensionInfo(teamID: "T", bundleID: "com.zap.mac.sysext", name: "Zap Shield",
                                                   state: "[activated enabled]", isRunning: true)]
        )
        let programs = running.programs(inside: ["/Library/Application Support/Zap"])
        XCTAssertEqual(programs.map(\.name), ["Helper"], "a folder with a similar name doesn't count")
        XCTAssertTrue(running.programs(inside: ["/Library/Application Support/Zap"],
                                       except: ["/Library/Application Support/Zap/Helper.app/Contents/MacOS/Helper"]).isEmpty)
        let extensions = running.extensions { AppScanners.sameProduct($0, "com.zap.mac.app") }
        XCTAssertEqual(extensions.map(\.name), ["Zap Shield"])
        XCTAssertTrue(running.isActive(extensions[0]))
        XCTAssertFalse(RunningSoftware().isActive(extensions[0]))

        let advice = RemovalPlan.comesBack(programs + extensions)
        XCTAssertTrue(advice.contains("Zap Shield"))
        XCTAssertTrue(advice.contains("Helper"))
        XCTAssertFalse(RemovalPlan.comesBack([]).isEmpty)
    }

    func testOwnershipRules() {
        XCTAssertTrue(AppScanners.sameProduct("com.malwarebytes.mbam.frontend", "com.malwarebytes.mbam.rtprotection.daemon"))
        XCTAssertFalse(AppScanners.sameProduct("com.google.Chrome", "com.google.keystone.agent"))
        XCTAssertTrue(AppScanners.identifier("com.malwarebytes.mbam.sysext", isNamed: "malwarebytes"))
        XCTAssertFalse(AppScanners.identifier("com.malwarebytes.mbam.sysext", isNamed: "com"), "too short to trust")
        XCTAssertFalse(AppScanners.identifier("com.example.helper", isNamed: "malwarebytes"))
    }

    func testReportsFilesThatComeStraightBack() async {
        let box = Sandbox()
        let folder = box.file("home/Library/Application Support/Zap/log.txt")
        let support = FS.parent(folder)
        let cache = box.file("home/Library/Caches/com.zap/data")
        let leftover = Item(id: "zap", categoryID: "leftovers", title: "Zap", risk: .review, note: "", paths: [support])
        let rebuilt = Item(id: "cache", categoryID: "userCaches", title: "Zap cache", risk: .safe, note: "",
                           paths: [FS.parent(cache)])
        // Stands in for a background helper that writes its files again as soon as they're gone.
        let remover = Remover(home: box.path("home")) { message in
            guard message.hasPrefix("Checking") else { return }
            for path in [folder, cache] {
                try? FileManager.default.createDirectory(atPath: FS.parent(path), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: path, contents: Data("again".utf8))
            }
        }
        let outcome = await remover.remove([leftover, rebuilt], options: RemovalOptions(useTrash: false, recheckDelay: 0))
        XCTAssertEqual(Set(outcome.removed), ["zap", "cache"])
        XCTAssertEqual(outcome.cameBack, ["zap": [support]], "caches rated Safe are rebuilt by design and not reported")
    }

    func testNothingReportedWhenFilesStayGone() async {
        let box = Sandbox()
        let folder = FS.parent(box.file("home/Library/Application Support/Gone/data"))
        let item = Item(categoryID: "leftovers", title: "Gone", risk: .review, note: "", paths: [folder])
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: false, recheckDelay: 0))
        XCTAssertEqual(outcome.removed, [item.id])
        XCTAssertTrue(outcome.cameBack.isEmpty)
    }

    func testAppUninstallIncludesHelpersThatRunFromIt() {
        let box = Sandbox()
        let home = box.path("home")
        let app = box.dir("home/Applications/Zap.app")
        box.file("home/Library/Application Support/Zap/db")
        let helper = home + "/Library/LaunchAgents/org.differently.named.plist"
        box.plist("home/Library/LaunchAgents/org.differently.named.plist",
                  ["Label": "org.differently.named",
                   "ProgramArguments": [home + "/Library/Application Support/Zap/Helper.app/Contents/MacOS/Helper", "--run"]])
        box.plist("home/Library/LaunchAgents/org.unrelated.plist", ["Label": "org.unrelated", "Program": "/usr/local/bin/other"])
        box.plist("home/Applications/Zap.app/Contents/Library/LaunchDaemons/com.zap.app.daemon.plist",
                  ["Label": "com.zap.app.daemon", "BundleProgram": "Contents/MacOS/zapd"])

        let found = AppScanners.LibraryIndex(home: home).leftovers(bundleID: "com.zap.app", appName: "Zap", appPath: app)
        XCTAssertTrue(found.contains(home + "/Library/Application Support/Zap"))
        XCTAssertTrue(found.contains(helper))
        XCTAssertFalse(found.contains(home + "/Library/LaunchAgents/org.unrelated.plist"))

        let bundled = Launchd.bundledJobs(in: app)
        XCTAssertEqual(bundled.map(\.label), ["com.zap.app.daemon"])
        XCTAssertEqual(bundled.first?.program, app + "/Contents/MacOS/zapd")
        XCTAssertEqual(bundled.first?.isDaemon, true)

        let steps = Launchd.stopSteps(found.filter(Launchd.isJobPlist).compactMap(Launchd.read) + bundled, uid: 501)
        XCTAssertEqual(steps, [
            .run(ShellCommand("/bin/launchctl", ["bootout", "gui/501/org.differently.named"], allowFailure: true)),
            .runAsAdmin(ShellCommand("/bin/launchctl", ["bootout", "system/com.zap.app.daemon"], allowFailure: true)),
        ])
    }

    func testLeftoversTakeTheirBackgroundJobsAlong() async {
        let box = Sandbox()
        let home = box.path("home")
        box.plist("home/Library/Preferences/com.gone.app.plist", ["a": 1])
        box.plist("home/Library/LaunchAgents/com.gone.app.updater.plist",
                  ["Label": "com.gone.app.updater", "ProgramArguments": ["/nowhere/updater"]])
        box.file("home/Library/Application Support/Zappo Sync/state.db", bytes: 4000)
        box.plist("home/Library/LaunchAgents/net.example.helper.plist",
                  ["Label": "net.example.helper", "Program": home + "/Library/Application Support/Zappo Sync/helper"])
        box.plist("home/Library/LaunchAgents/com.gone.other.plist", ["Label": "com.gone.other", "Program": "/nowhere/other"])

        let ctx = ScanContext(settings: ScanSettings(home: home), shell: Shell(home: home))
        let leftovers = await Catalog.scanner("leftovers")!.scan(ctx)

        let gone = leftovers.items.first { $0.title == "com.gone.app" }
        XCTAssertEqual(gone?.paths.sorted(), [home + "/Library/LaunchAgents/com.gone.app.updater.plist",
                                              home + "/Library/Preferences/com.gone.app.plist"])
        XCTAssertEqual(gone?.steps.first,
                       .run(ShellCommand("/bin/launchctl", ["bootout", "gui/\(ctx.uid)/com.gone.app.updater"], allowFailure: true)),
                       "the job is stopped before its files are removed")

        let zappo = leftovers.items.first { $0.title == "Zappo Sync" }
        XCTAssertTrue(zappo?.paths.contains(home + "/Library/LaunchAgents/net.example.helper.plist") ?? false,
                      "a job that runs a program from the leftover folder goes with it")
        XCTAssertFalse(leftovers.items.contains { $0.paths.contains(home + "/Library/LaunchAgents/com.gone.other.plist") },
                       "only the same product's jobs are taken along")
    }
}
