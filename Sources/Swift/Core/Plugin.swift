import Foundation
import Cocoa
import OsiriXAPI

final class OsiriXBackupSwift: PluginFilter {
    private var controller: OsiriXBackupController?

    override func initPlugin() {
        controller = OsiriXBackupController(pluginFilter: self)
        controller?.initializePlugin()
    }

    override func filterImage(_ menuName: String!) -> Int {
        guard let controller else {
            assertionFailure("OsiriXBackupSwift used before initialization")
            return 0
        }

        controller.handleMenuSelection(menuName)
        return 0
    }
}
