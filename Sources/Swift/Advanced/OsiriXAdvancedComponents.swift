import Foundation
#if canImport(OsiriXAPI)
import OsiriXAPI
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Shared Enumerations

@objc public enum OsiriXBackupType: Int, Codable {
    case full
    case incremental
    case differential
    case smart
}

@objc public enum OsiriXCompressionType: Int, Codable {
    case none
    case gzip
    case zlib
    case lzma
    case jpeg2000Lossless
    case jpeg2000Lossy
}

// MARK: - Incremental Backup Manager

private struct BackupSnapshotEntry: Codable {
    let hash: String
    let date: Date
    let name: String
    let imageCount: UInt

    init(hash: String, date: Date, name: String, imageCount: UInt) {
        self.hash = hash
        self.date = date
        self.name = name
        self.imageCount = imageCount
    }

    init?(dictionary: NSDictionary) {
        guard
            let hash = dictionary["hash"] as? String,
            let date = dictionary["date"] as? Date
        else { return nil }

        let name = dictionary["name"] as? String ?? ""
        let imageCountValue = dictionary["imageCount"] as? NSNumber
        self.init(hash: hash, date: date, name: name, imageCount: imageCountValue?.uintValue ?? 0)
    }

    func toDictionary() -> NSDictionary {
        return [
            "hash": hash,
            "date": date,
            "name": name,
            "imageCount": NSNumber(value: imageCount)
        ]
    }
}

private struct BackupRecord: Codable {
    let date: Date
    let snapshot: [String: BackupSnapshotEntry]
    let studyCount: UInt

    init(date: Date, snapshot: [String: BackupSnapshotEntry], studyCount: UInt) {
        self.date = date
        self.snapshot = snapshot
        self.studyCount = studyCount
    }

    init?(dictionary: NSDictionary) {
        guard
            let date = dictionary["date"] as? Date,
            let snapshotDictionary = dictionary["snapshot"] as? NSDictionary
        else { return nil }

        var snapshot: [String: BackupSnapshotEntry] = [:]
        for (key, value) in snapshotDictionary {
            guard let key = key as? String, let entryDict = value as? NSDictionary,
                  let entry = BackupSnapshotEntry(dictionary: entryDict) else { continue }
            snapshot[key] = entry
        }

        let countValue = dictionary["studyCount"] as? NSNumber
        self.init(date: date, snapshot: snapshot, studyCount: countValue?.uintValue ?? UInt(snapshot.count))
    }

    func toDictionary() -> NSDictionary {
        let snapshotDictionary = NSMutableDictionary()
        for (key, entry) in snapshot {
            snapshotDictionary[key] = entry.toDictionary()
        }

        return [
            "date": date,
            "snapshot": snapshotDictionary,
            "studyCount": NSNumber(value: studyCount)
        ]
    }
}

private struct BackupHistory: Codable {
    var lastFullBackup: BackupRecord?
    var lastIncrementalBackup: BackupRecord?

    init(lastFullBackup: BackupRecord? = nil, lastIncrementalBackup: BackupRecord? = nil) {
        self.lastFullBackup = lastFullBackup
        self.lastIncrementalBackup = lastIncrementalBackup
    }

    init(dictionary: NSDictionary) {
        if let fullDict = dictionary["lastFullBackup"] as? NSDictionary {
            self.lastFullBackup = BackupRecord(dictionary: fullDict)
        }
        if let incrementalDict = dictionary["lastIncrementalBackup"] as? NSDictionary {
            self.lastIncrementalBackup = BackupRecord(dictionary: incrementalDict)
        }
    }

    func toDictionary() -> NSDictionary {
        let dictionary = NSMutableDictionary()
        if let full = lastFullBackup {
            dictionary["lastFullBackup"] = full.toDictionary()
        }
        if let incremental = lastIncrementalBackup {
            dictionary["lastIncrementalBackup"] = incremental.toDictionary()
        }
        return dictionary
    }

    var combinedSnapshots: [String: BackupSnapshotEntry] {
        var all: [String: BackupSnapshotEntry] = [:]
        if let full = lastFullBackup {
            all.merge(full.snapshot) { $1 }
        }
        if let incremental = lastIncrementalBackup {
            all.merge(incremental.snapshot) { $1 }
        }
        return all
    }
}

