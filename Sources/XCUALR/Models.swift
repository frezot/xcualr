import Foundation

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
