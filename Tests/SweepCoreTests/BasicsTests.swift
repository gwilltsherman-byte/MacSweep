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
