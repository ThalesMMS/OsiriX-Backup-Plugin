import Foundation
import OsiriXAPI

/// Swift scaffolding for the `OsiriXBackupCore` Objective-C implementation.
/// Start moving the shared Core Data and backup coordination logic here.
final class OsiriXBackupCore {
    /// Temporary placeholder backing storage while migrating from Objective-C.
    private(set) var configuration: [String: Any] = [:]

    init() {}

    /// Loads the persisted configuration using the same keys as the Objective-C version.
    func loadConfiguration() {
        let defaults = UserDefaults.standard
        configuration = [
            "host": defaults.string(forKey: "OsiriXBackupHostAddress") ?? "127.0.0.1",
            "port": defaults.integer(forKey: "OsiriXBackupPortNumber"),
            "destinationAE": defaults.string(forKey: "OsiriXBackupAEDestination") ?? "DESTINO",
            "titleAE": defaults.string(forKey: "OsiriXBackupAETitle") ?? "OSIRIX"
        ]
    }
}
