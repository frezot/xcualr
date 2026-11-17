import Foundation

/// Resolves an optional report inside the Allure directory into its staging directory.
struct JUnitDestination {
    let url: URL
    private let relativePath: String?

    init(path: String, inputURL: URL, allureURL: URL) throws {
        let destination = Self.resolvedURL(URL(fileURLWithPath: path))
        let input = Self.resolvedURL(inputURL)
        let allure = Self.resolvedURL(allureURL)
        let destinationParts = destination.pathComponents
        let allureParts = allure.pathComponents

        guard !destinationParts.starts(with: input.pathComponents) else {
            throw CLIError.usage("--junit must not overwrite the input .xcresult bundle")
        }
        guard !allureParts.starts(with: destinationParts) else {
            throw CLIError.usage("--junit must name a file, not the Allure output directory or its parent")
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CLIError.usage("--junit must name a file, not a directory: \(destination.path)")
        }
        var parent = destination.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            parent.deleteLastPathComponent()
        }
        guard isDirectory.boolValue else {
            throw CLIError.usage("--junit parent is not a directory: \(parent.path)")
        }
        url = destination
        relativePath = destinationParts.starts(with: allureParts)
            ? destinationParts.dropFirst(allureParts.count).joined(separator: "/")
            : nil
        if relativePath != nil, Self.isAllureArtifactName(destination.lastPathComponent) {
            // Also protect artifacts from earlier bundles when appending an export.
            throw CLIError.usage("--junit conflicts with the Allure artifact namespace: \(destination.path)")
        }
    }

    func writeURL(stagingDirectory: URL) throws -> URL {
        guard let relativePath else { return url }
        let stagedURL = stagingDirectory.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: stagedURL.path) else {
            throw CLIError.usage("--junit conflicts with an exported Allure artifact: \(url.path)")
        }
        return stagedURL
    }

    private static func resolvedURL(_ url: URL) -> URL {
        // resolvingSymlinksInPath alone does not resolve parents of a nonexistent file.
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missingComponents.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return missingComponents.reversed().reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }
    }

    private static func isAllureArtifactName(_ name: String) -> Bool {
        guard UUID(uuidString: String(name.prefix(36))) != nil else { return false }
        let suffix = name.dropFirst(36).lowercased()
        return suffix == "-result.json" || suffix.hasPrefix("-attachment.")
    }
}
