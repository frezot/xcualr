import Foundation
import CryptoKit

extension ExportCommand {
    static func bundleIdentity(for inputPath: String) -> String {
        let normalizedPath = URL(fileURLWithPath: inputPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return deterministicHash(for: normalizedPath)
    }

    static func resolvePngQuantPath() -> String? {
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

    func mimeType(forExtension ext: String, fileName: String) -> String {
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

    func deterministicResultFileName(for testIdentifier: String) -> String {
        let namespacedIdentifier = "\(Self.bundleIdentity(for: configuration.inputPath))|\(testIdentifier)"
        return "\(deterministicUUID(for: namespacedIdentifier).uuidString.lowercased())-result.json"
    }

    func deterministicAttachmentSource(sourceKey: String, fileExtension: String) -> String {
        let namespacedSourceKey = "\(Self.bundleIdentity(for: configuration.inputPath))|\(sourceKey)"
        return "\(deterministicUUID(for: namespacedSourceKey).uuidString.lowercased())-attachment.\(fileExtension)"
    }

    private static func deterministicHash(for value: String) -> String {
        let bytes = Insecure.MD5.hash(data: Data(value.utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
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

    func replaceExtension(in fileName: String, with newExtension: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? fileName : "\(base).\(newExtension)"
    }

    func milliseconds(from value: Any?) -> Int64? {
        guard let value = doubleValue(value) else {
            return nil
        }
        return Int64(value * 1000)
    }

    func doubleValue(_ value: Any?) -> Double? {
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

    func iso8601Milliseconds(from value: String?) -> Int64? {
        guard let value else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    func normalizeFailureMessage(_ message: String) -> String {
        message.replacingOccurrences(
            of: #"^[^:\n]+:\d+:\s*"#,
            with: "",
            options: .regularExpression
        )
    }
}