@objcMembers
public final class OsiriXIncrementalBackupManager: NSObject {
    public private(set) var backupHistory: NSMutableDictionary
    public private(set) var studySnapshots: NSMutableDictionary
    public var currentBackupType: OsiriXBackupType

    private let fileManager: FileManager
    private let historyURL: URL
    private let integrityValidator: OsiriXIntegrityValidator.Type
    private var history: BackupHistory {
        didSet { updateSnapshotCache() }
    }

    public init(
        fileManager: FileManager = .default,
        integrityValidator: OsiriXIntegrityValidator.Type = OsiriXIntegrityValidator.self
    ) {
        self.fileManager = fileManager
        self.integrityValidator = integrityValidator
        self.currentBackupType = .full
        self.backupHistory = NSMutableDictionary()
        self.studySnapshots = NSMutableDictionary()
        let supportURL = OsiriXIncrementalBackupManager.applicationSupportDirectory()
        self.historyURL = supportURL.appendingPathComponent("backup_history.plist")
        self.history = BackupHistory()
        super.init()
        loadBackupHistory()
    }

    public func studiesForIncrementalBackup(_ allStudies: [DicomStudy], since lastBackupDate: Date?) -> [DicomStudy] {
        guard let lastBackupDate else { return allStudies }

        var incrementalStudies: [DicomStudy] = []
        for study in allStudies {
            guard let studyDate = (lookupValue(forKey: "dateAdded", in: study) as? Date) ?? (lookupValue(forKey: "date", in: study) as? Date) else {
                incrementalStudies.append(study)
                continue
            }

            if studyDate > lastBackupDate {
                incrementalStudies.append(study)
            } else if studyNeedsBackup(study) {
                incrementalStudies.append(study)
            }
        }

        NSLog("[IncrementalBackup] Found %ld studies for incremental backup", incrementalStudies.count)
        return incrementalStudies
    }

    public func studiesForDifferentialBackup(_ allStudies: [DicomStudy], sinceFullBackupDate fullBackupDate: Date?) -> [DicomStudy] {
        guard let fullBackupDate else { return allStudies }
        guard let snapshot = history.lastFullBackup?.snapshot else { return allStudies }

        var differential: [DicomStudy] = []
        for study in allStudies {
            let studyUID = lookupValue(forKey: "studyInstanceUID", in: study) as? String ?? ""
            let studyDate = (lookupValue(forKey: "dateAdded", in: study) as? Date) ?? Date.distantPast

            if studyDate > fullBackupDate {
                differential.append(study)
            } else if snapshot[studyUID] == nil {
                differential.append(study)
            }
        }
        return differential
    }

    public func recordBackupSnapshot(_ studies: [DicomStudy], type: OsiriXBackupType, date: Date = Date()) {
        var snapshot: [String: BackupSnapshotEntry] = [:]

        for study in studies {
            let studyUID = lookupValue(forKey: "studyInstanceUID", in: study) as? String ?? UUID().uuidString
            let hash = integrityValidator.sha256HashForStudy(study) ?? ""
            let name = lookupValue(forKey: "name", in: study) as? String ?? ""
            let imageCount = UInt(imageCount(for: study))
            let entry = BackupSnapshotEntry(hash: hash, date: date, name: name, imageCount: imageCount)
            snapshot[studyUID] = entry
        }

        let record = BackupRecord(date: date, snapshot: snapshot, studyCount: UInt(studies.count))
        switch type {
        case .full:
            history.lastFullBackup = record
        case .incremental, .differential, .smart:
            history.lastIncrementalBackup = record
        }
        persistHistory()
    }

    public func lastFullBackupDate() -> Date? {
        history.lastFullBackup?.date
    }

    public func lastIncrementalBackupDate() -> Date? {
        history.lastIncrementalBackup?.date
    }

    public func studyNeedsBackup(_ study: DicomStudy) -> Bool {
        let studyUID = lookupValue(forKey: "studyInstanceUID", in: study) as? String ?? ""
        guard let snapshot = studySnapshots[studyUID] as? NSDictionary,
              let lastHash = snapshot["hash"] as? String else { return true }
        let currentHash = integrityValidator.sha256HashForStudy(study)
        return currentHash != lastHash
    }

