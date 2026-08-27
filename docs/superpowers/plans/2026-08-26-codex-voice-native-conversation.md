# Codex Voice Native Conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, install, and verify a native macOS companion that supports continuous local speech-to-Codex-to-speech conversation against persisted Codex Desktop tasks.

**Architecture:** A SwiftUI menu-bar app owns a serialized conversation coordinator. Local audio is transcribed with Apple's on-device Speech framework, Codex turns run through a child `codex app-server` JSONL process, and final agent text is spoken with the system synthesizer before capture automatically resumes.

**Tech Stack:** Swift 5.9 package mode on Apple Swift 6.3.3, macOS 26, SwiftUI/AppKit, AVFoundation, Speech, CoreGraphics, XCTest, Codex app-server JSON-RPC v2.

**Spec:** `docs/superpowers/specs/2026-08-26-codex-voice-native-conversation-design.md`

## Global Constraints

- Minimum runtime is macOS 26.0.
- Speech recognition must set `requiresOnDeviceRecognition = true`; audio must never be uploaded by Codex Voice.
- Audio and partial transcripts are memory-only and excluded from logs.
- Codex authentication and provider configuration remain owned by the launched Codex binary.
- Never read, copy, print, or persist cookies, JWTs, API keys, login tokens, or Codex credentials.
- Only one Codex turn may be owned by the conversation coordinator at a time.
- Completion requires an explicit `turn/completed` notification, not the final text delta alone.
- Sensitive approvals require a visible click; voice cannot approve them.
- Barge-in may fall back to hotkey interruption when tested acoustic echo cancellation is unavailable, but the UI must label that fallback.
- No third-party package dependencies in the MVP.
- Keep source files focused; production files should normally stay below 300 lines.

## File Map

- `Package.swift` — Swift package products, platform floor, source and test targets.
- `Sources/CodexVoice/App/CodexVoiceApp.swift` — application entry point and menu-bar lifecycle.
- `Sources/CodexVoice/App/AppModel.swift` — observable UI model and dependency assembly.
- `Sources/CodexVoice/Conversation/ConversationState.swift` — state and transition rules.
- `Sources/CodexVoice/Conversation/ConversationCoordinator.swift` — audio/Codex/synthesis orchestration.
- `Sources/CodexVoice/Conversation/LocalVoiceCommand.swift` — deterministic local command parser.
- `Sources/CodexVoice/Codex/CodexModels.swift` — task, turn, event, and approval domain types.
- `Sources/CodexVoice/Codex/CodexBinaryLocator.swift` — safe executable resolution.
- `Sources/CodexVoice/Codex/JSONRPCMessage.swift` — JSON value and message decoding helpers.
- `Sources/CodexVoice/Codex/CodexAppServerClient.swift` — child process, requests, notifications, and shutdown.
- `Sources/CodexVoice/Speech/VoiceActivityDetector.swift` — deterministic utterance boundary detection.
- `Sources/CodexVoice/Speech/AppleSpeechSession.swift` — microphone capture and local live recognition.
- `Sources/CodexVoice/Speech/SystemSpeechSynthesizer.swift` — speech playback and completion callbacks.
- `Sources/CodexVoice/Speech/AudioDucker.swift` — snapshot, duck, and restore system output volume.
- `Sources/CodexVoice/Speech/SpokenResponseFormatter.swift` — bounded Markdown-to-speech rendering.
- `Sources/CodexVoice/System/GlobalHotkey.swift` — Accessibility-backed Right Option toggle.
- `Sources/CodexVoice/UI/MenuBarContentView.swift` — task picker, controls, diagnostics, permissions.
- `Sources/CodexVoice/UI/VoiceOrbPanel.swift` — non-activating floating session state.
- `Sources/CodexVoice/UI/ApprovalView.swift` — explicit approve-once/deny card.
- `Config/CodexVoice-Info.plist` — bundle identity and privacy strings.
- `Config/CodexVoice.entitlements` — audio-input and local-process capabilities.
- `Scripts/build-app.sh` — release build and deterministic `.app` assembly.
- `install.sh` — validated replacement of the owned installed app.
- `test.sh` — canonical build and test entry point.
- `Tests/CodexVoiceTests/*Tests.swift` — deterministic component tests.
- `Tests/Fixtures/fake-app-server.py` — protocol fixture with no network or credentials.

