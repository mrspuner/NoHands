import Foundation

public struct TaskSnapshot: Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let due: String?
    public let area: String
    /// Nil when the task sits in the area project itself.
    public let project: String?
    public let addedAt: String?
    public let updatedAt: String?
}

public enum InboundEvent: Equatable, Sendable {
    case closed(TaskSnapshot)
    case deleted(TaskSnapshot)
    /// Created or edited; BigHead tells the two apart by whether the id is already on its board.
    case changed(TaskSnapshot)
}

public struct ProjectAdded: Equatable, Sendable {
    public let id: String
    public let area: String
    public let name: String
}

public struct InboundBatch: Equatable, Sendable {
    public let tasks: [InboundEvent]
    public let projects: [ProjectAdded]
    /// The project map after this sync, to be saved.
    public let projectMap: [String: ProjectInfo]
}

/// Turns one sync answer into what BigHead should hear: only work (inside an area), never a
/// declined project, never an echo of NoHands's own change.
public enum InboundEvents {
    /// A journal entry this long before Todoist's `updated_at` still counts as ours: clocks of
    /// this machine and Todoist's servers are not the same clock.
    static let echoWindow: TimeInterval = 5

    public static func build(
        response: SyncResponse,
        previous: [String: ProjectInfo],
        areas: [String],
        ignored: Set<String>,
        journal: [ActionJournal.Entry]
    ) -> InboundBatch {
        // `placing` keeps projects deleted in this sync, so their deleted tasks still resolve to
        // an area; `map` is the pruned result to save.
        var map = previous
        var placing = previous
        for project in response.projects {
            placing[project.id] = ProjectInfo(name: project.name, parentID: project.parentID)
            if project.isDeleted {
                map[project.id] = nil
            } else {
                map[project.id] = ProjectInfo(name: project.name, parentID: project.parentID)
            }
        }
        let formatter = makeFormatter()
        let areaNames = Set(areas.map(normalize))
        let journalTimes = Dictionary(grouping: journal, by: \.todoistID)
            .mapValues { $0.compactMap { date($0.time, formatter) } }

        func placement(_ projectID: String) -> (area: String, project: String?)? {
            var chain: [String] = []
            var current: String? = projectID
            while let id = current, let info = placing[id] {
                if ignored.contains(id) { return nil }
                chain.append(id)
                guard chain.count < 32 else { return nil }  // a cycle in bad data
                current = info.parentID
            }
            guard let rootID = chain.last, let root = placing[rootID], root.parentID == nil,
                  areaNames.contains(normalize(root.name)) else { return nil }
            return (root.name, projectID == rootID ? nil : placing[projectID]?.name)
        }

        func isEcho(_ id: String, updatedAt: String?) -> Bool {
            guard let updatedAt, let changed = date(updatedAt, formatter) else { return false }
            return (journalTimes[id] ?? []).contains { $0 >= changed.addingTimeInterval(-echoWindow) }
        }

        var tasks: [InboundEvent] = []
        for item in response.items {
            guard let place = placement(item.projectID), !isEcho(item.id, updatedAt: item.updatedAt) else { continue }
            let snapshot = TaskSnapshot(
                id: item.id, title: item.content, description: item.description, due: item.dueDate,
                area: place.area, project: place.project, addedAt: item.addedAt, updatedAt: item.updatedAt
            )
            if item.isDeleted {
                tasks.append(.deleted(snapshot))
            } else if item.checked {
                tasks.append(.closed(snapshot))
            } else {
                tasks.append(.changed(snapshot))
            }
        }

        var added: [ProjectAdded] = []
        for project in response.projects where previous[project.id] == nil && !project.isDeleted && !project.isArchived {
            guard let parentID = project.parentID, let parent = placing[parentID], parent.parentID == nil,
                  areaNames.contains(normalize(parent.name)),
                  !ignored.contains(project.id), !ignored.contains(parentID),
                  journalTimes[project.id] == nil else { continue }
            added.append(ProjectAdded(id: project.id, area: parent.name, name: project.name))
        }
        return InboundBatch(tasks: tasks, projects: added, projectMap: map)
    }

    /// One formatter per `build` call, not per journal entry; it never leaves the call.
    static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Todoist writes six fractional digits, the journal none; seconds are all the filter needs.
    static func date(_ text: String, _ formatter: ISO8601DateFormatter) -> Date? {
        guard text.count >= 19 else { return nil }
        return formatter.date(from: String(text.prefix(19)) + "Z")
    }
}
