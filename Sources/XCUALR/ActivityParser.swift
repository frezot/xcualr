import Foundation

struct ActivityParser {
    var defaultFailureTrace: String?

    func parseActivity(_ activity: [String: Any],
                       resolver: inout AttachmentResolver,
                       timingResolver: inout ActivityTimingResolver) -> AllureStep? {
        guard let title = activity["title"] as? String else {
            return nil
        }
        if isDeferredFailureActivity(activity) {
            return nil
        }
        if isTraceOnlyLeaf(activity) {
            return nil
        }
        if title.hasPrefix("Start Test at") || shouldSkipTitle(title) {
            let fallbackStart = milliseconds(from: activity["startTime"])
            let matchedNode = timingResolver.resolveNode(for: title, fallbackStart: fallbackStart)
            var childTimingResolver = matchedNode.map { ActivityTimingResolver(siblings: $0.children) } ?? timingResolver
            let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
            let childSteps = childActivities.compactMap { parseActivity($0, resolver: &resolver, timingResolver: &childTimingResolver) }
            let attachments = resolveAttachments(from: activity, resolver: &resolver)
            return (childSteps.isEmpty && attachments.isEmpty)
                ? nil
                : makeContainerStep(
                    from: activity,
                    fallbackName: title,
                    attachments: attachments,
                    steps: childSteps,
                    resolvedStop: matchedNode?.stop
                )
        }

        let fallbackStart = milliseconds(from: activity["startTime"])
        let matchedNode = timingResolver.resolveNode(for: title, fallbackStart: fallbackStart)
        let resolvedStart = matchedNode?.start ?? fallbackStart
        let resolvedStop = matchedNode?.stop
        var childTimingResolver = ActivityTimingResolver(siblings: matchedNode?.children ?? [])

        let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
        var childSteps: [AllureStep] = []
        var deferredFailures: [AllureStep] = []
        for childActivity in childActivities {
            if shouldSkipAttachmentEchoChild(childActivity, parentTitle: title) {
                continue
            }
            if let deferredFailure = makeDeferredFailureStep(from: childActivity, resolver: &resolver, timingResolver: &childTimingResolver) {
                deferredFailures.append(deferredFailure)
                continue
            }
            if let step = parseActivity(childActivity, resolver: &resolver, timingResolver: &childTimingResolver) {
                childSteps.append(step)
            }
        }
        childSteps.append(contentsOf: deferredFailures)
        let duplicateDescendantAttachments = descendantAttachmentKeys(in: childActivities)
        let rawAttachments = activity["attachments"] as? [[String: Any]] ?? []
        let attachments = resolveAttachments(
            from: activity,
            resolver: &resolver,
            excluding: duplicateDescendantAttachments
        )
        if childSteps.isEmpty && attachments.isEmpty && (!rawAttachments.isEmpty || !childActivities.isEmpty) {
            return nil
        }
        let isFailed = (activity["isAssociatedWithFailure"] as? Bool) == true
            || deferredFailures.contains(where: { $0.status == "failed" })
        let fallbackStop = computeStop(start: resolvedStart ?? fallbackStart, childSteps: childSteps)
        let start = resolvedStart ?? fallbackStart
        let stop = mergedStop(primary: resolvedStop, fallback: fallbackStop)
        let status = isFailed ? "failed" : "passed"
        let details = deferredFailures.first?.statusDetails ?? (isFailed ? AllureStatusDetails(
            known: false,
            muted: false,
            flaky: false,
            message: title,
            trace: nil
        ) : nil)

        return AllureStep(
            name: title,
            status: status,
            start: start,
            stop: stop,
            attachments: attachments,
            steps: childSteps,
            statusDetails: details
        )
    }

    private func makeContainerStep(from activity: [String: Any],
                                   fallbackName: String,
                                   attachments: [AllureAttachment],
                                   steps: [AllureStep],
                                   resolvedStop: Int64? = nil) -> AllureStep {
        let start = milliseconds(from: activity["startTime"]) ?? steps.compactMap(\.start).min()
        let childStop = computeStop(start: start, childSteps: steps)
        let attachmentStop = attachmentStopTimestamp(from: activity)
        let fallbackStop = mergedStop(primary: childStop, fallback: attachmentStop)
        let stop = mergedStop(primary: resolvedStop, fallback: fallbackStop)
        return AllureStep(
            name: fallbackName,
            status: steps.contains(where: { $0.status == "failed" }) ? "failed" : "passed",
            start: start,
            stop: stop,
            attachments: attachments,
            steps: steps,
            statusDetails: nil
        )
    }

    private func computeStop(start: Int64?, childSteps: [AllureStep]) -> Int64? {
        if let childStop = childSteps.compactMap(\.stop).max() {
            return childStop
        }
        return start
    }

    private func mergedStop(primary: Int64?, fallback: Int64?) -> Int64? {
        switch (primary, fallback) {
        case let (.some(primary), .some(fallback)):
            return max(primary, fallback)
        case let (.some(primary), .none):
            return primary
        case let (.none, .some(fallback)):
            return fallback
        case (.none, .none):
            return nil
        }
    }

