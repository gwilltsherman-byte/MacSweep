import XCTest
import Foundation
@testable import SweepCore

final class GuardedFilesTests: XCTestCase {
    func testCredentialsAndAliasesAreProtected() {
        for path in ["/Users/me/.aws/credentials", "/Users/me/.codex/auth.json", "/Users/me/.config/gcloud/x",
                     "/Users/me/.netrc", "/Users/me/.azure/token", "/Users/me/.kube/config",
                     "/System/Volumes/Data/Users/me/.ssh/id_rsa", "/Users/me/.AWS/credentials"] {
            XCTAssertNotNil(Safety.refusal(for: path, home: "/Users/me"), path)
        }
        XCTAssertNotNil(Safety.refusal(for: "/Users/me/.unknown", home: "/Users/me"))
        XCTAssertNotNil(Safety.refusal(for: "/Users/me/Library/Caches/x\0/../../.ssh", home: "/Users/me"))
    }

    func testSymlinkParentCannotReachProtectedData() async throws {
        let box = Sandbox()
        let secret = box.file("home/.aws/credentials")
        let cache = box.dir("home/Library/Caches")
        try FileManager.default.createSymbolicLink(atPath: cache + "/alias", withDestinationPath: box.path("home/.aws"))
        let item = Item(categoryID: "cache", title: "alias", risk: .safe, note: "", paths: [cache + "/alias/credentials"])
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertNotNil(outcome.failures[item.id])
        XCTAssertTrue(FS.exists(secret))
    }

    func testSymlinkLeafIsUnlinkedWithoutFollowingIt() async throws {
        let box = Sandbox()
        let secret = box.file("home/.aws/credentials")
        let cache = box.dir("home/Library/Caches/example")
        try FileManager.default.createSymbolicLink(atPath: cache + "/link", withDestinationPath: secret)
        let item = Item(categoryID: "cache", title: "cache", risk: .safe, note: "", paths: [cache])
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertEqual(outcome.removed, [item.id])
        XCTAssertTrue(FS.exists(secret))
    }

    func testReplacingAScannedTargetIsRefused() async throws {
        let box = Sandbox()
        let path = box.file("home/Library/Caches/x")
        let item = Item(categoryID: "cache", title: "cache", risk: .safe, note: "", paths: [path])
        try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
        box.file("home/Library/Caches/x", bytes: 33)
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertNotNil(outcome.failures[item.id])
        XCTAssertEqual(FS.info(path)?.size, 33)
    }

    func testNewTargetAfterScanIsRefused() async {
        let box = Sandbox()
        let path = box.path("home/Library/Caches/new")
        let item = Item(categoryID: "cache", title: "cache", risk: .safe, note: "", paths: [path])
        box.file("home/Library/Caches/new")
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: false))
        XCTAssertNotNil(outcome.failures[item.id])
        XCTAssertTrue(FS.exists(path))
    }

    func testTrashIsRecoverableAndFailureNeverDeletes() async throws {
        let box = Sandbox()
        let path = box.file("home/Library/Caches/x")
        box.dir("home/.Trash")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: box.path("home/.Trash"))
        let item = Item(categoryID: "cache", title: "cache", risk: .safe, note: "", paths: [path])
        let outcome = await Remover(home: box.path("home")).remove([item], options: RemovalOptions(useTrash: true))
        XCTAssertEqual(outcome.removed, [item.id])
        XCTAssertEqual(FS.list(box.path("home/.Trash")).count, 1)
        let again = box.file("home/Library/Caches/y")
        try FileManager.default.removeItem(atPath: box.path("home/.Trash"))
        try FileManager.default.createSymbolicLink(atPath: box.path("home/.Trash"), withDestinationPath: box.dir("outside"))
        let other = Item(categoryID: "cache", title: "other", risk: .safe, note: "", paths: [again])
        let failed = await Remover(home: box.path("home")).remove([other], options: RemovalOptions(useTrash: true))
        XCTAssertNotNil(failed.failures[other.id])
        XCTAssertTrue(FS.exists(again))
    }

    func testPrivilegedExecutableCannotComeFromUserWritableDirectory() {
        let box = Sandbox()
        let fake = box.text("bin/port", "#!/bin/sh\nexit 0\n")
        XCTAssertThrowsError(try PrivilegedCommands.checkTrustedExecutable(fake))
    }

    #if os(macOS)
    func testBackgroundTasksAreStoppedByLabel() throws {
        XCTAssertNoThrow(try PrivilegedCommands.validate(ShellCommand("/bin/launchctl", ["bootout", "system/com.vendor.helper"]),
                                                         home: "/Users/me"))
        for label in ["system/../evil", "system/-x", "system/", "gui/501/com.vendor.agent", "system/a b"] {
            XCTAssertThrowsError(try PrivilegedCommands.validate(ShellCommand("/bin/launchctl", ["bootout", label]), home: "/Users/me"), label)
        }
    }
    #endif

    func testPackageRemovalTakesBundlesWholeAndLeavesSharedOnesAlone() {
        let own = ["/Applications/Foo.app/Contents/MacOS/Foo", "/Applications/Foo.app/Contents/Info.plist",
                   "/Library/Frameworks/Shared.framework/Versions/A/Shared", "/usr/local/bin/foo", "/Library/Foo.plugin/x"]
        let owners: [String: Set<String>] = ["/Applications/Foo.app": ["com.foo"], "/Library/Foo.plugin": ["com.foo"],
                                             "/Library/Frameworks/Shared.framework": ["com.foo", "com.bar"]]
        let targets = AppScanners.removalTargets(ownFiles: own, package: "com.foo", bundleOwners: owners) { $0 != "/Library/Foo.plugin" }
        XCTAssertEqual(targets, ["/Applications/Foo.app", "/Library/Foo.plugin/x", "/usr/local/bin/foo"])
        XCTAssertEqual(AppScanners.outermostBundle("/Applications/Foo.app/Contents/PlugIns/Bar.appex/x"), "/Applications/Foo.app")
        XCTAssertNil(AppScanners.outermostBundle("/usr/local/bin/foo"))
    }

    func testPrivilegedCommandsRejectArbitraryExecutablesAndOptions() {
        for command in [ShellCommand("/bin/sh", ["-c", "true"]),
                        ShellCommand("tmutil", ["deletelocalsnapshots", "2026-10-10-120000"]),
                        ShellCommand("/usr/bin/tmutil", ["deletelocalsnapshots", "-evil"]),
                        ShellCommand("/usr/sbin/pkgutil", ["--forget", "--help"]),
                        ShellCommand("/bin/launchctl", ["bootout", "system", "/tmp/agent.plist"])] {
            XCTAssertThrowsError(try PrivilegedCommands.validate(command, home: "/Users/me"))
        }
    }
}
