import Foundation

struct ActivityCatalog {
    private let rootsByIdentifier: [String: [DBActivity]]

    static func load(fromXCResultPath xcresultPath: String) throws -> ActivityCatalog {
        let databasePath = URL(fileURLWithPath: xcresultPath).appendingPathComponent("database.sqlite3").path
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return ActivityCatalog(rootsByIdentifier: [:])
        }

        let identifierRows = try runCommand(
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                "-noheader",
                "-separator", "\t",
                databasePath,
                "select distinct tc.identifier, tcr.rowid " +
                    "from TestCases tc join TestCaseRuns tcr on tcr.testCase_fk = tc.rowid;"
            ]
        )

        let lines = String(decoding: identifierRows, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)

        var rootsByIdentifier: [String: [DBActivity]] = [:]
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let testCaseRunId = Int(parts[1]) else {
                continue
            }
            let identifier = parts[0]
            let query = """
            with recursive activity_tree(rowid, parent_fk, orderInParent, title, startTime, finishTime, failureIDs) as (
                select rowid, parent_fk, orderInParent, title, startTime, finishTime, coalesce(failureIDs, '')
                from Activities
                where testCaseRun_fk = \(testCaseRunId)
                union all
                select a.rowid, a.parent_fk, a.orderInParent, a.title, a.startTime, a.finishTime, coalesce(a.failureIDs, '')
                from Activities a
                join activity_tree t on a.parent_fk = t.rowid
            )
            select rowid, coalesce(parent_fk, 0), orderInParent, json_quote(title), startTime, finishTime, coalesce(failureIDs, '')
            from activity_tree
            order by coalesce(parent_fk, 0), orderInParent;
            """
            let activityRows = try runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    "-noheader",
                    "-separator", "\t",
                    databasePath,
                    query
                ]
            )
            let dbActivities = parseActivities(from: String(decoding: activityRows, as: UTF8.self))
            let normalizedRoots = normalizeActivities(
                dbActivities.values.sorted { $0.orderInParent < $1.orderInParent },
                parentTitle: nil
            )
            rootsByIdentifier[identifier] = normalizedRoots
        }

        return ActivityCatalog(rootsByIdentifier: rootsByIdentifier)
    }

    func resolver(for test: ExportedTest) -> ActivityTimingResolver {
        ActivityTimingResolver(siblings: rootsByIdentifier[test.identifier] ?? [])
    }

    private static func parseActivities(from output: String) -> [Int: DBActivity] {
        var baseNodes: [Int: DBActivity] = [:]
        var childMap: [Int: [Int]] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7,
                  let rowId = Int(parts[0]),
                  let parentId = Int(parts[1]),
                  let orderInParent = Int(parts[2]) else {
                continue
            }
            let node = DBActivity(
                id: rowId,
                parentId: parentId == 0 ? nil : parentId,
                orderInParent: orderInParent,
                title: decodeSQLiteJSONString(parts[3]) ?? parts[3],
                start: parseAppleReferenceMilliseconds(parts[4]),
                stop: parseAppleReferenceMilliseconds(parts[5]),
                isFailure: !parts[6].isEmpty
            )
            baseNodes[rowId] = node
            childMap[parentId, default: []].append(rowId)
        }

        func buildActivity(_ id: Int) -> DBActivity? {
            guard let node = baseNodes[id] else {
                return nil
            }
            let sortedChildren = (childMap[id] ?? []).sorted {
                (baseNodes[$0]?.orderInParent ?? 0) < (baseNodes[$1]?.orderInParent ?? 0)
            }
            return node.withChildren(sortedChildren.compactMap(buildActivity))
        }

        let rootIds = (childMap[0] ?? []).sorted {
            (baseNodes[$0]?.orderInParent ?? 0) < (baseNodes[$1]?.orderInParent ?? 0)
        }
        var roots: [Int: DBActivity] = [:]
        for rootId in rootIds {
            if let root = buildActivity(rootId) {
                roots[rootId] = root
            }
        }
        return roots
    }

    private static func shouldDeferDBChild(_ child: DBActivity) -> Bool {
        shouldFlattenDBTitleStatic(child.title) || isTraceOnlyLeafStatic(child)
    }

    private static func shouldSkipAttachmentEchoChildStatic(_ activity: DBActivity, parentTitle: String) -> Bool {
        guard parentTitle.hasPrefix("Added attachment named '") else {
            return false
        }
        return activity.children.isEmpty
    }

    private static func shouldFlattenDBTitleStatic(_ title: String) -> Bool {
        ActivityParser.shouldFlattenDBTitleStatic(title)
    }

    private static func isTraceOnlyLeafStatic(_ activity: DBActivity) -> Bool {
        activity.start == nil && activity.children.isEmpty
    }

    private static func decodeSQLiteJSONString(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func normalizeActivities(_ activities: [DBActivity], parentTitle: String?) -> [DBActivity] {
        var normalized: [DBActivity] = []
        for activity in activities.sorted(by: { $0.orderInParent < $1.orderInParent }) {
            if let parentTitle, shouldSkipAttachmentEchoChildStatic(activity, parentTitle: parentTitle) {
                continue
            }
            if activity.title.hasPrefix("Start Test at") || shouldFlattenDBTitleStatic(activity.title) {
                normalized.append(contentsOf: normalizeActivities(activity.children, parentTitle: activity.title))
                continue
            }
            if isTraceOnlyLeafStatic(activity) {
                continue
            }

            if activity.isFailure, activity.children.allSatisfy({ shouldDeferDBChild($0) }) {
                normalized.append(activity.withChildren([]))
                continue
            }

            normalized.append(
                activity.withChildren(
                    normalizeActivities(activity.children, parentTitle: activity.title)
                )
            )
        }
        return normalized
    }
}

struct ActivityTimingResolver {
    private let siblings: [DBActivity]
    private var usedIndices: Set<Int> = []
    private static let startToleranceMs: Int64 = 250

    init(siblings: [DBActivity]) {
        self.siblings = siblings
    }

    mutating func resolveNode(for title: String, fallbackStart: Int64?) -> DBActivity? {
        guard !siblings.isEmpty else {
            return nil
        }
        let sameTitleIndices = siblings.indices.filter { index in
            !usedIndices.contains(index) && siblings[index].title == title
        }
        guard !sameTitleIndices.isEmpty else {
            return nil
        }

        let matchedIndex: Int
        if let fallbackStart {
            let withinTolerance = sameTitleIndices
                .filter { index in
                    guard let candidateStart = siblings[index].start else {
                        return false
                    }
                    return abs(candidateStart - fallbackStart) <= Self.startToleranceMs
                }
            let candidateIndices = withinTolerance.isEmpty ? sameTitleIndices : withinTolerance
            matchedIndex = candidateIndices.min { lhs, rhs in
                let lhsDelta = abs((siblings[lhs].start ?? fallbackStart) - fallbackStart)
                let rhsDelta = abs((siblings[rhs].start ?? fallbackStart) - fallbackStart)
                if lhsDelta == rhsDelta {
                    return lhs < rhs
                }
                return lhsDelta < rhsDelta
            } ?? candidateIndices[0]
        } else {
            matchedIndex = sameTitleIndices[0]
        }

        usedIndices.insert(matchedIndex)
        return siblings[matchedIndex]
    }
}

struct DBActivity {
    let id: Int
    let parentId: Int?
    let orderInParent: Int
    let title: String
    let start: Int64?
    let stop: Int64?
    let isFailure: Bool
    var children: [DBActivity] = []

    func withChildren(_ children: [DBActivity]) -> DBActivity {
        var copy = self
        copy.children = children
        return copy
    }
}
