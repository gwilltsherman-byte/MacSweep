import XCTest
@testable import SweepCore

final class BasicsTests: XCTestCase {
    func testPathHelpers() {
        XCTAssertEqual(FS.join("/", "Applications", "Foo.app"), "/Applications/Foo.app")
        XCTAssertEqual(FS.join(["/", "/Library/", "/x"]), "/Library/x")
        XCTAssertEqual(FS.name("/a/b/c.txt"), "c.txt")
        XCTAssertEqual(FS.parent("/a/b/c.txt"), "/a/b")
        XCTAssertEqual(FS.parent("/a"), "/")
        XCTAssertEqual(FS.ext("Archive.TAR.GZ"), "gz")
        XCTAssertEqual(FS.ext(".bashrc"), "")
        XCTAssertEqual(FS.stripExt("Foo.app"), "Foo")
        XCTAssertTrue(FS.versionLess("9.12", "10.2"))
        XCTAssertTrue(FS.versionLess("v18.17.0", "v20.1.0"))
    }

    func testSizeParser() {
        XCTAssertEqual(SizeParser.parse("1.5GB"), 1_500_000_000)
        XCTAssertEqual(SizeParser.parse("512 MB"), 512_000_000)
        XCTAssertEqual(SizeParser.parse("3.4kB"), 3_400)
        XCTAssertEqual(SizeParser.parse("2GiB"), 2_147_483_648)
        XCTAssertEqual(SizeParser.parse("0B"), 0)
        XCTAssertNil(SizeParser.parse("lots"))
    }

    func testUniqueTotalSkipsNestedPaths() {
        let outer = Item(categoryID: "a", title: "outer", size: 100, risk: .safe, note: "", paths: ["/x/cache"])
        let inner = Item(categoryID: "b", title: "inner", size: 40, risk: .safe, note: "", paths: ["/x/cache/sub"])
        let other = Item(categoryID: "c", title: "other", size: 7, risk: .safe, note: "", paths: ["/y"])
        let command = Item(id: "cmd", categoryID: "d", title: "cmd", size: 3, risk: .safe, note: "")
        XCTAssertEqual(SizeMath.uniqueTotal([inner, outer, other, command]), 110)
        XCTAssertEqual(SizeMath.uniqueTotal([inner]), 40)
    }

    func testDiskUsageCountsHardLinksOnceAndSkipsSymlinks() throws {
        let box = Sandbox()
        let a = box.file("tree/a.bin", bytes: 64 * 1024)
        box.file("tree/sub/b.bin", bytes: 64 * 1024)
        try FileManager.default.linkItem(atPath: a, toPath: box.path("tree/hardlink.bin"))
        box.file("elsewhere/huge.bin", bytes: 512 * 1024)
        try FileManager.default.createSymbolicLink(atPath: box.path("tree/link"), withDestinationPath: box.path("elsewhere"))
        let size = DiskUsage.allocatedSize(box.path("tree"))
        XCTAssertGreaterThanOrEqual(size, 128 * 1024)
        XCTAssertLessThan(size, 400 * 1024)
        XCTAssertEqual(DiskUsage.allocatedSize(box.path("missing")), 0)
    }

    func testCatalogIsConsistent() {
        let ids = Catalog.all.map(\.category.id)
        XCTAssertEqual(Set(ids).count, ids.count, "category ids must be unique")
        XCTAssertGreaterThanOrEqual(ids.count, 40)
        for section in SweepSection.allCases {
            XCTAssertTrue(Catalog.all.contains { $0.category.section == section })
        }
    }

    func testShellRunsAndTimesOut() async {
        let shell = Shell(home: NSHomeDirectory())
        let ok = await shell.run("/bin/sh", ["-c", "echo hello; echo oops >&2"])
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.stdout, "hello\n")
        XCTAssertEqual(ok.stderr, "oops\n")
        let fail = await shell.run("/bin/sh", ["-c", "exit 3"])
        XCTAssertEqual(fail.status, 3)
        let slow = await shell.run("/bin/sh", ["-c", "sleep 10"], timeout: 1)
        XCTAssertTrue(slow.timedOut)
        let missing = await shell.run("definitely-not-a-real-tool", [])
        XCTAssertEqual(missing.status, 127)
        XCTAssertEqual(Shell.quote("plain-word_1.2"), "plain-word_1.2")
        XCTAssertEqual(Shell.quote("it's here"), "'it'\\''s here'")
    }
}

final class RobustnessTests: XCTestCase {
    func testAbsurdBlockCountsDoNotTrap() {
        XCTAssertEqual(FileInfo.allocatedBytes(blocks: 8), 4096)
        XCTAssertEqual(FileInfo.allocatedBytes(blocks: -1), 0)
        XCTAssertEqual(FileInfo.allocatedBytes(blocks: Int64.max), FileInfo.maximumAllocation)
        XCTAssertEqual(DiskUsage.saturatingAdd(Int64.max, 10), Int64.max)
        XCTAssertEqual(DiskUsage.saturatingAdd(2, 3), 5)
        XCTAssertEqual(DuplicateFinder.wasted(DuplicateGroup(size: Int64.max / 2, paths: ["a", "b", "c", "d"])), Int64.max)
    }

