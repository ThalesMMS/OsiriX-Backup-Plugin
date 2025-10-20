import Foundation

public struct StudyTransferDestination {
    public let host: String
    public let port: Int
    public let callingAE: String
    public let calledAE: String

    public init(host: String, port: Int, callingAE: String, calledAE: String) {
        self.host = host
        self.port = port
        self.callingAE = callingAE
        self.calledAE = calledAE
    }
}

public enum TransferVerificationMode {
    case skip
    case simple(() -> Bool)
    case advanced(() -> Bool)
}

public struct StudyTransferMetrics {
    public let totalImages: UInt
    public let transferredImages: UInt
    public let remoteHash: String?

    public init(totalImages: UInt, transferredImages: UInt, remoteHash: String?) {
        self.totalImages = totalImages
        self.transferredImages = transferredImages
        self.remoteHash = remoteHash
    }
}

public protocol StudyTransferSending {
    func sendStudy(
        _ study: DicomStudy,
        using item: OsiriXTransferQueueItem,
        destination: StudyTransferDestination
    ) throws -> StudyTransferMetrics
}

public protocol StudyIntegrityValidating {
    func hash(for study: DicomStudy) -> String?
    func validate(study: DicomStudy, expectedHash: String) -> Bool
}

public struct DefaultStudyIntegrityValidator: StudyIntegrityValidating {
    public init() {}

    public func hash(for study: DicomStudy) -> String? {
        OsiriXIntegrityValidator.sha256HashForStudy(study)
    }

    public func validate(study: DicomStudy, expectedHash: String) -> Bool {
        OsiriXIntegrityValidator.validateStudyIntegrity(study, expectedHash: expectedHash)
    }
}

public struct NoOpStudySender: StudyTransferSending {
    public init() {}

    public func sendStudy(
        _ study: DicomStudy,
        using item: OsiriXTransferQueueItem,
        destination: StudyTransferDestination
    ) throws -> StudyTransferMetrics {
        let totalImages = UInt(OsiriXStudyTransferPipeline.estimatedImageCount(in: study))
        item.transferredImages = totalImages
        return StudyTransferMetrics(totalImages: totalImages, transferredImages: totalImages, remoteHash: nil)
    }
}

public struct StudyTransferOutcome {
    public let success: Bool
    public let expectedHash: String?
    public let queueItem: OsiriXTransferQueueItem
}

public final class OsiriXStudyTransferPipeline {
    private let queue: OsiriXTransferQueue
    private let sender: StudyTransferSending
    private let integrityValidator: StudyIntegrityValidating

    public init(
        queue: OsiriXTransferQueue = OsiriXTransferQueue(),
        sender: StudyTransferSending = NoOpStudySender(),
        integrityValidator: StudyIntegrityValidating = DefaultStudyIntegrityValidator()
    ) {
        self.queue = queue
        self.sender = sender
        self.integrityValidator = integrityValidator
    }

    @discardableResult
    public func performTransfer(
        study: DicomStudy,
        studyUID: String,
        destination: StudyTransferDestination,
        verification: TransferVerificationMode
    ) -> StudyTransferOutcome {
        let item = OsiriXTransferQueueItem()
        item.studyUID = studyUID
        item.study = study
        item.studyName = OsiriXStudyTransferPipeline.studyName(for: study)
        item.destinationAET = destination.calledAE
        item.queuedDate = Date()

        queue.addItem(item)
        item.status = .inProgress
        item.startDate = Date()

        var expectedHash: String?
        var success = false

        defer {
            if !success && item.status != .failed {
                item.status = .failed
                item.completionDate = Date()
            }
            queue.removeItem(item)
        }

        do {
            let metrics = try sender.sendStudy(study, using: item, destination: destination)
            item.totalImages = metrics.totalImages
            item.transferredImages = metrics.transferredImages

            if let remoteHash = metrics.remoteHash, !remoteHash.isEmpty {
                expectedHash = remoteHash
                item.sha256Hash = remoteHash
            } else if let computed = integrityValidator.hash(for: study) {
                expectedHash = computed
                item.sha256Hash = computed
            }

            item.status = .verifying

            switch verification {
            case .skip:
                success = true
            case .simple(let verifier):
                success = verifier()
            case .advanced(let verifier):
                let remoteResult = verifier()
                if remoteResult {
                    if let expectedHash {
                        success = integrityValidator.validate(study: study, expectedHash: expectedHash)
                    } else {
                        success = false
                    }
                } else {
                    success = false
                }
            }

            item.status = success ? .completed : .failed
            item.completionDate = Date()

            return StudyTransferOutcome(success: success, expectedHash: expectedHash, queueItem: item)
        } catch {
            item.lastError = "\(error)"
            item.status = .failed
            item.completionDate = Date()
            return StudyTransferOutcome(success: false, expectedHash: nil, queueItem: item)
        }
    }

    static func estimatedImageCount(in study: DicomStudy) -> Int {
        let seriesCollection = resolveSeriesCollection(from: study)
        return seriesCollection.reduce(0) { partialResult, series in
            partialResult + resolveImages(from: series).count
        }
    }

    private static func studyName(for study: DicomStudy) -> String {
        if let provider = study as? StudyNameProviding {
            return provider.studyName
        }

        if let child = Mirror(reflecting: study).children.first(where: { $0.label == "name" }) {
            return child.value as? String ?? ""
        }

        return ""
    }

    private static func resolveSeriesCollection(from study: DicomStudy) -> [Any] {
        if let provider = study as? StudySeriesProviding {
            return provider.seriesCollection
        }

        if let child = Mirror(reflecting: study).children.first(where: { $0.label == "series" }),
           let seriesArray = child.value as? [Any] {
            return seriesArray
        }

        return []
    }

    private static func resolveImages(from series: Any) -> [Any] {
        if let provider = series as? SeriesImageProviding {
            return provider.imageCollection
        }

        if let child = Mirror(reflecting: series).children.first(where: { $0.label == "images" }),
           let images = child.value as? [Any] {
            return images
        }

        return []
    }
}

public protocol StudyNameProviding {
    var studyName: String { get }
}

public protocol StudySeriesProviding {
    var seriesCollection: [Any] { get }
}

public protocol SeriesImageProviding {
    var imageCollection: [Any] { get }
}
