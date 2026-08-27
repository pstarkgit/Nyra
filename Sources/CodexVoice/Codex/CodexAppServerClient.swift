import Foundation

protocol CodexServing: AnyObject {
    func connect() async throws
    func listTasks(limit: Int) async throws -> [CodexTask]
    func resumeTask(id: String) async throws
    func startTurn(threadId: String, text: String) async throws -> String
    func steerTurn(threadId: String, text: String) async throws
    func interruptTurn(threadId: String, turnId: String) async throws
    func answerApproval(id: RequestID, decision: ApprovalDecision) async throws
    func events() async -> AsyncStream<CodexServerEvent>
    func shutdown() async
}

enum CodexAppServerClientError: Error, Equatable, Sendable {
    case notConnected
    case invalidResponse(String)
    case server(String)
    case processExited(Int32)
}

actor CodexAppServerClient: CodexServing {
    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var receiveBuffer = Data()
    private var nextRequestID = 1
    private var pending: [RequestID: CheckedContinuation<JSONRPCMessage, Error>] = [:]
    private let eventStream: AsyncStream<CodexServerEvent>
    private let eventContinuation: AsyncStream<CodexServerEvent>.Continuation
    private var streamFinished = false
    private var intentionalShutdown = false

    init(
        executableURL: URL,
        arguments: [String] = ["app-server", "--listen", "stdio://"]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        var continuation: AsyncStream<CodexServerEvent>.Continuation!
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func events() -> AsyncStream<CodexServerEvent> {
        eventStream
    }

    func connect() async throws {
        guard process == nil else { return }
        intentionalShutdown = false

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processDidExit(status: process.terminationStatus) }
        }

        try process.run()
        self.process = process
        standardInput = input.fileHandleForWriting
        standardOutput = output.fileHandleForReading
        standardError = errors.fileHandleForReading

        do {
            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": .string("codex_voice"),
                        "title": .string("Codex Voice"),
                        "version": .string("0.1.0"),
                    ]),
                ]
            )
            try sendNotification(method: "initialized", params: [:])
        } catch {
            await shutdown()
            throw error
        }
    }

    func listTasks(limit: Int = 50) async throws -> [CodexTask] {
        let message = try await request(
            method: "thread/list",
            params: [
                "limit": .integer(max(1, limit)),
                "archived": .bool(false),
                "sortKey": .string("updated_at"),
            ]
        )
        guard case .array(let values) = message.result?["data"] else {
            throw CodexAppServerClientError.invalidResponse("thread/list data")
        }
        return values.compactMap(Self.task(from:))
    }

    func resumeTask(id: String) async throws {
        _ = try await request(
            method: "thread/resume",
            params: ["threadId": .string(id)]
        )
    }

    func startTurn(threadId: String, text: String) async throws -> String {
        let message = try await request(
            method: "turn/start",
            params: [
                "threadId": .string(threadId),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]
        )
        guard let turnID = message.result?["turn"]?["id"]?.string else {
            throw CodexAppServerClientError.invalidResponse("turn/start turn id")
        }
        return turnID
    }

    func steerTurn(threadId: String, text: String) async throws {
        _ = try await request(
            method: "turn/steer",
            params: [
                "threadId": .string(threadId),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]
        )
    }

    func interruptTurn(threadId: String, turnId: String) async throws {
        _ = try await request(
            method: "turn/interrupt",
            params: [
                "threadId": .string(threadId),
                "turnId": .string(turnId),
            ]
        )
    }

    func answerApproval(
        id: RequestID,
        decision: ApprovalDecision
    ) async throws {
        let value = decision == .approveOnce ? "accept" : "decline"
        try write(try JSONRPCMessage.encodeResponse(
            id: id,
            result: .object(["decision": .string(value)])
        ))
    }

    func shutdown() async {
        guard !streamFinished else { return }
        intentionalShutdown = true
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        try? standardInput?.close()
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
        failPending(CodexAppServerClientError.notConnected)
        finishStream()
    }

    private func request(
        method: String,
        params: [String: JSONValue]
    ) async throws -> JSONRPCMessage {
        guard process?.isRunning == true else {
            throw CodexAppServerClientError.notConnected
        }
        let id = RequestID.integer(nextRequestID)
        nextRequestID += 1
        let data = try JSONRPCMessage.encodeRequest(
            id: id,
            method: method,
            params: params
        )
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(data)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(
        method: String,
        params: [String: JSONValue]
    ) throws {
        let object = JSONValue.object([
            "method": .string(method),
            "params": .object(params),
        ])
        guard case .object(let values) = object else { return }
        let data = try JSONSerialization.data(
            withJSONObject: values.mapValues(Self.foundationValue),
            options: [.sortedKeys]
        )
        try write(data)
    }

    private func write(_ data: Data) throws {
        guard let standardInput else {
            throw CodexAppServerClientError.notConnected
        }
        var line = data
        line.append(0x0A)
        try standardInput.write(contentsOf: line)
    }

    private func receive(_ data: Data) {
        guard !streamFinished else { return }
        guard !data.isEmpty else {
            if process?.isRunning != true {
                finishAfterDisconnect()
            }
            return
        }
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            do {
                handle(try JSONRPCMessage.decode(line: line))
            } catch {
                eventContinuation.yield(.error("Malformed app-server message"))
            }
        }
    }

    private func handle(_ message: JSONRPCMessage) {
        if message.kind == .response, let id = message.id,
           let continuation = pending.removeValue(forKey: id) {
            if let error = message.error {
                continuation.resume(throwing: CodexAppServerClientError.server(
                    Self.errorMessage(from: error)
                ))
            } else {
                continuation.resume(returning: message)
            }
            return
        }
        if message.kind == .request,
           let approval = Self.approval(from: message) {
            eventContinuation.yield(.approvalRequested(approval))
            return
        }
        guard message.kind == .notification, let method = message.method else {
            return
        }
        switch method {
        case "item/agentMessage/delta":
            guard let threadID = message.params?["threadId"]?.string,
                  let turnID = message.params?["turnId"]?.string,
                  let delta = message.params?["delta"]?.string else { return }
            eventContinuation.yield(.agentDelta(
                threadID: threadID,
                turnID: turnID,
                text: delta
            ))
        case "turn/completed":
            guard let threadID = message.params?["threadId"]?.string,
                  let turnID = message.params?["turn"]?["id"]?.string,
                  let status = message.params?["turn"]?["status"]?.string else {
                return
            }
            eventContinuation.yield(.turnCompleted(
                threadID: threadID,
                turnID: turnID,
                status: status
            ))
        case "error":
            let text = message.params?["error"]?["message"]?.string
                ?? message.params?["message"]?.string
                ?? "Codex app-server error"
            eventContinuation.yield(.error(text))
        default:
            break
        }
    }

    private func processDidExit(status: Int32) {
        process = nil
        standardInput = nil
        if !intentionalShutdown {
            failPending(CodexAppServerClientError.processExited(status))
            eventContinuation.yield(.disconnected)
        }
        finishStream()
    }

    private func finishAfterDisconnect() {
        if !intentionalShutdown {
            failPending(CodexAppServerClientError.notConnected)
            eventContinuation.yield(.disconnected)
        }
        finishStream()
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func finishStream() {
        guard !streamFinished else { return }
        streamFinished = true
        eventContinuation.finish()
    }

    private static func task(from value: JSONValue) -> CodexTask? {
        guard let id = value["id"]?.string,
              let cwd = value["cwd"]?.string else { return nil }
        let title = value["name"]?.string
            ?? value["preview"]?.string
            ?? "Untitled task"
        let updatedAt = value["updatedAt"]?.integer ?? 0
        let status = value["status"]?["type"]?.string ?? "unknown"
        return CodexTask(
            id: id,
            title: title,
            cwd: cwd,
            updatedAt: updatedAt,
            status: status
        )
    }

    private static func approval(from message: JSONRPCMessage) -> CodexApproval? {
        guard let id = message.id, let method = message.method else { return nil }
        let kind: CodexApprovalKind
        switch method {
        case "item/commandExecution/requestApproval": kind = .command
        case "item/fileChange/requestApproval": kind = .fileChange
        case "item/permissions/requestApproval": kind = .permissions
        default: return nil
        }
        let summary = message.params?["reason"]?.string ?? "Codex needs approval"
        let details = message.params?["command"]?.string
            ?? message.params?["grantRoot"]?.string
        return CodexApproval(id: id, kind: kind, summary: summary, details: details)
    }

    private static func errorMessage(from value: JSONValue) -> String {
        value["message"]?.string ?? "Unknown app-server error"
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(foundationValue)
        case .object(let values): return values.mapValues(foundationValue)
        }
    }
}