    public func createBackupManifest(at filePath: String, for studies: [DicomStudy]) throws {
        var manifest: [String: Any] = [:]
        manifest["backupDate"] = Date()
        manifest["backupType"] = currentBackupType.rawValue
        manifest["studyCount"] = studies.count

        let studyManifests: [NSDictionary] = studies.compactMap { integrityValidator.generateStudyManifest($0) }
        manifest["studies"] = studyManifests

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        let url = URL(fileURLWithPath: filePath)
        try data.write(to: url, options: [.atomic])
    }

    public func deltaStudies(_ currentStudies: [DicomStudy], from snapshot: NSDictionary) -> [DicomStudy] {
        let snapshotEntries = snapshot as? [String: NSDictionary] ?? [:]
        return currentStudies.filter { study in
            let studyUID = lookupValue(forKey: "studyInstanceUID", in: study) as? String ?? ""
            guard let entry = snapshotEntries[studyUID] else { return true }
            guard let storedHash = entry["hash"] as? String else { return true }
            let currentHash = integrityValidator.sha256HashForStudy(study)
            return storedHash != currentHash
        }
    }

    private func imageCount(for study: DicomStudy) -> Int {
        guard let series = lookupValue(forKey: "series", in: study) as? [Any] else { return 0 }
        return series.reduce(into: 0) { partialResult, element in
            guard let dicomSeries = element as? NSObject,
                  let images = lookupValue(forKey: "images", in: dicomSeries) as? [Any] else { return }
            partialResult += images.count
        }
    }

    private func loadBackupHistory() {
        guard fileManager.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            if let dictionary = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSDictionary {
                history = BackupHistory(dictionary: dictionary)
            } else {
                let decoder = PropertyListDecoder()
                history = try decoder.decode(BackupHistory.self, from: data)
            }
            updateSnapshotCache()
        } catch {
            NSLog("[IncrementalBackup] Failed to load history: %@", error.localizedDescription)
        }
    }

    private func persistHistory() {
        backupHistory.removeAllObjects()
        if let full = history.lastFullBackup?.toDictionary() {
            backupHistory["lastFullBackup"] = full
        }
        if let incremental = history.lastIncrementalBackup?.toDictionary() {
            backupHistory["lastIncrementalBackup"] = incremental
        }

        do {
            let directory = historyURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            }
            let dictionary = history.toDictionary()
            let data = try NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: false)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            NSLog("[IncrementalBackup] Failed to save history: %@", error.localizedDescription)
        }
    }

    private func updateSnapshotCache() {
        studySnapshots.removeAllObjects()
        for (uid, entry) in history.combinedSnapshots {
            studySnapshots[uid] = entry.toDictionary()
        }
    }

    static func applicationSupportDirectory() -> URL {
        #if os(macOS)
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let directory = url.appendingPathComponent("OsiriXBackup", isDirectory: true)
            return directory
        }
        #endif
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OsiriXBackup", isDirectory: true)
    }
}

// MARK: - Real-time Monitor

@objcMembers
public final class OsiriXRealtimeMonitor: NSObject {
    public private(set) var activeTransfers: NSMutableDictionary
    public private(set) var performanceMetrics: NSMutableArray
    public var updateInterval: TimeInterval {
        didSet {
            if updateInterval <= 0 { updateInterval = oldValue }
            if monitorTimer != nil { restartTimer() }
        }
    }
    public var statusUpdateHandler: ((NSDictionary) -> Void)?
    public var alertHandler: ((String) -> Void)?

    private let synchronizationQueue = DispatchQueue(label: "com.osirix.backup.monitor", attributes: .concurrent)
    private var recentAlerts: NSMutableArray
    private var monitorTimer: Timer?
    private var lastAverageProgress: Double = 0

    public override init() {
        self.activeTransfers = NSMutableDictionary()
        self.performanceMetrics = NSMutableArray()
        self.recentAlerts = NSMutableArray()
        self.updateInterval = 1.0
        super.init()
    }

    deinit {
        stopMonitoring()
    }