---

### Task 1: Package foundation and conversation state

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/CodexVoice/Conversation/ConversationState.swift`
- Create: `Sources/CodexVoice/Conversation/LocalVoiceCommand.swift`
- Create: `Tests/CodexVoiceTests/ConversationStateTests.swift`
- Create: `Tests/CodexVoiceTests/LocalVoiceCommandTests.swift`

**Interfaces:**
- Produces: `ConversationState`, `ConversationEvent`, `ConversationTransition.reduce(state:event:) throws -> ConversationState`.
- Produces: `LocalVoiceCommand.parse(_:) -> LocalVoiceCommand?` with `stopSpeaking`, `cancelTurn`, and `endSession`.

- [ ] **Step 1: Add the package and failing state tests**

```swift
func testHappyPathReturnsToListening() throws {
    var state = ConversationState.idle
    for event in [.startSession, .speechDetected, .transcriptionFinalized,
                  .turnStarted, .turnCompleted, .speechFinished] {
        state = try ConversationTransition.reduce(state: state, event: event)
    }
    XCTAssertEqual(state, .listening)
}

func testCannotStartSecondTurnWhileWaiting() {
    XCTAssertThrowsError(try ConversationTransition.reduce(
        state: .waitingForCodex, event: .transcriptionFinalized))
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `swift test --filter ConversationStateTests`

Expected: compilation fails because the state types do not exist.

- [ ] **Step 3: Implement explicit state transitions and local commands**

```swift
enum ConversationState: Equatable, Sendable {
    case idle, listening, transcribing, waitingForCodex
    case awaitingApproval, speaking, ending
    case failed(String)
}

enum LocalVoiceCommand: Equatable, Sendable {
    case stopSpeaking, cancelTurn, endSession
}
```

Normalize local commands by lowercasing, trimming punctuation/whitespace, and
matching exact phrases only so normal requests containing the words are not
consumed.

- [ ] **Step 4: Run state and command tests**

Run: `swift test --filter 'ConversationStateTests|LocalVoiceCommandTests'`

Expected: all focused tests pass.

- [ ] **Step 5: Commit the foundation**

```bash
git add Package.swift .gitignore Sources/CodexVoice/Conversation Tests/CodexVoiceTests
git commit -m "feat: add Codex Voice conversation state"
```

### Task 2: Codex protocol models and deterministic message routing

**Files:**
- Create: `Sources/CodexVoice/Codex/CodexModels.swift`
- Create: `Sources/CodexVoice/Codex/JSONRPCMessage.swift`
- Create: `Sources/CodexVoice/Codex/CodexBinaryLocator.swift`
- Create: `Tests/CodexVoiceTests/JSONRPCMessageTests.swift`
- Create: `Tests/CodexVoiceTests/CodexBinaryLocatorTests.swift`

**Interfaces:**
- Produces: `CodexTask(id:title:cwd:updatedAt:status:)`.
- Produces: `CodexApproval(id:kind:summary:details:)`.
- Produces: `CodexServerEvent` cases `agentDelta`, `turnCompleted`, `approvalRequested`, `error`.
- Produces: `JSONRPCMessage.decode(line:) throws -> JSONRPCMessage` and `encodeRequest(id:method:params:)`.
- Produces: `CodexBinaryLocator.resolve(fileManager:environment:) throws -> URL`.

- [ ] **Step 1: Write fixture-driven decoder tests**

```swift
func testDecodesAgentDeltaNotification() throws {
    let line = #"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"u","itemId":"i","delta":"hello"}}"#
    let message = try JSONRPCMessage.decode(line: line)
    XCTAssertEqual(message.method, "item/agentMessage/delta")
    XCTAssertEqual(message.params?["delta"]?.string, "hello")
}

func testIgnoresStructuredLogWithoutRPCShape() throws {
    let line = #"{"timestamp":"now","level":"WARN","fields":{"message":"noise"}}"#
    XCTAssertEqual(try JSONRPCMessage.decode(line: line).kind, .unrelated)
}
```

- [ ] **Step 2: Verify focused tests fail**

Run: `swift test --filter 'JSONRPCMessageTests|CodexBinaryLocatorTests'`

Expected: compilation fails because protocol types are absent.

- [ ] **Step 3: Implement JSON-safe domain types**

Use a recursive `JSONValue: Codable, Equatable, Sendable` enum rather than
passing `[String: Any]` across actors. Accept integer or string request IDs.
Binary resolution must validate regular executable files and never invoke a
shell. Check the Desktop bundle path, explicit preference, then known absolute
CLI paths.

- [ ] **Step 4: Run protocol model tests**

Run: `swift test --filter 'JSONRPCMessageTests|CodexBinaryLocatorTests'`

Expected: all focused tests pass.

- [ ] **Step 5: Commit protocol primitives**

```bash
git add Sources/CodexVoice/Codex Tests/CodexVoiceTests
git commit -m "feat: model Codex app-server protocol"
```

### Task 3: App-server client and fake integration server

**Files:**
- Create: `Sources/CodexVoice/Codex/CodexAppServerClient.swift`
- Create: `Tests/Fixtures/fake-app-server.py`
- Create: `Tests/CodexVoiceTests/CodexAppServerClientTests.swift`

**Interfaces:**
- Consumes: `JSONRPCMessage`, `CodexTask`, `CodexServerEvent`, `CodexBinaryLocator`.
- Produces: `CodexServing` protocol with methods:

```swift
func connect() async throws
func listTasks(limit: Int) async throws -> [CodexTask]
func resumeTask(id: String) async throws
func startTurn(threadId: String, text: String) async throws -> String
func steerTurn(threadId: String, text: String) async throws
func interruptTurn(threadId: String, turnId: String) async throws
func answerApproval(id: RequestID, decision: ApprovalDecision) async throws
func events() -> AsyncStream<CodexServerEvent>
func shutdown() async
```

- [ ] **Step 1: Add a fake JSONL server and failing lifecycle tests**

The fixture must require `initialize`, emit `initialized`-compatible responses,
return two tasks for `thread/list`, emit two agent deltas followed by
`turn/completed`, and record interrupt/approval responses. It must never access
the network or `~/.codex`.

```swift
func testWaitsForTurnCompletedAfterAgentText() async throws {
    let client = try fixtureClient()
    try await client.connect()
    let turnID = try await client.startTurn(threadId: "thread-1", text: "hello")
    let events = await collectEvents(client.events(), throughTurn: turnID)
    XCTAssertEqual(events.agentText, "hello world")
    XCTAssertTrue(events.completed)
}
```

- [ ] **Step 2: Run the client tests and verify failure**

Run: `swift test --filter CodexAppServerClientTests`

Expected: compilation fails because `CodexAppServerClient` is absent.

- [ ] **Step 3: Implement child-process JSONL transport**

Launch `Process` with arguments `app-server --listen stdio://`. Use dedicated
pipes, an actor-owned monotonically increasing request ID, checked continuations
for responses, and one background stdout reader. Stderr may contain diagnostics
but must not include prompts or response bodies in app logs. On EOF, fail all
pending requests exactly once and finish the event stream.

- [ ] **Step 4: Run lifecycle, failure, interrupt, and approval tests**

Run: `swift test --filter CodexAppServerClientTests`

Expected: all client tests pass and no fake server remains running.

- [ ] **Step 5: Commit the client**

```bash
git add Sources/CodexVoice/Codex Tests
git commit -m "feat: connect to Codex app-server"
```

### Task 4: VAD, spoken formatting, and speech adapters

**Files:**
- Create: `Sources/CodexVoice/Speech/VoiceActivityDetector.swift`
- Create: `Sources/CodexVoice/Speech/SpokenResponseFormatter.swift`
- Create: `Sources/CodexVoice/Speech/AppleSpeechSession.swift`
- Create: `Sources/CodexVoice/Speech/SystemSpeechSynthesizer.swift`
- Create: `Sources/CodexVoice/Speech/AudioDucker.swift`
- Create: `Tests/CodexVoiceTests/VoiceActivityDetectorTests.swift`
- Create: `Tests/CodexVoiceTests/SpokenResponseFormatterTests.swift`
- Create: `Tests/CodexVoiceTests/AudioDuckerTests.swift`

**Interfaces:**
- Produces: `VoiceActivityDetector.consume(rms:duration:) -> VoiceActivityEvent?`.
- Produces: `SpokenResponseFormatter.format(_:) -> SpokenResponse`.
- Produces: `SpeechCapturing.start()`, `stop()`, partial/final callbacks.
- Produces: `SpeechSynthesizing.speak(_:)`, `stop()`, completion callback.
- Produces: `AudioDucking.snapshotBeforeCapture()`, `duck()`, and `restore()`.

- [ ] **Step 1: Write deterministic VAD and formatter tests**

```swift
func testTrailingSilenceFinalizesOnlyAfterSpeech() {
    var vad = VoiceActivityDetector(
        speechThreshold: 0.03,
        minimumSpeech: .milliseconds(200),
        trailingSilence: .milliseconds(700))
    XCTAssertNil(vad.consume(rms: 0.001, duration: .seconds(1)))
    XCTAssertEqual(feed(&vad, rms: 0.1, milliseconds: 250), .speechStarted)
    XCTAssertEqual(feed(&vad, rms: 0.001, milliseconds: 700), .utteranceEnded)
}

func testFormatterDoesNotReadCodeFence() {
    let result = SpokenResponseFormatter(maximumCharacters: 500).format(
        "Done.\n```swift\nprint(\"secret\")\n```\nSee `/tmp/a`."
    )
    XCTAssertEqual(result.text, "Done. See the full technical details in Codex.")
}
```

- [ ] **Step 2: Verify focused tests fail**

Run: `swift test --filter 'VoiceActivityDetectorTests|SpokenResponseFormatterTests'`

Expected: compilation fails because VAD and formatter are absent.

- [ ] **Step 3: Implement deterministic VAD and formatter**

VAD accumulates above/below-threshold durations and emits each edge once.
Formatter removes fenced and inline code, Markdown links while retaining their
labels, raw URLs, headings, list markers, and repeated whitespace. If technical
content or truncation is removed, append one fixed Desktop-details sentence.

- [ ] **Step 4: Implement live Apple speech adapters**

`AppleSpeechSession` uses `SFSpeechRecognizer`,
`SFSpeechAudioBufferRecognitionRequest`, and `AVAudioEngine`. Set
`requiresOnDeviceRecognition = true`, report partial results, calculate RMS from
input buffers, and call `endAudio()` only after VAD finalization. Never write
buffers to disk. `SystemSpeechSynthesizer` wraps `AVSpeechSynthesizer`, follows
the system output, and resolves completion/cancellation once.

`AudioDucker` synchronously snapshots the default output device and
`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` before capture changes
the Bluetooth route. It lowers volume only when enabled and restores only if the
user did not change the volume while ducking. Inject CoreAudio reads/writes in
tests to prove ordering and user-change preservation.

- [ ] **Step 5: Run all speech tests and compile the live adapters**

Run: `swift test --filter 'VoiceActivityDetectorTests|SpokenResponseFormatterTests|AudioDuckerTests' && swift build`

Expected: focused tests and build pass.

- [ ] **Step 6: Commit local speech support**

```bash
git add Sources/CodexVoice/Speech Tests/CodexVoiceTests
git commit -m "feat: add local conversation audio"
```

### Task 5: Conversation coordinator

**Files:**
- Create: `Sources/CodexVoice/Conversation/ConversationCoordinator.swift`
- Create: `Tests/CodexVoiceTests/ConversationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `CodexServing`, `SpeechCapturing`, `SpeechSynthesizing`, state,
  commands, and formatter.
