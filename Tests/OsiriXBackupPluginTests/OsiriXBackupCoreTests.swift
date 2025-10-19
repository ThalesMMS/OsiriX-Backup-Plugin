import XCTest
@testable import OsiriXBackupPlugin

private final class MockDicomImage: NSObject {
    var sopInstanceUID: String

    init(uid: String) {
        self.sopInstanceUID = uid
    }
}

private final class MockDicomSeries: NSObject {
    var seriesInstanceUID: String
    var modality: String
    var images: [MockDicomImage]

    init(uid: String, modality: String, images: [MockDicomImage]) {
        self.seriesInstanceUID = uid
        self.modality = modality
        self.images = images
    }
}

private final class MockDicomStudy: DicomStudy {
    var studyInstanceUID: String
    var name: String
    var date: Date
    var modality: String
    var series: [MockDicomSeries]

    init(uid: String, name: String, modality: String, date: Date, series: [MockDicomSeries]) {
        self.studyInstanceUID = uid
        self.name = name
        self.modality = modality
        self.date = date
        self.series = series
        super.init()
    }
}

final class OsiriXBackupCoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OsiriXBackupCacheManager.sharedManager.invalidateCache()
    }

    func testCacheStoresAndRetrievesHashes() throws {
        let manager = OsiriXBackupCacheManager.sharedManager
        let study = MockDicomStudy(
            uid: "study-1",
            name: "Chest CT",
            modality: "CT",
            date: Date(),
            series: []
        )

        manager.cacheStudy(study, withHash: "hash-1")

        XCTAssertTrue(manager.isStudyCached("study-1"))
        XCTAssertEqual(manager.cachedHashForStudy("study-1"), "hash-1")

        let stats = manager.cacheStatistics()
        XCTAssertEqual(stats["totalEntries"] as? Int, 1)
    }

    func testCachePersistenceRoundTrip() throws {
        let manager = OsiriXBackupCacheManager.sharedManager
        let study = MockDicomStudy(
            uid: "study-2",
            name: "Brain MRI",
            modality: "MR",
            date: Date(),
            series: []
        )

        manager.cacheStudy(study, withHash: "hash-2")
        manager.persistCacheToDisk()

        let cacheURL = try Self.cacheFileURL()
        let persistedData = try Data(contentsOf: cacheURL)

        // Simulate a fresh launch by clearing memory and restoring the persisted data.
        manager.invalidateCache()
        try persistedData.write(to: cacheURL, options: .atomic)
        manager.loadCacheFromDisk()

        XCTAssertEqual(manager.cachedHashForStudy("study-2"), "hash-2")
    }

    func testQueuePrioritizesHigherPriorityItems() {
        let queue = OsiriXTransferQueue()

        let normal = OsiriXTransferQueueItem()
        normal.studyUID = "normal"
        normal.priority = .normal
        normal.status = .pending
        normal.queuedDate = Date()

        let urgent = OsiriXTransferQueueItem()
        urgent.studyUID = "urgent"
        urgent.priority = .urgent
        urgent.status = .pending
        urgent.queuedDate = Date().addingTimeInterval(-60)

        let high = OsiriXTransferQueueItem()
        high.studyUID = "high"
        high.priority = .high
        high.status = .pending
        high.queuedDate = Date().addingTimeInterval(-30)

        queue.addItem(normal)
        queue.addItem(urgent)
        queue.addItem(high)

        XCTAssertEqual(queue.nextItemToProcess()?.studyUID, "urgent")

        queue.removeItem(urgent)
        XCTAssertEqual(queue.nextItemToProcess()?.studyUID, "high")
    }

    func testQueueStatisticsReflectsProgress() {
        let queue = OsiriXTransferQueue()

        let inProgress = OsiriXTransferQueueItem()
        inProgress.status = .inProgress
        inProgress.totalImages = 100
        inProgress.transferredImages = 50

        let completed = OsiriXTransferQueueItem()
        completed.status = .completed

        let failed = OsiriXTransferQueueItem()
        failed.status = .failed

        queue.addItem(inProgress)
        queue.addItem(completed)
        queue.addItem(failed)

        let stats = queue.queueStatistics()
        XCTAssertEqual(stats["totalItems"] as? Int, 3)
        XCTAssertEqual(stats["inProgress"] as? Int, 1)
        XCTAssertEqual(stats["completed"] as? Int, 1)
        XCTAssertEqual(stats["failed"] as? Int, 1)

        let averageProgress = stats["averageProgress"] as? Double
        XCTAssertNotNil(averageProgress)
        XCTAssertGreaterThan(averageProgress ?? 0, 0)
    }

    func testIntegrityValidatorGeneratesValidManifest() {
        let images = [MockDicomImage(uid: "img-1"), MockDicomImage(uid: "img-2")]
        let series = [MockDicomSeries(uid: "series-1", modality: "CT", images: images)]
        let study = MockDicomStudy(
            uid: "study-3",
            name: "Abdomen CT",
            modality: "CT",
            date: Date(),
            series: series
        )

        let hash = OsiriXIntegrityValidator.sha256HashForStudy(study)
        XCTAssertNotNil(hash)

        let manifest = OsiriXIntegrityValidator.generateStudyManifest(study)
        XCTAssertNotNil(manifest)
        XCTAssertTrue(OsiriXIntegrityValidator.validateManifest(manifest, for: study))
    }

    private static func cacheFileURL() throws -> URL {
        let fileManager = FileManager.default
        #if os(macOS)
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #else
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        #endif
        let root = base ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent("OsiriXBackup", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("study_cache.plist")
    }
}