    private func milliseconds(from value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return Int64(number.doubleValue * 1000)
        case let value as Double:
            return Int64(value * 1000)
        case let value as Int:
            return Int64(Double(value) * 1000)
        default:
            return nil
        }
    }

    private func resolveAttachments(from activity: [String: Any],
                                    resolver: inout AttachmentResolver,
                                    excluding excluded: Set<AttachmentKey> = []) -> [AllureAttachment] {
        let rawAttachments = activity["attachments"] as? [[String: Any]] ?? []
        return rawAttachments.flatMap { attachment in
            if let key = attachmentKey(for: attachment), excluded.contains(key) {
                return [AllureAttachment]()
            }
            return resolver.resolve(name: attachment["name"] as? String, timestamp: attachment["timestamp"])
        }
    }

    private func descendantAttachmentKeys(in activities: [[String: Any]]) -> Set<AttachmentKey> {
        var keys: Set<AttachmentKey> = []
        for activity in activities {
            let attachments = activity["attachments"] as? [[String: Any]] ?? []
            for attachment in attachments {
                if let key = attachmentKey(for: attachment) {
                    keys.insert(key)
                }
            }
            let children = activity["childActivities"] as? [[String: Any]] ?? []
            keys.formUnion(descendantAttachmentKeys(in: children))
        }
        return keys
    }

    private func attachmentKey(for attachment: [String: Any]) -> AttachmentKey? {
        guard let name = attachment["name"] as? String,
              let timestampMillis = AttachmentResolver.timestampMillis(from: attachment["timestamp"]) else {
            return nil
        }
        return AttachmentKey(name: name, timestampMillis: timestampMillis)
    }

    private func attachmentStopTimestamp(from activity: [String: Any]) -> Int64? {
        let rawAttachments = activity["attachments"] as? [[String: Any]] ?? []
        return rawAttachments.compactMap { AttachmentResolver.timestampMillis(from: $0["timestamp"]) }.max()
    }

    fileprivate func shouldSkipTitle(_ title: String) -> Bool {
        Self.shouldSkipTitleStatic(title)
    }

    fileprivate static func shouldSkipTitleStatic(_ title: String) -> Bool {
        title == "Collecting debug information to assist test failure triage"
            || shouldFlattenDBTitleStatic(title)
    }

    static func shouldFlattenDBTitleStatic(_ title: String) -> Bool {
        title.hasPrefix("kXCTAttachmentLegacy")
            || title.hasPrefix("Debug description for ")
            || title.hasPrefix("App UI hierarchy for ")
    }

    private func isTraceOnlyLeaf(_ activity: [String: Any]) -> Bool {
        if activity["startTime"] != nil {
            return false
        }
        let hasAttachments = !(activity["attachments"] as? [[String: Any]] ?? []).isEmpty
        let hasChildren = !(activity["childActivities"] as? [[String: Any]] ?? []).isEmpty
        return !hasAttachments && !hasChildren
    }

    private func shouldSkipAttachmentEchoChild(_ activity: [String: Any], parentTitle: String) -> Bool {
        guard parentTitle.hasPrefix("Added attachment named '") else {
            return false
        }
        let hasAttachments = !(activity["attachments"] as? [[String: Any]] ?? []).isEmpty
        let hasChildren = !(activity["childActivities"] as? [[String: Any]] ?? []).isEmpty
        return !hasAttachments && !hasChildren
    }

    private func isDeferredFailureActivity(_ activity: [String: Any]) -> Bool {
        guard (activity["isAssociatedWithFailure"] as? Bool) == true else {
            return false
        }
        let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
        return !childActivities.isEmpty && childActivities.allSatisfy { child in
            shouldSkipTitle(child["title"] as? String ?? "") || isTraceOnlyLeaf(child)
        }
    }

    private func makeDeferredFailureStep(from activity: [String: Any],
                                         resolver: inout AttachmentResolver,
                                         timingResolver: inout ActivityTimingResolver) -> AllureStep? {
        guard isDeferredFailureActivity(activity),
              let title = activity["title"] as? String else {
            return nil
        }
        let attachments = resolveAttachments(from: activity, resolver: &resolver)
        let fallbackStart = milliseconds(from: activity["startTime"])
        let matchedNode = timingResolver.resolveNode(for: title, fallbackStart: fallbackStart)
        let start = matchedNode?.start ?? fallbackStart
        let stop = matchedNode?.stop ?? fallbackStart
        let details = AllureStatusDetails(
            known: false,
            muted: false,
            flaky: false,
            message: title,
            trace: defaultFailureTrace ?? deferredFailureTrace(from: activity)
        )
        return AllureStep(
            name: title,
            status: "failed",
            start: start,
            stop: stop ?? start,
            attachments: attachments,
            steps: [],
            statusDetails: details
        )
    }

    private func deferredFailureTrace(from activity: [String: Any]) -> String? {
        let childActivities = activity["childActivities"] as? [[String: Any]] ?? []
        let lines = childActivities.compactMap { child -> String? in
            let title = child["title"] as? String ?? ""
            guard !title.isEmpty, !shouldSkipTitle(title), isTraceOnlyLeaf(child) else {
                return nil
            }
            return title
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
