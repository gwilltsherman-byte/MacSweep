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

    #if os(macOS)
    func testLockedFilesAreRemoved() async throws {
        let box = Sandbox()
        let locked = box.file("home/Library/Caches/com.foo/locked.bin")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked)
        let folder = Item(categoryID: "userCaches", title: "foo", risk: .safe, note: "", paths: [FS.parent(locked)])
        let gone = await Remover(home: box.path("home"), helpers: FakeHelpers().helpers)
            .remove([folder], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(gone.removed, [folder.id], gone.failures[folder.id] ?? "")
        XCTAssertFalse(FS.exists(FS.parent(locked)))

        let file = box.file("home/Library/Caches/other.bin")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        let other = Item(categoryID: "userCaches", title: "other", risk: .safe, note: "", paths: [file])
        let trashed = await Remover(home: box.path("home"), helpers: FakeHelpers().helpers)
            .remove([other], options: RemovalOptions(useTrash: true))
        XCTAssertEqual(trashed.removed, [other.id], trashed.failures[other.id] ?? "")
        XCTAssertFalse(FS.exists(file))
        XCTAssertEqual(FS.list(box.path("home/.Trash")).count, 1)
    }

    /// An access control entry that stops even the owner from deleting, as macOS uses for protected items.
    private func guardFile(_ path: String) {
        XCTAssertTrue(Shell.execute("/bin/chmod", ["+a", "everyone deny delete", path], environment: nil, timeout: 10).ok)
    }

    private func unguard(_ path: String) {
        _ = Shell.execute("/bin/chmod", ["-N", path], environment: nil, timeout: 10)
    }

    func testWhatMacOSWontLetMacSweepDeleteGoesToAnAdministrator() async throws {
        let box = Sandbox()
        let home = box.dir("home")
        let guarded = box.file("home/Library/Caches/guarded.bin")
        guardFile(guarded)
        defer { unguard(guarded) }
        let inode = try XCTUnwrap(FS.info(guarded)).inode
        let item = Item(categoryID: "userCaches", title: "guarded", risk: .safe, note: "", paths: [guarded])
        let fake = FakeHelpers()
        fake.administrator = { _ in ShellResult(status: 0, stdout: "MSOK 0\n", stderr: "") }
        let outcome = await Remover(home: home, helpers: fake.helpers).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(outcome.removed, [item.id])
        XCTAssertTrue(fake.finderRequests.isEmpty)
        let script = try XCTUnwrap(fake.scripts.first)
        XCTAssertTrue(script.contains("gone ./guarded.bin \(inode) || failed=1"), script)
        let folder = try XCTUnwrap(FS.realPath(FS.parent(guarded)))
        XCTAssertTrue(script.contains("cd -P -- \(Shell.quote(folder))"), script)
    }

    func testMovingWhatMacOSWontLetMacSweepMoveIsFindersJob() async throws {
        let box = Sandbox()
        let home = box.dir("home")
        let guarded = box.file("home/Library/Caches/guarded.bin")
        guardFile(guarded)
        defer { unguard(guarded) }
        let item = Item(categoryID: "userCaches", title: "guarded", risk: .safe, note: "", paths: [guarded])

        let refusing = FakeHelpers()
        refusing.finder = { _ in ShellResult(status: 0, stdout: "MSFAIL 0 -1743 Not authorized to send Apple events to Finder.\n", stderr: "") }
        let refused = await Remover(home: home, helpers: refusing.helpers).remove([item], options: RemovalOptions(useTrash: true))
        XCTAssertTrue(refused.failures[item.id]?.contains("Automation") == true, refused.failures[item.id] ?? "")
        XCTAssertTrue(refusing.scripts.isEmpty, "a Trash move never becomes a permanent deletion")
        XCTAssertTrue(FS.exists(guarded))

        let fake = FakeHelpers()
        fake.finder = { paths in
            for path in paths {
                self.unguard(path)
                try? FileManager.default.moveItem(atPath: path, toPath: box.path("finder-moved-" + FS.name(path)))
            }
            return ShellResult(status: 0, stdout: "MSALL\n", stderr: "")
        }
        let outcome = await Remover(home: home, helpers: fake.helpers).remove([item], options: RemovalOptions(useTrash: true))
        XCTAssertEqual(outcome.removed, [item.id], outcome.failures[item.id] ?? "")
        XCTAssertEqual(fake.finderRequests, [[guarded]])
        XCTAssertTrue(outcome.movedToTrash.isEmpty, "it was meant for the Trash anyway")
    }

    func testFinderMovesWhatEvenAnAdministratorMayNotDelete() async throws {
        let box = Sandbox()
        let home = box.dir("home")
        let guarded = box.file("home/Library/Caches/guarded.bin")
        guardFile(guarded)
        defer { unguard(guarded) }
        let item = Item(categoryID: "userCaches", title: "guarded", risk: .safe, note: "", paths: [guarded])
        let fake = FakeHelpers()
        fake.administrator = { _ in
            ShellResult(status: 0, stdout: "MSFAIL 0 find: -delete: unlinkat(./guarded.bin): Operation not permitted\n", stderr: "")
        }
        fake.finder = { paths in
            for path in paths { self.unguard(path); try? FileManager.default.removeItem(atPath: path) }
            return ShellResult(status: 0, stdout: "MSALL\n", stderr: "")
        }
        let outcome = await Remover(home: home, helpers: fake.helpers).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(outcome.removed, [item.id], outcome.failures[item.id] ?? "")
        XCTAssertEqual(outcome.movedToTrash, [item.id])
    }

    func testSystemToolsWaitForTheirItemsFiles() async throws {
        let box = Sandbox()
        let home = box.dir("home")
        let guarded = box.file("home/Library/Caches/pkg/file.bin")
        guardFile(guarded)
        defer { unguard(guarded) }
        let item = Item(id: "pkg", categoryID: "receipts", title: "pkg", risk: .caution, note: "", paths: [guarded],
                        steps: [.files([guarded]), .runAsAdmin(ShellCommand("/usr/sbin/pkgutil", ["--forget", "com.vendor.pkg"]))])
        let fake = FakeHelpers()
        fake.administrator = { _ in ShellResult(status: 0, stdout: "MSOK 0\nMSOK 1\n", stderr: "") }
        let outcome = await Remover(home: home, helpers: fake.helpers).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(outcome.removed, [item.id], outcome.failures[item.id] ?? "")
        let script = try XCTUnwrap(fake.scripts.first)
        let forget = try XCTUnwrap(script.range(of: "op_1() {\n"))
        XCTAssertTrue(script[forget.upperBound...].hasPrefix("[ \"${ok_0:-}\" = 1 ] ||"), script)
    }

    /// The administrator script itself, run as you rather than root: it deletes the scanned item, Locked files
    /// and all, and leaves alone anything that isn't what was scanned.
    func testAdministratorDeletionRemovesOnlyTheScannedItem() throws {
        let box = Sandbox()
        let folder = box.dir("home/Library/Caches/vendor")
        box.file("home/Library/Caches/vendor/old/data.bin")
        let locked = box.file("home/Library/Caches/vendor/old/deeper/locked.bin")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked)
        let old = folder + "/old"
        let swapped = box.file("home/Library/Caches/vendor/swapped.bin")
        let real = try XCTUnwrap(FS.realPath(folder))
        let lines = Remover.adminDeletion(in: real, [("old", try XCTUnwrap(FS.info(old)).inode),
                                                     ("swapped.bin", try XCTUnwrap(FS.info(swapped)).inode + 1),
                                                     ("missing", 42)])
        let script = box.text("s.sh", Remover.adminScript(for: [lines]))
        let result = Shell.execute("/bin/sh", [script], environment: nil, timeout: 60)
        XCTAssertFalse(FS.exists(old), result.stdout)
        XCTAssertTrue(FS.exists(swapped))
        let failure = try XCTUnwrap(Remover.parseAdminOutput(result.stdout)[0] ?? nil, result.stdout)
        XCTAssertTrue(failure.contains("swapped.bin changed"), failure)
    }

    /// Both AppleScripts must at least compile, or Finder and the password prompt could never help.
    func testAppleScriptsCompile() throws {
        let box = Sandbox()
        let script = Remover.adminScript(for: [Remover.adminDeletion(in: "/Library/Caches", [("it's \"odd\"", 1)])])
        for source in [Remover.finderScript, Remover.administratorAppleScript(script)] {
            let result = Shell.execute("/usr/bin/osacompile", ["-o", box.path("check.scpt"), "-e", source], environment: nil, timeout: 60)
            XCTAssertTrue(result.ok, result.errorSummary)
        }
    }

    func testAdministratorDeletionStaysInItsFolder() throws {
        let box = Sandbox()
        let target = box.file("home/Library/Caches/vendor/data.bin")
        let elsewhere = box.file("elsewhere/data.bin")
        let lines = Remover.adminDeletion(in: try XCTUnwrap(FS.realPath(box.path("home/Library/Caches/vendor"))),
                                          [("data.bin", try XCTUnwrap(FS.info(target)).inode)])
        // The folder is swapped for a symlink to somewhere else after scanning.
        try FileManager.default.moveItem(atPath: box.path("home/Library/Caches/vendor"), toPath: box.path("home/Library/Caches/moved"))
        try FileManager.default.createSymbolicLink(atPath: box.path("home/Library/Caches/vendor"), withDestinationPath: box.path("elsewhere"))
        let script = box.text("s.sh", Remover.adminScript(for: [lines]))
        let result = Shell.execute("/bin/sh", [script], environment: nil, timeout: 60)
        XCTAssertTrue(FS.exists(elsewhere))
        XCTAssertTrue(FS.exists(box.path("home/Library/Caches/moved/data.bin")))
        XCTAssertNotNil(Remover.parseAdminOutput(result.stdout)[0] ?? nil, result.stdout)
    }
    #endif

    func testPlanDescribesEverything() {
        let items = [
            Item(categoryID: "a", title: "x", risk: .safe, note: "", paths: ["/Users/me/Library/Caches/x"]),
            Item(id: "b", categoryID: "b", title: "wget", risk: .safe, note: "",
                 steps: [.run(ShellCommand("/opt/homebrew/bin/brew", ["uninstall", "--formula"], targets: ["wget"], batchable: true))]),
            Item(id: "c", categoryID: "c", title: "pkg", risk: .caution, note: "",
                 steps: [.runAsAdmin(ShellCommand("/usr/sbin/pkgutil", ["--forget", "com.vendor.pkg"]))]),
        ]
        let lines = RemovalPlan.describe(items, useTrash: true, home: "/Users/me")
        XCTAssertEqual(lines, ["Move to Trash: ~/Library/Caches/x", "Run: brew uninstall --formula wget",
                               "Run as administrator: pkgutil --forget com.vendor.pkg"])
    }
}
