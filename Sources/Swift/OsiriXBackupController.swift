import Cocoa
import CoreData
import OsiriXAPI

private let maxSimultaneousTransfers = 2

/// Swift controller responsible for orchestrating the OsiriX backup workflow.
/// It mirrors the responsibilities of the legacy Objective-C `OsiriXBackup` class
/// while leveraging modern Swift concurrency primitives.
private struct PendingStudy {
    let objectID: NSManagedObjectID
    let studyUID: String
}

final class OsiriXBackupController: NSObject {
    // MARK: - Public API

    init(
        pluginFilter: PluginFilter,
        transferPipeline: OsiriXStudyTransferPipeline = OsiriXStudyTransferPipeline()
    ) {
        self.pluginFilter = pluginFilter
        self.transferPipeline = transferPipeline
        super.init()
    }

    deinit {
        stopTimer()
    }

    func initializePlugin() {
        workerQueue.async { [weak self] in
            guard let self else { return }
            self.updateState { state in
                state.pendingStudies.removeAll()
                state.activeTransfers.removeAll()
                state.retryCounts.removeAll()
                state.completedCount = 0
                state.totalStudyCount = 0
                state.hadTransferFailures = false
                state.isBackupRunning = false
                state.isBackupPaused = false
            }
        }
        loadSettings()
        ensureWindowLoaded()
        NSLog("[OsiriXBackupController] Swift backup controller initialized")
    }

    func handleMenuSelection(_ menuName: String?) {
        guard let menuName = menuName else { return }
        ensureWindowLoaded()

        switch menuName {
        case "Iniciar Backup DICOM":
            configWindow?.makeKeyAndOrderFront(self)
            startBackup(nil)
        case "Configurações de Backup":
            configWindow?.makeKeyAndOrderFront(self)
        default:
            break
        }
    }

    // MARK: - Interface Builder Outlets

    @IBOutlet weak var configWindow: NSWindow?

    // MARK: - Private UI Elements

    private weak var hostField: NSTextField?
    private weak var portField: NSTextField?
    private weak var aeDestinationField: NSTextField?
    private weak var aeTitleField: NSTextField?
    private weak var skipVerificationCheckbox: NSButton?
    private weak var simpleVerificationCheckbox: NSButton?
    private weak var progressIndicator: NSProgressIndicator?
    private weak var statusLabel: NSTextField?
    private weak var startBackupButton: NSButton?
    private weak var pauseBackupButton: NSButton?
    private weak var stopBackupButton: NSButton?
    private weak var closeWindowButton: NSButton?

    // MARK: - Plugin & State Management

    private weak var pluginFilter: PluginFilter?
    private let workerQueue = DispatchQueue(label: "com.osirix.backup.worker", qos: .userInitiated)
    private let transferQueue = DispatchQueue(label: "com.osirix.backup.transfer", qos: .userInitiated, attributes: .concurrent)
    private let transferPipeline: OsiriXStudyTransferPipeline

    private var backupTimer: DispatchSourceTimer?

    private struct BackupState {
        var isBackupRunning = false
        var isBackupPaused = false
        var pendingStudies: [PendingStudy] = []
        var activeTransfers: Set<String> = []
        var retryCounts: [String: Int] = [:]
        var totalStudyCount: Int = 0
        var completedCount: Int = 0
        var hadTransferFailures = false
    }

    private let stateQueue = DispatchQueue(label: "com.osirix.backup.state")
    private var state = BackupState()

    private var hostAddress: String = ""
    private var portNumber: Int = 104
    private var aeDestination: String = ""
    private var aeTitle: String = ""
    private var skipVerification = false
    private var useSimpleVerification = true
    private var findscuPath: String?
    private lazy var findscuLocator: FindscuLocator = {
        let environment = FindscuLocator.Environment(
            fileManager: FileManager.default,
            processRunner: DefaultFindscuProcessRunner(),
            candidatePaths: [
                "/opt/homebrew/bin/findscu",
                "/usr/local/bin/findscu",
                "/opt/dcmtk/bin/findscu",
                "/usr/bin/findscu"
            ],
            cachedPathProvider: { [weak self] in self?.findscuPath },
            updateCachedPath: { [weak self] path in
                self?.findscuPath = path
                guard let self else { return }
                if let path {
                    self.defaults.set(path, forKey: "OsiriXBackupFindscuPath")
                } else {
                    self.defaults.removeObject(forKey: "OsiriXBackupFindscuPath")
                }
            },
            bundledExecutablePath: { [weak self] in self?.bundledFindscuPath() }
        )
        return FindscuLocator(environment: environment)
    }()

