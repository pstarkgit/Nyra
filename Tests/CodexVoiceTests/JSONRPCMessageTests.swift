import Foundation
import Testing
@testable import CodexVoice

@Test func decodesAgentDeltaNotification() throws {
    let line = #"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"u","itemId":"i","delta":"hello"}}"#

    let message = try JSONRPCMessage.decode(line: line)

    #expect(message.kind == .notification)
    #expect(message.method == "item/agentMessage/delta")
    #expect(message.params?["delta"]?.string == "hello")
}

@Test func decodesIntegerIDResponse() throws {
    let line = #"{"id":7,"result":{"thread":{"id":"thread-1"}}}"#

    let message = try JSONRPCMessage.decode(line: line)

    #expect(message.kind == .response)
    #expect(message.id == .integer(7))
    #expect(message.result?["thread"]?["id"]?.string == "thread-1")
}

@Test func decodesServerRequestWithStringID() throws {
    let line = #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"reason":"Needs access"}}"#

    let message = try JSONRPCMessage.decode(line: line)

    #expect(message.kind == .request)
    #expect(message.id == .string("approval-1"))
    #expect(message.params?["reason"]?.string == "Needs access")
}

@Test func classifiesStructuredLogAsUnrelated() throws {
    let line = #"{"timestamp":"now","level":"WARN","fields":{"message":"noise"}}"#

    let message = try JSONRPCMessage.decode(line: line)

    #expect(message.kind == .unrelated)
    #expect(message.method == nil)
}

@Test func encodesRequestWithoutLosingNestedValues() throws {
    let data = try JSONRPCMessage.encodeRequest(
        id: .integer(9),
        method: "turn/start",
        params: [
            "threadId": .string("thread-1"),
            "input": .array([
                .object(["type": .string("text"), "text": .string("hello")]),
            ]),
        ]
    )
    let line = try #require(String(data: data, encoding: .utf8))
    let decoded = try JSONRPCMessage.decode(line: line)

    #expect(decoded.id == .integer(9))
    #expect(decoded.method == "turn/start")
    #expect(decoded.params?["input"]?[0]?["text"]?.string == "hello")
}

@Test func rejectsNonObjectJSON() {
    #expect(throws: JSONRPCMessageError.invalidTopLevel) {
        try JSONRPCMessage.decode(line: #"["not", "an", "object"]"#)
    }
}
