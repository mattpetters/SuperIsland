import Foundation

@MainActor
final class TaskwarriorProvider {
    static let shared = TaskwarriorProvider()

    fileprivate struct ExportedTask: Decodable {
        let id: Int?
        let uuid: String?
        let status: String?
        let description: String?
        let project: String?
        let priority: String?
        let due: String?
        let end: String?
        let urgency: Double?
        let tags: [String]?
    }

    private let refreshQueue = DispatchQueue(label: "superisland.taskwarrior", qos: .utility)
    private var cachedTasks: [[String: Any]] = []
    private var lastRefreshDate: Date = .distantPast
    private var lastError: String?
    private var isRefreshing = false

    private init() {}

    func snapshot(forceRefresh: Bool = false, query: String = "", includeCompleted: Bool = false) -> [String: Any] {
        if forceRefresh || shouldRefresh {
            refresh()
        }

        let filteredTasks = Self.filteredTasks(
            cachedTasks,
            query: query,
            includeCompleted: includeCompleted
        )

        return [
            "tasks": filteredTasks,
            "isRefreshing": isRefreshing,
            "lastError": lastError as Any,
            "lastRefreshedAtEpochMs": Int(lastRefreshDate.timeIntervalSince1970 * 1000)
        ]
    }

    func completeTask(identifier: String) -> [String: Any] {
        mutateTask(identifier: identifier, arguments: [identifier, "done"])
    }

    func uncompleteTask(identifier: String) -> [String: Any] {
        mutateTask(identifier: identifier, arguments: [identifier, "modify", "status:pending", "end:"])
    }

    func renameTask(identifier: String, description: String) -> [String: Any] {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return mutationPayload(ok: false, error: "Task description cannot be empty.")
        }
        return mutateTask(identifier: identifier, arguments: [identifier, "modify", trimmed])
    }

    func createTask(description: String) -> [String: Any] {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return mutationPayload(ok: false, error: "Task description cannot be empty.")
        }
        return mutateTask(identifier: nil, arguments: ["add", trimmed])
    }

    private var shouldRefresh: Bool {
        Date().timeIntervalSince(lastRefreshDate) > 30 && !isRefreshing
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        refreshQueue.async { [weak self] in
            let result = Self.loadVisibleTasks()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                self.lastRefreshDate = Date()

                switch result {
                case .success(let tasks):
                    self.cachedTasks = tasks
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func mutateTask(identifier: String?, arguments: [String]) -> [String: Any] {
        let normalizedIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if identifier != nil && normalizedIdentifier.isEmpty {
            return mutationPayload(ok: false, error: "No Taskwarrior task is selected.")
        }

        switch Self.runTask(arguments: arguments, timeoutSeconds: 8) {
        case .success:
            let refreshResult = Self.loadVisibleTasks()
            switch refreshResult {
            case .success(let tasks):
                cachedTasks = tasks
                lastError = nil
            case .failure(let error):
                lastError = error.localizedDescription
            }
            lastRefreshDate = Date()
            return mutationPayload(ok: true, error: nil)

        case .failure(let error):
            lastError = error.localizedDescription
            return mutationPayload(ok: false, error: error.localizedDescription)
        }
    }

    private func mutationPayload(ok: Bool, error: String?) -> [String: Any] {
        [
            "ok": ok,
            "error": error as Any,
            "snapshot": snapshot(forceRefresh: false, query: "", includeCompleted: true)
        ]
    }

    nonisolated private static func loadVisibleTasks() -> Result<[[String: Any]], Error> {
        let pendingResult = loadTasks(arguments: ["status:pending", "export"])
        switch pendingResult {
        case .failure(let error):
            return .failure(error)
        case .success(let pendingTasks):
            let completedResult = loadTasks(arguments: ["status:completed", "limit:75", "export"])
            switch completedResult {
            case .success(let completedTasks):
                return .success(pendingTasks + completedTasks)
            case .failure:
                return .success(pendingTasks)
            }
        }
    }

    nonisolated private static func loadTasks(arguments: [String]) -> Result<[[String: Any]], Error> {
        switch runTask(arguments: arguments, timeoutSeconds: 4) {
        case .success(let outputData):
            do {
                let exported = try JSONDecoder().decode([ExportedTask].self, from: outputData)
                return .success(exported.map(\.payload))
            } catch {
                return .failure(error)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    nonisolated private static func runTask(arguments taskArguments: [String], timeoutSeconds: TimeInterval) -> Result<Data, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            """
            if [ -f "$HOME/.zprofile" ]; then source "$HOME/.zprofile" >/dev/null 2>&1; fi
            if [ -f "$HOME/.zshrc" ]; then source "$HOME/.zshrc" >/dev/null 2>&1; fi
            task_path="$(command -v task)" || exit 127
            exec "$task_path" "$@"
            """,
            "task",
            "rc.verbose=nothing",
            "rc.confirmation=no"
        ] + taskArguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(error)
        }

        let timeout = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            timeout.signal()
        }

        if timeout.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            return .failure(TaskwarriorError.timedOut)
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 127 {
                return .failure(TaskwarriorError.commandNotFound)
            }
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(TaskwarriorError.commandFailed(message ?? "task exited with status \(process.terminationStatus)"))
        }

        return .success(outputData)
    }

    nonisolated private static func filteredTasks(
        _ tasks: [[String: Any]],
        query: String,
        includeCompleted: Bool
    ) -> [[String: Any]] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return tasks.filter { task in
            let status = (task["status"] as? String) ?? "pending"
            guard includeCompleted || status != "completed" else { return false }
            guard !tokens.isEmpty else { return true }

            let tags = (task["tags"] as? [String])?.joined(separator: " ") ?? ""
            let haystack = [
                task["description"] as? String,
                task["project"] as? String,
                task["priority"] as? String,
                task["uuid"] as? String,
                task["id"].map(String.init(describing:)),
                tags
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()

            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}

private enum TaskwarriorError: LocalizedError {
    case commandNotFound
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .commandNotFound:
            return "Taskwarrior command `task` was not found."
        case .commandFailed(let message):
            return message
        case .timedOut:
            return "Taskwarrior did not respond within 4 seconds."
        }
    }
}

private extension TaskwarriorProvider.ExportedTask {
    var payload: [String: Any] {
        [
            "id": id.map { $0 as Any } ?? NSNull(),
            "uuid": nullable(uuid),
            "status": status ?? "pending",
            "description": description ?? "",
            "project": nullable(project),
            "priority": nullable(priority),
            "due": nullable(due),
            "end": nullable(end),
            "urgency": urgency.map { $0 as Any } ?? NSNull(),
            "tags": tags ?? []
        ]
    }

    private func nullable(_ value: String?) -> Any {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NSNull()
        }
        return value
    }
}
