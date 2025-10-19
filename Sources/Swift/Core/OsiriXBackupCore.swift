import Foundation
#if canImport(OsiriXAPI)
import OsiriXAPI
#endif
#if canImport(Compression)
import Compression
#endif

#if SWIFT_PACKAGE
public enum OsiriXTransferPriority: Int {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3
    case emergency = 4
}

public enum OsiriXTransferStatus: Int {
    case pending
    case queued
    case inProgress
    case completed
    case failed
    case retrying
    case cancelled
    case verifying
}
#endif

#if !canImport(OsiriXAPI)
#if canImport(ObjectiveC)
@objc public class DicomStudy: NSObject {}
@objc public class DicomSeries: NSObject {}
#else
public class DicomStudy: NSObject {}
public class DicomSeries: NSObject {}
#endif
#endif

// MARK: - Helpers

private struct CacheEntry: Codable {
    let hash: String
    let date: Date
    let name: String
    let modality: String
}

private struct CacheSnapshot: Codable {
    let maxCacheSize: UInt
    let entries: [String: CacheEntry]
}

private enum CompressionHelper {
    static func compress(_ data: Data) -> Data {
        #if canImport(Compression)
        return perform(data, operation: COMPRESSION_STREAM_ENCODE) ?? data
        #else
        return data
        #endif
    }

    static func decompress(_ data: Data) -> Data {
        #if canImport(Compression)
        return perform(data, operation: COMPRESSION_STREAM_DECODE) ?? data
        #else
        return data
        #endif
    }

    #if canImport(Compression)
    private static func perform(_ data: Data, operation: compression_stream_operation) -> Data? {
        guard !data.isEmpty else { return data }

        var stream = compression_stream()
        var status = compression_stream_init(&stream, operation, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        var output = Data()
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let sourcePointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            stream.src_ptr = sourcePointer
            stream.src_size = data.count
            stream.dst_ptr = destinationBuffer
            stream.dst_size = bufferSize

            repeat {
                status = compression_stream_process(&stream, 0)

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    if stream.dst_size == 0 || status == COMPRESSION_STATUS_END {
                        output.append(destinationBuffer, count: bufferSize - stream.dst_size)
                        stream.dst_ptr = destinationBuffer
                        stream.dst_size = bufferSize
                    }
                case COMPRESSION_STATUS_ERROR:
                    return nil
                default:
                    break
                }
            } while status == COMPRESSION_STATUS_OK

            if stream.dst_size < bufferSize {
                output.append(destinationBuffer, count: bufferSize - stream.dst_size)
            }

            return output
        }
    }
    #endif
}

private func lookupValue(for key: String, in object: AnyObject?) -> Any? {
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

private enum SHA256Hasher {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(data: Data) -> Data {
        var message = Array(data)
        let bitLength = UInt64(message.count * 8)

        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0)
        }

        let lengthBytes = bitLength.bigEndian
        withUnsafeBytes(of: lengthBytes) { buffer in
            message.append(contentsOf: buffer)
        }

        var h = initialHash

        let chunkCount = message.count / 64
        for chunkIndex in 0..<chunkCount {
            let chunkStart = chunkIndex * 64
            var w = [UInt32](repeating: 0, count: 64)

            for i in 0..<16 {
                let start = chunkStart + (i * 4)
                let word = (UInt32(message[start]) << 24) |
                    (UInt32(message[start + 1]) << 16) |
                    (UInt32(message[start + 2]) << 8) |
                    UInt32(message[start + 3])
                w[i] = word
            }

            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], by: 7) ^ rotateRight(w[i - 15], by: 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], by: 17) ^ rotateRight(w[i - 2], by: 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0]
            var b = h[1]
            var c = h[2]
            var d = h[3]
            var e = h[4]
            var f = h[5]
            var g = h[6]
            var thisH = h[7]

            for i in 0..<64 {
                let S1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = thisH &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = S0 &+ maj

                thisH = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ thisH
        }

        var digest = Data(capacity: 32)
        for value in h {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { buffer in
                digest.append(buffer.bindMemory(to: UInt8.self))
            }
        }

        return digest
    }

    private static func rotateRight(_ value: UInt32, by: UInt32) -> UInt32 {
        return (value >> by) | (value << (32 - by))
    }
}

