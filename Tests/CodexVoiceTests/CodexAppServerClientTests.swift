import Foundation
import Testing
@testable import CodexVoice

private func fixtureClient() -> CodexAppServerClient {
    let fixture = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/fake-app-server.py")
    return CodexAppServerClient(
        executableURL: URL(filePath: "/usr/bin/python3"),
        arguments: [fixture.path]
    )
}

@Test func connectsAndListsTasks() async throws {
    let client = fixtureClient()
    try await client.connect()
    defer { Task { await client.shutdown() } }

    let tasks = try await client.listTasks(limit: 10)

    #expect(tasks == [
        CodexTask(id: "thread-1", title: "First task", cwd: "/tmp/one", updatedAt: 42, status: "idle"),
        CodexTask(id: "thread-2", title: "Second task preview", cwd: "/tmp/two", updatedAt: 41, status: "notLoaded"),
    ])
}

@Test func streamsAgentTextAndExplicitCompletion() async throws {
    let client = fixtureClient()
    let stream = await client.events()
    try await client.connect()
    try await client.resumeTask(id: "thread-1")

    let turnID = try await client.startTurn(threadId: "thread-1", text: "hello")
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    let completed = await iterator.next()
    await client.shutdown()

    #expect(turnID == "turn-1")
    #expect(first == .agentDelta(threadID: "thread-1", turnID: "turn-1", text: "hello "))
    #expect(second == .agentDelta(threadID: "thread-1", turnID: "turn-1", text: "world"))
    #expect(completed == .turnCompleted(threadID: "thread-1", turnID: "turn-1", status: "completed"))
}

@Test func surfacesApprovalAndSendsExplicitDecision() async throws {
    let client = fixtureClient()
    let stream = await client.events()
    try await client.connect()

    _ = try await client.startTurn(threadId: "thread-1", text: "approval")
    var iterator = stream.makeAsyncIterator()
    let event = await iterator.next()
    let approval = try #require(event?.approval)
    try await client.answerApproval(id: approval.id, decision: .decline)
    let completed = await iterator.next()
    await client.shutdown()

    #expect(approval.kind == .command)
    #expect(approval.summary == "Needs access")
    #expect(approval.details == "echo hello")
    #expect(completed == .turnCompleted(
        threadID: "thread-1",
        turnID: "turn-approval",
        status: "completed"
    ))
}

@Test func interruptWaitsForInterruptedCompletionEvent() async throws {
    let client = fixtureClient()
    let stream = await client.events()
    try await client.connect()
    try await client.interruptTurn(threadId: "thread-1", turnId: "turn-live")
    var iterator = stream.makeAsyncIterator()
    let event = await iterator.next()
    await client.shutdown()

    #expect(event == .turnCompleted(
        threadID: "thread-1",
        turnID: "turn-live",
        status: "interrupted"
    ))
}

@Test func shutdownFinishesEventStream() async throws {
    let client = fixtureClient()
    let stream = await client.events()
    try await client.connect()
    await client.shutdown()
    var iterator = stream.makeAsyncIterator()

    #expect(await iterator.next() == nil)
}

private extension CodexServerEvent {
    var approval: CodexApproval? {
        guard case .approvalRequested(let approval) = self else { return nil }
        return approval
    }
}