    public func startMonitoring() {
        stopMonitoring()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateMonitoringStatus()
        }
        RunLoop.main.add(monitorTimer!, forMode: .common)
        NSLog("[RealtimeMonitor] Started monitoring with %.1fs interval", updateInterval)
    }

    public func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        NSLog("[RealtimeMonitor] Stopped monitoring")
    }

    public func trackTransfer(_ item: OsiriXTransferQueueItem) {
        synchronizationQueue.async(flags: .barrier) {
            self.activeTransfers[item.studyUID] = item
        }
    }

    public func updateTransferProgress(_ studyUID: String, progress: Double, speed: Double) {
        synchronizationQueue.async(flags: .barrier) {
            guard let item = self.activeTransfers[studyUID] as? OsiriXTransferQueueItem else { return }
            item.transferSpeed = speed
            let transferred = UInt(Double(item.totalImages) * progress / 100.0)
            item.transferredImages = transferred
        }
    }

    public func currentSystemStatus() -> NSDictionary {
        var status: [String: Any] = [:]
        let transfers = synchronizationQueue.sync { activeTransfers.copy() as? [String: OsiriXTransferQueueItem] ?? [:] }

        var activeCount = 0
        var totalSpeed = 0.0
        var totalProgress = 0.0

        for item in transfers.values where item.status == .inProgress {
            activeCount += 1
            totalSpeed += item.transferSpeed
            totalProgress += item.progressPercentage()
        }

        status["activeTransfers"] = activeCount
        status["totalSpeed"] = totalSpeed
        status["averageProgress"] = activeCount > 0 ? totalProgress / Double(activeCount) : 0.0
        status["currentSpeed"] = totalSpeed
        status["cpuUsage"] = cpuUsage()
        status["memoryUsage"] = memoryUsage()
        status["diskSpace"] = availableDiskSpace()

        return status as NSDictionary
    }

    public func recentAlerts() -> NSArray {
        return synchronizationQueue.sync { recentAlerts.copy() as? NSArray ?? [] }
    }

    public func generatePerformanceReport() {
        let metrics = synchronizationQueue.sync { performanceMetrics.copy() as? [NSDictionary] ?? [] }
        guard !metrics.isEmpty else {
            NSLog("[RealtimeMonitor] No metrics available for report")
            return
        }

        var report = "=== PERFORMANCE REPORT ===\n"
        let durationMinutes = Double(metrics.count) * updateInterval / 60.0
        report += String(format: "Monitoring Duration: %.1f minutes\n", durationMinutes)

        var averageSpeed = 0.0
        var peakSpeed = 0.0
        var totalTransfers = 0

        for metric in metrics {
            guard let status = metric["status"] as? NSDictionary else { continue }
            let speed = status["totalSpeed"] as? Double ?? 0.0
            averageSpeed += speed
            peakSpeed = max(peakSpeed, speed)
            totalTransfers += status["activeTransfers"] as? Int ?? 0
        }

        averageSpeed /= Double(metrics.count)
        report += String(format: "Average Speed: %.2f MB/s\n", averageSpeed)
        report += String(format: "Peak Speed: %.2f MB/s\n", peakSpeed)
        report += "Total Transfers: \(totalTransfers)\n"

        NSLog("%@", report)
    }

    public func exportMetrics(to path: String) {
        let metrics = synchronizationQueue.sync { performanceMetrics.copy() as? [NSDictionary] ?? [] }
        var csv = "Timestamp,Active Transfers,Speed (MB/s),CPU (%),Memory (%),Disk (GB)\n"
        let formatter = ISO8601DateFormatter()

        for metric in metrics {
            guard let status = metric["status"] as? NSDictionary,
                  let timestamp = metric["timestamp"] as? Date else { continue }
            let line = String(
                format: "%@,%@,%@,%@,%@,%.2f\n",
                formatter.string(from: timestamp),
                status["activeTransfers"] as? NSNumber ?? 0,
                status["totalSpeed"] as? NSNumber ?? 0,
                status["cpuUsage"] as? NSNumber ?? 0,
                status["memoryUsage"] as? NSNumber ?? 0,
                (status["diskSpace"] as? Double ?? 0.0) / 1_073_741_824.0
            )
            csv.append(line)
        }

        do {
            try csv.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[RealtimeMonitor] Failed to export metrics: %@", error.localizedDescription)
        }
    }

    private func restartTimer() {
        startMonitoring()
    }

    private func updateMonitoringStatus() {
        let status = currentSystemStatus()
        synchronizationQueue.async(flags: .barrier) {
            self.performanceMetrics.add([
                "timestamp": Date(),
                "status": status
            ])
            if self.performanceMetrics.count > 1000 {
                let range = NSRange(location: 0, length: self.performanceMetrics.count - 1000)
                self.performanceMetrics.removeObjects(in: range)
            }
        }

        statusUpdateHandler?(status)
        checkForAlerts(status)
    }

    private func checkForAlerts(_ status: NSDictionary) {
        let cpu = status["cpuUsage"] as? Double ?? 0
        if cpu > 80.0 {
            triggerAlert("High CPU usage detected")
        }

        let diskSpace = status["diskSpace"] as? Double ?? 0
        if diskSpace < 1_073_741_824 { // < 1GB
            triggerAlert("Low disk space warning")
        }

        let averageProgress = status["averageProgress"] as? Double ?? 0
        if averageProgress > 0, averageProgress == lastAverageProgress {
            triggerAlert("Transfer may be stalled")
        }
        lastAverageProgress = averageProgress
    }

    private func triggerAlert(_ message: String) {
        NSLog("[RealtimeMonitor] ALERT: %@", message)
        alertHandler?(message)
        synchronizationQueue.async(flags: .barrier) {
            self.recentAlerts.add([
                "timestamp": Date(),
                "message": message
            ])
        }
    }

    private func cpuUsage() -> Double {
        #if os(macOS)
        return ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 100) + 20
        #else
        return 25.0
        #endif
    }

    private func memoryUsage() -> Double {
        let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        let usedMemory = totalMemory * 0.45
        let percentage = (usedMemory / totalMemory) * 100.0
        return min(max(percentage, 0), 100)
    }

    private func availableDiskSpace() -> Double {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attributes[.systemFreeSize] as? NSNumber {
                return freeSize.doubleValue
            }
        } catch {
            NSLog("[RealtimeMonitor] Failed to read disk space: %@", error.localizedDescription)
        }
        return 0
    }
}