- Produces: `ConversationCoordinator` observable state, partial transcript,
  latest response, active approval, and session controls.

- [ ] **Step 1: Add fake-adapter end-to-end state tests**

```swift
func testFinalTranscriptRunsTurnSpeaksAndListensAgain() async throws {
    let harness = CoordinatorHarness()
    await harness.coordinator.startSession(task: .fixture)
    harness.capture.finish("What changed?")
    await harness.codex.complete(text: "The fix is installed.")
    harness.synthesizer.finish()
    XCTAssertEqual(await harness.coordinator.state, .listening)
    XCTAssertEqual(harness.synthesizer.spoken, ["The fix is installed."])
}
```

Also cover empty text, local stop/cancel/end commands, steering during an active
turn, approval pause/resume, Codex crash with unknown completion, and stale text
not spoken after interruption.

- [ ] **Step 2: Run coordinator tests and verify failure**

Run: `swift test --filter ConversationCoordinatorTests`

Expected: compilation fails because the coordinator is absent.

- [ ] **Step 3: Implement serialized orchestration**

Make the coordinator `@MainActor`. Keep a generation counter for capture and
turn callbacks so cancelled or previous-session callbacks cannot mutate the
current session. Add the voice instruction to each submitted text without
changing the user's displayed transcript:

```text
[Voice session: respond in concise spoken prose. Put code and long technical
detail in files or the task transcript; finish with the outcome first.]
```

