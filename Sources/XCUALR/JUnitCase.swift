import Foundation

struct JUnitCase {
    let name: String
    let className: String
    let duration: Double
    let status: TestStatus
    let failureMessages: [String]
    let trace: String?

    var roundedDuration: Double {
        let milliseconds = duration * 1000
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        return milliseconds.rounded() / 1000
    }
}

struct JUnitCaseBuilder {
    func build(for test: ExportedTest, testDetails: [String: Any]?, issueTrace: String?) throws -> JUnitCase {
        guard let status = TestStatus(xcresultStatus: test.status) else {
            throw CLIError.invalidJSON(
                "Cannot export JUnit: unsupported status '\(test.status ?? "<missing>")' for \(test.identifier)"
            )
        }
        return JUnitCase(
            name: test.name,
            className: test.suite,
            duration: doubleValue(testDetails?["durationInSeconds"]) ?? 0,
            status: status,
            failureMessages: status == .failed ? FailureMessageCollector.messages(for: test, details: testDetails) : [],
            trace: status == .failed ? (issueTrace ?? FailureTraceParser().trace(from: testDetails)) : nil
        )
    }
}
