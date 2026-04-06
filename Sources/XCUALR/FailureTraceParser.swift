import Foundation

struct FailureTraceParser {
    func trace(from testDetails: [String: Any]?) -> String? {
        guard let testRuns = testDetails?["testRuns"] as? [[String: Any]] else {
            return nil
        }
        var lines: [String] = []
        for testRun in testRuns {
            collectTraceLines(from: testRun, into: &lines)
        }
        if lines.isEmpty {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private func collectTraceLines(from node: [String: Any], into lines: inout [String]) {
        if let nodeType = node["nodeType"] as? String,
           nodeType == "Source Code Reference",
           let name = node["name"] as? String,
           !name.isEmpty {
            lines.append(name)
        }
        let children = node["children"] as? [[String: Any]] ?? []
        for child in children {
            collectTraceLines(from: child, into: &lines)
        }
    }
}
