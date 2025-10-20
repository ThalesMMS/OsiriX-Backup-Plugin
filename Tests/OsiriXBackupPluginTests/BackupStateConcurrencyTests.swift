import XCTest
import Dispatch

final class BackupStateConcurrencyTests: XCTestCase {
    func testConcurrentPauseResumeAndStopTogglesMaintainConsistency() {
        let harness = ThreadSafeBackupStateHarness()
        harness.start()

        let iterations = 200
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.osirix.backup.concurrency-test", attributes: .concurrent)

        for index in 0..<iterations {
            group.enter()
            queue.async {
                harness.togglePause()
                harness.togglePause()
                group.leave()
            }

            group.enter()
            queue.async {
                if index.isMultiple(of: 5) {
                    harness.requestStop()
                    harness.start()
                } else {
                    _ = harness.togglePause()
                }
                group.leave()
            }
        }

        group.wait()
        harness.requestStop()

        let snapshot = harness.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertFalse(snapshot.isPaused)
    }
}

private final class ThreadSafeBackupStateHarness {
    private struct State {
        var isRunning = false
        var isPaused = false
    }

    private let queue = DispatchQueue(label: "com.osirix.backup.state-harness")
    private var state = State()

    func start() {
        queue.sync {
            state.isRunning = true
            state.isPaused = false
        }
    }

    @discardableResult
    func togglePause() -> Bool {
        queue.sync {
            guard state.isRunning else { return state.isPaused }
            state.isPaused.toggle()
            return state.isPaused
        }
    }

    func requestStop() {
        queue.sync {
            state.isRunning = false
            state.isPaused = false
        }
    }

    func snapshot() -> (isRunning: Bool, isPaused: Bool) {
        queue.sync {
            (state.isRunning, state.isPaused)
        }
    }
}
