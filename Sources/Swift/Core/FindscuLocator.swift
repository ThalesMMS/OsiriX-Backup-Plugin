import Foundation

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
        return String(data: data, encoding: .utf8) ?? ""
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
            return false
        }
    }
}