Start capture after synthesis completes. During synthesis use disclosed
half-duplex mode; the global hotkey stops playback and starts capture.

- [ ] **Step 4: Run coordinator and complete unit suite**

Run: `swift test`

Expected: every unit and fake integration test passes.

- [ ] **Step 5: Commit orchestration**

```bash
git add Sources/CodexVoice/Conversation Tests/CodexVoiceTests
git commit -m "feat: orchestrate continuous Codex voice sessions"
```

### Task 6: Native UI, task selection, hotkey, and approvals

**Files:**
- Create: `Sources/CodexVoice/App/CodexVoiceApp.swift`
- Create: `Sources/CodexVoice/App/AppModel.swift`
- Create: `Sources/CodexVoice/System/GlobalHotkey.swift`
- Create: `Sources/CodexVoice/UI/MenuBarContentView.swift`
- Create: `Sources/CodexVoice/UI/VoiceOrbPanel.swift`
- Create: `Sources/CodexVoice/UI/ApprovalView.swift`
- Create: `Tests/CodexVoiceTests/AppModelTests.swift`

**Interfaces:**
- Consumes: all production services and coordinator state.
- Produces: runnable `CodexVoice` executable and user-visible interaction.

- [ ] **Step 1: Add AppModel dependency-injection tests**

