import XCTest
@testable import XCUALR

final class ExportConfigurationTests: XCTestCase {
    func testJUnitIsAdditiveAndOptional() throws {
        let arguments = ["bundle.xcresult", "-o", "allure"]
        XCTAssertNil(try XCUALR.parseExportConfiguration(arguments).junitPath)
        let configuration = try XCUALR.parseExportConfiguration(arguments + ["--junit", "reports/junit.xml", "-f"])
        XCTAssertEqual(configuration.junitPath, "reports/junit.xml")
        XCTAssertTrue(configuration.force)
        XCTAssertThrowsError(try XCUALR.parseExportConfiguration(["bundle.xcresult", "--junit", "junit.xml"]))
    }

    func testMissingPathDoesNotConsumeAnotherOption() {
        for option in ["-o", "--output", "--junit"] {
            for missing in [[], [""], ["--force"]] {
                XCTAssertThrowsError(try XCUALR.parseExportConfiguration(["bundle.xcresult", option] + missing))
            }
        }
    }
}
