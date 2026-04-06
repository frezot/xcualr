import Foundation

struct SummaryParser {
    func collectTests(from testsTree: [String: Any], summary: [String: Any]) -> [ExportedTest] {
        guard let testNodes = testsTree["testNodes"] as? [[String: Any]] else {
            return []
        }

        let start = summary["startTime"] as? String
        let runDestination = extractRunDestination(from: summary)

        var exportedTests: [ExportedTest] = []
        for node in testNodes {
            exportedTests.append(contentsOf: collectTestCases(
                from: node,
                currentSuite: nil,
                runDestination: runDestination,
                start: start
            ))
        }
        return exportedTests
    }

    private func collectTestCases(from node: [String: Any],
                                  currentSuite: String?,
                                  runDestination: String?,
                                  start: String?) -> [ExportedTest] {
        var exported: [ExportedTest] = []
        let nodeType = node["nodeType"] as? String
        let suite = nodeType == "Test Suite" ? (node["name"] as? String ?? currentSuite) : currentSuite

        if nodeType == "Test Case",
           let exportedTest = makeExportedTest(from: node, suite: suite ?? "Default", runDestination: runDestination, start: start) {
            exported.append(exportedTest)
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                exported.append(contentsOf: collectTestCases(
                    from: child,
                    currentSuite: suite,
                    runDestination: runDestination,
                    start: start
                ))
            }
        }

        return exported
    }

    private func makeExportedTest(from node: [String: Any],
                                  suite: String,
                                  runDestination: String?,
                                  start: String?) -> ExportedTest? {
        guard let name = node["name"] as? String else {
            return nil
        }

        let identifier = (node["nodeIdentifier"] as? String) ?? name
        let identifierURL = node["nodeIdentifierURL"] as? String
        let status = node["result"] as? String
        let failureMessages = extractFailureMessages(from: node)

        return ExportedTest(
            name: name,
            identifier: identifier,
            identifierURL: identifierURL,
            status: status,
            suite: suite,
            runDestination: runDestination,
            start: start,
            failureMessages: failureMessages
        )
    }

    private func extractRunDestination(from summary: [String: Any]) -> String? {
        guard let devicesAndConfigurations = summary["devicesAndConfigurations"] as? [[String: Any]],
              let firstEntry = devicesAndConfigurations.first else {
            return nil
        }
        if let device = firstEntry["device"] as? [String: Any],
           let name = (device["name"] as? String) ?? (device["deviceName"] as? String) {
            return name
        }
        if let configuration = firstEntry["configuration"] as? [String: Any],
           let name = (configuration["name"] as? String) ?? (configuration["configurationName"] as? String) {
            return name
        }
        if let testPlanConfiguration = firstEntry["testPlanConfiguration"] as? [String: Any],
           let name = (testPlanConfiguration["name"] as? String) ?? (testPlanConfiguration["configurationName"] as? String) {
            return name
        }
        return nil
    }

    private func extractFailureMessages(from node: [String: Any]) -> [String] {
        guard let children = node["children"] as? [[String: Any]] else {
            return []
        }
        return children.compactMap { child in
            guard let nodeType = child["nodeType"] as? String,
                  nodeType == "Failure Message" else {
                return nil
            }
            return child["name"] as? String
        }
    }
}
