import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case processFailed(String)
    case processTimedOut(String)
    case invalidJSON(String)

    var description: String {
        switch self {
        case .usage(let message), .processFailed(let message), .processTimedOut(let message), .invalidJSON(let message):
            return message
        }
    }
}

@main
struct XCUALR {
    static let version = "0.1.2"

    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                throw CLIError.usage(usage())
            }

            switch command {
            case "export":
                let configuration = try parseExportConfiguration(Array(arguments.dropFirst()))
                try ExportCommand(configuration: configuration).run()
            case "--help", "-h", "help":
                print(usage())
            case "--version", "-v", "version":
                print(version)
            default:
                throw CLIError.usage(usage())
            }
        } catch {
            fputs("\(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func parseExportConfiguration(_ arguments: [String]) throws -> ExportConfiguration {
        var outputPath: String?
        var imageScale = 3
        var passedStepImagePaletteColors = 64
        var rawAttachments = false
        var force = false
        var noLibs = false
        var positional: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("Missing value for \(argument)\n\n\(usage())")
                }
                outputPath = arguments[index]
            case "--image-scale":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CLIError.usage("Invalid value for --image-scale\n\n\(usage())")
                }
                imageScale = value
            case "--passed-step-image-palette-colors":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                    throw CLIError.usage("Invalid value for --passed-step-image-palette-colors\n\n\(usage())")
                }
                passedStepImagePaletteColors = value
            case "--raw-attachments":
                rawAttachments = true
            case "-f", "--force":
                force = true
            case "--no-libs":
                noLibs = true
            case "--help", "-h":
                throw CLIError.usage(usage())
            default:
                positional.append(argument)
            }
            index += 1
        }

        guard positional.count == 1 else {
            throw CLIError.usage("Expected one .xcresult path\n\n\(usage())")
        }
        guard let outputPath else {
            throw CLIError.usage("Missing -o/--output\n\n\(usage())")
        }

        return ExportConfiguration(
            inputPath: positional[0],
            outputPath: outputPath,
            imageScale: imageScale,
            passedStepImagePaletteColors: passedStepImagePaletteColors,
            rawAttachments: rawAttachments,
            force: force,
            noLibs: noLibs
        )
    }

    private static func usage() -> String {
        """
        Usage:
          xcualr export <path-to-xcresult> -o <output-dir> [options]

        Options:
          --image-scale <int>                            Default: 3
          --passed-step-image-palette-colors <int>       Default: 64
          --raw-attachments                              Keep attachments as-is; HEIC/HEIF stay in their original format
          -f, --force                                    Clear output directory before exporting
        """
    }
}

struct ExportCommand {
    let configuration: ExportConfiguration
    let pngQuantPath = Self.resolvePngQuantPath()
    private nonisolated(unsafe) static var didPrintPngQuantHint = false
    static let paletteOptimizationMinimumSizeBytes: Int64 = 16 * 1024

    private func logStage(_ message: String) {
        fputs("\(message)\n", stderr)
    }

    func logPngQuantHintIfNeeded() {
        guard Self.didPrintPngQuantHint == false else {
            return
        }
        Self.didPrintPngQuantHint = true
        if configuration.noLibs {
            logStage("pngquant disabled; falling back to native palette quantization.")
        } else {
            logStage("pngquant not found; falling back to native palette quantization. For faster exports, run: brew install pngquant")
        }
    }

