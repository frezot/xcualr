import Foundation
import Darwin

struct XCResultTool {
    private let xcresultToolPath: String
    private let legacyMode: Bool

    init() {
        self.xcresultToolPath = Self.resolveXcresultToolPath()
        self.legacyMode = Self.detectLegacyMode()
    }

    func readSummary(at xcresultPath: String) throws -> [String: Any] {
        try runJSON(["get", "--format", "json", "--path", xcresultPath])
    }

    func readTestResultsSummary(at xcresultPath: String) throws -> [String: Any] {
        try runJSON(["get", "test-results", "summary", "--path", xcresultPath, "--compact"])
    }

    func readTestResultsTree(at xcresultPath: String) throws -> [String: Any] {
        try runJSON(["get", "test-results", "tests", "--path", xcresultPath, "--compact"])
    }

    func readTestActivities(at xcresultPath: String, testID: String) throws -> [String: Any] {
        try runJSON([
            "get", "test-results", "activities",
            "--path", xcresultPath,
            "--compact",
            "--test-id", testID
        ])
    }

    func readTestDetails(at xcresultPath: String, testID: String) throws -> [String: Any] {
        try runJSON([
            "get", "test-results", "test-details",
            "--path", xcresultPath,
            "--compact",
            "--test-id", testID
        ])
    }

    func exportAttachments(at xcresultPath: String, to outputURL: URL) throws {
        try runCommand(executablePath: xcresultToolPath, arguments: [
            "export", "attachments",
            "--path", xcresultPath,
            "--output-path", outputURL.path
        ])
    }

    private func runJSON(_ arguments: [String]) throws -> [String: Any] {
        var command = [xcresultToolPath]
        if arguments.starts(with: ["get", "test-results"]) {
            command.append(contentsOf: arguments)
        } else if let subcommand = arguments.first {
            command.append(subcommand)
            if legacyMode {
                command.append("--legacy")
            }
            command.append(contentsOf: arguments.dropFirst())
        } else {
            command.append(contentsOf: arguments)
        }
        let stdoutData = try runCommand(executablePath: command[0], arguments: Array(command.dropFirst()))
        let jsonObject = try JSONSerialization.jsonObject(with: stdoutData)
        guard let dictionary = jsonObject as? [String: Any] else {
            throw CLIError.invalidJSON("xcresulttool returned unexpected JSON root")
        }
        return dictionary
    }

    private static func resolveXcresultToolPath() -> String {
        guard let stdout = try? runCommand(executablePath: "/usr/bin/xcrun", arguments: ["-f", "xcresulttool"]),
              let resolved = String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !resolved.isEmpty else {
            return "/usr/bin/xcresulttool"
        }
        return resolved
    }

    private static func detectLegacyMode() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-version"]
        let stdout = Pipe()
        process.standardOutput = stdout
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return false
            }
            guard let firstLine = output.split(separator: "\n").first else {
                return false
            }
            let version = firstLine.replacingOccurrences(of: "Xcode ", with: "")
            guard let major = Int(version.split(separator: ".").first ?? "") else {
                return false
            }
            return major >= 16
        } catch {
            return false
        }
    }
}

@discardableResult
func runCommand(executablePath: String, arguments: [String]) throws -> Data {
    let timeout: TimeInterval = 15 * 60

    final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let group = DispatchGroup()
    let stdoutBox = DataBox()
    let stderrBox = DataBox()
    let terminationSemaphore = DispatchSemaphore(value: 0)

    func read(_ handle: FileHandle, into box: DataBox, qos: DispatchQoS.QoSClass) {
        group.enter()
        DispatchQueue.global(qos: qos).async {
            box.data = handle.readDataToEndOfFile()
            group.leave()
        }
    }

    process.terminationHandler = { _ in
        terminationSemaphore.signal()
    }

    try process.run()
    read(stdout.fileHandleForReading, into: stdoutBox, qos: .userInitiated)
    read(stderr.fileHandleForReading, into: stderrBox, qos: .utility)

    if terminationSemaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        throw CLIError.processTimedOut("Command timed out after \(Int(timeout))s: \(executablePath) \(arguments.joined(separator: " "))")
    }

    group.wait()

    guard process.terminationStatus == 0 else {
        let stderrString = String(data: stderrBox.data, encoding: .utf8) ?? "<no stderr>"
        throw CLIError.processFailed(stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return stdoutBox.data
}