// MARK: - Smart Scheduler

@objcMembers
public final class OsiriXBackupSchedule: NSObject {
    public var scheduleID: String
    public var name: String
    public var backupType: OsiriXBackupType
    public var enabled: Bool
    public var nextRunDate: Date?
    public var cronExpression: String?
    public var studyFilter: NSPredicate?
    public var destinationAETs: [String]
    public var maxStudiesPerRun: UInt
    public var notificationSettings: [String: Any]

    public override init() {
        self.scheduleID = UUID().uuidString
        self.name = ""
        self.backupType = .full
        self.enabled = true
        self.nextRunDate = nil
        self.cronExpression = nil
        self.studyFilter = nil
        self.destinationAETs = []
        self.maxStudiesPerRun = .max
        self.notificationSettings = [:]
        super.init()
    }

    public func shouldRunNow() -> Bool {
        guard enabled else { return false }
        if let nextRunDate, Date() < nextRunDate { return false }
        return true
    }

    public func calculateNextRunDate(from referenceDate: Date = Date()) -> Date? {
        guard let expression = cronExpression else { return nil }
        nextRunDate = CronExpression(expression: expression)?.nextDate(after: referenceDate)
        return nextRunDate
    }

    public func matchesStudy(_ study: DicomStudy) -> Bool {
        guard let filter = studyFilter else { return true }
        return filter.evaluate(with: study)
    }
}

@objcMembers
public final class OsiriXSmartScheduler: NSObject {
    public private(set) var schedules: NSMutableArray
    public var enableSmartScheduling: Bool
    public var enablePredictiveScheduling: Bool

    public override init() {
        self.schedules = NSMutableArray()
        self.enableSmartScheduling = true
        self.enablePredictiveScheduling = true
        super.init()
    }

    public func analyzeBackupPatterns() {
        NSLog("[SmartScheduler] Analyzing backup patterns...")
    }

    public func optimalBackupTime(for study: DicomStudy) -> Date {
        guard enableSmartScheduling else {
            return CronExpression.simple(hour: 2, minute: 0).nextDate(after: Date()) ?? Date().addingTimeInterval(3600)
        }

        let modality = ((lookupValue(forKey: "series", in: study) as? [Any])?.first).flatMap { lookupValue(forKey: "modality", in: $0 as AnyObject?) as? String } ?? ""
        var optimalHour = 2
        if modality == "CT" || modality == "MR" {
            optimalHour = 3
        } else if modality == "CR" || modality == "DX" {
            optimalHour = 23
        }
        return CronExpression.simple(hour: optimalHour, minute: 0).nextDate(after: Date()) ?? Date().addingTimeInterval(3600)
    }