    private let defaults = UserDefaults.standard

    private var resourceBundle: Bundle {
        if let pluginFilter {
            return Bundle(for: type(of: pluginFilter))
        }
        return Bundle(for: OsiriXBackupController.self)
    }

    // MARK: - User Actions

    @IBAction func startBackup(_ sender: Any?) {
        ensureWindowLoaded()
        captureSettingsFromUI()

        if !validateConfiguration() {
            return
        }

        if !skipVerification {
            findscuPath = resolveFindscuPath()
            guard findscuPath != nil else {
                presentFindscuMissingAlert()
                return
            }
        }

        guard !isBackupRunning() else {
            configWindow?.makeKeyAndOrderFront(self)
            return
        }

        updateState { state in
            state.isBackupRunning = true
            state.isBackupPaused = false
            state.hadTransferFailures = false
        }
        updateButtonsForRunningState()
        updateStatus("Preparando estudos para envio...")
        persistSettings()

        workerQueue.async { [weak self] in
            guard let self else { return }

            let studies = self.fetchPendingStudies()
            let hasPending = self.updateState { state in
                state.pendingStudies = studies
                state.totalStudyCount = studies.count
                state.completedCount = 0
                state.retryCounts.removeAll()
                return !state.pendingStudies.isEmpty
            }

            DispatchQueue.main.async {
                self.progressIndicator?.doubleValue = 0.0
                self.progressIndicator?.maxValue = 100.0
            }

            if !hasPending {
                self.finishBackup(interrupted: false)
            } else {
                self.startTimer()
            }
        }
    }

    @IBAction func pauseBackup(_ sender: Any?) {
        guard isBackupRunning() else { return }

        let isPaused = updateState { state -> Bool in
            guard state.isBackupRunning else { return state.isBackupPaused }
            state.isBackupPaused.toggle()
            return state.isBackupPaused
        }
        updateButtonsForRunningState()
        updateStatus(isPaused ? "Backup pausado." : "Retomando backup...")
    }

    @IBAction func stopBackup(_ sender: Any?) {
        guard isBackupRunning() else { return }

        workerQueue.async { [weak self] in
            self?.finishBackup(interrupted: true)
        }
    }

    @IBAction func closeWindow(_ sender: Any?) {
        configWindow?.orderOut(sender)
    }

    // MARK: - Window & UI Configuration

    private func ensureWindowLoaded() {
        guard configWindow == nil else { return }

        let bundle = resourceBundle
        if bundle.loadNibNamed("Settings", owner: self, topLevelObjects: nil) {
            configureWindowInterface()
        } else {
            NSLog("[OsiriXBackupController] Failed to load Settings.xib. Building window programmatically.")
            buildWindowProgrammatically()
        }
        loadSettings()
    }

    private func configureWindowInterface() {
        guard let window = configWindow else {
            buildWindowProgrammatically()
            return
        }

        window.title = "Configuração de Backup DICOM"
        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()

        if let contentView = window.contentView {
            contentView.subviews.forEach { $0.removeFromSuperview() }
        }

        buildInterface(in: window)
    }

    private func buildWindowProgrammatically() {
        let windowRect = NSRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: windowRect,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Configuração de Backup DICOM"
        window.center()
        configWindow = window
        buildInterface(in: window)
    }

