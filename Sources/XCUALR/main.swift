import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import zlib
import Darwin

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case processFailed(String)
    case processTimedOut(String)
    case invalidJSON(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .usage(let message), .processFailed(let message), .processTimedOut(let message), .invalidJSON(let message), .writeFailed(let message):
            return message
        }
    }
}

struct ExportConfiguration {
    let inputPath: String
    let outputPath: String
    let imageScale: Int
    let passedStepImagePaletteColors: Int
    let rawAttachments: Bool
    let force: Bool
    let noLibs: Bool
}

struct ExportedTest: Codable {
    let name: String
    let identifier: String
    let identifierURL: String?
    let status: String?
    let suite: String
    let runDestination: String?
    let start: String?
    let failureMessages: [String]
}

struct AllureResult: Encodable {
    let name: String
    var status: String?
    let fullName: String
    let historyId: String
    let start: Int64?
    let stop: Int64?
    let description: String?
    let descriptionHtml: String?
    let labels: [AllureLabel]
    let links: [AllureLink]
    let parameters: [AllureParameter]
    let rerunOf: String?
    let stage: String?
    let testCaseId: String?
    let uuid: String?
    let attachments: [AllureAttachment]
    let steps: [AllureStep]
    let statusDetails: AllureStatusDetails?

    enum CodingKeys: String, CodingKey {
        case attachments
        case description
        case descriptionHtml
        case fullName
        case historyId
        case labels
        case links
        case name
        case parameters
        case rerunOf
        case stage
        case start
        case status
        case statusDetails
        case steps
        case stop
        case testCaseId
        case uuid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeNil(forKey: .description)
        try container.encodeNil(forKey: .descriptionHtml)
        try container.encode(fullName, forKey: .fullName)
        try container.encode(historyId, forKey: .historyId)
        try container.encode(labels, forKey: .labels)
        try container.encode(links, forKey: .links)
        try container.encode(name, forKey: .name)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeNil(forKey: .rerunOf)
        try container.encodeNil(forKey: .stage)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encodeIfPresent(status, forKey: .status)
        if let statusDetails {
            try container.encode(statusDetails, forKey: .statusDetails)
        } else {
            try container.encodeNil(forKey: .statusDetails)
        }
        try container.encode(steps, forKey: .steps)
        try container.encodeIfPresent(stop, forKey: .stop)
        try container.encodeNil(forKey: .testCaseId)
        try container.encodeNil(forKey: .uuid)
    }
}

struct AllureLabel: Codable {
    let name: String
    let value: String
}

struct AllureStatusDetails: Codable {
    let known: Bool
    let muted: Bool
    let flaky: Bool
    let message: String?
    let trace: String?
}

struct AllureStep: Encodable {
    let name: String
    let status: String?
    let start: Int64?
    let stop: Int64?
    let attachments: [AllureAttachment]
    let steps: [AllureStep]
    let statusDetails: AllureStatusDetails?
    let description: String? = nil
    let descriptionHtml: String? = nil
    let parameters: [AllureParameter] = []
    let stage: String? = nil

    enum CodingKeys: String, CodingKey {
        case attachments
        case description
        case descriptionHtml
        case name
        case parameters
        case stage
        case start
        case status
        case statusDetails
        case steps
        case stop
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeNil(forKey: .description)
        try container.encodeNil(forKey: .descriptionHtml)
        try container.encode(name, forKey: .name)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeNil(forKey: .stage)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encodeIfPresent(status, forKey: .status)
        if let statusDetails {
            try container.encode(statusDetails, forKey: .statusDetails)
        } else {
            try container.encodeNil(forKey: .statusDetails)
        }
        try container.encode(steps, forKey: .steps)
        try container.encodeIfPresent(stop, forKey: .stop)
    }
}

struct AllureAttachment: Codable {
    let name: String
    let source: String
    let type: String
}

struct AllureLink: Codable {
    let name: String?
    let type: String?
    let url: String?
}

struct AllureParameter: Codable {
    let name: String?
    let value: String?
}

struct AttachmentExportRecord: Codable {
    let testIdentifier: String?
    let testIdentifierURL: String?
    let attachments: [AttachmentExportItem]
}

struct AttachmentExportItem: Codable {
    let exportedFileName: String
    let suggestedHumanReadableName: String?
    let timestamp: Double?
    let isAssociatedWithFailure: Bool?
}

struct AttachmentMetadata {
    let originalFilename: String
    let payloadRef: String
}

struct AttachmentWorkItem {
    let record: AttachmentExportRecord
    let exportItem: AttachmentExportItem
    let metadata: AttachmentMetadata?
}

struct PreparedAttachmentCandidate {
    let record: AttachmentExportRecord
    let exportItem: AttachmentExportItem
    let metadata: AttachmentMetadata?
    let prepared: PreparedAttachment
}

private let paletteOptimizationMinimumSizeBytes: Int64 = 16 * 1024

