import Foundation

/// A project addressed by its Todoist-side names: the area (a root project) and the project
/// inside it. The same pair BigHead keeps in its schema and project pages.
public struct ProjectRequest: Equatable, Sendable {
    public let area: String
    public let project: String

    public init(area: String, project: String) {
        self.area = area
        self.project = project
    }

    public static func decode(_ data: Data) throws -> ProjectRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else {
            throw RequestError.malformedJSON
        }
        func required(_ name: String) throws -> String {
            guard let text = (fields[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw RequestError.missingField(name)
            }
            return text
        }
        return ProjectRequest(area: try required("area"), project: try required("project"))
    }
}