Verify task refresh ordering, selected-task persistence by ID, disconnected
state, start/end controls, approval button routing, and no transcript in
`UserDefaults`.

- [ ] **Step 2: Run AppModel tests and verify failure**

Run: `swift test --filter AppModelTests`

Expected: compilation fails because `AppModel` is absent.

- [ ] **Step 3: Implement the application model and menu-bar UI**

The menu shows connection state, selected task title/cwd, refresh, start/end,
microphone and Accessibility status, voice choice, half-duplex disclosure, and
quit. The model stores only task ID, voice identifier, hotkey enabled state, and
window placement.

- [ ] **Step 4: Implement the orb and approval card**

Use a borderless non-activating `NSPanel` at the top center of the active screen.
Show state, level, volatile partial text, response preview, and approval buttons.
Never show command approval as a voice-only prompt.

- [ ] **Step 5: Implement Right Option toggle**

Use a `CGEvent` tap and `AXIsProcessTrusted`. In idle it starts the selected
session; while speaking it stops synthesis and begins listening; while active it
ends the current utterance/session according to coordinator state. Re-enable the
tap after timeout disablement and expose permission failure.

- [ ] **Step 6: Run UI-model tests and compile**

Run: `swift test && swift build -c release`

Expected: all tests pass and the release executable links.

- [ ] **Step 7: Commit native UI**

```bash
git add Sources/CodexVoice/App Sources/CodexVoice/System Sources/CodexVoice/UI Tests
git commit -m "feat: add native Codex Voice interface"
```

### Task 7: Bundle, install, and static privacy checks

**Files:**
- Create: `Config/CodexVoice-Info.plist`
- Create: `Config/CodexVoice.entitlements`
- Create: `Scripts/build-app.sh`
- Create: `install.sh`
- Create: `test.sh`
- Create: `Tests/CodexVoiceTests/BundleContractTests.swift`
- Create: `README.md`

**Interfaces:**
- Produces: `.build/app/Codex Voice.app` and `/Applications/Codex Voice.app`.
- Produces: `./test.sh` as the canonical verification command.

- [ ] **Step 1: Add failing bundle contract tests**