    private func buildInterface(in window: NSWindow) {
        let contentView = window.contentView ?? NSView(frame: window.frame)
        window.contentView = contentView

        let labelWidth: CGFloat = 140
        let fieldWidth: CGFloat = 320
        let fieldHeight: CGFloat = 24
        let baseX: CGFloat = 20
        var currentY: CGFloat = 320
        let spacing: CGFloat = 36

        func makeLabel(_ title: String, _ y: CGFloat) -> NSTextField {
            let label = NSTextField(frame: NSRect(x: baseX, y: y, width: labelWidth, height: fieldHeight))
            label.stringValue = title
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            return label
        }

        // Host field
        contentView.addSubview(makeLabel("Host:", currentY))
        let hostField = NSTextField(frame: NSRect(x: baseX + labelWidth + 10, y: currentY, width: fieldWidth, height: fieldHeight))
        contentView.addSubview(hostField)
        self.hostField = hostField
        currentY -= spacing

        // Port field
        contentView.addSubview(makeLabel("Porta:", currentY))
        let portField = NSTextField(frame: NSRect(x: baseX + labelWidth + 10, y: currentY, width: fieldWidth, height: fieldHeight))
        contentView.addSubview(portField)
        self.portField = portField
        currentY -= spacing

        // AE Title field
        contentView.addSubview(makeLabel("AE Title Local:", currentY))
        let aeTitleField = NSTextField(frame: NSRect(x: baseX + labelWidth + 10, y: currentY, width: fieldWidth, height: fieldHeight))
        contentView.addSubview(aeTitleField)
        self.aeTitleField = aeTitleField
        currentY -= spacing

        // AE Destination field
        contentView.addSubview(makeLabel("AE Destination:", currentY))
        let aeDestinationField = NSTextField(frame: NSRect(x: baseX + labelWidth + 10, y: currentY, width: fieldWidth, height: fieldHeight))
        contentView.addSubview(aeDestinationField)
        self.aeDestinationField = aeDestinationField
        currentY -= spacing

        // Skip verification checkbox
        let skipVerificationCheckbox = NSButton(frame: NSRect(x: baseX, y: currentY, width: fieldWidth + labelWidth, height: fieldHeight))
        skipVerificationCheckbox.setButtonType(.switch)
        skipVerificationCheckbox.title = "Pular verificação de existência"
        contentView.addSubview(skipVerificationCheckbox)
        self.skipVerificationCheckbox = skipVerificationCheckbox
        currentY -= spacing

        // Simple verification checkbox
        let simpleVerificationCheckbox = NSButton(frame: NSRect(x: baseX, y: currentY, width: fieldWidth + labelWidth, height: fieldHeight))
        simpleVerificationCheckbox.setButtonType(.switch)
        simpleVerificationCheckbox.title = "Usar verificação simplificada (recomendado)"
        contentView.addSubview(simpleVerificationCheckbox)
        self.simpleVerificationCheckbox = simpleVerificationCheckbox
        currentY -= spacing

        // Status label
        let statusLabel = NSTextField(frame: NSRect(x: baseX, y: currentY, width: fieldWidth + labelWidth, height: fieldHeight))
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.stringValue = "Status: aguardando"
        contentView.addSubview(statusLabel)
        self.statusLabel = statusLabel
        currentY -= spacing

        // Progress indicator
        let progressIndicator = NSProgressIndicator(frame: NSRect(x: baseX, y: currentY, width: fieldWidth + labelWidth, height: 20))
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0
        contentView.addSubview(progressIndicator)
        self.progressIndicator = progressIndicator

        // Buttons
        let buttonWidth: CGFloat = 130
        let buttonHeight: CGFloat = 32
        let buttonY: CGFloat = 20

        let startButton = NSButton(frame: NSRect(x: baseX, y: buttonY, width: buttonWidth, height: buttonHeight))
        startButton.title = "Iniciar Backup"
        startButton.target = self
        startButton.action = #selector(startBackup(_:))
        contentView.addSubview(startButton)
        self.startBackupButton = startButton

        let pauseButton = NSButton(frame: NSRect(x: baseX + buttonWidth + 10, y: buttonY, width: buttonWidth, height: buttonHeight))
        pauseButton.title = "Pausar"
        pauseButton.target = self
        pauseButton.action = #selector(pauseBackup(_:))
        pauseButton.isEnabled = false
        pauseButton.isHidden = true
        contentView.addSubview(pauseButton)
        self.pauseBackupButton = pauseButton

        let stopButton = NSButton(frame: NSRect(x: baseX + 2 * (buttonWidth + 10), y: buttonY, width: buttonWidth, height: buttonHeight))
        stopButton.title = "Parar"
        stopButton.target = self
        stopButton.action = #selector(stopBackup(_:))
        stopButton.isEnabled = false
        stopButton.isHidden = true
        contentView.addSubview(stopButton)
        self.stopBackupButton = stopButton

        let closeButton = NSButton(frame: NSRect(x: baseX + buttonWidth + 10, y: buttonY, width: buttonWidth, height: buttonHeight))
        closeButton.title = "Fechar"
        closeButton.target = self
        closeButton.action = #selector(closeWindow(_:))
        closeButton.isHidden = true
        contentView.addSubview(closeButton)
        self.closeWindowButton = closeButton
    }

