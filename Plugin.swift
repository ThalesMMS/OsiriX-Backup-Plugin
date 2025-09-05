import Foundation
import Cocoa

@objc(OsiriXBackupSwift)
class OsiriXBackupSwift: PluginFilter {
    @IBOutlet var configWindow: NSWindow!
    @IBOutlet weak var hostField: NSTextField!
    @IBOutlet weak var portField: NSTextField!
    @IBOutlet weak var aeDestinationField: NSTextField!
    @IBOutlet weak var aeTitleField: NSTextField!
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    @IBOutlet weak var statusLabel: NSTextField!
    
    override func filterImage(_ menuName: String!) -> Int {
        switch menuName {
        case "Iniciar Backup DICOM":
            handleBackupRequest()
        case "Configurações de Backup":
            showConfigWindow()
        default:
            break
        }
        return 0
    }
    
    private func handleBackupRequest() {
        if configWindow == nil {
            loadConfigWindow()
        }
        configWindow?.makeKeyAndOrderFront(self)
    }
    
    private func showConfigWindow() {
        if configWindow == nil {
            loadConfigWindow()
        }
        configWindow?.makeKeyAndOrderFront(self)
    }
    
    private func loadConfigWindow() {
        Bundle(for: type(of: self)).loadNibNamed("Settings", owner: self, topLevelObjects: nil)
        loadSettings()
    }
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        hostField?.stringValue = defaults.string(forKey: "OsiriXBackupHostAddress") ?? "127.0.0.1"
        portField?.stringValue = String(defaults.integer(forKey: "OsiriXBackupPortNumber"))
        aeDestinationField?.stringValue = defaults.string(forKey: "OsiriXBackupAEDestination") ?? "DESTINO"
        aeTitleField?.stringValue = defaults.string(forKey: "OsiriXBackupAETitle") ?? "OSIRIX"
    }
    
    @IBAction func closeWindow(_ sender: Any) {
        configWindow?.orderOut(self)
    }
    
    override func initPlugin() {
        NSLog("[OsiriXBackupSwift] Plugin Swift inicializado com sucesso!")
    }
}
