import Foundation
import XCTest
@testable import XCUALR

final class JUnitDestinationTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/tmp/junit-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath()
    }

    func testRejectsDirectoryInputAndAncestorDestinations() throws {
        let root = try workspace()
        let input = root.appendingPathComponent("input.xcresult")
        let allure = root.appendingPathComponent("allure")
        for url in [root, allure, input, input.appendingPathComponent("database.sqlite3")] {
            XCTAssertThrowsError(try JUnitDestination(path: url.path, inputURL: input, allureURL: allure))
        }
        let file = root.appendingPathComponent("file")
        try Data("existing".utf8).write(to: file)
        XCTAssertThrowsError(try JUnitDestination(path: file.appendingPathComponent("report.xml").path,
                                                 inputURL: input, allureURL: allure))
    }

    func testStagesInternalReportAndRejectsArtifactCollision() throws {
        let root = try workspace()
        let allure = root.appendingPathComponent("allure")
        let staging = root.appendingPathComponent("staging")
        let destination = try JUnitDestination(
            path: allure.appendingPathComponent("reports/junit.xml").path,
            inputURL: root.appendingPathComponent("input.xcresult"), allureURL: allure
        )
        let stagedReport = try destination.writeURL(stagingDirectory: staging)
        XCTAssertEqual(stagedReport, staging.appendingPathComponent("reports/junit.xml"))
        try JUnitExporter().write(tests: [], suiteName: "empty", to: stagedReport)
        XCTAssertThrowsError(try destination.writeURL(stagingDirectory: staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.url.path))
    }

    func testRejectsNamesReservedForArtifactsFromEarlierExports() throws {
        let root = try workspace()
        let allure = root.appendingPathComponent("allure")
        for suffix in ["-result.json", "-attachment.xml"] {
            let name = UUID().uuidString.lowercased() + suffix
            XCTAssertThrowsError(try JUnitDestination(
                path: allure.appendingPathComponent(name).path,
                inputURL: root.appendingPathComponent("input.xcresult"), allureURL: allure
            ))
        }
    }

    func testResolvesAliasesAndDoesNotConfuseCommonPathPrefixes() throws {
        let root = try workspace()
        let allure = root.appendingPathComponent("allure")
        let input = root.appendingPathComponent("input.xcresult")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        XCTAssertThrowsError(try JUnitDestination(path: alias.appendingPathComponent("report.xml").path,
                                                 inputURL: input, allureURL: allure))
        let external = root.appendingPathComponent("allure-other/junit.xml")
        let destination = try JUnitDestination(path: external.path, inputURL: input, allureURL: allure)
        XCTAssertEqual(try destination.writeURL(stagingDirectory: root.appendingPathComponent("staging")), external)
    }
}