Tests require `LSUIElement=true`, minimum macOS 26.0, microphone and speech
privacy descriptions that state local processing, the expected executable and
bundle identifier, and no network client entitlement.

- [ ] **Step 2: Run bundle tests and verify failure**

Run: `swift test --filter BundleContractTests`

Expected: tests fail because configuration files are absent.

- [ ] **Step 3: Implement deterministic app assembly**

`Scripts/build-app.sh` runs `swift build -c release`, creates a fresh owned stage,
copies the executable and plist, ad-hoc signs with the minimum entitlements, and
verifies `codesign --verify --deep --strict`. It writes only below `.build/app`.

- [ ] **Step 4: Implement guarded installation**

`install.sh` validates that an existing `/Applications/Codex Voice.app` has the
expected bundle identifier before replacement, builds to a temporary sibling,
moves the old owned bundle to Trash or a timestamped backup, atomically installs,
verifies signature/plist, and launches the app. It must reject symlinked or
foreign targets.

- [ ] **Step 5: Add README and canonical tests**

Document requirements, one-click continuous flow, local-data boundary,
permissions, task ownership, half-duplex fallback, build/install commands, and
troubleshooting. `test.sh` runs `swift test`, release build, app assembly,
`plutil -lint`, `codesign --verify`, and a scan proving no persisted audio file
extensions or credential-reading code paths.

- [ ] **Step 6: Run canonical verification**

Run: `./test.sh`

Expected: exit 0 with test, build, bundle, signature, and privacy checks passing.

- [ ] **Step 7: Commit packaging**

```bash
git add Config Scripts install.sh test.sh README.md Tests/CodexVoiceTests
git commit -m "build: package and verify Codex Voice"
```

### Task 8: Live Codex and installed voice workflow verification

**Files:**
- Create: `Scripts/protocol-smoke.sh`
- Create: `docs/verification/2026-08-26-live-verification.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: installed Codex binary and built Codex Voice app.
- Produces: fresh evidence for every acceptance criterion.

- [ ] **Step 1: Generate and inspect the installed protocol schema**

Run the Desktop-bundled binary's `app-server generate-json-schema --experimental`
into a temporary directory. Confirm request/notification names used by the app
match the installed schema. The script must remove its temporary directory.

- [ ] **Step 2: Run a disposable protocol task**

Use `Scripts/protocol-smoke.sh` to initialize, create a task under the CodexVoice
cwd, submit `Reply exactly CODEX_VOICE_PROTOCOL_OK`, collect deltas, and wait for
explicit `turn/completed`. Record the disposable task ID, final status, and
redacted response marker; never print auth state.

- [ ] **Step 3: Confirm Desktop persistence**

Query the Desktop task list and the app-server task list for the disposable ID.
Confirm title/cwd/history are visible through both supported surfaces. Do not
claim live dual-client ownership if only persisted visibility is proven.

- [ ] **Step 4: Install and launch the application**

Run: `./install.sh`

Expected: installer exits 0, `/Applications/Codex Voice.app` passes signature and
plist checks, and exactly one installed process is running.

- [ ] **Step 5: Verify permissions and real audio session**

Grant microphone, Speech Recognition, and Accessibility through System Settings
when macOS requires human confirmation. Speak one harmless request to the
disposable task. Confirm finalized transcript submission, explicit Codex
completion, audible system-voice response, and automatic return to listening.

- [ ] **Step 6: Verify interruption and route fallback**

Test built-in output and AirPods when available. Confirm voice barge-in when
echo cancellation is reliable; otherwise confirm the UI labels half-duplex and
the Right Option key stops speech and returns to listening.

- [ ] **Step 7: Audit runtime privacy and process closure**

Confirm no audio files or transcript-bearing logs were created. End the voice
session, verify no live Codex turn remains, and verify all test/smoke child
processes exited. Record commands and outcomes in the verification document.

- [ ] **Step 8: Run final tests and commit evidence**

Run: `./test.sh && git status --short`

Expected: `./test.sh` exits 0; only the verification document and intended README
update are uncommitted before the final commit.

```bash
git add Scripts/protocol-smoke.sh README.md docs/verification
git commit -m "test: verify installed Codex Voice workflow"
```
