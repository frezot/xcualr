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
            failureMessages: status == .failed ? failureMessages(for: test, details: testDetails) : [],
            trace: status == .failed ? (issueTrace ?? FailureTraceParser().trace(from: testDetails)) : nil
        )
    }

    private func failureMessages(for test: ExportedTest, details: [String: Any]?) -> [String] {
        func nonempty(_ messages: [String]) -> [String] {
            messages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        // Merged bundles put failures under repetitions instead of directly under the test.
        func collect(_ node: [String: Any]) -> [String] {
            var messages: [String] = []
            if node["nodeType"] as? String == "Test Case Run",
               node["result"] as? String == "Failed",
               let message = node["name"] as? String {
                messages.append(message)
            }
            for child in node["children"] as? [[String: Any]] ?? [] {
                messages.append(contentsOf: collect(child))
            }
            return messages
        }
        let summaryMessages = nonempty(test.failureMessages)
        let detailMessages = nonempty((details?["testRuns"] as? [[String: Any]] ?? []).flatMap(collect))

        // The two sources describe the same failures. Match occurrences instead of dropping
        // repeated assertions, and retain messages present in only one of the sources.
        var unmatchedDetails = detailMessages
        for message in summaryMessages {
            if let index = unmatchedDetails.firstIndex(of: message) {
                unmatchedDetails.remove(at: index)
            }
        }
        return summaryMessages + unmatchedDetails
    }
}
