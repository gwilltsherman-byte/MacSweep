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
                     "/cores/core.123", "/Users/me/.npm/_cacache", "/Library/Developer/CommandLineTools"] {
            XCTAssertFalse(refused(path), "should allow \(path): \(Safety.refusal(for: path, home: home) ?? "")")
        }
    }

    func testCanonical() {
        XCTAssertEqual(Safety.canonical("/tmp//x/./y/"), "/private/tmp/x/y")
        XCTAssertEqual(Safety.canonical("/var/folders"), "/private/var/folders")
        XCTAssertEqual(Safety.canonical("/variable"), "/variable")
    }
}
