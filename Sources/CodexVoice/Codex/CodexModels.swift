import Foundation

struct CodexTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let cwd: String
    let updatedAt: Int
    let status: String
}

enum CodexApprovalKind: String, Equatable, Sendable {
    case command
    case fileChange
    case permissions
    case unknown
}

struct CodexApproval: Identifiable, Equatable, Sendable {
    let id: RequestID
    let kind: CodexApprovalKind
    let summary: String
    let details: String?
}

enum ApprovalDecision: Equatable, Sendable {
    case approveOnce
    case decline
}

enum CodexServerEvent: Equatable, Sendable {
    case agentDelta(threadID: String, turnID: String, text: String)
    case turnCompleted(threadID: String, turnID: String, status: String)
    case approvalRequested(CodexApproval)
    case error(String)
    case disconnected
}