    func run() throws {
        let exportStartedAt = Date()
        let inputURL = URL(fileURLWithPath: configuration.inputPath)
        let outputURL = URL(fileURLWithPath: configuration.outputPath)
        let stagingURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try? FileManager.default.removeItem(at: stagingURL)
        }
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingURL)
        }

        let tool = XCResultTool()
        logStage("XCUALR \(XCUALR.version) export started:")
        logStage("  \(inputURL.lastPathComponent) -> \(outputURL.path)")
        logStage("Reading xcresult bundle...")
        let issueCatalog = try IssueCatalog.load(fromXCResultPath: configuration.inputPath)
        let activityCatalog = try ActivityCatalog.load(fromXCResultPath: configuration.inputPath)
        let summary = try tool.readTestResultsSummary(at: configuration.inputPath)
        let testsTree = try tool.readTestResultsTree(at: configuration.inputPath)
        let exportedTests = SummaryParser()
            .collectTests(from: testsTree, summary: summary)

        logStage("Exporting attachments...")
        let attachmentCatalog = try exportAttachments(tool: tool, to: stagingURL)
        logStage("Writing Allure results...")
        try writeAllureResults(
            for: exportedTests,
            tool: tool,
            attachmentCatalog: attachmentCatalog,
            issueCatalog: issueCatalog,
            activityCatalog: activityCatalog,
            to: stagingURL
        )

        logStage("Finalizing output...")
        if configuration.force, FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if configuration.force {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagingURL)
            } else {
                try mergeExportArtifacts(from: stagingURL, into: outputURL)
            }
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        }

        logStage("Export time: \(String(format: "%.2f", Date().timeIntervalSince(exportStartedAt)))s")
    }

    private func mergeExportArtifacts(from stagingURL: URL, into outputURL: URL) throws {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for entryURL in entries {
            let destinationURL = outputURL.appendingPathComponent(entryURL.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: entryURL, to: destinationURL)
        }
    }

    private func writeAllureResults(for tests: [ExportedTest],
                                    tool: XCResultTool,
                                    attachmentCatalog: AttachmentCatalog,
                                    issueCatalog: IssueCatalog,
                                    activityCatalog: ActivityCatalog,
                                    to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for test in tests {
            let activities = try test.identifierURL.map {
                try tool.readTestActivities(at: configuration.inputPath, testID: $0)
            }
            let testDetails = try test.identifierURL.map {
                try tool.readTestDetails(at: configuration.inputPath, testID: $0)
            }
            let failureTrace = issueCatalog.trace(for: test.identifier)
            var resolver = attachmentCatalog.resolver(for: test)
            var timingResolver = activityCatalog.resolver(for: test)
            let rootAttachments = buildRootAttachments(from: activities, resolver: &resolver)
            let steps = buildSteps(
                from: activities,
                resolver: &resolver,
                timingResolver: &timingResolver,
                defaultFailureTrace: failureTrace
            )
            let normalizedStart = steps.first?.start ?? buildStart(for: test, testDetails: testDetails)
            let normalizedStop = steps.last?.stop ?? buildStop(for: test, testDetails: testDetails)
            let result = AllureResult(
                name: test.name,
                status: mapStatus(test.status),
                fullName: test.identifier,
                historyId: "\(test.suite)/\(test.identifier)",
                start: normalizedStart,
                stop: normalizedStop,
                description: nil,
                descriptionHtml: nil,
                labels: buildLabels(for: test),
                links: [],
                parameters: [],
                rerunOf: nil,
                stage: nil,
                testCaseId: nil,
                uuid: nil,
                attachments: rootAttachments,
                steps: steps,
                statusDetails: buildStatusDetails(for: test, testDetails: testDetails, issueCatalog: issueCatalog)
            )
            if !configuration.rawAttachments && configuration.passedStepImagePaletteColors > 0 {
                optimizePassedStepAttachments(in: result.steps, outputURL: outputURL)
            }
            let fileURL = outputURL.appendingPathComponent(deterministicResultFileName(for: test.identifier))
            let data = try encoder.encode(result)
            try data.write(to: fileURL)
        }
    }

    private func buildLabels(for test: ExportedTest) -> [AllureLabel] {
        var labels = [AllureLabel(name: "suite", value: test.suite)]
        if let runDestination = test.runDestination {
            labels.append(AllureLabel(name: "runDestination", value: runDestination))
        }
        return labels
    }

    private func buildStatusDetails(for test: ExportedTest,
                                    testDetails: [String: Any]?,
                                    issueCatalog: IssueCatalog) -> AllureStatusDetails? {
        let normalizedStatus = mapStatus(test.status)
        let shouldEmitDetails = normalizedStatus == "failed" || normalizedStatus == "broken"
        guard shouldEmitDetails else {
            return nil
        }
        let message = test.failureMessages.isEmpty
            ? nil
            : test.failureMessages.map(normalizeFailureMessage).joined(separator: "\n")
        let trace = issueCatalog.trace(for: test.identifier) ?? FailureTraceParser().trace(from: testDetails)
        if message == nil, trace == nil {
            return nil
        }
        return AllureStatusDetails(
            known: false,
            muted: false,
            flaky: false,
            message: message,
            trace: trace
        )
    }

    private func mapStatus(_ status: String?) -> String? {
        switch status {
        case "Passed", "Expected Failure":
            return "passed"
        case "Failed":
            return "failed"
        case "Skipped":
            return "skipped"
        default:
            return nil
        }
    }

    private func buildStart(for test: ExportedTest, testDetails: [String: Any]?) -> Int64? {
        if let start = milliseconds(from: testDetails?["startTime"]) {
            return start
        }
        return iso8601Milliseconds(from: test.start)
    }

    private func buildStop(for test: ExportedTest, testDetails: [String: Any]?) -> Int64? {
        guard let start = buildStart(for: test, testDetails: testDetails) else {
            return nil
        }
        let durationSeconds = doubleValue(testDetails?["durationInSeconds"])
        guard let durationSeconds else {
            return nil
        }
        return start + Int64(durationSeconds * 1000)
    }

    private func buildSteps(from activities: [String: Any]?,
                            resolver: inout AttachmentResolver,
                            timingResolver: inout ActivityTimingResolver,
                            defaultFailureTrace: String?) -> [AllureStep] {
        guard let testRuns = activities?["testRuns"] as? [[String: Any]] else {
            return []
        }
        return testRuns.flatMap { testRun in
            let activities = testRun["activities"] as? [[String: Any]] ?? []
            return activities.compactMap { activity in
                var parser = ActivityParser()
                parser.defaultFailureTrace = defaultFailureTrace
                return parser.parseActivity(activity, resolver: &resolver, timingResolver: &timingResolver)
            }
        }
    }

    private func buildRootAttachments(from activities: [String: Any]?, resolver: inout AttachmentResolver) -> [AllureAttachment] {
        guard let testRuns = activities?["testRuns"] as? [[String: Any]] else {
            return []
        }
        var attachments: [AllureAttachment] = []
        for testRun in testRuns {
            let activities = testRun["activities"] as? [[String: Any]] ?? []
            for activity in activities {
                guard let title = activity["title"] as? String,
                      title.hasPrefix("Start Test at") else {
                    continue
                }
                let rawAttachments = activity["attachments"] as? [[String: Any]] ?? []
                for attachment in rawAttachments {
                    attachments.append(contentsOf: resolver.resolve(
                        name: attachment["name"] as? String,
                        timestamp: attachment["timestamp"]
                    ))
                }
            }
        }
        return attachments
    }
}
