import Foundation

extension ExportCommand {
    func exportAttachments(tool: XCResultTool,
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
}
