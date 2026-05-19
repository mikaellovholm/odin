#if os(macOS)
import Foundation

enum OdinMCPTools {
    static let descriptors: [[String: Any]] = [
        [
            "name": "run_background_task",
            "description": """
            Spawn a headless Claude Code session in the background to perform a single task. \
            Returns immediately with a task_id. Use await_task to retrieve the result, or \
            get_task_status to poll without blocking. The background session has no UI and \
            runs with --dangerously-skip-permissions, so scope its prompt narrowly.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description": "The prompt the background session will execute. Be specific about the expected output format."
                    ],
                    "cwd": [
                        "type": "string",
                        "description": "Working directory for the background session. Defaults to the user's home directory."
                    ],
                    "model": [
                        "type": "string",
                        "description": "Optional Claude model id to pin for this worker (e.g. 'claude-sonnet-4-6', 'claude-opus-4-7', 'claude-haiku-4-5'). Omit to use the host claude CLI's default model."
                    ]
                ],
                "required": ["prompt"]
            ]
        ],
        [
            "name": "get_task_status",
            "description": "Check the status of a background task without blocking. Returns running, completed, or failed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task_id": ["type": "string", "description": "The id returned by run_background_task."]
                ],
                "required": ["task_id"]
            ]
        ],
        [
            "name": "await_task",
            "description": "Block until a background task finishes (or timeout_seconds elapses) and return its result.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task_id": ["type": "string", "description": "The id returned by run_background_task."],
                    "timeout_seconds": [
                        "type": "number",
                        "description": "Maximum seconds to wait. Defaults to 300 (5 minutes)."
                    ]
                ],
                "required": ["task_id"]
            ]
        ]
    ]

    @MainActor
    static func call(name: String, args: [String: Any]) async throws -> String {
        switch name {
        case "run_background_task":
            return try runBackgroundTask(args)
        case "get_task_status":
            return try getTaskStatus(args)
        case "await_task":
            return try await awaitTask(args)
        default:
            throw OdinMCPError.invalidArgument("unknown tool: \(name)")
        }
    }

    @MainActor
    private static func runBackgroundTask(_ args: [String: Any]) throws -> String {
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            throw OdinMCPError.invalidArgument("prompt is required")
        }
        let cwd = (args["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let model = (args["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let runner = try BackgroundTaskRegistry.shared.create(
            prompt: prompt,
            cwd: cwd,
            parentSessionId: CurrentMCPRequest.sessionId,
            model: model
        )
        var response: [String: Any] = [
            "task_id": runner.id,
            "status": "running",
            "cwd": cwd
        ]
        if let model {
            response["model"] = model
        }
        return jsonString(response)
    }

    @MainActor
    private static func getTaskStatus(_ args: [String: Any]) throws -> String {
        guard let id = args["task_id"] as? String else {
            throw OdinMCPError.invalidArgument("task_id is required")
        }
        guard let runner = BackgroundTaskRegistry.shared.get(id) else {
            throw OdinMCPError.taskNotFound(id)
        }
        return jsonString(stateDict(runner: runner))
    }

    @MainActor
    private static func awaitTask(_ args: [String: Any]) async throws -> String {
        guard let id = args["task_id"] as? String else {
            throw OdinMCPError.invalidArgument("task_id is required")
        }
        guard let runner = BackgroundTaskRegistry.shared.get(id) else {
            throw OdinMCPError.taskNotFound(id)
        }
        let timeout = (args["timeout_seconds"] as? Double) ?? 300
        let final = await runner.awaitCompletion(timeout: timeout)
        var dict = stateDict(runner: runner)
        if final == nil {
            dict["timed_out"] = true
        }
        return jsonString(dict)
    }

    @MainActor
    private static func stateDict(runner: BackgroundClaudeRunner) -> [String: Any] {
        var dict: [String: Any] = [
            "task_id": runner.id,
            "cwd": runner.cwd,
            "created_at": ISO8601DateFormatter().string(from: runner.createdAt)
        ]
        switch runner.state {
        case .running:
            dict["status"] = "running"
        case .completed(let text):
            dict["status"] = "completed"
            dict["result"] = text
        case .failed(let msg):
            dict["status"] = "failed"
            dict["error"] = msg
        }
        return dict
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
#endif
