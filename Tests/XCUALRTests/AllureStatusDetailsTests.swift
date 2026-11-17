import XCTest
@testable import XCUALR

final class AllureStatusDetailsTests: XCTestCase {
    private func statusDetails(messages: [String] = [], details: [String: Any]? = nil,
                               status: String = "Failed", trace: String? = nil) throws -> AllureStatusDetails? {
        let command = ExportCommand(configuration: try XCUALR.parseExportConfiguration(["bundle.xcresult", "-o", "allure"]))
        let test = ExportedTest(name: "test()", identifier: "Suite/test()", identifierURL: nil,
                                status: status, suite: "Suite", runDestination: nil, start: nil,
                                failureMessages: messages)
        return command.buildStatusDetails(for: test, testDetails: details, failureTrace: trace)
    }

    func testMergedFailuresWithoutSourceReferences() throws {
        let messages = ["failed - first", "failed - repeated", "failed - repeated", "failed - fourth"]
        let details: [String: Any] = ["testRuns": [["nodeType": "Device", "children": [
            ["nodeType": "Repetition", "children": messages.map {
                ["nodeType": "Test Case Run", "result": "Failed", "name": $0]
            }]
        ]]]]
        let result = try XCTUnwrap(statusDetails(details: details))
        XCTAssertEqual(result.message, messages.joined(separator: "\n"))
        XCTAssertNil(result.trace)
        XCTAssertEqual(try statusDetails(messages: [messages[0]], details: details)?.message, result.message)
        XCTAssertNil(try statusDetails(details: details, status: "Passed"))
    }

    func testSingleDeviceNormalizationAndTraceArePreserved() throws {
        let result = try XCTUnwrap(statusDetails(messages: ["Test.swift:42: assertion failed", "second"], trace: "trace"))
        XCTAssertEqual(result.message, "assertion failed\nsecond")
        XCTAssertEqual(result.trace, "trace")
        XCTAssertNil(try statusDetails())
    }
}