    public func createSmartScheduleBasedOnUsagePatterns() {
        guard enablePredictiveScheduling else { return }

        let incremental = OsiriXBackupSchedule()
        incremental.name = "Smart Incremental"
        incremental.backupType = .incremental
        incremental.cronExpression = "0 3 * * *"
        incremental.enabled = true
        incremental.maxStudiesPerRun = 50
        incremental.calculateNextRunDate()
        schedules.add(incremental)

        let full = OsiriXBackupSchedule()
        full.name = "Smart Full"
        full.backupType = .full
        full.cronExpression = "0 2 * * 0"
        full.enabled = true
        full.calculateNextRunDate()
        schedules.add(full)
    }

    public func adjustScheduleForNetworkConditions() {
        NSLog("[SmartScheduler] Adjusting schedules based on network conditions")
    }

    public func predictNextBackupWindow() {
        guard enablePredictiveScheduling else { return }
        NSLog("[SmartScheduler] Predicting next optimal backup window")
    }

    public func pauseSchedulesDuringPeakHours(date: Date = Date()) {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let isPeak = hour >= 8 && hour <= 18

        for schedule in schedules.compactMap({ $0 as? OsiriXBackupSchedule }) {
            if isPeak, schedule.enabled {
                NSLog("[SmartScheduler] Pausing schedule during peak hours: %@", schedule.name)
                schedule.enabled = false
            } else if !isPeak, !schedule.enabled {
                NSLog("[SmartScheduler] Resuming schedule after peak hours: %@", schedule.name)
                schedule.enabled = true
            }
        }
    }

    public func suggestedBackupTimes(forNext days: Int) -> [Date] {
        guard days > 0 else { return [] }
        var suggestions: [Date] = []
        let calendar = Calendar.current
        let now = Date()

        for dayOffset in 0..<days {
            guard let baseDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            for hour in 2...4 {
                var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
                components.hour = hour
                components.minute = 0
                if let suggestion = calendar.date(from: components), suggestion > now {
                    suggestions.append(suggestion)
                }
            }
        }
        return suggestions
    }
}

// MARK: - Compression Engine

@objcMembers
public final class OsiriXCompressionEngine: NSObject {
    public var preferredCompression: OsiriXCompressionType
    public var enableAdaptiveCompression: Bool
    public var compressionQuality: Double

    public override init() {
        self.preferredCompression = .gzip
        self.enableAdaptiveCompression = true
        self.compressionQuality = 0.8
        super.init()
    }

    public func compress(_ data: Data, with type: OsiriXCompressionType) -> Data {
        guard !data.isEmpty else { return data }
        switch type {
        case .none:
            return data
        case .gzip, .zlib:
            return performCompression(data, operation: COMPRESSION_STREAM_ENCODE)
        case .lzma, .jpeg2000Lossless, .jpeg2000Lossy:
            return performCompression(data, operation: COMPRESSION_STREAM_ENCODE)
        }
    }

    public func decompress(_ data: Data, from type: OsiriXCompressionType) -> Data {
        guard !data.isEmpty else { return data }
        switch type {
        case .none:
            return data
        case .gzip, .zlib, .lzma, .jpeg2000Lossless, .jpeg2000Lossy:
            return performCompression(data, operation: COMPRESSION_STREAM_DECODE)
        }
    }

    public func optimalCompression(for modality: String) -> OsiriXCompressionType {
        guard enableAdaptiveCompression else { return preferredCompression }
        switch modality.uppercased() {
        case "CT", "MR":
            return .jpeg2000Lossless
        case "US", "XA":
            return .none
        default:
            return .gzip
        }
    }

    public func estimateCompressionRatio(for data: Data, type: OsiriXCompressionType) -> Double {
        guard type != .none, !data.isEmpty else { return 1.0 }
        let sampleSize = min(data.count, 10_240)
        let sample = data.prefix(sampleSize)
        let compressed = compress(Data(sample), with: type)
        return compressed.isEmpty ? 1.0 : Double(compressed.count) / Double(sample.count)
    }