@main
struct XCUALR {
    private static let version = "0.1.0"

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
        return """
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
    private let useColor = isatty(STDERR_FILENO) != 0
    private let pngQuantPath = Self.resolvePngQuantPath()
    private nonisolated(unsafe) static var didPrintPngQuantHint = false

    private func stylize(_ text: String, _ code: String) -> String {
        guard useColor else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func coloredAppName() -> String {
        stylize("XCUALR", "1;36")
    }

    private func logStage(_ message: String) {
        fputs("\(message)\n", stderr)
    }

    private func logPngQuantHintIfNeeded() {
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
        logStage("\(coloredAppName()) export started: \(inputURL.lastPathComponent) -> \(outputURL.path)")
        logStage("Reading xcresult bundle...")
        let issueCatalog = try IssueCatalog.load(fromXCResultPath: configuration.inputPath)
        let activityCatalog = try ActivityCatalog.load(fromXCResultPath: configuration.inputPath)
        let summary = try tool.readTestResultsSummary(at: configuration.inputPath)
        let testsTree = try tool.readTestResultsTree(at: configuration.inputPath)
        let exportedTests = SummaryParser()
            .collectTests(from: testsTree, summary: summary)

        logStage("Exporting attachments...")
        let attachmentCatalog = try exportAttachments(tool: tool, tests: exportedTests, to: stagingURL)
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
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        }

        logStage("Export time: \(String(format: "%.2f", Date().timeIntervalSince(exportStartedAt)))s")
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

    private func exportAttachments(tool: XCResultTool,
                                   tests: [ExportedTest],
                                   to outputURL: URL) throws -> AttachmentCatalog {
        let temporaryAttachmentsURL = outputURL.appendingPathComponent(".attachments-export", isDirectory: true)
        if FileManager.default.fileExists(atPath: temporaryAttachmentsURL.path) {
            try FileManager.default.removeItem(at: temporaryAttachmentsURL)
        }
        try FileManager.default.createDirectory(at: temporaryAttachmentsURL, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: temporaryAttachmentsURL)
        }

        try tool.exportAttachments(at: configuration.inputPath, to: temporaryAttachmentsURL)
        let manifestURL = temporaryAttachmentsURL.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let records = try JSONDecoder().decode([AttachmentExportRecord].self, from: manifestData)
        var filenameCatalog = try AttachmentFilenameCatalog.load(fromXCResultPath: configuration.inputPath)

        var workItems: [AttachmentWorkItem] = []
        for record in records {
            for attachment in record.attachments {
                workItems.append(AttachmentWorkItem(
                    record: record,
                    exportItem: attachment,
                    metadata: filenameCatalog.consumeMetadata(record: record, item: attachment)
                ))
            }
        }

        var preparedAttachments: [PreparedAttachmentCandidate] = []
        preparedAttachments.reserveCapacity(workItems.count)
        for workItem in workItems {
            if let candidate = try autoreleasepool(invoking: {
                try prepareAttachmentCandidate(
                    workItem,
                    temporaryAttachmentsURL: temporaryAttachmentsURL
                )
            }) {
                preparedAttachments.append(candidate)
            }
        }

        var processedFiles: [String: ProcessedAttachment] = [:]
        for candidate in preparedAttachments {
            processedFiles[candidate.exportItem.exportedFileName] = try finalizePreparedAttachment(
                candidate,
                outputURL: outputURL
            )
        }

        return AttachmentCatalog.make(records: records, processedFiles: processedFiles)
    }

    private func prepareAttachmentCandidate(_ workItem: AttachmentWorkItem,
                                            temporaryAttachmentsURL: URL) throws -> PreparedAttachmentCandidate? {
        let sourceURL = temporaryAttachmentsURL.appendingPathComponent(workItem.exportItem.exportedFileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return nil
        }

        let suggestedName = workItem.exportItem.suggestedHumanReadableName ?? workItem.exportItem.exportedFileName
        let displayName = workItem.metadata?.originalFilename ?? suggestedName
        if shouldSkipAttachment(named: suggestedName) || isBinaryPlist(at: sourceURL) {
            try? FileManager.default.removeItem(at: sourceURL)
            return nil
        }
        if isEmptyFile(at: sourceURL) {
            try? FileManager.default.removeItem(at: sourceURL)
            return nil
        }

        let prepared = try prepareAttachment(at: sourceURL, suggestedName: displayName)
        if isEmptyFile(at: prepared.url) {
            try? FileManager.default.removeItem(at: prepared.url)
            return nil
        }
        return PreparedAttachmentCandidate(
            record: workItem.record,
            exportItem: workItem.exportItem,
            metadata: workItem.metadata,
            prepared: prepared
        )
    }

    private func finalizePreparedAttachment(_ candidate: PreparedAttachmentCandidate,
                                            outputURL: URL) throws -> ProcessedAttachment {
        let fallbackSourceKey = [String]([
            candidate.record.testIdentifierURL ?? candidate.record.testIdentifier ?? "",
            candidate.exportItem.timestamp.map { String($0) } ?? "",
            candidate.prepared.displayName
        ]).joined(separator: "|")
        let sourceKey = candidate.metadata?.payloadRef ?? fallbackSourceKey
        let canonicalExtension = URL(fileURLWithPath: candidate.prepared.displayName).pathExtension.lowercased()
        let finalExtension = canonicalExtension.isEmpty ? candidate.prepared.extension : canonicalExtension
        let finalSource = deterministicAttachmentSource(sourceKey: sourceKey, fileExtension: finalExtension)
        let destinationURL = outputURL.appendingPathComponent(finalSource)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: candidate.prepared.url)
        } else {
            try FileManager.default.moveItem(at: candidate.prepared.url, to: destinationURL)
        }

        return .exported(AllureAttachment(
            name: candidate.prepared.displayName,
            source: finalSource,
            type: mimeType(forExtension: candidate.prepared.extension, fileName: candidate.prepared.displayName)
        ))
    }

    private func prepareAttachment(at sourceURL: URL, suggestedName: String) throws -> PreparedAttachment {
        let ext = sourceURL.pathExtension.lowercased()
        if configuration.rawAttachments {
            return PreparedAttachment(url: sourceURL, displayName: suggestedName, extension: ext)
        }
        if ext == "heic" || ext == "heif" {
            let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("png")
            try convertHEICImage(at: sourceURL, to: destinationURL, scale: configuration.imageScale)
            let displayName = replaceExtension(in: suggestedName, with: "png")
            return PreparedAttachment(url: destinationURL, displayName: displayName, extension: "png")
        }

        if ext == "png" || ext == "jpg" || ext == "jpeg" {
            if configuration.imageScale > 1 {
                let format: ImageFormat = ext == "png" ? .png : .jpeg
                let destinationURL = sourceURL.deletingLastPathComponent()
                    .appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent)-scaled.\(ext)")
                try convertImage(at: sourceURL, to: destinationURL, format: format, scale: configuration.imageScale)
                try? FileManager.default.removeItem(at: sourceURL)
                return PreparedAttachment(url: destinationURL, displayName: suggestedName, extension: ext)
            }
        }

        return PreparedAttachment(url: sourceURL, displayName: suggestedName, extension: ext)
    }

    private func convertHEICImage(at sourceURL: URL, to destinationURL: URL, scale: Int) throws {
        guard let sourceImage = NSImage(contentsOf: sourceURL) else {
            throw CLIError.processFailed("Failed to read image: \(sourceURL.path)")
        }

        guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CLIError.processFailed("Failed to decode image: \(sourceURL.path)")
        }

        let pixelScale = max(scale, 1)
        let targetWidth = max(cgImage.width / pixelScale, 1)
        let targetHeight = max(cgImage.height / pixelScale, 1)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CLIError.processFailed("Failed to create graphics context for: \(sourceURL.path)")
        }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let rendered = context.makeImage() else {
            throw CLIError.processFailed("Failed to render image: \(sourceURL.path)")
        }

        try writePNGImage(rendered, to: destinationURL)
    }

    private func shouldSkipAttachment(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("Snapshot_")
            || trimmed.hasPrefix("SynthesizedEvent_")
            || trimmed.hasPrefix("UI Snapshot ")
            || trimmed.hasPrefix("Synthesized Event ")
    }

    private func isBinaryPlist(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 8)
        guard let data, let signature = String(data: data, encoding: .ascii) else {
            return false
        }
        return signature == "bplist00"
    }

    private func isEmptyFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue == 0
    }

    private func convertImage(at sourceURL: URL, to destinationURL: URL, format: ImageFormat, scale: Int) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw CLIError.processFailed("Failed to read image: \(sourceURL.path)")
        }

        let scale = max(scale, 1)
        let image: CGImage
        if scale > 1 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let maxPixelSize = max(max(sourceWidth, sourceHeight) / scale, 1)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CLIError.processFailed("Failed to create image thumbnail: \(sourceURL.path)")
            }
            image = try normalizedImage(from: thumbnail, sourceName: sourceURL.lastPathComponent)
        } else {
            guard let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CLIError.processFailed("Failed to read image: \(sourceURL.path)")
            }
            image = fullImage
        }

        let destinationType = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType as CFString, 1, nil) else {
            throw CLIError.processFailed("Failed to create destination for \(destinationURL.lastPathComponent)")
        }
        if format == .png {
            CGImageDestinationAddImage(destination, opaqueImage(from: image) ?? image, nil)
        } else {
            let options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
            CGImageDestinationAddImage(destination, image, options)
        }
        if !CGImageDestinationFinalize(destination) {
            throw CLIError.processFailed("Failed to finalize image: \(destinationURL.lastPathComponent)")
        }
    }

    private func normalizedImage(from image: CGImage, sourceName: String) throws -> CGImage {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CLIError.processFailed("Failed to allocate image context for \(sourceName)")
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else {
            throw CLIError.processFailed("Failed to normalize image: \(sourceName)")
        }
        return normalized
    }

    private func writePNGImage(_ image: CGImage, to destinationURL: URL) throws {
        let destinationType = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType, 1, nil) else {
            throw CLIError.processFailed("Failed to create destination for \(destinationURL.lastPathComponent)")
        }
        let opaqueImage = opaqueImage(from: image) ?? image
        CGImageDestinationAddImage(destination, opaqueImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.processFailed("Failed to finalize image: \(destinationURL.lastPathComponent)")
        }
    }

    private func writePNGImage(_ image: IndexedImage, to destinationURL: URL) throws {
        let data = try encodeIndexedPNG(image)
        try data.write(to: destinationURL)
    }

    private func encodeIndexedPNG(_ image: IndexedImage) throws -> Data {
        var data = Data()
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        data.append(pngChunk(type: "IHDR", payload: try pngIHDRPayload(width: image.width, height: image.height)))
        data.append(pngChunk(type: "PLTE", payload: Data(image.palette)))
        data.append(pngChunk(type: "IDAT", payload: try pngIDATPayload(image: image)))
        data.append(pngChunk(type: "IEND", payload: Data()))
        return data
    }

    private func pngIHDRPayload(width: Int, height: Int) throws -> Data {
        var payload = Data()
        payload.append(bigEndian(width))
        payload.append(bigEndian(height))
        payload.append(UInt8(8)) // bit depth
        payload.append(UInt8(3)) // indexed color
        payload.append(UInt8(0)) // compression method
        payload.append(UInt8(0)) // filter method
        payload.append(UInt8(0)) // interlace method
        return payload
    }

    private func pngIDATPayload(image: IndexedImage) throws -> Data {
        let rowLength = image.width + 1
        var raw = Data(count: rowLength * image.height)
        raw.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            image.indices.withUnsafeBytes { indexBuffer in
                guard let indexBase = indexBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                for y in 0..<image.height {
                    let rawRow = y * rowLength
                    base[rawRow] = 0
                    let sourceOffset = y * image.width
                    memcpy(base.advanced(by: rawRow + 1), indexBase.advanced(by: sourceOffset), image.width)
                }
            }
        }

        let compressedLength = compressBound(uLong(raw.count))
        var compressed = Data(count: Int(compressedLength))
        var destinationLength = compressedLength
        let result = compressed.withUnsafeMutableBytes { compressedBuffer -> Int32 in
            guard let compressedBase = compressedBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                return Z_MEM_ERROR
            }
            return raw.withUnsafeBytes { rawBuffer -> Int32 in
                guard let rawBase = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                    return Z_MEM_ERROR
                }
                return compress2(
                    compressedBase,
                    &destinationLength,
                    rawBase,
                    uLong(raw.count),
                    Z_BEST_COMPRESSION
                )
            }
        }
        guard result == Z_OK else {
            throw CLIError.processFailed("Failed to compress PNG data")
        }
        compressed.removeSubrange(Int(destinationLength)..<compressed.count)
        return compressed
    }

    private func pngChunk(type: String, payload: Data) -> Data {
        var chunk = Data()
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { chunk.append(contentsOf: $0) }
        let typeBytes = Array(type.utf8)
        chunk.append(contentsOf: typeBytes)
        chunk.append(payload)
        var crc: uLong = crc32(0, nil, 0)
        crc = typeBytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return crc
            }
            return crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(typeBytes.count))
        }
        crc = payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return crc
            }
            return crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(payload.count))
        }
        let crcBE = UInt32(crc).bigEndian
        withUnsafeBytes(of: crcBE) { chunk.append(contentsOf: $0) }
        return chunk
    }

    private func bigEndian(_ value: Int) -> Data {
        var bigEndianValue = UInt32(value).bigEndian
        return Data(bytes: &bigEndianValue, count: 4)
    }

    private func opaqueImage(from image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func optimizePassedStepAttachments(in steps: [AllureStep],
                                               outputURL: URL,
                                               parentBranchPassed: Bool = true) {
        let urls = collectPassedStepAttachmentURLs(in: steps, outputURL: outputURL, parentBranchPassed: parentBranchPassed)
        let pngURLs = Array(Set(urls))
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.path < $1.path }
        guard !pngURLs.isEmpty else {
            return
        }
        for url in pngURLs {
            do {
                try optimizePNGPaletteNatively(at: url)
            } catch {
                continue
            }
        }
    }

    private func collectPassedStepAttachmentURLs(in steps: [AllureStep],
                                                 outputURL: URL,
                                                 parentBranchPassed: Bool) -> [URL] {
        var urls: [URL] = []
        for step in steps {
            let currentBranchPassed = parentBranchPassed && step.status == "passed"
            if currentBranchPassed {
                urls.append(contentsOf: step.attachments.map { outputURL.appendingPathComponent($0.source) })
            }
            urls.append(contentsOf: collectPassedStepAttachmentURLs(
                in: step.steps,
                outputURL: outputURL,
                parentBranchPassed: currentBranchPassed
            ))
        }
        return urls
    }

    private func optimizePNGPaletteNatively(at url: URL) throws {
        guard configuration.passedStepImagePaletteColors > 0 else {
            return
        }
        guard let originalSize = fileSize(at: url),
              originalSize >= paletteOptimizationMinimumSizeBytes else {
            return
        }
        if !configuration.noLibs, let pngQuantPath {
            do {
                try optimizePNGPaletteWithPNGQuant(at: url, executablePath: pngQuantPath, originalSize: originalSize)
                return
            } catch {
                // Fall back to the native quantizer if pngquant is unavailable or fails.
            }
        } else {
            logPngQuantHintIfNeeded()
        }
        guard let sourceImage = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decodedImage = CGImageSourceCreateImageAtIndex(sourceImage, 0, nil) else {
            return
        }

        guard let quantizedImage = try SwiftPaletteQuantizer.quantize(
            image: decodedImage,
            colors: configuration.passedStepImagePaletteColors
        ) else {
            return
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-quantized.png")
        try? FileManager.default.removeItem(at: temporaryURL)
        try writePNGImage(quantizedImage, to: temporaryURL)

        let quantizedSize = fileSize(at: temporaryURL)
        guard let quantizedSize, quantizedSize < originalSize else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private func optimizePNGPaletteWithPNGQuant(at url: URL,
                                                executablePath: String,
                                                originalSize: Int64) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-pngquant.png")
        try? FileManager.default.removeItem(at: temporaryURL)

        let colors = max(2, min(configuration.passedStepImagePaletteColors, 256))
        _ = try runCommand(
            executablePath: executablePath,
            arguments: [
                "--speed", "1",
                "--strip",
                "--force",
                "--output", temporaryURL.path,
                "--colors", "\(colors)",
                url.path
            ]
        )

        guard let quantizedSize = fileSize(at: temporaryURL),
              quantizedSize < originalSize else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private static func resolvePngQuantPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/pngquant",
            "/usr/local/bin/pngquant",
            "/usr/bin/pngquant"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        guard let path = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/pngquant"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func mimeType(forExtension ext: String, fileName: String) -> String {
        switch ext.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "heic", "heif":
            return "image/heic"
        case "gif":
            return "image/gif"
        case "txt", "log", "springboard":
            return "text/plain"
        case "json":
            return "application/json"
        case "plist":
            return "application/x-plist"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            if fileName.lowercased().hasSuffix(".springboard") {
                return "text/plain"
            }
            return "application/octet-stream"
        }
    }

    private func deterministicResultFileName(for testIdentifier: String) -> String {
        "\(deterministicUUID(for: testIdentifier).uuidString.lowercased())-result.json"
    }

    private func deterministicAttachmentSource(sourceKey: String, fileExtension: String) -> String {
        "\(deterministicUUID(for: sourceKey).uuidString.lowercased())-attachment.\(fileExtension)"
    }

    private func deterministicUUID(for value: String) -> UUID {
        let bytes = Array(Insecure.MD5.hash(data: Data(value.utf8)))
        let adjusted = bytes.enumerated().map { index, byte -> UInt8 in
            switch index {
            case 6:
                return (byte & 0x0F) | 0x30
            case 8:
                return (byte & 0x3F) | 0x80
            default:
                return byte
            }
        }
        let tuple: uuid_t = (
            adjusted[0], adjusted[1], adjusted[2], adjusted[3],
            adjusted[4], adjusted[5], adjusted[6], adjusted[7],
            adjusted[8], adjusted[9], adjusted[10], adjusted[11],
            adjusted[12], adjusted[13], adjusted[14], adjusted[15]
        )
        return UUID(uuid: tuple)
    }

    private func replaceExtension(in fileName: String, with newExtension: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? fileName : "\(base).\(newExtension)"
    }

    private func milliseconds(from value: Any?) -> Int64? {
        guard let value = doubleValue(value) else {
            return nil
        }
        return Int64(value * 1000)
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private func iso8601Milliseconds(from value: String?) -> Int64? {
        guard let value else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func normalizeFailureMessage(_ message: String) -> String {
        message.replacingOccurrences(
            of: #"^[^:\n]+:\d+:\s*"#,
            with: "",
            options: .regularExpression
        )
    }
}

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

struct SummaryParser {
    func collectTests(from testsTree: [String: Any], summary: [String: Any]) -> [ExportedTest] {
        guard let testNodes = testsTree["testNodes"] as? [[String: Any]] else {
            return []
        }

        let start = summary["startTime"] as? String
        let runDestination = extractRunDestination(from: summary)

        var exportedTests: [ExportedTest] = []
        for node in testNodes {
            exportedTests.append(contentsOf: collectTestCases(
                from: node,
                currentSuite: nil,
                runDestination: runDestination,
                start: start
            ))
        }
        return exportedTests
    }

    private func collectTestCases(from node: [String: Any],
                                      currentSuite: String?,
                                      runDestination: String?,
                                      start: String?) -> [ExportedTest] {
        var exported: [ExportedTest] = []
        let nodeType = node["nodeType"] as? String
        let suite = nodeType == "Test Suite" ? (node["name"] as? String ?? currentSuite) : currentSuite

        if nodeType == "Test Case",
           let exportedTest = makeExportedTest(from: node, suite: suite ?? "Default", runDestination: runDestination, start: start) {
            exported.append(exportedTest)
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                exported.append(contentsOf: collectTestCases(
                    from: child,
                    currentSuite: suite,
                    runDestination: runDestination,
                    start: start
                ))
            }
        }

        return exported
    }

    private func makeExportedTest(from node: [String: Any],
                                  suite: String,
                                  runDestination: String?,
                                  start: String?) -> ExportedTest? {
        guard let name = node["name"] as? String else {
            return nil
        }

        let identifier = (node["nodeIdentifier"] as? String) ?? name
        let identifierURL = node["nodeIdentifierURL"] as? String
        let status = node["result"] as? String
        let failureMessages = extractFailureMessages(from: node)

        return ExportedTest(
            name: name,
            identifier: identifier,
            identifierURL: identifierURL,
            status: status,
            suite: suite,
            runDestination: runDestination,
            start: start,
            failureMessages: failureMessages
        )
    }

    private func extractRunDestination(from summary: [String: Any]) -> String? {
        guard let devicesAndConfigurations = summary["devicesAndConfigurations"] as? [[String: Any]],
              let firstEntry = devicesAndConfigurations.first else {
            return nil
        }
        if let device = firstEntry["device"] as? [String: Any],
           let name = (device["name"] as? String) ?? (device["deviceName"] as? String) {
            return name
        }
        if let configuration = firstEntry["configuration"] as? [String: Any],
           let name = (configuration["name"] as? String) ?? (configuration["configurationName"] as? String) {
            return name
        }
        if let testPlanConfiguration = firstEntry["testPlanConfiguration"] as? [String: Any],
           let name = (testPlanConfiguration["name"] as? String) ?? (testPlanConfiguration["configurationName"] as? String) {
            return name
        }
        return nil
    }

    private func extractFailureMessages(from node: [String: Any]) -> [String] {
        guard let children = node["children"] as? [[String: Any]] else {
            return []
        }
        return children.compactMap { child in
            guard let nodeType = child["nodeType"] as? String,
                  nodeType == "Failure Message" else {
                return nil
            }
            return child["name"] as? String
        }
    }
}

struct PreparedAttachment {
    let url: URL
    let displayName: String
    let `extension`: String
}

enum ProcessedAttachment {
    case exported(AllureAttachment)
    case skipped
}

struct AttachmentKey: Hashable {
    let name: String
    let timestampMillis: Int64
}

struct AttachmentCatalog {
    let records: [AttachmentExportRecord]
    private let recordIndicesByTestKey: [String: [Int]]
    let processedFiles: [String: ProcessedAttachment]

    func resolver(for test: ExportedTest) -> AttachmentResolver {
        var attachmentsByKey: [AttachmentKey: [AllureAttachment]] = [:]
        var seenRecordIndices = Set<Int>()
        var matchingRecordIndices: [Int] = []
        if let identifierURL = test.identifierURL {
            for index in recordIndicesByTestKey[identifierURL] ?? [] where seenRecordIndices.insert(index).inserted {
                matchingRecordIndices.append(index)
            }
        }
        for index in recordIndicesByTestKey[test.identifier] ?? [] where seenRecordIndices.insert(index).inserted {
            matchingRecordIndices.append(index)
        }

        for recordIndex in matchingRecordIndices {
            let record = records[recordIndex]
            for attachment in record.attachments {
                guard let suggestedName = attachment.suggestedHumanReadableName,
                      let timestamp = attachment.timestamp,
                      case .exported(let exported)? = processedFiles[attachment.exportedFileName] else {
                    continue
                }
                let key = AttachmentKey(
                    name: suggestedName,
                    timestampMillis: Int64(timestamp * 1000)
                )
                attachmentsByKey[key, default: []].append(exported)
            }
        }

        return AttachmentResolver(attachmentsByKey: attachmentsByKey)
    }

    static func make(records: [AttachmentExportRecord],
                     processedFiles: [String: ProcessedAttachment]) -> AttachmentCatalog {
        var recordIndicesByTestKey: [String: [Int]] = [:]
        for (index, record) in records.enumerated() {
            if let testIdentifierURL = record.testIdentifierURL {
                recordIndicesByTestKey[testIdentifierURL, default: []].append(index)
            }
            if let testIdentifier = record.testIdentifier {
                recordIndicesByTestKey[testIdentifier, default: []].append(index)
            }
        }
        return AttachmentCatalog(
            records: records,
            recordIndicesByTestKey: recordIndicesByTestKey,
            processedFiles: processedFiles
        )
    }
}

struct AttachmentFilenameCatalog {
    private var metadataByTestKey: [String: [Int64: [AttachmentMetadata]]]

    static func load(fromXCResultPath xcresultPath: String) throws -> AttachmentFilenameCatalog {
        let databasePath = URL(fileURLWithPath: xcresultPath).appendingPathComponent("database.sqlite3").path
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return AttachmentFilenameCatalog(metadataByTestKey: [:])
        }

        let query = """
        with recursive activity_runs(activity_id, testCaseRunId) as (
            select rowid, testCaseRun_fk
            from Activities
            where testCaseRun_fk is not null
            union all
            select a.rowid, ar.testCaseRunId
            from Activities a
            join activity_runs ar on a.parent_fk = ar.activity_id
        )
        select
            coalesce(tc_activity.identifier, tc_issue.identifier),
            coalesce(tc_activity.identifierURL, tc_issue.identifierURL),
            att.timestamp,
            att.filenameOverride,
            att.xcResultKitPayloadRefId
        from Attachments att
        left join activity_runs ar on ar.activity_id = att.activity_fk
        left join TestCaseRuns tcr_activity on tcr_activity.rowid = ar.testCaseRunId
        left join TestCases tc_activity on tc_activity.rowid = tcr_activity.testCase_fk
        left join TestIssues ti on ti.rowid = att.testIssue_fk
        left join TestCaseRuns tcr_issue on tcr_issue.rowid = ti.testCaseRun_fk
        left join TestCases tc_issue on tc_issue.rowid = tcr_issue.testCase_fk
        where att.xcResultKitPayloadRefId is not null
          and att.filenameOverride is not null
        order by coalesce(tc_activity.identifierURL, tc_issue.identifierURL),
                 att.timestamp,
                 att.rowid;
        """
        let rows = try runCommand(
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                "-noheader",
                "-separator", "\t",
                databasePath,
                query
            ]
        )

        var metadataByTestKey: [String: [Int64: [AttachmentMetadata]]] = [:]
        for line in String(decoding: rows, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5,
                  let timestampMillis = parseAppleReferenceMilliseconds(parts[2]),
                  !parts[3].isEmpty,
                  !parts[4].isEmpty else {
                continue
            }
            let metadata = AttachmentMetadata(originalFilename: parts[3], payloadRef: parts[4])
            for key in [parts[1], parts[0]] where !key.isEmpty {
                metadataByTestKey[key, default: [:]][timestampMillis, default: []].append(metadata)
            }
        }
        return AttachmentFilenameCatalog(metadataByTestKey: metadataByTestKey)
    }

    mutating func consumeMetadata(record: AttachmentExportRecord, item: AttachmentExportItem) -> AttachmentMetadata? {
        guard let timestamp = item.timestamp else {
            return nil
        }
        let timestampMillis = Int64(timestamp * 1000)
        for key in [record.testIdentifierURL, record.testIdentifier].compactMap({ $0 }) where !key.isEmpty {
            guard var perTimestamp = metadataByTestKey[key],
                  var bucket = perTimestamp[timestampMillis],
                  !bucket.isEmpty else {
                continue
            }
            let metadata = bucket.removeFirst()
            perTimestamp[timestampMillis] = bucket.isEmpty ? nil : bucket
            metadataByTestKey[key] = perTimestamp
            return metadata
        }
        return nil
    }

}

struct AttachmentResolver {
    fileprivate var attachmentsByKey: [AttachmentKey: [AllureAttachment]]

    mutating func resolve(name: String?, timestamp: Any?) -> [AllureAttachment] {
        guard let name, let timestampMillis = AttachmentResolver.timestampMillis(from: timestamp) else {
            return []
        }
        let key = AttachmentKey(name: name, timestampMillis: timestampMillis)
        guard var bucket = attachmentsByKey[key], !bucket.isEmpty else {
            return []
        }
        let attachment = bucket.removeFirst()
        attachmentsByKey[key] = bucket.isEmpty ? nil : bucket
        return [attachment]
    }

    fileprivate static func timestampMillis(from value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return Int64(number.doubleValue * 1000)
        case let value as Double:
            return Int64(value * 1000)
        case let value as Int:
            return Int64(Double(value) * 1000)
        case let value as String:
            guard let parsed = Double(value) else {
                return nil
            }
            return Int64(parsed * 1000)
        default:
            return nil
        }
    }
}

private func parseAppleReferenceMilliseconds(_ value: String) -> Int64? {
    guard let seconds = Double(value), seconds > 0 else {
        return nil
    }
    return Int64(seconds * 1000) + 978_307_200_000
}

enum ImageFormat {
    case png
    case jpeg
}

struct IndexedImage {
    let width: Int
    let height: Int
    let indices: [UInt8]
    let palette: [UInt8]

    func makeCGImage() -> CGImage? {
        guard !palette.isEmpty, palette.count.isMultiple(of: 3) else {
            return nil
        }
        let lastIndex = palette.count / 3 - 1
        guard let colorSpace = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: lastIndex, colorTable: palette) else {
            return nil
        }
        let data = Data(indices)
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

struct SwiftPaletteQuantizer {
    private static let binLevels = 32
    private static let histogramSize = binLevels * binLevels * binLevels
    private static let ditherStrength: Float = 1.0
    private static let luminanceWeights: (Float, Float, Float) = (0.2126, 0.7152, 0.0722)

    private static let srgbToLinear: [Float] = {
        (0..<256).map { value in
            let c = Float(value) / 255.0
            if c <= 0.04045 {
                return c / 12.92
            }
            return pow((c + 0.055) / 1.055, 2.4)
        }
    }()

    struct HistogramBin {
        let r: Float
        let g: Float
        let b: Float
        let weight: Int
    }

    struct LinearColor {
        var r: Float
        var g: Float
        var b: Float
    }

    private struct HistogramAccumulator {
        var weight: Int = 0
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
    }

    private struct ColorBox {
        let indices: [Int]

        func score(histogram: [HistogramBin]) -> Float {
            guard !indices.isEmpty else {
                return 0
            }
            let mean = meanColor(histogram: histogram)
            var varianceR: Float = 0
            var varianceG: Float = 0
            var varianceB: Float = 0
            for index in indices {
                let bin = histogram[index]
                let weight = Float(bin.weight)
                let dr = bin.r - mean.r
                let dg = bin.g - mean.g
                let db = bin.b - mean.b
                varianceR += dr * dr * weight
                varianceG += dg * dg * weight
                varianceB += db * db * weight
            }
            return max(varianceR, varianceG, varianceB)
        }

        func meanColor(histogram: [HistogramBin]) -> LinearColor {
            var sumR: Float = 0
            var sumG: Float = 0
            var sumB: Float = 0
            var totalWeight: Float = 0
            for index in indices {
                let bin = histogram[index]
                let weight = Float(bin.weight)
                sumR += bin.r * weight
                sumG += bin.g * weight
                sumB += bin.b * weight
                totalWeight += weight
            }
            guard totalWeight > 0 else {
                return LinearColor(r: 0, g: 0, b: 0)
            }
            return LinearColor(
                r: sumR / totalWeight,
                g: sumG / totalWeight,
                b: sumB / totalWeight
            )
        }

        func split(histogram: [HistogramBin]) -> (ColorBox, ColorBox)? {
            guard indices.count > 1 else {
                return nil
            }

            let axis = dominantAxis(histogram: histogram)
            let sorted = indices.sorted { lhs, rhs in
                switch axis {
                case .r:
                    return histogram[lhs].r < histogram[rhs].r
                case .g:
                    return histogram[lhs].g < histogram[rhs].g
                case .b:
                    return histogram[lhs].b < histogram[rhs].b
                }
            }
            let totalWeight = sorted.reduce(0) { $0 + histogram[$1].weight }
            guard totalWeight > 1 else {
                return nil
            }

            let halfWeight = totalWeight / 2
            var accumulated = 0
            var splitIndex = 0
            for (index, histogramIndex) in sorted.enumerated() {
                accumulated += histogram[histogramIndex].weight
                if accumulated >= halfWeight {
                    splitIndex = index + 1
                    break
                }
            }

            if splitIndex <= 0 || splitIndex >= sorted.count {
                splitIndex = sorted.count / 2
            }
            guard splitIndex > 0, splitIndex < sorted.count else {
                return nil
            }

            let left = Array(sorted[..<splitIndex])
            let right = Array(sorted[splitIndex...])
            guard !left.isEmpty, !right.isEmpty else {
                return nil
            }
            return (ColorBox(indices: left), ColorBox(indices: right))
        }

        private func dominantAxis(histogram: [HistogramBin]) -> Axis {
            let mean = meanColor(histogram: histogram)
            var varianceR: Float = 0
            var varianceG: Float = 0
            var varianceB: Float = 0
            for index in indices {
                let bin = histogram[index]
                let weight = Float(bin.weight)
                let dr = bin.r - mean.r
                let dg = bin.g - mean.g
                let db = bin.b - mean.b
                varianceR += dr * dr * weight
                varianceG += dg * dg * weight
                varianceB += db * db * weight
            }
            if varianceR >= varianceG && varianceR >= varianceB {
                return .r
            }
            if varianceG >= varianceB {
                return .g
            }
            return .b
        }

        private enum Axis {
            case r
            case g
            case b
        }
    }

    static func quantize(image: CGImage, colors requestedColors: Int) throws -> IndexedImage? {
        let targetColors = min(max(requestedColors, 2), 256)
        let (pixels, width, height) = try decodeImage(image)
        let histogram = buildHistogram(from: pixels)
        guard histogram.count > targetColors else {
            return nil
        }

        let boxes = splitBoxes(histogram: histogram, targetColors: targetColors)
        guard !boxes.isEmpty else {
            return nil
        }

        var palette = boxes.map { $0.meanColor(histogram: histogram) }
        palette = refinePalette(histogram: histogram, palette: palette, passes: 2)
        let lookup = buildLookupTable(palette: palette)
        let output = try remap(
            pixels: pixels,
            width: width,
            height: height,
            palette: palette,
            lookup: lookup
        )
        return IndexedImage(
            width: width,
            height: height,
            indices: output,
            palette: palette.flatMap { color in
                [linearToSrgb(color.r), linearToSrgb(color.g), linearToSrgb(color.b)]
            }
        )
    }

    private static func decodeImage(_ image: CGImage) throws -> ([UInt8], Int, Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard success else {
            throw CLIError.processFailed("Failed to decode image for quantization")
        }
        return (pixels, width, height)
    }

    private static func buildHistogram(from pixels: [UInt8]) -> [HistogramBin] {
        var accumulators = Array(repeating: HistogramAccumulator(), count: histogramSize)

        pixels.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            let pixelCount = pixels.count / 4
            for index in 0..<pixelCount {
                let offset = index * 4
                var r = Int(pointer[offset])
                var g = Int(pointer[offset + 1])
                var b = Int(pointer[offset + 2])
                let a = Int(pointer[offset + 3])
                if a == 0 {
                    r = 255
                    g = 255
                    b = 255
                } else if a < 255 {
                    r = min(255, r + 255 - a)
                    g = min(255, g + 255 - a)
                    b = min(255, b + 255 - a)
                }

                let binIndex = histogramIndex(red: r, green: g, blue: b)
                let linearR = srgbToLinear[r]
                let linearG = srgbToLinear[g]
                let linearB = srgbToLinear[b]

                accumulators[binIndex].weight += 1
                accumulators[binIndex].sumR += linearR
                accumulators[binIndex].sumG += linearG
                accumulators[binIndex].sumB += linearB
            }
        }

        var histogram: [HistogramBin] = []
        histogram.reserveCapacity(4096)
        for accumulator in accumulators where accumulator.weight > 0 {
            let weight = Float(accumulator.weight)
            histogram.append(HistogramBin(
                r: accumulator.sumR / weight,
                g: accumulator.sumG / weight,
                b: accumulator.sumB / weight,
                weight: accumulator.weight
            ))
        }
        return histogram
    }

    private static func splitBoxes(histogram: [HistogramBin], targetColors: Int) -> [ColorBox] {
        var boxes = [ColorBox(indices: Array(histogram.indices))]
        while boxes.count < targetColors {
            var bestIndex: Int?
            var bestScore: Float = 0
            for (index, box) in boxes.enumerated() {
                let score = box.score(histogram: histogram)
                if score > bestScore, box.indices.count > 1 {
                    bestScore = score
                    bestIndex = index
                }
            }

            guard let index = bestIndex, let split = boxes[index].split(histogram: histogram) else {
                break
            }

            boxes[index] = split.0
            boxes.append(split.1)
        }
        return boxes
    }

    private static func refinePalette(histogram: [HistogramBin], palette: [LinearColor], passes: Int) -> [LinearColor] {
        guard !palette.isEmpty else {
            return palette
        }

        var currentPalette = palette
        for _ in 0..<max(passes, 0) {
            var sums = Array(repeating: (r: Float(0), g: Float(0), b: Float(0), weight: Int(0)), count: currentPalette.count)
            for bin in histogram {
                let index = nearestPaletteIndex(for: bin, palette: currentPalette)
                let weight = bin.weight
                sums[index].r += bin.r * Float(weight)
                sums[index].g += bin.g * Float(weight)
                sums[index].b += bin.b * Float(weight)
                sums[index].weight += weight
            }

            for index in sums.indices where sums[index].weight > 0 {
                let weight = Float(sums[index].weight)
                currentPalette[index] = LinearColor(
                    r: sums[index].r / weight,
                    g: sums[index].g / weight,
                    b: sums[index].b / weight
                )
            }
        }
        return currentPalette
    }

    private static func buildLookupTable(palette: [LinearColor]) -> [Int] {
        var lookup = [Int](repeating: 0, count: histogramSize)
        for red in 0..<binLevels {
            for green in 0..<binLevels {
                for blue in 0..<binLevels {
                    let bin = histogramIndex(red: red * 8 + 4, green: green * 8 + 4, blue: blue * 8 + 4)
                    let sample = LinearColor(
                        r: srgbToLinear[min(red * 8 + 4, 255)],
                        g: srgbToLinear[min(green * 8 + 4, 255)],
                        b: srgbToLinear[min(blue * 8 + 4, 255)]
                    )
                    lookup[bin] = nearestPaletteIndex(for: sample, palette: palette)
                }
            }
        }
        return lookup
    }

    private static func remap(
        pixels: [UInt8],
        width: Int,
        height: Int,
        palette: [LinearColor],
        lookup: [Int]
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height)
        var currentErrorR = [Float](repeating: 0, count: width + 2)
        var currentErrorG = [Float](repeating: 0, count: width + 2)
        var currentErrorB = [Float](repeating: 0, count: width + 2)
        var nextErrorR = [Float](repeating: 0, count: width + 2)
        var nextErrorG = [Float](repeating: 0, count: width + 2)
        var nextErrorB = [Float](repeating: 0, count: width + 2)

        pixels.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                swap(&currentErrorR, &nextErrorR)
                swap(&currentErrorG, &nextErrorG)
                swap(&currentErrorB, &nextErrorB)
                nextErrorR = [Float](repeating: 0, count: width + 2)
                nextErrorG = [Float](repeating: 0, count: width + 2)
                nextErrorB = [Float](repeating: 0, count: width + 2)

                let rowOffset = y * width * 4
                for x in 0..<width {
                    let pixelOffset = rowOffset + x * 4
                    var red = Int(pointer[pixelOffset])
                    var green = Int(pointer[pixelOffset + 1])
                    var blue = Int(pointer[pixelOffset + 2])
                    let alpha = Int(pointer[pixelOffset + 3])
                    if alpha == 0 {
                        red = 255
                        green = 255
                        blue = 255
                    } else if alpha < 255 {
                        red = min(255, red + 255 - alpha)
                        green = min(255, green + 255 - alpha)
                        blue = min(255, blue + 255 - alpha)
                    }

                    var linearR = srgbToLinear[red] + currentErrorR[x + 1] * ditherStrength
                    var linearG = srgbToLinear[green] + currentErrorG[x + 1] * ditherStrength
                    var linearB = srgbToLinear[blue] + currentErrorB[x + 1] * ditherStrength
                    linearR = clamp(linearR)
                    linearG = clamp(linearG)
                    linearB = clamp(linearB)

                    let sr = Int(linearToSrgb(linearR))
                    let sg = Int(linearToSrgb(linearG))
                    let sb = Int(linearToSrgb(linearB))
                    let paletteIndex = lookup[histogramIndex(red: sr, green: sg, blue: sb)]
                    output[y * width + x] = UInt8(paletteIndex)

                    let errorR = linearR - palette[paletteIndex].r
                    let errorG = linearG - palette[paletteIndex].g
                    let errorB = linearB - palette[paletteIndex].b

                    currentErrorR[x + 2] += errorR * 7.0 / 16.0
                    currentErrorG[x + 2] += errorG * 7.0 / 16.0
                    currentErrorB[x + 2] += errorB * 7.0 / 16.0

                    nextErrorR[x] += errorR * 3.0 / 16.0
                    nextErrorG[x] += errorG * 3.0 / 16.0
                    nextErrorB[x] += errorB * 3.0 / 16.0

                    nextErrorR[x + 1] += errorR * 5.0 / 16.0
                    nextErrorG[x + 1] += errorG * 5.0 / 16.0
                    nextErrorB[x + 1] += errorB * 5.0 / 16.0

                    nextErrorR[x + 2] += errorR * 1.0 / 16.0
                    nextErrorG[x + 2] += errorG * 1.0 / 16.0
                    nextErrorB[x + 2] += errorB * 1.0 / 16.0
                }
            }
        }

        return output
    }

    private static func nearestPaletteIndex(for color: HistogramBin, palette: [LinearColor]) -> Int {
        nearestPaletteIndex(
            for: LinearColor(r: color.r, g: color.g, b: color.b),
            palette: palette
        )
    }

    private static func nearestPaletteIndex(for color: LinearColor, palette: [LinearColor]) -> Int {
        var bestIndex = 0
        var bestDistance = Float.greatestFiniteMagnitude
        let (wr, wg, wb) = luminanceWeights
        for (index, candidate) in palette.enumerated() {
            let dr = color.r - candidate.r
            let dg = color.g - candidate.g
            let db = color.b - candidate.b
            let distance = dr * dr * wr + dg * dg * wg + db * db * wb
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func histogramIndex(red: Int, green: Int, blue: Int) -> Int {
        let r = clampComponent(red) >> 3
        let g = clampComponent(green) >> 3
        let b = clampComponent(blue) >> 3
        return (r << 10) | (g << 5) | b
    }

    private static func clampComponent(_ value: Int) -> Int {
        min(max(value, 0), 255)
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func linearToSrgb(_ value: Float) -> UInt8 {
        let clamped = clamp(value)
        let srgb: Float
        if clamped <= 0.0031308 {
            srgb = clamped * 12.92
        } else {
            srgb = 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }
        return UInt8(max(0, min(255, Int((srgb * 255.0).rounded()))))
    }
}

struct IssueCatalog {
    private let tracesByIdentifier: [String: String]

    static func load(fromXCResultPath xcresultPath: String) throws -> IssueCatalog {
        let databasePath = URL(fileURLWithPath: xcresultPath).appendingPathComponent("database.sqlite3").path
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return IssueCatalog(tracesByIdentifier: [:])
        }

        let identifiersOutput = try runCommand(
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                "-noheader",
                "-separator", "\t",
                databasePath,
                "select distinct tc.identifier " +
                "from TestCases tc " +
                "join TestCaseRuns tcr on tcr.testCase_fk = tc.rowid " +
                "join TestIssues ti on ti.testCaseRun_fk = tcr.rowid " +
                "where ti.sourceCodeContext_fk is not null;"
            ]
        )
        let identifiers = String(decoding: identifiersOutput, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var tracesByIdentifier: [String: String] = [:]
        for identifier in identifiers {
            let escapedIdentifier = identifier.replacingOccurrences(of: "'", with: "''")
            let query = """
            select scl.filePath || ':' || scl.lineNumber
            from TestCases tc
            join TestCaseRuns tcr on tcr.testCase_fk = tc.rowid
            join TestIssues ti on ti.testCaseRun_fk = tcr.rowid
            join SourceCodeFrames scf on scf.context_fk = ti.sourceCodeContext_fk
            join SourceCodeSymbolInfos scsi on scsi.rowid = scf.symbolInfo_fk
            join SourceCodeLocations scl on scl.rowid = scsi.location_fk
            where tc.identifier = '\(escapedIdentifier)'
            order by scf.orderInContainer;
            """
            let traceOutput = try runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    "-noheader",
                    databasePath,
                    query
                ]
            )
            let trace = String(decoding: traceOutput, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
                .joined(separator: "\n")
            if !trace.isEmpty {
                tracesByIdentifier[identifier] = trace
            }
        }

        return IssueCatalog(tracesByIdentifier: tracesByIdentifier)
    }

    func trace(for identifier: String) -> String? {
        tracesByIdentifier[identifier]
    }
}

struct ActivityTiming {
    let title: String
    let start: Int64?
    let stop: Int64?
}

struct ActivityCatalog {
    private let rootsByIdentifier: [String: [DBActivity]]

    static func load(fromXCResultPath xcresultPath: String) throws -> ActivityCatalog {
        let databasePath = URL(fileURLWithPath: xcresultPath).appendingPathComponent("database.sqlite3").path
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return ActivityCatalog(rootsByIdentifier: [:])
        }

        let identifierRows = try runCommand(
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                "-noheader",
                "-separator", "\t",
                databasePath,
                "select distinct tc.identifier, tcr.rowid " +
                "from TestCases tc join TestCaseRuns tcr on tcr.testCase_fk = tc.rowid;"
            ]
        )

        let lines = String(decoding: identifierRows, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)

        var rootsByIdentifier: [String: [DBActivity]] = [:]
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let testCaseRunId = Int(parts[1]) else {
                continue
            }
            let identifier = parts[0]
            let query = """
            with recursive activity_tree(rowid, parent_fk, orderInParent, title, startTime, finishTime, failureIDs) as (
                select rowid, parent_fk, orderInParent, title, startTime, finishTime, coalesce(failureIDs, '')
                from Activities
                where testCaseRun_fk = \(testCaseRunId)
                union all
                select a.rowid, a.parent_fk, a.orderInParent, a.title, a.startTime, a.finishTime, coalesce(a.failureIDs, '')
                from Activities a
                join activity_tree t on a.parent_fk = t.rowid
            )
            select rowid, coalesce(parent_fk, 0), orderInParent, json_quote(title), startTime, finishTime, coalesce(failureIDs, '')
            from activity_tree
            order by coalesce(parent_fk, 0), orderInParent;
            """
            let activityRows = try runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    "-noheader",
                    "-separator", "\t",
                    databasePath,
                    query
                ]
            )
            let dbActivities = parseActivities(from: String(decoding: activityRows, as: UTF8.self))
            let normalizedRoots = normalizeActivities(
                dbActivities.values.sorted { $0.orderInParent < $1.orderInParent },
                parentTitle: nil
            )
            rootsByIdentifier[identifier] = normalizedRoots
        }

        return ActivityCatalog(rootsByIdentifier: rootsByIdentifier)
    }

    func resolver(for test: ExportedTest) -> ActivityTimingResolver {
        ActivityTimingResolver(siblings: rootsByIdentifier[test.identifier] ?? [])
    }

    private static func parseActivities(from output: String) -> [Int: DBActivity] {
        var baseNodes: [Int: DBActivity] = [:]
        var childMap: [Int: [Int]] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7,
                  let rowId = Int(parts[0]),
                  let parentId = Int(parts[1]),
                  let orderInParent = Int(parts[2]) else {
                continue
            }
            let node = DBActivity(
                id: rowId,
                parentId: parentId == 0 ? nil : parentId,
                orderInParent: orderInParent,
                title: decodeSQLiteJSONString(parts[3]) ?? parts[3],
                start: parseAppleReferenceMilliseconds(parts[4]),
                stop: parseAppleReferenceMilliseconds(parts[5]),
                isFailure: !parts[6].isEmpty
            )
            baseNodes[rowId] = node
            childMap[parentId, default: []].append(rowId)
        }

        func buildActivity(_ id: Int) -> DBActivity? {
            guard let node = baseNodes[id] else {
                return nil
            }
            let sortedChildren = (childMap[id] ?? []).sorted {
                (baseNodes[$0]?.orderInParent ?? 0) < (baseNodes[$1]?.orderInParent ?? 0)
            }
            return node.withChildren(sortedChildren.compactMap(buildActivity))
        }

        let rootIds = (childMap[0] ?? []).sorted {
            (baseNodes[$0]?.orderInParent ?? 0) < (baseNodes[$1]?.orderInParent ?? 0)
        }
        var roots: [Int: DBActivity] = [:]
        for rootId in rootIds {
            if let root = buildActivity(rootId) {
                roots[rootId] = root
            }
        }
        return roots
    }

    private static func shouldDeferDBChild(_ child: DBActivity) -> Bool {
        shouldFlattenDBTitleStatic(child.title) || isTraceOnlyLeafStatic(child)
    }

    private static func shouldSkipAttachmentEchoChildStatic(_ activity: DBActivity, parentTitle: String) -> Bool {
        guard parentTitle.hasPrefix("Added attachment named '") else {
            return false
        }
        return activity.children.isEmpty
    }

    private static func shouldFlattenDBTitleStatic(_ title: String) -> Bool {
        ActivityParser.shouldFlattenDBTitleStatic(title)
    }

    private static func isTraceOnlyLeafStatic(_ activity: DBActivity) -> Bool {
        activity.start == nil && activity.children.isEmpty
    }

    private static func decodeSQLiteJSONString(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func normalizeActivities(_ activities: [DBActivity], parentTitle: String?) -> [DBActivity] {
        var normalized: [DBActivity] = []
        for activity in activities.sorted(by: { $0.orderInParent < $1.orderInParent }) {
            if let parentTitle, shouldSkipAttachmentEchoChildStatic(activity, parentTitle: parentTitle) {
                continue
            }
            if activity.title.hasPrefix("Start Test at") || shouldFlattenDBTitleStatic(activity.title) {
                normalized.append(contentsOf: normalizeActivities(activity.children, parentTitle: activity.title))
                continue
            }
            if isTraceOnlyLeafStatic(activity) {
                continue
            }

            if activity.isFailure, activity.children.allSatisfy({ shouldDeferDBChild($0) }) {
                normalized.append(activity.withChildren([]))
                continue
            }

            normalized.append(
                activity.withChildren(
                    normalizeActivities(activity.children, parentTitle: activity.title)
                )
            )
        }
        return normalized
    }
}

struct ActivityTimingResolver {
    private let siblings: [DBActivity]
    private var usedIndices: Set<Int> = []
    private static let startToleranceMs: Int64 = 250

    init(siblings: [DBActivity]) {
        self.siblings = siblings
    }

    mutating func resolveNode(for title: String, fallbackStart: Int64?) -> DBActivity? {
        guard !siblings.isEmpty else {
            return nil
        }
        let sameTitleIndices = siblings.indices.filter { index in
            !usedIndices.contains(index) && siblings[index].title == title
        }
        guard !sameTitleIndices.isEmpty else {
            return nil
        }

        let matchedIndex: Int
        if let fallbackStart {
            let withinTolerance = sameTitleIndices
                .filter { index in
                    guard let candidateStart = siblings[index].start else {
                        return false
                    }
                    return abs(candidateStart - fallbackStart) <= Self.startToleranceMs
                }
            let candidateIndices = withinTolerance.isEmpty ? sameTitleIndices : withinTolerance
            matchedIndex = candidateIndices.min { lhs, rhs in
                let lhsDelta = abs((siblings[lhs].start ?? fallbackStart) - fallbackStart)
                let rhsDelta = abs((siblings[rhs].start ?? fallbackStart) - fallbackStart)
                if lhsDelta == rhsDelta {
                    return lhs < rhs
                }
                return lhsDelta < rhsDelta
            } ?? candidateIndices[0]
        } else {
            matchedIndex = sameTitleIndices[0]
        }

        usedIndices.insert(matchedIndex)
        return siblings[matchedIndex]
    }
}

struct DBActivity {
    let id: Int
    let parentId: Int?
    let orderInParent: Int
    let title: String
    let start: Int64?
    let stop: Int64?
    let isFailure: Bool
    var children: [DBActivity] = []

    func withChildren(_ children: [DBActivity]) -> DBActivity {
        var copy = self
        copy.children = children
        return copy
    }
}

struct ActivityParser {
    var defaultFailureTrace: String?

    func parseActivity(_ activity: [String: Any],
                       resolver: inout AttachmentResolver,
                       timingResolver: inout ActivityTimingResolver) -> AllureStep? {
        guard let title = activity["title"] as? String else {
            return nil
        }
        if isDeferredFailureActivity(activity) {
            return nil
        }
        if isTraceOnlyLeaf(activity) {
            return nil
        }
        if title.hasPrefix("Start Test at") || shouldSkipTitle(title) {
            let fallbackStart = milliseconds(from: activity["startTime"])
            let matchedNode = timingResolver.resolveNode(for: title, fallbackStart: fallbackStart)
            var childTimingResolver = matchedNode.map { ActivityTimingResolver(siblings: $0.children) } ?? timingResolver
            let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
            let childSteps = childActivities.compactMap { parseActivity($0, resolver: &resolver, timingResolver: &childTimingResolver) }
            let attachments = resolveAttachments(from: activity, resolver: &resolver)
            return (childSteps.isEmpty && attachments.isEmpty)
                ? nil
                : makeContainerStep(
                    from: activity,
                    fallbackName: title,
                    attachments: attachments,
                    steps: childSteps,
                    resolvedStop: matchedNode?.stop
                )
        }

        let fallbackStart = milliseconds(from: activity["startTime"])
        let matchedNode = timingResolver.resolveNode(for: title, fallbackStart: fallbackStart)
        let resolvedStart = matchedNode?.start ?? fallbackStart
        let resolvedStop = matchedNode?.stop
        var childTimingResolver = ActivityTimingResolver(siblings: matchedNode?.children ?? [])

        let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
        var childSteps: [AllureStep] = []
        var deferredFailures: [AllureStep] = []
        for childActivity in childActivities {
            if shouldSkipAttachmentEchoChild(childActivity, parentTitle: title) {
                continue
            }
            if let deferredFailure = makeDeferredFailureStep(from: childActivity, resolver: &resolver, timingResolver: &childTimingResolver) {
                deferredFailures.append(deferredFailure)
                continue
            }
            if let step = parseActivity(childActivity, resolver: &resolver, timingResolver: &childTimingResolver) {
                childSteps.append(step)
            }
        }
        childSteps.append(contentsOf: deferredFailures)
        let duplicateDescendantAttachments = descendantAttachmentKeys(in: childActivities)
        let rawAttachments = activity["attachments"] as? [[String: Any]] ?? []
        let attachments = resolveAttachments(
            from: activity,
            resolver: &resolver,
            excluding: duplicateDescendantAttachments
        )
        if childSteps.isEmpty && attachments.isEmpty && (!rawAttachments.isEmpty || !childActivities.isEmpty) {
            return nil
        }
        let isFailed = (activity["isAssociatedWithFailure"] as? Bool) == true
            || deferredFailures.contains(where: { $0.status == "failed" })
        let fallbackStop = computeStop(start: resolvedStart ?? fallbackStart, childSteps: childSteps)
        let start = resolvedStart ?? fallbackStart
        let stop = mergedStop(primary: resolvedStop, fallback: fallbackStop)
        let status = isFailed ? "failed" : "passed"
        let details = deferredFailures.first?.statusDetails ?? (isFailed ? AllureStatusDetails(
            known: false,
            muted: false,
            flaky: false,
            message: title,
            trace: nil
        ) : nil)

        return AllureStep(
            name: title,
            status: status,
            start: start,
            stop: stop,
            attachments: attachments,
            steps: childSteps,
            statusDetails: details
        )
    }

    private func makeContainerStep(from activity: [String: Any],
                                   fallbackName: String,
                                   attachments: [AllureAttachment],
                                   steps: [AllureStep],
                                   resolvedStop: Int64? = nil) -> AllureStep {
        let start = milliseconds(from: activity["startTime"]) ?? steps.compactMap(\.start).min()
        let childStop = computeStop(start: start, childSteps: steps)
        let attachmentStop = attachmentStopTimestamp(from: activity)
        let fallbackStop = mergedStop(primary: childStop, fallback: attachmentStop)
        let stop = mergedStop(primary: resolvedStop, fallback: fallbackStop)
        return AllureStep(
            name: fallbackName,
            status: steps.contains(where: { $0.status == "failed" }) ? "failed" : "passed",
            start: start,
            stop: stop,
            attachments: attachments,
            steps: steps,
            statusDetails: nil
        )
    }

    private func computeStop(start: Int64?, childSteps: [AllureStep]) -> Int64? {
        if let childStop = childSteps.compactMap(\.stop).max() {
            return childStop
        }
        return start
    }

    private func mergedStop(primary: Int64?, fallback: Int64?) -> Int64? {
        switch (primary, fallback) {
        case let (.some(primary), .some(fallback)):
            return max(primary, fallback)
        case let (.some(primary), .none):
            return primary
        case let (.none, .some(fallback)):
            return fallback
        case (.none, .none):
            return nil
        }
    }

    private func milliseconds(from value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return Int64(number.doubleValue * 1000)
        case let value as Double:
            return Int64(value * 1000)
        case let value as Int:
            return Int64(Double(value) * 1000)
        default:
            return nil
        }
    }

    private func resolveAttachments(from activity: [String: Any],
                                    resolver: inout AttachmentResolver,
                                    excluding excluded: Set<AttachmentKey> = []) -> [AllureAttachment] {
        let rawAttachments = activity["attachments"] as? [[String: Any]] ?? []
        return rawAttachments.flatMap { attachment in
            if let key = attachmentKey(for: attachment), excluded.contains(key) {
                return [AllureAttachment]()
            }
            return resolver.resolve(name: attachment["name"] as? String, timestamp: attachment["timestamp"])
        }
    }

    private func descendantAttachmentKeys(in activities: [[String: Any]]) -> Set<AttachmentKey> {
        var keys: Set<AttachmentKey> = []
        for activity in activities {
            let attachments = activity["attachments"] as? [[String: Any]] ?? []
            for attachment in attachments {
                if let key = attachmentKey(for: attachment) {
                    keys.insert(key)
                }
            }
            let children = activity["childActivities"] as? [[String: Any]] ?? []
            keys.formUnion(descendantAttachmentKeys(in: children))
        }
        return keys
    }

    private func attachmentKey(for attachment: [String: Any]) -> AttachmentKey? {
        guard let name = attachment["name"] as? String,
              let timestampMillis = AttachmentResolver.timestampMillis(from: attachment["timestamp"]) else {
            return nil
        }
        return AttachmentKey(name: name, timestampMillis: timestampMillis)
    }

    private func attachmentStopTimestamp(from activity: [String: Any]) -> Int64? {
        let rawAttachments = activity["attachments"] as? [[String: Any]] ?? []
        return rawAttachments.compactMap { AttachmentResolver.timestampMillis(from: $0["timestamp"]) }.max()
    }

    fileprivate func shouldSkipTitle(_ title: String) -> Bool {
        Self.shouldSkipTitleStatic(title)
    }

    fileprivate static func shouldSkipTitleStatic(_ title: String) -> Bool {
        title == "Collecting debug information to assist test failure triage"
            || shouldFlattenDBTitleStatic(title)
    }

    fileprivate static func shouldFlattenDBTitleStatic(_ title: String) -> Bool {
        title.hasPrefix("kXCTAttachmentLegacy")
            || title.hasPrefix("Debug description for ")
            || title.hasPrefix("App UI hierarchy for ")
    }

    private func isTraceOnlyLeaf(_ activity: [String: Any]) -> Bool {
        if activity["startTime"] != nil {
            return false
        }
        let hasAttachments = !(activity["attachments"] as? [[String: Any]] ?? []).isEmpty
        let hasChildren = !(activity["childActivities"] as? [[String: Any]] ?? []).isEmpty
        return !hasAttachments && !hasChildren
    }

    private func shouldSkipAttachmentEchoChild(_ activity: [String: Any], parentTitle: String) -> Bool {
        guard parentTitle.hasPrefix("Added attachment named '") else {
            return false
        }
        let hasAttachments = !(activity["attachments"] as? [[String: Any]] ?? []).isEmpty
        let hasChildren = !(activity["childActivities"] as? [[String: Any]] ?? []).isEmpty
        return !hasAttachments && !hasChildren
    }

    private func isDeferredFailureActivity(_ activity: [String: Any]) -> Bool {
        guard (activity["isAssociatedWithFailure"] as? Bool) == true else {
            return false
        }
        let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
        return !childActivities.isEmpty && childActivities.allSatisfy { child in
            shouldSkipTitle(child["title"] as? String ?? "") || isTraceOnlyLeaf(child)
        }
    }

    private func makeDeferredFailureStep(from activity: [String: Any],
                                         resolver: inout AttachmentResolver,
                                         timingResolver: inout ActivityTimingResolver) -> AllureStep? {
        guard isDeferredFailureActivity(activity),
              let title = activity["title"] as? String else {
            return nil
        }
        let attachments = resolveAttachments(from: activity, resolver: &resolver)
        let fallbackStart = milliseconds(from: activity["startTime"])
        let matchedNode = timingResolver.resolveNode(for: title, fallbackStart: fallbackStart)
        let start = matchedNode?.start ?? fallbackStart
        let stop = matchedNode?.stop ?? fallbackStart
        let details = AllureStatusDetails(
            known: false,
            muted: false,
            flaky: false,
            message: title,
            trace: defaultFailureTrace ?? deferredFailureTrace(from: activity)
        )
        return AllureStep(
            name: title,
            status: "failed",
            start: start,
            stop: stop ?? start,
            attachments: attachments,
            steps: [],
            statusDetails: details
        )
    }

    private func deferredFailureTrace(from activity: [String: Any]) -> String? {
        let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
        let lines = childActivities.compactMap { child -> String? in
            let title = child["title"] as? String ?? ""
            guard !title.isEmpty, !shouldSkipTitle(title), isTraceOnlyLeaf(child) else {
                return nil
            }
            return title
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

struct FailureTraceParser {
    func trace(from testDetails: [String: Any]?) -> String? {
        guard let testRuns = testDetails?["testRuns"] as? [[String: Any]] else {
            return nil
        }
        var lines: [String] = []
        for testRun in testRuns {
            collectTraceLines(from: testRun, into: &lines)
        }
        if lines.isEmpty {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private func collectTraceLines(from node: [String: Any], into lines: inout [String]) {
        if let nodeType = node["nodeType"] as? String,
           nodeType == "Source Code Reference",
           let name = node["name"] as? String,
           !name.isEmpty {
            lines.append(name)
        }
        let children = node["children"] as? [[String: Any]] ?? []
        for child in children {
            collectTraceLines(from: child, into: &lines)
        }
    }
}
