import Foundation
import XCTest
@testable import XCUALR

final class JUnitExporterTests: XCTestCase {
    func testCountsDurationsAndFailureRoundTrip() throws {
        let cases = [
            JUnitCase(name: "test<&\"\n", className: "Suite&", duration: 263.8294, status: .failed,
                      failureMessages: ["XCTAssert \"a\" -> 'b' & <x>]]>\u{1}", "second\nline"],
                      trace: "trace\nfile.swift:42"),
            JUnitCase(name: "expected failure", className: "Suite", duration: 0.1234,
                      status: .passed, failureMessages: ["expected"], trace: nil),
            JUnitCase(name: "skipped", className: "Suite", duration: 0,
                      status: .skipped, failureMessages: [], trace: nil)
        ]
        let xml = JUnitExporter().render(tests: cases, suiteName: "Bundle<&")
        let document = try XMLDocument(xmlString: xml)
        let root = try XCTUnwrap(document.rootElement())
        for element in [root, try XCTUnwrap(root.elements(forName: "testsuite").first)] {
            XCTAssertEqual(element.attribute(forName: "tests")?.stringValue, "3")
            XCTAssertEqual(element.attribute(forName: "failures")?.stringValue, "1")
            XCTAssertEqual(element.attribute(forName: "skipped")?.stringValue, "1")
            XCTAssertEqual(element.attribute(forName: "errors")?.stringValue, "0")
            XCTAssertEqual(element.attribute(forName: "time")?.stringValue, "263.952")
        }
        let tests = try XCTUnwrap(document.nodes(forXPath: "//testcase") as? [XMLElement])
        XCTAssertEqual(tests.count, 3)
        XCTAssertEqual(tests[0].attribute(forName: "name")?.stringValue, cases[0].name)
        XCTAssertEqual(tests[0].attribute(forName: "time")?.stringValue, "263.829")
        let failure = try XCTUnwrap(tests[0].elements(forName: "failure").first)
        XCTAssertEqual(failure.attribute(forName: "message")?.stringValue, "Test failed with 2 errors")
        XCTAssertEqual(failure.stringValue, "XCTAssert “a“ → ‘b‘ & <x>]]>\n\n---\n\nsecond\nline\n\n---\n\ntrace\nfile.swift:42")
        XCTAssertTrue(tests[1].elements(forName: "failure").isEmpty)
        XCTAssertEqual(tests[2].elements(forName: "skipped").count, 1)
        XCTAssertEqual(xml, JUnitExporter().render(tests: cases, suiteName: "Bundle<&"))
    }

    func testEmptyReportAndSingleFailure() throws {
        let empty = try XMLDocument(xmlString: JUnitExporter().render(tests: [], suiteName: "empty"))
        XCTAssertEqual(empty.rootElement()?.attribute(forName: "tests")?.stringValue, "0")
        for messages in [[], ["first line\nsecond line"]] {
            let test = JUnitCase(name: "test", className: "Suite", duration: .nan,
                                 status: .failed, failureMessages: messages, trace: nil)
            let document = try XMLDocument(xmlString: JUnitExporter().render(tests: [test], suiteName: "suite"))
            let failure = try XCTUnwrap(document.nodes(forXPath: "//failure").first as? XMLElement)
            XCTAssertEqual(failure.attribute(forName: "message")?.stringValue, messages.isEmpty ? "Test failed" : "first line")
            XCTAssertFalse(try XCTUnwrap(failure.stringValue).isEmpty)
            XCTAssertEqual(try (document.nodes(forXPath: "//testcase").first as? XMLElement)?.attribute(forName: "time")?.stringValue, "0.000")
        }
    }
    func testBlankMessagesAndIllegalCharactersCannotProduceEmptyFailure() throws {
        let test = JUnitCase(name: "test", className: "Suite", duration: 0, status: .failed,
                             failureMessages: ["", " \n", "\u{1}", "\nassertion\nsecond line"],
                             trace: "\u{2}")
        let document = try XMLDocument(xmlString: JUnitExporter().render(tests: [test], suiteName: "suite"))
        let failure = try XCTUnwrap(document.nodes(forXPath: "//failure").first as? XMLElement)
        XCTAssertEqual(failure.attribute(forName: "message")?.stringValue, "assertion")
        XCTAssertEqual(failure.stringValue, "\nassertion\nsecond line")
    }

    func testInvalidDurationsAndMillisecondTotals() throws {
        let durations: [Double] = [-1, .nan, .infinity, .greatestFiniteMagnitude, 0.0006, 0.0006]
        let cases = durations.enumerated().map {
            JUnitCase(name: "test\($0.offset)", className: "Suite", duration: $0.element,
                      status: .passed, failureMessages: [], trace: nil)
        }
        let document = try XMLDocument(xmlString: JUnitExporter().render(tests: cases, suiteName: "suite"))
        XCTAssertEqual(document.rootElement()?.attribute(forName: "time")?.stringValue, "0.002")
        let times = try document.nodes(forXPath: "//testcase/@time").compactMap(\.stringValue)
        XCTAssertEqual(times, ["0.000", "0.000", "0.000", "0.000", "0.001", "0.001"])
    }

}