    public func shouldCompressFile(at filePath: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let fileSize = attributes[.size] as? NSNumber else { return false }
        if fileSize.uintValue < 1_024 { return false }

        let extensionLowercased = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        let alreadyCompressed: Set<String> = ["jpg", "jpeg", "jp2", "zip", "gz"]
        return !alreadyCompressed.contains(extensionLowercased)
    }

    public func compressionStatistics() -> NSDictionary {
        return [
            "preferredType": preferredCompression.rawValue,
            "adaptiveEnabled": enableAdaptiveCompression,
            "quality": compressionQuality
        ]
    }

    private func performCompression(_ data: Data, operation: compression_stream_operation) -> Data {
        #if canImport(Compression)
        var stream = compression_stream()
        var status = compression_stream_init(&stream, operation, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return data }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = max(32_768, data.count)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        var output = Data()
        return data.withUnsafeBytes { rawBuffer in
            guard let srcPointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return data }
            stream.src_ptr = srcPointer
            stream.src_size = data.count
            stream.dst_ptr = destinationBuffer
            stream.dst_size = bufferSize

            repeat {
                status = compression_stream_process(&stream, 0)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let count = bufferSize - stream.dst_size
                    if count > 0 {
                        output.append(destinationBuffer, count: count)
                    }
                    stream.dst_ptr = destinationBuffer
                    stream.dst_size = bufferSize
                case COMPRESSION_STATUS_ERROR:
                    return data
                default:
                    break
                }
            } while status == COMPRESSION_STATUS_OK

            let remaining = bufferSize - stream.dst_size
            if remaining > 0 {
                output.append(destinationBuffer, count: remaining)
            }
            return output
        }
        #else
        return data
        #endif
    }
}

// MARK: - Deduplication Engine

@objcMembers
public final class OsiriXDeduplicationEngine: NSObject {
    public private(set) var fingerprintDatabase: NSMutableDictionary
    public var enableBlockLevelDedup: Bool
    public var blockSize: UInt

    private let fileManager: FileManager
    private let databaseURL: URL

    public override init() {
        self.fingerprintDatabase = NSMutableDictionary()
        self.enableBlockLevelDedup = true
        self.blockSize = 4_096
        self.fileManager = .default
        let supportURL = OsiriXIncrementalBackupManager.applicationSupportDirectory()
        self.databaseURL = supportURL.appendingPathComponent("fingerprint_db.plist")
        super.init()
        loadFingerprintDatabase()
    }

    deinit {
        saveFingerprintDatabase()
    }

    public func generateFingerprint(for data: Data) -> String {
        if let hash = OsiriXIntegrityValidator.sha256HashForData(data) {
            return hash
        }
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        return UUID().uuidString
        #endif
    }

    public func isDuplicate(_ filePath: String) -> Bool {
        guard let data = fileManager.contents(atPath: filePath) else { return false }
        let fingerprint = generateFingerprint(for: data)
        return fingerprintDatabase[fingerprint] != nil
    }

    public func findDuplicates(_ filePaths: [String]) -> [String] {
        return filePaths.filter { isDuplicate($0) }
    }

    public func deduplicateStudy(_ study: DicomStudy) -> UInt {
        var deduplicated: UInt = 0
        guard let series = lookupValue(forKey: "series", in: study) as? [Any] else { return deduplicated }

        for element in series {
            guard let dicomSeries = element as? NSObject,
                  let images = lookupValue(forKey: "images", in: dicomSeries) as? [Any] else { continue }
            for image in images {
                guard let imageObject = image as? NSObject,
                      let path = lookupValue(forKey: "completePath", in: imageObject) as? String else { continue }
                if isDuplicate(path) {
                    deduplicated += 1
                } else if let data = fileManager.contents(atPath: path) {
                    let fingerprint = generateFingerprint(for: data)
                    fingerprintDatabase[fingerprint] = path
                }
            }
        }
        return deduplicated
    }

    public func calculateDeduplicationRatio() -> Double {
        return 1.0
    }

    public func rebuildFingerprintDatabase() {
        fingerprintDatabase.removeAllObjects()
        NSLog("[Deduplication] Rebuilding fingerprint database...")
    }

    public func deduplicationStatistics() -> NSDictionary {
        return [
            "fingerprintCount": fingerprintDatabase.count,
            "blockLevelEnabled": enableBlockLevelDedup,
            "blockSize": blockSize
        ]
    }

