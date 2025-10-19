import Foundation
import OsiriXAPI

/// Swift counterpart for the legacy `OsiriXBackup` Objective-C class.
/// Implement the shared backup orchestration logic here as the migration progresses.
final class OsiriXBackup {
    // MARK: - Placeholder API

    /// Entry point that mirrors the Objective-C `-filterImage:` implementation.
    /// Replace the body with the real backup workflow when ported to Swift.
    func run(using filter: PluginFilter, menuName: String) {
        // TODO: Implement backup handling in Swift.
        NSLog("[OsiriXBackup] Swift template invoked with menu: \(menuName)")
    }
}
