import Foundation

enum FailureMessageCollector {
    static func messages(for test: ExportedTest, details: [String: Any]?) -> [String] {
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