    // MARK: - Settings Management

    private func loadSettings() {
        hostAddress = defaults.string(forKey: "OsiriXBackupHostAddress") ?? "127.0.0.1"
        portNumber = defaults.integer(forKey: "OsiriXBackupPortNumber")
        if portNumber == 0 { portNumber = 104 }
        aeDestination = defaults.string(forKey: "OsiriXBackupAEDestination") ?? "DESTINO"
        aeTitle = defaults.string(forKey: "OsiriXBackupAETitle") ?? "OSIRIX"
        findscuPath = defaults.string(forKey: "OsiriXBackupFindscuPath")
        skipVerification = defaults.bool(forKey: "OsiriXBackupSkipVerification")

        if defaults.object(forKey: "OsiriXBackupUseSimpleVerification") == nil {
            useSimpleVerification = true
        } else {
            useSimpleVerification = defaults.bool(forKey: "OsiriXBackupUseSimpleVerification")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostField?.stringValue = self.hostAddress
            self.portField?.stringValue = "\(self.portNumber)"
            self.aeDestinationField?.stringValue = self.aeDestination
            self.aeTitleField?.stringValue = self.aeTitle
            self.skipVerificationCheckbox?.state = self.skipVerification ? .on : .off
            self.simpleVerificationCheckbox?.state = self.useSimpleVerification ? .on : .off
        }
    }

    private func captureSettingsFromUI() {
        hostAddress = hostField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        portNumber = Int(portField?.stringValue ?? "") ?? 0
        aeDestination = aeDestinationField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aeTitle = aeTitleField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        skipVerification = (skipVerificationCheckbox?.state == .on)
        useSimpleVerification = (simpleVerificationCheckbox?.state != .off)
    }

    private func persistSettings() {
        defaults.set(hostAddress, forKey: "OsiriXBackupHostAddress")
        defaults.set(portNumber, forKey: "OsiriXBackupPortNumber")
        defaults.set(aeDestination, forKey: "OsiriXBackupAEDestination")
        defaults.set(aeTitle, forKey: "OsiriXBackupAETitle")
        defaults.set(findscuPath, forKey: "OsiriXBackupFindscuPath")
        defaults.set(skipVerification, forKey: "OsiriXBackupSkipVerification")
        defaults.set(useSimpleVerification, forKey: "OsiriXBackupUseSimpleVerification")
        defaults.synchronize()
    }

    private func validateConfiguration() -> Bool {
        if hostAddress.isEmpty || portNumber <= 0 || aeDestination.isEmpty || aeTitle.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Configurações Incompletas"
            alert.informativeText = "Preencha todas as configurações antes de iniciar o backup."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        return true
    }

    private func presentFindscuMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Ferramenta findscu não encontrada"
        alert.informativeText = "O utilitário findscu é necessário para verificar a existência de estudos no destino. Ajuste as configurações ou habilite 'Pular verificação'."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFindscuExecutionFailureAlert(status: Int32, reason: Process.TerminationReason, output: String) {
        let alert = NSAlert()
        alert.messageText = "Falha ao executar findscu"

        let reasonDescription: String
        switch reason {
        case .exit:
            reasonDescription = "exit"
        case .uncaughtSignal:
            reasonDescription = "signal"
        @unknown default:
            reasonDescription = "unknown"
        }

        var informativeText = "findscu terminou com código \(status) (motivo: \(reasonDescription))."
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            informativeText += "\n\nSaída:\n\(output)"
        }

        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Timer & Processing

    private func startTimer() {
        stopTimer()

        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.processQueue()
        }
        timer.resume()
        backupTimer = timer

