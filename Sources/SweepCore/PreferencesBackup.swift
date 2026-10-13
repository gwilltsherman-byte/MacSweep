import Foundation
import CoreFoundation

public enum PreferencesBackup {
    public static let keys = ["largeFileMB", "oldDownloadDays", "duplicateMinKB", "extraFolders", "ignoredItems", "showCategoryHelp", "showBeginnerGuide", "scanOnLaunch"]
    public enum InvalidBackup: Error { case invalid }

    public static func export(from defaults: UserDefaults) throws -> Data {
        var values: [String: Any] = [:]
        for key in keys { if let value = defaults.object(forKey: key) { values[key] = value } }
        return try JSONSerialization.data(withJSONObject: ["app": "MacSweep", "version": 1, "settings": values], options: [.prettyPrinted, .sortedKeys])
    }

    public static func validate(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2_000_000,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["app"] as? String == "MacSweep", envelope["version"] as? Int == 1,
              let values = envelope["settings"] as? [String: Any],
              values.keys.allSatisfy({ keys.contains($0) }) else { throw InvalidBackup.invalid }
        for (key, value) in values {
            switch key {
            case "largeFileMB":
                guard let n = value as? Int, [100, 250, 500, 1000, 2000, 5000].contains(n) else { throw InvalidBackup.invalid }
            case "oldDownloadDays":
                guard let n = value as? Int, [30, 60, 90, 180, 365].contains(n) else { throw InvalidBackup.invalid }
            case "duplicateMinKB":
                guard let n = value as? Int, [100, 1000, 10_000, 100_000].contains(n) else { throw InvalidBackup.invalid }
            case "extraFolders":
                guard let paths = value as? String, paths.count < 100_000,
                      paths.split(separator: "\n").allSatisfy({ $0.hasPrefix("/") && $0.count <= 4096 }) else { throw InvalidBackup.invalid }
            case "ignoredItems":
                guard let ids = value as? [String], ids.count <= 50_000, ids.allSatisfy({ $0.count <= 8192 }) else { throw InvalidBackup.invalid }
            default:
                guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw InvalidBackup.invalid }
            }
        }
        return values
    }

    public static func restore(_ values: [String: Any], to defaults: UserDefaults) {
        for key in keys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        // A backup never disables confirmation, changes permissions or enables permanent deletion.
    }
}