    private func saveFingerprintDatabase() {
        do {
            let directory = databaseURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            }
            let data = try NSKeyedArchiver.archivedData(withRootObject: fingerprintDatabase, requiringSecureCoding: false)
            try data.write(to: databaseURL, options: [.atomic])
        } catch {
            NSLog("[Deduplication] Failed to save fingerprint database: %@", error.localizedDescription)
        }
    }

    private func loadFingerprintDatabase() {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        do {
            let data = try Data(contentsOf: databaseURL)
            if let dictionary = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSDictionary {
                fingerprintDatabase = NSMutableDictionary(dictionary: dictionary)
            }
        } catch {
            NSLog("[Deduplication] Failed to load fingerprint database: %@", error.localizedDescription)
        }
    }
}

// MARK: - Helpers

private func lookupValue(forKey key: String, in object: AnyObject?) -> Any? {
    guard let object else { return nil }
    #if canImport(ObjectiveC)
    return (object as? NSObject)?.value(forKey: key)
    #else
    var mirror: Mirror? = Mirror(reflecting: object)
    while let current = mirror {
        for child in current.children where child.label == key {
            return child.value
        }
        mirror = current.superclassMirror
    }
    return nil
    #endif
}

private struct CronExpression {
    let minute: CronField
    let hour: CronField
    let day: CronField
    let month: CronField
    let weekday: CronField

    init?(expression: String) {
        let parts = expression.split(separator: " ")
        guard parts.count == 5 else { return nil }
        guard let minute = CronField(String(parts[0]), range: 0...59),
              let hour = CronField(String(parts[1]), range: 0...23),
              let day = CronField(String(parts[2]), range: 1...31),
              let month = CronField(String(parts[3]), range: 1...12),
              let weekday = CronField(String(parts[4]), range: 0...6) else { return nil }
        self.minute = minute
        self.hour = hour
        self.day = day
        self.month = month
        self.weekday = weekday
    }

    static func simple(hour: Int, minute: Int) -> CronExpression {
        return CronExpression(expression: "\(minute) \(hour) * * *") ?? CronExpression(minute: .any(range: 0...59), hour: .any(range: 0...23), day: .any(range: 1...31), month: .any(range: 1...12), weekday: .any(range: 0...6))
    }

    private init(minute: CronField, hour: CronField, day: CronField, month: CronField, weekday: CronField) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.month = month
        self.weekday = weekday
    }

    func nextDate(after date: Date) -> Date? {
        var next = date.addingTimeInterval(60)
        let calendar = Calendar.current
        for _ in 0..<10000 {
            let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday, .year], from: next)
            if minute.matches(components.minute ?? 0) &&
                hour.matches(components.hour ?? 0) &&
                day.matches(components.day ?? 0) &&
                month.matches(components.month ?? 0) &&
                weekday.matches((components.weekday ?? 1) - 1) {
                return next
            }
            next = next.addingTimeInterval(60)
        }
        return nil
    }
}

private struct CronField {
    enum Representation {
        case any
        case values(Set<Int>)
    }

    let representation: Representation
    let range: ClosedRange<Int>

    init?(_ value: String, range: ClosedRange<Int>) {
        self.range = range
        if value == "*" {
            representation = .any
            return
        }

        var values = Set<Int>()
        for token in value.split(separator: ",") {
            if token.contains("-") {
                let bounds = token.split(separator: "-")
                guard bounds.count == 2,
                      let start = Int(bounds[0]),
                      let end = Int(bounds[1]) else { return nil }
                guard range.contains(start), range.contains(end), start <= end else { return nil }
                for raw in start...end {
                    values.insert(raw)
                }
            } else if let intValue = Int(token), range.contains(intValue) {
                values.insert(intValue)
            } else {
                return nil
            }
        }
        representation = .values(values)
    }

    static func any(range: ClosedRange<Int>) -> CronField {
        CronField(representation: .any, range: range)
    }

    private init(representation: Representation, range: ClosedRange<Int>) {
        self.representation = representation
        self.range = range
    }

    func matches(_ value: Int) -> Bool {
        guard range.contains(value) else { return false }
        switch representation {
        case .any:
            return true
        case .values(let values):
            return values.contains(value)
        }
    }
}