        DispatchQueue.main.async { [weak self] in
            self?.pauseBackupButton?.isEnabled = true
            self?.pauseBackupButton?.isHidden = false
            self?.stopBackupButton?.isEnabled = true
            self?.stopBackupButton?.isHidden = false
            self?.startBackupButton?.isEnabled = false
            self?.closeWindowButton?.isHidden = true
        }
    }

    private func stopTimer() {
        backupTimer?.cancel()
        backupTimer = nil
    }

    private func processQueue() {
        enum QueueDecision {
            case idle
            case finish
            case study(PendingStudy)
        }

        let decision = updateState { state -> QueueDecision in
            guard state.isBackupRunning, !state.isBackupPaused else { return .idle }

            if state.pendingStudies.isEmpty {
                return state.activeTransfers.isEmpty ? .finish : .idle
            }

            guard state.activeTransfers.count < maxSimultaneousTransfers else { return .idle }

            let study = state.pendingStudies.removeFirst()
            state.activeTransfers.insert(study.studyUID)
            return .study(study)
        }

        switch decision {
        case .idle:
            return
        case .finish:
            finishBackup(interrupted: false)
            return
        case .study(let study):
            let studyUID = study.studyUID

        DispatchQueue.main.async { [weak self] in
            self?.updateStatus("Enviando estudo \(studyUID)...")
        }

        transferQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let success = self.performTransfer(for: study.objectID, studyUID: studyUID)
                self.workerQueue.async {
                    self.handleTransferCompletion(for: study, success: success)
                }
            }
        }
        }
    }

    private func handleTransferCompletion(for study: PendingStudy, success: Bool) {
        let outcome = updateState { state -> (shouldContinue: Bool, shouldFinish: Bool) in
            guard state.isBackupRunning else {
                state.activeTransfers.remove(study.studyUID)
                return (false, false)
            }

            state.activeTransfers.remove(study.studyUID)

            if success {
                state.completedCount += 1
                state.retryCounts.removeValue(forKey: study.studyUID)
            } else {
                let attempts = state.retryCounts[study.studyUID, default: 0] + 1
                state.retryCounts[study.studyUID] = attempts
                if attempts < 3 {
                    state.pendingStudies.append(study)
                } else {
                    state.completedCount += 1
                    state.hadTransferFailures = true
                    NSLog("[OsiriXBackupController] Falha persistente ao enviar estudo %@. Ignorando após 3 tentativas.", study.studyUID)
                }
            }

            let shouldFinish = state.pendingStudies.isEmpty && state.activeTransfers.isEmpty
            return (true, shouldFinish)
        }

        guard outcome.shouldContinue else { return }

        updateProgress()

        if outcome.shouldFinish {
            finishBackup(interrupted: false)
        }
    }

    private func finishBackup(interrupted: Bool) {
        stopTimer()
        let summary = readState { state in
            if interrupted {
                return "Backup interrompido."
            } else if state.hadTransferFailures {
                return "Backup finalizado com pendências."
            } else if state.pendingStudies.isEmpty && state.activeTransfers.isEmpty {
                return "Backup finalizado com sucesso!"
            } else {
                return "Backup finalizado com pendências."
            }
        }

        updateState { state in
            state.isBackupRunning = false
            state.isBackupPaused = false
            state.pendingStudies.removeAll()
            state.activeTransfers.removeAll()
            state.retryCounts.removeAll()
            state.totalStudyCount = 0
            state.completedCount = 0
            state.hadTransferFailures = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateStatus(summary)
            self.pauseBackupButton?.isEnabled = false
            self.pauseBackupButton?.isHidden = true
            self.pauseBackupButton?.title = "Pausar"
            self.stopBackupButton?.isEnabled = false
            self.stopBackupButton?.isHidden = true
            self.startBackupButton?.isEnabled = true
            self.startBackupButton?.title = "Iniciar Backup"
            self.closeWindowButton?.isHidden = false
            self.hostField?.isEnabled = true
            self.portField?.isEnabled = true
            self.aeDestinationField?.isEnabled = true
            self.aeTitleField?.isEnabled = true
            self.skipVerificationCheckbox?.isEnabled = true
            self.simpleVerificationCheckbox?.isEnabled = true
        }

        updateButtonsForRunningState()
    }

    private func updateButtonsForRunningState() {
        let snapshot = readState { state in
            (state.isBackupRunning, state.isBackupPaused)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if snapshot.0 {
                self.startBackupButton?.title = "Backup em andamento"
                self.startBackupButton?.isEnabled = false
                self.pauseBackupButton?.isHidden = false
                self.stopBackupButton?.isHidden = false
                self.closeWindowButton?.isHidden = true
                self.hostField?.isEnabled = false
                self.portField?.isEnabled = false
                self.aeDestinationField?.isEnabled = false
                self.aeTitleField?.isEnabled = false
                self.skipVerificationCheckbox?.isEnabled = false
                self.simpleVerificationCheckbox?.isEnabled = false

                self.pauseBackupButton?.title = snapshot.1 ? "Retomar" : "Pausar"
            } else {
                self.startBackupButton?.title = "Iniciar Backup"
                self.startBackupButton?.isEnabled = true
                self.pauseBackupButton?.isHidden = true
                self.stopBackupButton?.isHidden = true
                self.closeWindowButton?.isHidden = false
            }
        }
    }

    private func updateProgress() {
        let (completed, total) = readState { state in
            (state.completedCount, state.totalStudyCount)
        }
        let percentage: Double = total == 0 ? 0 : (Double(completed) / Double(total)) * 100.0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progressIndicator?.doubleValue = percentage
            self.statusLabel?.stringValue = "Status: \(completed) de \(total) estudos sincronizados"
        }
    }

    private func updateStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.stringValue = "Status: \(message)"
        }
    }

    private func performTransfer(for studyID: NSManagedObjectID, studyUID: String) -> Bool {
        let destination = StudyTransferDestination(
            host: hostAddress,
            port: portNumber,
            callingAE: aeTitle,
            calledAE: aeDestination
        )

        let verificationMode: TransferVerificationMode
        if skipVerification {
            verificationMode = .skip
        } else if useSimpleVerification {
            verificationMode = .simple { [weak self] in
                guard let self else { return false }
                return self.studyExistsWithCountCheck(studyUID: studyUID)
            }
        } else {
            verificationMode = .advanced { [weak self] in
                guard let self else { return false }
                return self.studyExistsOnDestination(studyUID: studyUID)
            }
        }

#if canImport(CoreData)
        guard let database = DicomDatabase.activeLocalDatabase() else {
            NSLog("[OsiriXBackupController] Não foi possível localizar o banco de dados ativo para o estudo %@.", studyUID)
            return false
        }

        guard let transferContext = makeTransferContext(from: database) else {
            NSLog("[OsiriXBackupController] Não foi possível criar um contexto de transferência para o estudo %@.", studyUID)
            return false
        }

        var transferSuccess = false
        var didAttemptTransfer = false

        transferContext.performAndWait {
            do {
                guard let study = try transferContext.existingObject(with: studyID) as? DicomStudy else {
                    NSLog("[OsiriXBackupController] Não foi possível localizar o estudo %@ para envio.", studyUID)
                    return
                }

                let outcome = transferPipeline.performTransfer(
                    study: study,
                    studyUID: studyUID,
                    destination: destination,
                    verification: verificationMode
                )

                transferSuccess = outcome.success
                didAttemptTransfer = true
            } catch {
                NSLog("[OsiriXBackupController] Erro ao buscar o estudo %@: %@", studyUID, String(describing: error))
            }
        }

        if !didAttemptTransfer {
            NSLog("[OsiriXBackupController] Não foi possível preparar o estudo %@ para envio.", studyUID)
        }

        return transferSuccess
#else
        var study: DicomStudy?
        let fetchBlock = {
            guard let database = DicomDatabase.activeLocalDatabase(),
                  let studies = database.objects(forEntity: "Study") as? [DicomStudy] else {
                NSLog("[OsiriXBackupController] Não foi possível localizar o banco de dados ativo para o estudo %@.", studyUID)
                return
            }

            study = studies.first(where: { $0.objectID == studyID })
        }

        if Thread.isMainThread {
            fetchBlock()
        } else {
            DispatchQueue.main.sync(execute: fetchBlock)
        }

        guard let resolvedStudy = study else {
            NSLog("[OsiriXBackupController] Não foi possível localizar o estudo %@ para envio.", studyUID)
            return false
        }

        let outcome = transferPipeline.performTransfer(
            study: resolvedStudy,
            studyUID: studyUID,
            destination: destination,
            verification: verificationMode
        )

        return outcome.success
#endif
    }

