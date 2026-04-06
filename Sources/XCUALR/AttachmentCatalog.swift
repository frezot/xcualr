import Foundation

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

    static func timestampMillis(from value: Any?) -> Int64? {
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
