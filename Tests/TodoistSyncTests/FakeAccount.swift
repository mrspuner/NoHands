import Foundation
@testable import TodoistSync

/// An in-memory Todoist account shared by the operation and creator tests.
actor FakeAccount: TodoistAPI {
    var projectList: [TodoistProject]
    var archivedList: [TodoistProject] = []
    var tasks: [NewTodoistTask] = []
    /// Task id → project id, for every task the fake knows about.
    var taskProjects: [String: String] = [:]
    var updates: [(id: String, update: TaskUpdate)] = []
    var moves: [(id: String, projectID: String)] = []
    var closed: [String] = []
    var deleted: [String] = []
    var archivedIDs: [String] = []
    var unarchivedIDs: [String] = []
    var projectCalls = 0
    var createTaskError: (any Error)?
    private var counter = 0

    init(_ projects: [TodoistProject] = []) { projectList = projects }

    func setFailTaskCreation() { createTaskError = TodoistError.requestFailed(status: 500, message: "down") }
    func setCreateTaskError(_ error: any Error) { createTaskError = error }
    /// Kept for the slice-1 creator tests.
    func failTaskCreation(with error: any Error) { createTaskError = error }
    func addTask(id: String, projectID: String) { taskProjects[id] = projectID }
    func setArchived(_ projects: [TodoistProject]) { archivedList = projects }

    func projects() async throws -> [TodoistProject] {
        projectCalls += 1
        // A suspension point, so two overlapping requests really do interleave here.
        try await Task.sleep(for: .milliseconds(20))
        return projectList
    }

    func createProject(name: String, parentID: String?) async throws -> TodoistProject {
        counter += 1
        let project = TodoistProject(id: "new\(counter)", name: name, parentID: parentID)
        projectList.append(project)
        return project
    }

    func createTask(_ task: NewTodoistTask) async throws -> String {
        if let createTaskError { throw createTaskError }
        tasks.append(task)
        counter += 1
        let id = "task\(counter)"
        taskProjects[id] = task.projectID
        return id
    }

    func task(id: String) async throws -> TodoistTaskInfo {
        guard let projectID = taskProjects[id] else { throw TodoistError.notFound }
        return TodoistTaskInfo(id: id, projectID: projectID)
    }

    func updateTask(id: String, _ update: TaskUpdate) async throws {
        guard taskProjects[id] != nil else { throw TodoistError.notFound }
        updates.append((id, update))
    }

    func moveTask(id: String, toProject projectID: String) async throws {
        guard taskProjects[id] != nil else { throw TodoistError.notFound }
        taskProjects[id] = projectID
        moves.append((id, projectID))
    }

    func closeTask(id: String) async throws {
        guard taskProjects.removeValue(forKey: id) != nil else { throw TodoistError.notFound }
        closed.append(id)
    }

    func deleteTask(id: String) async throws {
        guard taskProjects.removeValue(forKey: id) != nil else { throw TodoistError.notFound }
        deleted.append(id)
    }

    func archivedProjects() async throws -> [TodoistProject] { archivedList }

    func archiveProject(id: String) async throws {
        guard let index = projectList.firstIndex(where: { $0.id == id }) else { throw TodoistError.notFound }
        archivedList.append(projectList.remove(at: index))
        archivedIDs.append(id)
    }

    func unarchiveProject(id: String) async throws {
        guard let index = archivedList.firstIndex(where: { $0.id == id }) else { throw TodoistError.notFound }
        projectList.append(archivedList.remove(at: index))
        unarchivedIDs.append(id)
    }
}
