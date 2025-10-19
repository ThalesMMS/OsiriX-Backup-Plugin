import Foundation
import OsiriXAPI

/// Swift placeholder for the advanced backup behaviours.
/// Use this type to encapsulate networking, DICOM transfers and scheduling rules.
final class OsiriXBackupAdvanced {
    private let core: OsiriXBackupCore

    init(core: OsiriXBackupCore = .init()) {
        self.core = core
    }

    /// Entry point that should mirror `OsiriXBackupAdvanced`'s Objective-C API surface.
    func performBackup(using filter: PluginFilter) {
        core.loadConfiguration()
        NSLog("[OsiriXBackupAdvanced] Ready to start backup with configuration: \(core.configuration)")
    }
}
