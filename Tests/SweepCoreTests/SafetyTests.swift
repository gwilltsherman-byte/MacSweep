import XCTest
@testable import SweepCore

final class SafetyTests: XCTestCase {
    let home = "/Users/me"

    func refused(_ path: String) -> Bool { Safety.refusal(for: path, home: home) != nil }

    func testRefusesCriticalLocations() {
        for path in ["/", "/Users", "/Users/me", "/Users/me/", "/Users/me/Documents", "/Users/me/Library",
                     "/Users/me/Library/Caches", "/Users/me/Library/Application Support", "/Applications", "/Library",
                     "/Library/Caches", "/System", "/System/Library/Fonts", "/usr", "/usr/bin/ls", "/usr/local",
                     "/usr/local/bin", "/opt/homebrew", "/opt/homebrew/Cellar", "/private", "/private/var",
                     "/private/var/folders/ab/cd/T", "/var/folders/ab", "/tmp", "/etc/hosts", "/private/var/db/receipts",
                     "/Volumes/Backup", "/Users/other", "relative/path", "/Users/me/../other",
                     "/Users/me/.ssh", "/Users/me/.ssh/id_rsa", "/Users/me/.config", "/Users/me/.npm", "/Users/me/Downloads",
                     "/bin/ls", "/sbin/mount", "/Users/me/Library/Keychains/login.keychain-db"] {
            XCTAssertTrue(refused(path), "should refuse \(path)")
        }
    }

    func testAllowsTypicalTargets() {
        for path in ["/Users/me/Library/Caches/com.spotify.client", "/Applications/Slack.app",
                     "/Library/Caches/com.vendor.thing", "/Library/LaunchDaemons/com.vendor.helper.plist",
                     "/usr/local/bin/oldtool", "/private/tmp/foo", "/tmp/foo", "/private/var/folders/ab/cd/T/item",
                     "/var/folders/ab/cd/C/com.vendor", "/Users/me/projects/app/node_modules", "/Users/me/.diffusionbee",
                     "/Users/me/Downloads/old.dmg", "/Users/me/.Trash/thing", "/Volumes/Ext/.Trashes/501/x",
                      "/cores/core.123", "/Users/me/.npm/_cacache", "/Library/Developer/CommandLineTools",
                      "/Users/me/.DS_Store", "/Users/me/.localized", "/Users/me/._document"] {
            XCTAssertFalse(refused(path), "should allow \(path): \(Safety.refusal(for: path, home: home) ?? "")")
        }
    }

    func testAllowsWhatScannersOffer() {
        for path in ["/Users/me/.pnpm-store", "/Users/me/.node-gyp", "/Users/me/.electron", "/Users/me/.expo",
                     "/Users/me/.templateengine", "/Users/me/.kube/cache", "/Users/me/.kube/cache/discovery/x.json",
                     "/Users/me/.kube/http-cache", "/Users/me/Library/Mail Downloads", "/Users/me/movie.iso",
                     "/Users/me/Thumbs.db", "/Users/me/.matplotlib/fontlist-v390.json"] {
            XCTAssertFalse(refused(path), "should allow \(path): \(Safety.refusal(for: path, home: home) ?? "")")
        }
        for path in ["/Users/me/.kube", "/Users/me/.kube/config", "/Users/me/.kube/cache-not", "/Users/me/Library/Mail",
                     "/Users/me/.zshrc", "/Users/me/.netrc", "/Users/me/Desktop"] {
            XCTAssertTrue(refused(path), "should refuse \(path)")
        }
    }

    func testFoldersDirectlyInHomeStayProtected() {
        let box = Sandbox()
        let home = box.dir("home")
        box.dir("home/Code")
        box.file("home/disk.iso")
        XCTAssertNotNil(Safety.refusal(for: home + "/Code", home: home))
        XCTAssertNil(Safety.refusal(for: home + "/disk.iso", home: home))
        // A shortcut is only a pointer, unless it stands in for one of your folders.
        try? FileManager.default.createSymbolicLink(atPath: home + "/.zshrc", withDestinationPath: box.path("gone/zshrc"))
        try? FileManager.default.createSymbolicLink(atPath: home + "/Documents", withDestinationPath: box.path("gone/Documents"))
        box.text("home/.bashrc", "export X=1\n")
        XCTAssertNil(Safety.refusal(for: home + "/.zshrc", home: home))
        XCTAssertNotNil(Safety.refusal(for: home + "/Documents", home: home))
        XCTAssertNotNil(Safety.refusal(for: home + "/.bashrc", home: home))
    }

    func testOnlyRemovableItemsAreListed() {
        let box = Sandbox()
        let home = box.dir("home")
        let cache = Item(categoryID: "x", title: "cache", risk: .safe, note: "", paths: [box.file("home/Library/Caches/a")])
        let key = Item(categoryID: "x", title: "key", risk: .safe, note: "", paths: [box.file("home/.ssh/id_ed25519")])
        let nothing = Item(categoryID: "x", title: "nothing", risk: .safe, note: "")
        let tool = Item(id: "t", categoryID: "x", title: "tool", risk: .safe, note: "",
                        steps: [.run(ShellCommand("/usr/bin/true", []))])
        XCTAssertTrue(Safety.canRemove(cache, home: home))
        XCTAssertFalse(Safety.canRemove(key, home: home))
        XCTAssertFalse(Safety.canRemove(nothing, home: home))
        XCTAssertTrue(Safety.canRemove(tool, home: home))
    }

    func testCanonical() {
        XCTAssertEqual(Safety.canonical("/tmp//x/./y/"), "/private/tmp/x/y")
        XCTAssertEqual(Safety.canonical("/var/folders"), "/private/var/folders")
        XCTAssertEqual(Safety.canonical("/variable"), "/variable")
    }
}
