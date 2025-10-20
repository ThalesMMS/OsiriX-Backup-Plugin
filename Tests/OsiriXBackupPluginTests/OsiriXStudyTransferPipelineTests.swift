import XCTest
@testable import OsiriXBackupPlugin

final class OsiriXStudyTransferPipelineTests: XCTestCase {
    func testSuccessfulTransferCompletesAndValidates() throws {
        let queue = OsiriXTransferQueue()
        let sender = MockStudySender(result: .success(StudyTransferMetrics(totalImages: 4, transferredImages: 4, remoteHash: "abc123")))
        let validator = MockIntegrityValidator(expectedHash: "abc123", validationResult: true)
        let pipeline = OsiriXStudyTransferPipeline(queue: queue, sender: sender, integrityValidator: validator)

        let study = MockDicomStudy(seriesCount: 2, imagesPerSeries: 2)

        let outcome = pipeline.performTransfer(
            study: study,
            studyUID: "1.2.3",
            destination: StudyTransferDestination(host: "example", port: 104, callingAE: "CALLER", calledAE: "CALLED"),
            verification: .advanced { true }
        )

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.expectedHash, "abc123")
        XCTAssertEqual(outcome.queueItem.status, .completed)
        XCTAssertEqual(outcome.queueItem.transferredImages, 4)
        XCTAssertEqual(outcome.queueItem.totalImages, 4)
        XCTAssertEqual(outcome.queueItem.sha256Hash, "abc123")
        XCTAssertTrue(sender.didSend)
        XCTAssertEqual(validator.validateCallCount, 1)
        XCTAssertEqual(queue.queue.count, 0)
    }

    func testTransferFailureWhenSenderThrows() throws {
        let queue = OsiriXTransferQueue()
        let sender = MockStudySender(result: .failure(MockError.transferFailed))
        let validator = MockIntegrityValidator(expectedHash: nil, validationResult: false)
        let pipeline = OsiriXStudyTransferPipeline(queue: queue, sender: sender, integrityValidator: validator)
        let study = MockDicomStudy(seriesCount: 1, imagesPerSeries: 1)

        let outcome = pipeline.performTransfer(
            study: study,
            studyUID: "4.5.6",
            destination: StudyTransferDestination(host: "example", port: 104, callingAE: "CALLER", calledAE: "CALLED"),
            verification: .simple { true }
        )

        XCTAssertFalse(outcome.success)
        XCTAssertNil(outcome.expectedHash)
        XCTAssertEqual(outcome.queueItem.status, .failed)
        XCTAssertFalse(sender.didSend)
        XCTAssertEqual(queue.queue.count, 0)
        XCTAssertEqual(outcome.queueItem.lastError, "transferFailed")
    }
}

private enum MockError: Error {
    case transferFailed
}

private final class MockStudySender: StudyTransferSending {
    private let result: Result<StudyTransferMetrics, Error>
    private(set) var didSend = false

    init(result: Result<StudyTransferMetrics, Error>) {
        self.result = result
    }

    func sendStudy(
        _ study: DicomStudy,
        using item: OsiriXTransferQueueItem,
        destination: StudyTransferDestination
    ) throws -> StudyTransferMetrics {
        switch result {
        case .success(let metrics):
            didSend = true
            item.transferredImages = metrics.transferredImages
            return metrics
        case .failure(let error):
            throw error
        }
    }
}

private final class MockIntegrityValidator: StudyIntegrityValidating {
    private let expectedHash: String?
    private let validationResult: Bool
    private(set) var validateCallCount = 0

    init(expectedHash: String?, validationResult: Bool) {
        self.expectedHash = expectedHash
        self.validationResult = validationResult
    }

    func hash(for study: DicomStudy) -> String? {
        expectedHash
    }

    func validate(study: DicomStudy, expectedHash: String) -> Bool {
        validateCallCount += 1
        return validationResult
    }
}

private final class MockDicomStudy: DicomStudy {
    var name: String = "Mock"
    var series: [MockDicomSeries] = []

    init(seriesCount: Int, imagesPerSeries: Int) {
        super.init()
        series = (0..<seriesCount).map { _ in MockDicomSeries(imageCount: imagesPerSeries) }
    }
}

private final class MockDicomSeries: DicomSeries {
    var images: [MockDicomImage] = []

    init(imageCount: Int) {
        super.init()
        images = (0..<imageCount).map { _ in MockDicomImage() }
    }
}

private final class MockDicomImage: NSObject {}

extension MockDicomStudy: StudyNameProviding {
    var studyName: String { name }
}

extension MockDicomStudy: StudySeriesProviding {
    var seriesCollection: [Any] { series }
}

extension MockDicomSeries: SeriesImageProviding {
    var imageCollection: [Any] { images }
}
