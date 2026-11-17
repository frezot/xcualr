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
    static let version = "0.1.3"

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

    static func parseExportConfiguration(_ arguments: [String]) throws -> ExportConfiguration {
        var outputPath: String?
        var junitPath: String?
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
                guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("-") else {
                    throw CLIError.usage("Missing value for \(argument)\n\n\(usage())")
                }
                outputPath = arguments[index]
            case "--junit":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("-") else {
                    throw CLIError.usage("Missing value for --junit\n\n\(usage())")
                }
                junitPath = arguments[index]
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
            junitPath: junitPath,
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
          --junit <file.xml>                             Also write a JUnit XML report
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
        let junitDestination = try configuration.junitPath.map {
            try JUnitDestination(path: $0, inputURL: inputURL, allureURL: outputURL)
        }
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
        let summary = try tool.readTestResultsSummary(at: configuration.inputPath)
        let testsTree = try tool.readTestResultsTree(at: configuration.inputPath)
        // xcresulttool creates the SQLite database lazily for freshly merged bundles.
        let issueCatalog = try IssueCatalog.load(fromXCResultPath: configuration.inputPath)
        let activityCatalog = try ActivityCatalog.load(fromXCResultPath: configuration.inputPath)
        let exportedTests = SummaryParser()
            .collectTests(from: testsTree, summary: summary)

        logStage("Exporting attachments...")
        let attachmentCatalog = try exportAttachments(tool: tool, to: stagingURL)
        logStage(junitDestination == nil ? "Writing Allure results..." : "Writing Allure and JUnit results...")
        try writeTestResults(
            for: exportedTests,
            tool: tool,
            attachmentCatalog: attachmentCatalog,
            issueCatalog: issueCatalog,
            activityCatalog: activityCatalog,
            allureDirectory: stagingURL,
            junitDestination: junitDestination
        )

        logStage("Finalizing output...")
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
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for entryURL in entries {
            let destinationURL = outputURL.appendingPathComponent(entryURL.lastPathComponent)
            var destinationIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory) {
                if destinationIsDirectory.boolValue,
                   try entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    try mergeExportArtifacts(from: entryURL, into: destinationURL)
                    continue
                }
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: entryURL, to: destinationURL)
        }
    }

    // Both formats consume the same per-test reads; only the small JUnit cases are retained.
    private func writeTestResults(for tests: [ExportedTest],
                                  tool: XCResultTool,
                                  attachmentCatalog: AttachmentCatalog,
                                  issueCatalog: IssueCatalog,
                                  activityCatalog: ActivityCatalog,
                                  allureDirectory: URL,
                                  junitDestination: JUnitDestination?) throws {
        var junitCases: [JUnitCase] = []
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
            if junitDestination != nil {
                junitCases.append(try JUnitCaseBuilder().build(
                    for: test, testDetails: testDetails, issueTrace: failureTrace
                ))
            }
            let result = buildAllureResult(
                for: test,
                activities: activities,
                testDetails: testDetails,
                failureTrace: failureTrace,
                attachmentCatalog: attachmentCatalog,
                activityCatalog: activityCatalog
            )
            try writeAllureResult(result, for: test, encoder: encoder, to: allureDirectory)
        }

        if let junitDestination {
            try JUnitExporter().write(
                tests: junitCases,
                suiteName: URL(fileURLWithPath: configuration.inputPath).deletingPathExtension().lastPathComponent,
                to: junitDestination.writeURL(stagingDirectory: allureDirectory)
            )
        }
    }

    private func buildAllureResult(for test: ExportedTest,
                                   activities: [String: Any]?,
                                   testDetails: [String: Any]?,
                                   failureTrace: String?,
                                   attachmentCatalog: AttachmentCatalog,
                                   activityCatalog: ActivityCatalog) -> AllureResult {
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
        return AllureResult(
            name: test.name,
            status: TestStatus(xcresultStatus: test.status)?.rawValue,
            fullName: test.identifier,
            historyId: "\(test.suite)/\(test.identifier)",
            start: normalizedStart,
            stop: normalizedStop,
            description: nil,
            descriptionHtml: nil,
            labels: buildLabels(for: test, testDetails: testDetails),
            links: [],
            parameters: [],
            rerunOf: nil,
            stage: nil,
            testCaseId: nil,
            uuid: nil,
            attachments: rootAttachments,
            steps: steps,
            statusDetails: buildStatusDetails(for: test, testDetails: testDetails, failureTrace: failureTrace)
        )
    }

    private func writeAllureResult(_ result: AllureResult,
                                  for test: ExportedTest,
                                  encoder: JSONEncoder,
                                  to outputURL: URL) throws {
        if !configuration.rawAttachments && configuration.passedStepImagePaletteColors > 0 {
            optimizePassedStepAttachments(in: result.steps, outputURL: outputURL)
        }
        let fileURL = outputURL.appendingPathComponent(deterministicResultFileName(for: test.identifier))
        try encoder.encode(result).write(to: fileURL)
    }

    private func buildLabels(for test: ExportedTest, testDetails: [String: Any]?) -> [AllureLabel] {
        var labels = [AllureLabel(name: "suite", value: test.suite)]
        let host = deviceName(from: testDetails) ?? test.runDestination
        if let host {
            labels.append(AllureLabel(name: "host", value: host))
            labels.append(AllureLabel(name: "runDestination", value: host))
        }
        return labels
    }

    private func deviceName(from testDetails: [String: Any]?) -> String? {
        guard let devices = testDetails?["devices"] as? [[String: Any]],
              let first = devices.first else {
            return nil
        }
        return (first["deviceName"] as? String) ?? (first["name"] as? String)
    }

    func buildStatusDetails(for test: ExportedTest,
                            testDetails: [String: Any]?,
                            failureTrace: String?) -> AllureStatusDetails? {
        guard TestStatus(xcresultStatus: test.status) == .failed else {
            return nil
        }
        let messages = FailureMessageCollector.messages(for: test, details: testDetails)
        let message = messages.isEmpty
            ? nil
            : messages.map(normalizeFailureMessage).joined(separator: "\n")
        let trace = failureTrace ?? FailureTraceParser().trace(from: testDetails)
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
