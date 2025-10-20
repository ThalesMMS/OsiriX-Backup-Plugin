import Foundation

enum FindscuProcessError: LocalizedError {
    case nonZeroExit(status: Int32, reason: Process.TerminationReason, output: String)

    var errorDescription: String? {
        switch self {
        case let .nonZeroExit(status, reason, output):
            let reasonDescription: String
            switch reason {
            case .exit:
                reasonDescription = "exit"
            case .uncaughtSignal:
                reasonDescription = "signal"
            @unknown default:
                reasonDescription = "unknown"
            }
            if output.isEmpty {
                return "findscu terminou com código \(status) (motivo: \(reasonDescription))"
            } else {
                return "findscu terminou com código \(status) (motivo: \(reasonDescription)). Saída: \(output)"
            }
        }
    }
}

protocol FindscuProcessRunning {
    func run(path: String, arguments: [String]) throws -> String
}

struct DefaultFindscuProcessRunner: FindscuProcessRunning {
    func run(path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw FindscuProcessError.nonZeroExit(
                status: process.terminationStatus,
                reason: process.terminationReason,
                output: output
            )
        }

        return output
    }
}

struct FindscuLocator {
    struct Environment {
        let fileManager: FileManager
        let processRunner: FindscuProcessRunning
        let candidatePaths: [String]
        let cachedPathProvider: () -> String?
        let updateCachedPath: (String?) -> Void
        let bundledExecutablePath: () -> String?
    }

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func resolve() -> String? {
        if let cached = environment.cachedPathProvider(),
           environment.fileManager.isExecutableFile(atPath: cached),
           testExecutable(at: cached) {
            return cached
        }

        var lookupPaths = environment.candidatePaths
        if let bundled = environment.bundledExecutablePath(), !lookupPaths.contains(bundled) {
            lookupPaths.insert(bundled, at: 0)
        }

        for path in lookupPaths {
            guard environment.fileManager.isExecutableFile(atPath: path) else { continue }
            if testExecutable(at: path) {
                environment.updateCachedPath(path)
                return path
            }
        }

        environment.updateCachedPath(nil)
        return nil
    }

    func testExecutable(at path: String) -> Bool {
        do {
            let output = try environment.processRunner.run(path: path, arguments: ["--version"])
            return output.contains("findscu") && output.contains("DCMTK")
        } catch {
            NSLog("[FindscuLocator] Falha ao validar findscu em %@: %@", path, error.localizedDescription)
            return false
        }
    }
}
