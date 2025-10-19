import Foundation
import Cocoa
import OsiriXAPI

@objc(OsiriXBackupSwift)
class OsiriXBackupSwift: PluginFilter {
    private lazy var controller = OsiriXBackupController(pluginFilter: self)

    override func initPlugin() {
        controller.initializePlugin()
    }

    override func filterImage(_ menuName: String!) -> Int {
        controller.handleMenuSelection(menuName)
        return 0
    }
}
