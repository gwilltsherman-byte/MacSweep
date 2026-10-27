import XCTest
import Foundation
@testable import SweepCore

final class PreferencesBackupTests: XCTestCase {
    func testSettingsRoundTripExcludesDeletionAndCredentials() throws {
        let sourceName = "MacSweep-backup-test-" + UUID().uuidString
        let targetName = "MacSweep-backup-test-" + UUID().uuidString
        let source = UserDefaults(suiteName: sourceName)!, target = UserDefaults(suiteName: targetName)!
        defer { source.removePersistentDomain(forName: sourceName); target.removePersistentDomain(forName: targetName) }
        source.set(1000, forKey: "largeFileMB")
        source.set(["example-hidden-id"], forKey: "ignoredItems")
        source.set(false, forKey: "useTrash")
        source.set("private", forKey: "unrelated-secret")
        let data = try PreferencesBackup.export(from: source)
        let values = try PreferencesBackup.validate(data)
        XCTAssertNil(values["useTrash"])
        XCTAssertNil(values["unrelated-secret"])
        PreferencesBackup.restore(values, to: target)
        XCTAssertEqual(target.integer(forKey: "largeFileMB"), 1000)
        XCTAssertEqual(target.stringArray(forKey: "ignoredItems"), ["example-hidden-id"])
    }
    func testRejectsForeignUnsafeAndMalformedBackups() throws {
        for values: [String: Any] in [["useTrash": false], ["largeFileMB": -1], ["extraFolders": "relative/path"], ["scanOnLaunch": "yes"]] {
            let data = try JSONSerialization.data(withJSONObject: ["app": "MacSweep", "version": 1, "settings": values])
            XCTAssertThrowsError(try PreferencesBackup.validate(data))
        }
        XCTAssertThrowsError(try PreferencesBackup.validate(Data("{}".utf8)))
    }
}