private enum Hashing {
    static func hexString(for data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Cache Manager

#if canImport(ObjectiveC)
@objcMembers
#endif
public final class OsiriXBackupCacheManager: NSObject {
    public static let sharedManager = OsiriXBackupCacheManager()

    public let studyCache = NSCache<NSString, AnyObject>()

    private let accessLock = NSLock()
    private let persistenceQueue = DispatchQueue(label: "com.osirix.backup.cache.persistence")

    private var storage: [String: CacheEntry] = [:]
    private var writeCounter = 0
    private var _maxCacheSize: UInt = 500 * 1024 * 1024

    public var maxCacheSize: UInt {
        get {
            accessLock.lock()
            defer { accessLock.unlock() }
            return _maxCacheSize
        }
        set {
            accessLock.lock()
            _maxCacheSize = newValue
            updateStudyCacheLimitsLocked()
            accessLock.unlock()
        }
    }

    public var hashCache: NSMutableDictionary {
        accessLock.lock()
        defer { accessLock.unlock() }

        let dict = NSMutableDictionary(capacity: storage.count)
        for (key, entry) in storage {
            dict[key] = [
                "hash": entry.hash,
                "date": entry.date,
                "name": entry.name,
                "modality": entry.modality
            ]
        }
        return dict
    }

    override private init() {
        super.init()
        studyCache.countLimit = 1000
        updateStudyCacheLimitsLocked()
        loadCacheFromDisk()
    }

    public func cacheStudy(_ study: DicomStudy?, withHash hash: String?) {
        guard let study, let hash else { return }

        let studyUID = (lookupValue(for: "studyInstanceUID", in: study) as? String) ?? UUID().uuidString
        let entry = CacheEntry(
            hash: hash,
            date: Date(),
            name: (lookupValue(for: "name", in: study) as? String) ?? "",
            modality: (lookupValue(for: "modality", in: study) as? String) ?? ""
        )

        accessLock.lock()
        storage[studyUID] = entry
        studyCache.setObject(study, forKey: studyUID as NSString)
        writeCounter += 1
        let shouldPersist = writeCounter % 10 == 0
        accessLock.unlock()

        if shouldPersist {
            persistCacheToDisk()
        }
    }

    public func cachedHashForStudy(_ studyUID: String) -> String? {
        accessLock.lock()
        defer { accessLock.unlock() }
        return storage[studyUID]?.hash
    }

    public func isStudyCached(_ studyUID: String) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        return storage[studyUID] != nil
    }

    public func invalidateCache() {
        accessLock.lock()
        storage.removeAll()
        studyCache.removeAllObjects()
        accessLock.unlock()

        let url = cacheFileURL()
        try? FileManager.default.removeItem(at: url)
    }

    public func persistCacheToDisk() {
        let snapshot: CacheSnapshot = accessLock.withLock { [storage, _maxCacheSize] in
            CacheSnapshot(maxCacheSize: _maxCacheSize, entries: storage)
        }

        persistenceQueue.sync {
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)
                let compressed = CompressionHelper.compress(data)
                try compressed.write(to: cacheFileURL(), options: .atomic)
            } catch {
                NSLog("[OsiriXBackupCache] Failed to persist cache: %@", error.localizedDescription)
            }
        }
    }

    public func loadCacheFromDisk() {
        persistenceQueue.sync {
            let url = cacheFileURL()
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            let decodedData = CompressionHelper.decompress(data)

            do {
                let snapshot = try PropertyListDecoder().decode(CacheSnapshot.self, from: decodedData)
                accessLock.lock()
                storage = snapshot.entries
                _maxCacheSize = snapshot.maxCacheSize
                updateStudyCacheLimitsLocked()
                accessLock.unlock()
            } catch {
                NSLog("[OsiriXBackupCache] Failed to load cache: %@", error.localizedDescription)
                accessLock.lock()
                storage.removeAll()
                accessLock.unlock()
            }
        }
    }

    public func cacheStatistics() -> NSDictionary {
        accessLock.lock()
        let entries = storage
        accessLock.unlock()

        let dates = entries.values.map { $0.date }
        let oldest = dates.min()
        let newest = dates.max()

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: cacheFileURL().path)[.size] as? NSNumber)?.uintValue ?? 0

        return [
            "totalEntries": entries.count,
            "cacheSize": fileSize,
            "oldestEntry": oldest ?? NSNull(),
            "newestEntry": newest ?? NSNull(),
            "hitRate": 0.0
        ] as NSDictionary
    }

    private func updateStudyCacheLimitsLocked() {
        studyCache.totalCostLimit = Int(min(_maxCacheSize, UInt(Int.max)))
    }

    private func cacheFileURL() -> URL {
        let directory = cacheDirectoryURL()
        return directory.appendingPathComponent("study_cache.plist")
    }

    private func cacheDirectoryURL() -> URL {
        let fileManager = FileManager.default
        #if os(macOS)
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #else
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        #endif
        let root = base ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent("OsiriXBackup", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}

// MARK: - Transfer Queue Item

#if canImport(ObjectiveC)
@objcMembers
#endif
public final class OsiriXTransferQueueItem: NSObject {
    public var studyUID: String = ""
    public var studyName: String = ""
    public var study: DicomStudy?
    public var priority: OsiriXTransferPriority = .normal
    public var status: OsiriXTransferStatus = .pending
    public var queuedDate: Date = Date()
    public var startDate: Date?
    public var completionDate: Date?
    public var retryCount: UInt = 0
    public var nextRetryInterval: TimeInterval = 5.0
    public var destinationAET: String = ""
    public var lastError: String = ""
    public var totalImages: UInt = 0
    public var transferredImages: UInt = 0
    public var transferSpeed: Double = 0
    public var sha256Hash: String = ""

    public override init() {
        super.init()
    }

    public func elapsedTime() -> TimeInterval {
        guard let startDate else { return 0 }
        let endDate = completionDate ?? Date()
        return endDate.timeIntervalSince(startDate)
    }

    public func estimatedTimeRemaining() -> TimeInterval {
        guard transferredImages > 0, transferSpeed > 0 else { return -1 }
        let remainingImages = totalImages > transferredImages ? totalImages - transferredImages : 0
        let averageImageSize = 0.5 // MB estimate
        let remainingMB = Double(remainingImages) * averageImageSize
        return remainingMB / transferSpeed
    }

    public func progressPercentage() -> Double {
        guard totalImages > 0 else { return 0 }
        return (Double(transferredImages) * 100.0) / Double(totalImages)
    }
}

// MARK: - Transfer Queue

#if canImport(ObjectiveC)
@objcMembers
#endif
public final class OsiriXTransferQueue: NSObject {
    private var items: [OsiriXTransferQueueItem] = []
    private let lock = NSLock()

    private var _maxConcurrentTransfers: UInt = 3
    private var _maxRetries: UInt = 3
    private var _enablePriorityQueue: Bool = true

    public var queue: NSMutableArray {
        lock.lock()
        defer { lock.unlock() }
        return NSMutableArray(array: items)
    }

    public var maxConcurrentTransfers: UInt {
        get { lock.withLock { _maxConcurrentTransfers } }
        set { lock.withLock { _maxConcurrentTransfers = newValue } }
    }

    public var maxRetries: UInt {
        get { lock.withLock { _maxRetries } }
        set { lock.withLock { _maxRetries = newValue } }
    }

    public var enablePriorityQueue: Bool {
        get { lock.withLock { _enablePriorityQueue } }
        set { lock.withLock { _enablePriorityQueue = newValue; sortQueueByPriorityLocked() } }
    }

    public override init() {
        super.init()
    }

    public func addItem(_ item: OsiriXTransferQueueItem) {
        lock.lock()
        items.append(item)
        if _enablePriorityQueue {
            sortQueueByPriorityLocked()
        }
        lock.unlock()
    }

    public func removeItem(_ item: OsiriXTransferQueueItem) {
        lock.lock()
        items.removeAll { $0 === item }
        lock.unlock()
    }

    public func nextItemToProcess() -> OsiriXTransferQueueItem? {
        lock.lock()
        defer { lock.unlock() }

        let activeCount = items.filter { $0.status == .inProgress }.count
        if activeCount >= _maxConcurrentTransfers {
            return nil
        }

        if let pending = items.first(where: { $0.status == .pending || $0.status == .queued }) {
            return pending
        }

        let now = Date()
        return items.first { item in
            guard item.status == .retrying else { return false }
            let nextDate = item.queuedDate.addingTimeInterval(item.nextRetryInterval)
            return now >= nextDate
        }
    }

    public func itemsWithStatus(_ status: OsiriXTransferStatus) -> [OsiriXTransferQueueItem] {
        lock.lock()
        let result = items.filter { $0.status == status }
        lock.unlock()
        return result
    }

    public func prioritizeItem(_ item: OsiriXTransferQueueItem) {
        lock.lock()
        item.priority = .urgent
        sortQueueByPriorityLocked()
        lock.unlock()
    }

    public func cancelAllTransfers() {
        lock.lock()
        for item in items where item.status == .inProgress || item.status == .pending || item.status == .queued {
            item.status = .cancelled
        }
        lock.unlock()
    }

    public func queueStatistics() -> NSDictionary {
        lock.lock()
        defer { lock.unlock() }

        var pending = 0
        var inProgress = 0
        var completed = 0
        var failed = 0
        var totalProgress: Double = 0

        for item in items {
            switch item.status {
            case .pending, .queued:
                pending += 1
            case .inProgress:
                inProgress += 1
                totalProgress += item.progressPercentage()
            case .completed:
                completed += 1
            case .failed:
                failed += 1
            default:
                break
            }
        }

        let averageProgress = inProgress > 0 ? totalProgress / Double(inProgress) : 0
        return [
            "totalItems": items.count,
            "pending": pending,
            "inProgress": inProgress,
            "completed": completed,
            "failed": failed,
            "averageProgress": averageProgress
        ] as NSDictionary
    }

    private func sortQueueByPriorityLocked() {
        items.sort { lhs, rhs in
            if lhs.priority.rawValue != rhs.priority.rawValue {
                return lhs.priority.rawValue > rhs.priority.rawValue
            }
            return lhs.queuedDate < rhs.queuedDate
        }
    }
}

// MARK: - Integrity Validator

#if canImport(ObjectiveC)
@objcMembers
#endif
public final class OsiriXIntegrityValidator: NSObject {
    public static func sha256HashForFile(_ filePath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            data.append(chunk)
        }

        return Hashing.hexString(for: SHA256Hasher.hash(data: data))
    }

    public static func sha256HashForData(_ data: Data?) -> String? {
        guard let data else { return nil }
        return Hashing.hexString(for: SHA256Hasher.hash(data: data))
    }

    public static func sha256HashForStudy(_ study: DicomStudy?) -> String? {
        guard let study else { return nil }

        var combined = ""
        combined += (lookupValue(for: "studyInstanceUID", in: study) as? String) ?? ""
        combined += (lookupValue(for: "name", in: study) as? String) ?? ""
        if let date = lookupValue(for: "date", in: study) as? Date {
            combined += String(date.timeIntervalSince1970)
        }

        if let series = lookupValue(for: "series", in: study) as? [Any] {
            for element in series {
                if let dicomSeries = element as? NSObject {
                    combined += (lookupValue(for: "seriesInstanceUID", in: dicomSeries) as? String) ?? ""
                    if let images = lookupValue(for: "images", in: dicomSeries) as? [Any] {
                        combined += String(images.count)
                        for image in images {
                            if let imageObject = image as? NSObject {
                                combined += (lookupValue(for: "sopInstanceUID", in: imageObject) as? String) ?? ""
                            }
                        }
                    }
                }
            }
        }

        guard let data = combined.data(using: .utf8) else { return nil }
        return Hashing.hexString(for: SHA256Hasher.hash(data: data))
    }

    public static func validateStudyIntegrity(_ study: DicomStudy?, expectedHash: String) -> Bool {
        guard let currentHash = sha256HashForStudy(study) else { return false }
        return currentHash == expectedHash
    }

    public static func generateStudyManifest(_ study: DicomStudy?) -> NSDictionary? {
        guard let study else { return nil }

        let manifest = NSMutableDictionary()
        manifest["studyInstanceUID"] = lookupValue(for: "studyInstanceUID", in: study)
        let studyHash = sha256HashForStudy(study)
        manifest["studyHash"] = studyHash
        manifest["createdDate"] = Date()
        manifest["studyDate"] = lookupValue(for: "date", in: study)
        manifest["patientName"] = lookupValue(for: "name", in: study)

        let seriesManifest = NSMutableArray()
        if let series = lookupValue(for: "series", in: study) as? [Any] {
            for element in series {
                guard let dicomSeries = element as? NSObject else { continue }
                let seriesInfo = NSMutableDictionary()
                seriesInfo["seriesInstanceUID"] = lookupValue(for: "seriesInstanceUID", in: dicomSeries)
                seriesInfo["modality"] = lookupValue(for: "modality", in: dicomSeries)

                if let images = lookupValue(for: "images", in: dicomSeries) as? [Any] {
                    seriesInfo["imageCount"] = images.count
                    var seriesData = ""
                    seriesData += (lookupValue(for: "seriesInstanceUID", in: dicomSeries) as? String) ?? ""
                    for image in images {
                        if let imageObject = image as? NSObject {
                            seriesData += (lookupValue(for: "sopInstanceUID", in: imageObject) as? String) ?? ""
                        }
                    }
                    if let hashData = seriesData.data(using: .utf8) {
                        seriesInfo["seriesHash"] = Hashing.hexString(for: SHA256Hasher.hash(data: hashData))
                    }
                }

                seriesManifest.add(seriesInfo)
            }
        }

        manifest["series"] = seriesManifest
        manifest["totalImages"] = totalImages(in: study)
        return manifest
    }

    public static func validateManifest(_ manifest: NSDictionary?, for study: DicomStudy?) -> Bool {
        guard let manifest, let study else { return false }

        guard let manifestUID = (manifest["studyInstanceUID"] as? String)?.lowercased(),
              let studyUID = (lookupValue(for: "studyInstanceUID", in: study) as? String)?.lowercased(),
              manifestUID == studyUID else {
            return false
        }

        guard let expectedHash = manifest["studyHash"] as? String,
              let currentHash = sha256HashForStudy(study),
              expectedHash == currentHash else {
            NSLog("[IntegrityValidator] Study hash mismatch")
            return false
        }

        if let expectedTotal = manifest["totalImages"] as? UInt, expectedTotal != totalImages(in: study) {
            NSLog("[IntegrityValidator] Image count mismatch: %u vs %u", UInt(totalImages(in: study)), expectedTotal)
            return false
        }

        return true
    }

    private static func totalImages(in study: DicomStudy) -> UInt {
        guard let series = lookupValue(for: "series", in: study) as? [Any] else { return 0 }
        var total: UInt = 0
        for element in series {
            if let dicomSeries = element as? NSObject,
               let images = lookupValue(for: "images", in: dicomSeries) as? [Any] {
                total += UInt(images.count)
            }
        }
        return total
    }
}

// MARK: - Core Placeholder

final class OsiriXBackupCore {
    private(set) var configuration: [String: Any] = [:]

    init() {}

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
