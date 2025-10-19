import XCTest
@testable import OsiriXBackupPlugin

private final class StubFileManager: FileManager, @unchecked Sendable {
    var executablePaths: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        return executablePaths.contains(path)
    }
}

private final class StubProcessRunner: FindscuProcessRunning, @unchecked Sendable {
    var outputs: [String: String] = [:]
    var shouldThrow = false

    func run(path: String, arguments: [String]) throws -> String {
        if shouldThrow { throw NSError(domain: "test", code: 1) }
        return outputs[path] ?? ""
    }
}

final class FindscuLocatorTests: XCTestCase {
    func testResolveReturnsCachedPathWhenStillValid() {
        let fileManager = StubFileManager()
        fileManager.executablePaths = ["/cached/findscu"]

        let runner = StubProcessRunner()
        runner.outputs["/cached/findscu"] = "findscu - DCMTK"

        let locator = FindscuLocator(environment: FindscuLocator.Environment(
            fileManager: fileManager,
            processRunner: runner,
            candidatePaths: ["/other/findscu"],
            cachedPathProvider: { "/cached/findscu" },
            updateCachedPath: { _ in },
            bundledExecutablePath: { return nil }
        ))

        XCTAssertEqual(locator.resolve(), "/cached/findscu")
    }

    func testResolveFallsBackToCandidates() {
        let fileManager = StubFileManager()
        fileManager.executablePaths = ["/other/findscu"]

        let runner = StubProcessRunner()
        runner.outputs["/other/findscu"] = "findscu - DCMTK"

        var capturedPath: String?
        let locator = FindscuLocator(environment: FindscuLocator.Environment(
            fileManager: fileManager,
            processRunner: runner,
            candidatePaths: ["/other/findscu"],
            cachedPathProvider: { return nil },
            updateCachedPath: { capturedPath = $0 },
            bundledExecutablePath: { return nil }
        ))

        XCTAssertEqual(locator.resolve(), "/other/findscu")
        XCTAssertEqual(capturedPath, "/other/findscu")
    }

    func testResolveIncludesBundledPath() {
        let fileManager = StubFileManager()
        fileManager.executablePaths = ["/bundled/findscu"]

        let runner = StubProcessRunner()
        runner.outputs["/bundled/findscu"] = "findscu - DCMTK"

        var updateCount = 0
        let locator = FindscuLocator(environment: FindscuLocator.Environment(
            fileManager: fileManager,
            processRunner: runner,
            candidatePaths: [],
            cachedPathProvider: { return nil },
            updateCachedPath: { _ in updateCount += 1 },
            bundledExecutablePath: { "/bundled/findscu" }
        ))

        XCTAssertEqual(locator.resolve(), "/bundled/findscu")
        XCTAssertEqual(updateCount, 1)
    }

    func testTestExecutableHandlesFailures() {
        let fileManager = StubFileManager()
        let runner = StubProcessRunner()
        runner.shouldThrow = true

        let locator = FindscuLocator(environment: FindscuLocator.Environment(
            fileManager: fileManager,
            processRunner: runner,
            candidatePaths: [],
            cachedPathProvider: { return nil },
            updateCachedPath: { _ in },
            bundledExecutablePath: { return nil }
        ))

        XCTAssertFalse(locator.testExecutable(at: "/missing/findscu"))
    }
}
