import XCTest
@testable import SweepCore

final class RemoverTests: XCTestCase {
    func testDeletesFilesAndRefusesProtectedPaths() async {
        let box = Sandbox()
        let cache = box.file("home/Library/Caches/com.foo/data.bin", bytes: 4096)
        let item = Item(categoryID: "userCaches", title: "foo", size: 4096, risk: .safe, note: "",
                        paths: [FS.parent(cache)])
        let dangerous = Item(categoryID: "x", title: "home", risk: .safe, note: "", paths: [box.path("home")])
        let gone = Item(categoryID: "y", title: "already gone", risk: .safe, note: "", paths: [box.path("home/Library/Caches/nothing-here")])
        let remover = Remover(home: box.path("home"))
        let outcome = await remover.remove([item, dangerous, gone], options: RemovalOptions(useTrash: false))
        XCTAssertFalse(FS.exists(FS.parent(cache)))
        XCTAssertTrue(FS.exists(box.path("home")))
        XCTAssertEqual(Set(outcome.removed), [item.id, gone.id])
        XCTAssertNotNil(outcome.failures[dangerous.id])
        XCTAssertEqual(outcome.freedEstimate, 4096)
    }

    func testReadOnlyTreesAreDeleted() async throws {
        let box = Sandbox()
        box.file("home/go/pkg/mod/example.com/x@v1/file.go")
        let module = box.path("home/go/pkg/mod/example.com/x@v1")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: module)
        let item = Item(categoryID: "go", title: "mod", risk: .safe, note: "", paths: [box.path("home/go/pkg/mod")])
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(outcome.removed, [item.id])
        XCTAssertFalse(FS.exists(box.path("home/go/pkg/mod")))
    }

    func testBatchedCommandsFallBackToOneAtATime() async {
        let box = Sandbox()
        let log = box.path("log.txt")
        // Fails whenever "bad" is among its arguments, and logs every argument it accepted.
        let script = "for a in \"$@\"; do [ \"$a\" = bad ] && exit 1; done; for a in \"$@\"; do echo \"$a\" >> \(log); done"
        func item(_ name: String) -> Item {
            Item(id: name, categoryID: "t", title: name, risk: .safe, note: "",
                 steps: [.run(ShellCommand("/bin/sh", ["-c", script, "sh"], targets: [name], batchable: true))])
        }
        let leftover = box.file("leftover-of-bad")
        var bad = item("bad")
        bad.steps.append(.files([leftover]))
        let outcome = await Remover(home: box.path("home")).remove([item("good1"), bad, item("good2")],
                                                                   options: RemovalOptions(useTrash: false))
        XCTAssertEqual(Set(outcome.removed), ["good1", "good2"])
        XCTAssertNotNil(outcome.failures["bad"])
        XCTAssertTrue(FS.exists(leftover), "files of an item whose command failed must be left alone")
        let accepted = FS.readText(log)?.split(separator: "\n").map(String.init).sorted()
        XCTAssertEqual(accepted, ["good1", "good2"])
    }

    func testAllowFailureCommandsDontBlockFileRemoval() async {
        let box = Sandbox()
        let plist = box.file("home/Library/LaunchAgents/com.gone.agent.plist")
        let item = Item(categoryID: "launchItems", title: "agent", risk: .safe, note: "",
                        steps: [.run(ShellCommand("/bin/sh", ["-c", "exit 5"], allowFailure: true)), .files([plist])])
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(outcome.removed, [item.id])
        XCTAssertFalse(FS.exists(plist))
    }

    func testAdminScriptRoundTrip() {
        let script = Remover.adminScript(for: [["/bin/rm -rf -- '/Library/x'"], ["echo one", "false"]])
        XCTAssertTrue(script.contains("op_0()"))
        XCTAssertTrue(script.contains("op_1()"))
        XCTAssertTrue(script.hasSuffix("exit 0\n"))
        let parsed = Remover.parseAdminOutput("MSOK 0\rMSFAIL 1 permission denied here\n")
        XCTAssertEqual(parsed[0], .some(nil))
        XCTAssertEqual(parsed[1], .some("permission denied here"))
        XCTAssertNil(parsed[2] ?? nil)
    }

    func testAdminScriptRunsUnderSh() throws {
        let script = Remover.adminScript(for: [["true"], ["echo boom >&2", "false"]])
        let box = Sandbox()
        let path = box.text("s.sh", script)
        let result = Shell.execute("/bin/sh", [path], environment: nil, timeout: 10)
        let parsed = Remover.parseAdminOutput(result.stdout)
        XCTAssertEqual(parsed[0], .some(nil))
        XCTAssertEqual(parsed[1], .some("boom"))
    }

    func testPlanDescribesEverything() {
        let items = [
            Item(categoryID: "a", title: "x", risk: .safe, note: "", paths: ["/Users/me/Library/Caches/x"]),
            Item(id: "b", categoryID: "b", title: "wget", risk: .safe, note: "",
                 steps: [.run(ShellCommand("/opt/homebrew/bin/brew", ["uninstall", "--formula"], targets: ["wget"], batchable: true))]),
            Item(id: "c", categoryID: "c", title: "pkg", risk: .caution, note: "",
                 steps: [.adminScript(AdminScript(summary: "Delete 3 files", body: "true"))]),
        ]
        let lines = RemovalPlan.describe(items, useTrash: true, home: "/Users/me")
        XCTAssertEqual(lines, ["Move to Trash: ~/Library/Caches/x", "Run: brew uninstall --formula wget",
                               "As administrator: Delete 3 files"])
    }
}
