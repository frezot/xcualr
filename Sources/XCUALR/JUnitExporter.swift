import Foundation

struct JUnitExporter {
    func write(tests: [JUnitCase], suiteName: String, to url: URL) throws {
        let xml = render(tests: tests, suiteName: suiteName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: url, options: .atomic)
    }

    func render(tests: [JUnitCase], suiteName: String) -> String {
        let failures = tests.filter { $0.status == .failed }.count
        let skipped = tests.filter { $0.status == .skipped }.count
        let duration = suiteDuration(tests)
        let counts = "tests=\"\(tests.count)\" failures=\"\(failures)\" errors=\"0\" "
            + "skipped=\"\(skipped)\" time=\"\(time(duration))\""
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<testsuites \(counts)>",
            "  <testsuite name=\"\(attribute(suiteName))\" \(counts)>"
        ]
        for test in tests {
            let opening = "    <testcase classname=\"\(attribute(test.className))\" name=\"\(attribute(test.name))\" time=\"\(time(test.roundedDuration))\""
            switch test.status {
            case .failed:
                let messages = test.failureMessages.compactMap(normalizedFailureText)
                let parts = messages + [test.trace.flatMap(normalizedFailureText)].compactMap { $0 }
                let body = parts.isEmpty ? "Test failed" : parts.joined(separator: "\n\n---\n\n")
                let summary = messages.count > 1
                    ? "Test failed with \(messages.count) errors"
                    : (messages.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: .newlines).first ?? "Test failed")
                let cdata = body.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
                lines.append(opening + ">")
                lines.append("      <failure message=\"\(attribute(summary))\"><![CDATA[\(cdata)]]></failure>")
                lines.append("    </testcase>")
            case .skipped:
                lines.append(opening + "><skipped/></testcase>")
            case .passed:
                lines.append(opening + "/>")
            }
        }
        lines += ["  </testsuite>", "</testsuites>"]
        return lines.joined(separator: "\n") + "\n"
    }

    private func suiteDuration(_ tests: [JUnitCase]) -> Double {
        // An incomplete interval cannot describe the full run; retain the legacy sum.
        let intervals = tests.compactMap { test -> (start: Int64, stop: Int64)? in
            guard let start = test.start, let stop = test.stop, stop >= start else { return nil }
            return (start, stop)
        }
        guard intervals.count == tests.count,
              let start = intervals.map(\.start).min(),
              let stop = intervals.map(\.stop).max() else {
            return tests.reduce(0) { $0 + $1.roundedDuration }
        }
        return (Double(stop) - Double(start)) / 1000
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private func normalizedFailureText(_ text: String) -> String? {
        let cleaned = validXML(text)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return cleaned
            .replacingOccurrences(of: "->", with: "→")
            .replacingOccurrences(of: "\"", with: "“")
            .replacingOccurrences(of: "'", with: "‘")
    }

    private func attribute(_ text: String) -> String {
        validXML(text).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    // XML 1.0 cannot represent other control characters, even inside CDATA.
    private func validXML(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            let value = $0.value
            return value == 9 || value == 10 || value == 13
                || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value)
        }))
    }
}
