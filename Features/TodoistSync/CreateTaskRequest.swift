import Foundation

/// What the BigHead agent sends to create one task. Names, not ids: `area` and `project` are the
/// Todoist-side names from the pair BigHead keeps, and resolving them is `TaskCreator`'s job.
public struct CreateTaskRequest: Equatable, Sendable {
    public let title: String
    public let description: String?
    /// A calendar date, `YYYY-MM-DD`, already checked to exist.
    public let due: String?
    public let area: String
    /// Absent for a task from an area's «Общее» section: it goes into the area project itself.
    public let project: String?

    public init(title: String, description: String?, due: String?, area: String, project: String?) {
        self.title = title
        self.description = description
        self.due = due
        self.area = area
        self.project = project
    }

    public static func decode(_ data: Data) throws -> CreateTaskRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else {
            throw RequestError.malformedJSON
        }
        let due = try optional(fields["due"], name: "due")
        if let due, !isCalendarDate(due) {
            throw RequestError.invalidDue(due)
        }
        return CreateTaskRequest(
            title: try required(fields["title"], name: "title"),
            description: try optional(fields["description"], name: "description"),
            due: due,
            area: try required(fields["area"], name: "area"),
            project: try optional(fields["project"], name: "project")
        )
    }

    private static func optional(_ value: Any?, name: String) throws -> String? {
        // Absent key returns nil
        guard let value = value else { return nil }

        // JSON null (NSNull) becomes nil
        if value is NSNull { return nil }

        // Must be a string at this point
        guard let text = value as? String else {
            throw RequestError.wrongType(name)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func required(_ value: Any?, name: String) throws -> String {
        // Absent key
        guard let value = value else { throw RequestError.missingField(name) }

        // Must be a string
        guard let text = value as? String else { throw RequestError.missingField(name) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RequestError.missingField(name) }

        return trimmed
    }

    /// Shape first, then a round trip through a strict formatter: `2026-02-30` has the right
    /// shape and no such day.
    private static func isCalendarDate(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }
}

public enum RequestError: Error, Equatable, LocalizedError {
    case malformedJSON
    case missingField(String)
    case invalidDue(String)
    case wrongType(String)

    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "Request body is not a JSON object"
        case .missingField(let name):
            return "Required field \"\(name)\" is missing or empty"
        case .invalidDue(let value):
            return "Field \"due\" must be a real date as YYYY-MM-DD, got \"\(value)\""
        case .wrongType(let name):
            return "Field \"\(name)\" must be a string"
        }
    }
}
