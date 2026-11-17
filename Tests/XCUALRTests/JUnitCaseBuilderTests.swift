import XCTest
@testable import XCUALR

final class JUnitCaseBuilderTests: XCTestCase {
    private func test(status: String? = "Failed", messages: [String] = []) -> ExportedTest {
        ExportedTest(name: "test()", identifier: "Suite/test()", identifierURL: nil,
                     status: status, suite: "Suite", runDestination: nil, start: nil,
                     failureMessages: messages)
    }

    func testStatusMappingIncludingExpectedFailure() throws {
        for (raw, expected) in [("Passed", TestStatus.passed), ("Expected Failure", .passed),
                                ("Failed", .failed), ("Skipped", .skipped)] {
            let result = try JUnitCaseBuilder().build(
                for: test(status: raw), testDetails: ["durationInSeconds": 263.829], issueTrace: nil
            )
            XCTAssertEqual(result.status, expected)
            XCTAssertEqual(result.duration, 263.829)
            XCTAssertEqual(result.name, "test()")
            XCTAssertEqual(result.className, "Suite")
        }
        for raw: String? in [nil, "Unknown", ""] {
            XCTAssertThrowsError(try JUnitCaseBuilder().build(for: test(status: raw), testDetails: nil, issueTrace: nil))
        }
    }

    func testMergesSummaryAndRepeatedFailuresWithoutDuplicatingSources() throws {
        let details: [String: Any] = ["testRuns": [
            ["nodeType": "Repetition", "children": [
                ["nodeType": "Test Case Run", "result": "Expected Failure", "name": "expected"],
                ["nodeType": "Test Case Run", "result": "Failed", "name": "assertion"],
                ["nodeType": "Test Case Run", "result": "Failed", "name": "assertion"],
                ["nodeType": "Test Case Run", "result": "Failed", "name": "other"]
            ]]
        ]]
        let result = try JUnitCaseBuilder().build(
            for: test(messages: [" ", "assertion", "summary only"]), testDetails: details, issueTrace: nil
        )
        XCTAssertEqual(result.failureMessages, ["assertion", "summary only", "assertion", "other"])
        XCTAssertEqual(result.duration, 0)
    }

    func testNestedFailuresAndTraceFallback() throws {
        let details: [String: Any] = ["testRuns": [
            ["nodeType": "Test Case Run", "result": "Failed", "name": "outer", "children": [
                ["nodeType": "Test Case Run", "result": "Failed", "name": "inner"],
                ["nodeType": "Source Code Reference", "name": "test.swift:42"]
            ]]
        ]]
        let builder = JUnitCaseBuilder()
        let result = try builder.build(for: test(messages: ["\n"]), testDetails: details, issueTrace: nil)
        XCTAssertEqual(result.failureMessages, ["outer", "inner"])
        XCTAssertEqual(result.trace, "test.swift:42")
        XCTAssertEqual(try builder.build(for: test(), testDetails: details, issueTrace: "catalog").trace, "catalog")
        let passed = try builder.build(for: test(status: "Expected Failure"), testDetails: details, issueTrace: "catalog")
        XCTAssertTrue(passed.failureMessages.isEmpty)
        XCTAssertNil(passed.trace)
    }
}