#if canImport(CoreData)
    private func makeTransferContext(from database: AnyObject) -> NSManagedObjectContext? {
        if let coordinator: NSPersistentStoreCoordinator = value(forKey: "persistentStoreCoordinator", in: database) {
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            context.undoManager = nil
            return context
        }

        if let parentContext: NSManagedObjectContext = value(forKey: "managedObjectContext", in: database) {
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.parent = parentContext
            context.mergePolicy = parentContext.mergePolicy
            context.undoManager = nil
            return context
        }

        return nil
    }
#endif

    private func value<T>(forKey key: String, in object: AnyObject?) -> T? {
        guard let object else { return nil }
#if canImport(ObjectiveC)
        return (object as? NSObject)?.value(forKey: key) as? T
#else
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            for child in current.children where child.label == key {
                return child.value as? T
            }
            mirror = current.superclassMirror
        }
        return nil
#endif
    }

    // MARK: - Helpers

    private func fetchPendingStudies() -> [PendingStudy] {
        var result: [PendingStudy] = []

        let fetchBlock = {
            guard let database = DicomDatabase.activeLocalDatabase() else {
                NSLog("[OsiriXBackupController] Nenhum banco de dados ativo encontrado.")
                return
            }

            guard let studies = database.objects(forEntity: "Study") as? [DicomStudy] else {
                NSLog("[OsiriXBackupController] Não foi possível carregar estudos do banco de dados.")
                return
            }

            result = studies.map { study in
                let uid = study.studyInstanceUID ?? UUID().uuidString
                return PendingStudy(objectID: study.objectID, studyUID: uid)
            }
        }

        if Thread.isMainThread {
            fetchBlock()
        } else {
            DispatchQueue.main.sync(execute: fetchBlock)
        }

        return result
    }

    private func resolveFindscuPath() -> String? {
        return findscuLocator.resolve()
    }

    private func bundledFindscuPath() -> String? {
        let pluginBundle = resourceBundle
        let resourcePath = pluginBundle.path(forResource: "findscu", ofType: nil)
        if let resourcePath, FileManager.default.isExecutableFile(atPath: resourcePath) {
            return resourcePath
        }

        if let bundlePath = pluginBundle.bundlePath as NSString? {
            let candidate = bundlePath.appendingPathComponent("Contents/Resources/findscu")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func studyExistsOnDestination(studyUID: String) -> Bool {
        guard let findscuPath = resolveFindscuPath() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: findscuPath)
        process.arguments = [
            "-v",
            "-aet", aeTitle,
            "-aec", aeDestination,
            "-P",
            "-k", "QueryRetrieveLevel=STUDY",
            "-k", "StudyInstanceUID=\(studyUID)",
            hostAddress,
            "\(portNumber)"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            NSLog("[OsiriXBackupController] Não foi possível executar findscu: %@", error.localizedDescription)
            return false
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let reason = process.terminationReason
            NSLog(
                "[OsiriXBackupController] findscu falhou ao verificar estudo %@: status=%d reason=%@ output=%@",
                studyUID,
                process.terminationStatus,
                String(describing: reason),
                output
            )
            DispatchQueue.main.async { [weak self] in
                self?.presentFindscuExecutionFailureAlert(status: process.terminationStatus, reason: reason, output: output)
            }
            return false
        }

        return output.contains(studyUID)
    }

    private func studyExistsWithCountCheck(studyUID: String) -> Bool {
        guard let findscuPath = resolveFindscuPath() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: findscuPath)
        process.arguments = [
            "-S", "-xi",
            "-k", "0008,0052=STUDY",
            "-k", "0020,000D=\(studyUID)",
            "-k", "0020,1200",
            "-k", "0020,1206",
            "-aet", aeTitle,
            "-aec", aeDestination,
            "-to", "30",
            hostAddress,
            "\(portNumber)"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            NSLog("[OsiriXBackupController] Erro ao executar findscu em modo simplificado: %@", error.localizedDescription)
            return false
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let reason = process.terminationReason
            NSLog(
                "[OsiriXBackupController] findscu falhou em verificação simplificada para %@: status=%d reason=%@ output=%@",
                studyUID,
                process.terminationStatus,
                String(describing: reason),
                output
            )
            DispatchQueue.main.async { [weak self] in
                self?.presentFindscuExecutionFailureAlert(status: process.terminationStatus, reason: reason, output: output)
            }
            return false
        }

        return output.contains("# Dicom-Data-Set")
    }
}

// MARK: - State Helpers

private extension OsiriXBackupController {
    @discardableResult
    func updateState<T>(_ block: (inout BackupState) -> T) -> T {
        stateQueue.sync {
            block(&state)
        }
    }

    func readState<T>(_ block: (BackupState) -> T) -> T {
        stateQueue.sync {
            block(state)
        }
    }

    func isBackupRunning() -> Bool {
        readState { $0.isBackupRunning }
    }
}