    func testLongAndUnicodeFileNamesAreReadCorrectly() throws {
        let box = Sandbox()
        let long = String(repeating: "n", count: 250) + ".bin"
        box.file("tree/\(long)", bytes: 8192)
        box.file("tree/héllo wörld ✓.txt", bytes: 8192)
        box.file("tree/a", bytes: 8192)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: box.path("tree")))
        XCTAssertEqual(names, [long, "héllo wörld ✓.txt", "a"])
        // Every file must be found by name (a wrong name would make lstat fail and the size come out short).
        XCTAssertGreaterThanOrEqual(DiskUsage.allocatedSize(box.path("tree")), 3 * 8192)
    }

    func testContentHashMatchesContentAndHonoursLimit() {
        let box = Sandbox()
        let a = box.file("a.bin", bytes: 3_000_000, fill: 0x41)
        let b = box.file("b.bin", bytes: 3_000_000, fill: 0x41)
        let c = box.text("c.bin", String(repeating: "A", count: 65_536) + "different tail")
        XCTAssertNotNil(ContentHash.hash(a, limit: nil))
        XCTAssertEqual(ContentHash.hash(a, limit: nil), ContentHash.hash(b, limit: nil))
        XCTAssertEqual(ContentHash.hash(a, limit: 65_536), ContentHash.hash(c, limit: 65_536))
        XCTAssertNotEqual(ContentHash.hash(a, limit: nil), ContentHash.hash(c, limit: nil))
        XCTAssertNil(ContentHash.hash(box.path("missing"), limit: nil))
        XCTAssertEqual(ContentHash.hex([0x00, 0x0f, 0xa5, 0xff]), "000fa5ff")
    }
}

final class ExplanationTests: XCTestCase {
    func testEveryCategoryHasAPlainExplanation() {
        for scanner in Catalog.all {
            let help = scanner.category.help
            XCTAssertFalse(help.whatItIs.isEmpty, scanner.category.id)
            XCTAssertFalse(help.ifDeleted.isEmpty, "\(scanner.category.id) needs an 'if you delete it' explanation")
            XCTAssertLessThan(help.whatItIs.count, 260, "\(scanner.category.id): keep it short enough to read at a glance")
            XCTAssertLessThan(help.ifDeleted.count, 260, scanner.category.id)
        }
        XCTAssertEqual(Set(CategoryHelpText.all.keys), Set(Catalog.all.map(\.category.id)), "help texts and categories must match")
    }

    func testRecoveryExplainsHowToUndo() {
        let home = "/Users/me"
        let cache = Item(categoryID: "userCaches", title: "x", risk: .safe, note: "", paths: ["/Users/me/Library/Caches/x"])
        XCTAssertTrue(RemovalPlan.recovery(for: cache, useTrash: true, home: home).contains("put it back"))
        XCTAssertTrue(RemovalPlan.recovery(for: cache, useTrash: false, home: home).contains("can't be undone"))
        XCTAssertEqual(RemovalPlan.kinds(for: cache, useTrash: true), [.trash])

        let system = Item(categoryID: "systemCaches", title: "y", risk: .safe, note: "", paths: ["/Library/Caches/y"])
        XCTAssertTrue(RemovalPlan.recovery(for: system, useTrash: true, home: home).contains("administrator password"))

        let trashed = Item(categoryID: "trash", title: "z", risk: .safe, note: "", steps: [.deleteForever(["/Users/me/.Trash/z"])])
        XCTAssertTrue(RemovalPlan.recovery(for: trashed, useTrash: true, home: home).contains("deleted for good"))
        XCTAssertEqual(RemovalPlan.kinds(for: trashed, useTrash: true), [.permanent])

        let formula = Item(id: "f", categoryID: "brewFormulae", title: "wget", risk: .review, note: "",
                           steps: [.run(ShellCommand("/opt/homebrew/bin/brew", ["uninstall", "--formula"], targets: ["wget"], batchable: true))])
        XCTAssertTrue(RemovalPlan.recovery(for: formula, useTrash: true, home: home).contains("Homebrew uninstalls it"))
        XCTAssertEqual(RemovalPlan.kinds(for: formula, useTrash: true), [.uninstall])

        // Stopping a helper first (allowFailure) isn't mentioned; only the file removal is.
        let agent = Item(id: "a", categoryID: "launchItems", title: "agent", risk: .safe, note: "",
                         steps: [.run(ShellCommand("/bin/launchctl", ["bootout"], allowFailure: true)),
                                 .files(["/Users/me/Library/LaunchAgents/a.plist"])])
        XCTAssertEqual(RemovalPlan.recovery(for: agent, useTrash: true, home: home),
                       "It goes to the Trash, so you can put it back until you empty the Trash.")

        let receipt = Item(id: "r", categoryID: "receipts", title: "pkg", risk: .caution, note: "",
                           steps: [.adminScript(AdminScript(summary: "x", body: "true"))])
        XCTAssertEqual(RemovalPlan.kinds(for: receipt, useTrash: true), [.admin])
        XCTAssertEqual(Risk.review.label, "Check first")
        XCTAssertEqual(Risk.caution.label, "Careful")
    }
}
