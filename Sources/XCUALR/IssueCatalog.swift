import Foundation

struct IssueCatalog {
    private let tracesByIdentifier: [String: String]

    static func load(fromXCResultPath xcresultPath: String) throws -> IssueCatalog {
        let databasePath = URL(fileURLWithPath: xcresultPath).appendingPathComponent("database.sqlite3").path
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return IssueCatalog(tracesByIdentifier: [:])
        }

        let identifiersOutput = try runCommand(
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                "-noheader",
                "-separator", "\t",
                databasePath,
                "select distinct tc.identifier " +
                    "from TestCases tc " +
                    "join TestCaseRuns tcr on tcr.testCase_fk = tc.rowid " +
                    "join TestIssues ti on ti.testCaseRun_fk = tcr.rowid " +
                    "where ti.sourceCodeContext_fk is not null;"
            ]
        )
        let identifiers = String(decoding: identifiersOutput, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var tracesByIdentifier: [String: String] = [:]
        for identifier in identifiers {
            let escapedIdentifier = identifier.replacingOccurrences(of: "'", with: "''")
            let query = """
            select scl.filePath || ':' || scl.lineNumber
            from TestCases tc
            join TestCaseRuns tcr on tcr.testCase_fk = tc.rowid
            join TestIssues ti on ti.testCaseRun_fk = tcr.rowid
            join SourceCodeFrames scf on scf.context_fk = ti.sourceCodeContext_fk
            join SourceCodeSymbolInfos scsi on scsi.rowid = scf.symbolInfo_fk
            join SourceCodeLocations scl on scl.rowid = scsi.location_fk
            where tc.identifier = '\(escapedIdentifier)'
            order by scf.orderInContainer;
            """
            let traceOutput = try runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    "-noheader",
                    databasePath,
                    query
                ]
            )
            let trace = String(decoding: traceOutput, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
                .joined(separator: "\n")
            if !trace.isEmpty {
                tracesByIdentifier[identifier] = trace
            }
        }

        return IssueCatalog(tracesByIdentifier: tracesByIdentifier)
    }

    func trace(for identifier: String) -> String? {
        tracesByIdentifier[identifier]
    }
}
