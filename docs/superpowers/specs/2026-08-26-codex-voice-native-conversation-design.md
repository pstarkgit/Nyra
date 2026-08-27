# Codex Voice Native Conversation Design

**Status:** Proposed for implementation  
**Date:** 2026-08-26  
**Product:** Codex Voice for macOS  
**Owner:** Patrick Stark

## Verdict

Build Codex Voice as a native, Dock-less macOS companion app. It will use
Murmr-proven local speech patterns for microphone capture and transcription,
Apple speech synthesis for spoken output, and the documented Codex app-server
JSON-RPC protocol for task discovery, turns, streamed events, interruption, and
approvals.

This is not an Accessibility macro and does not modify the Codex Desktop app.
It is a first-class Codex client that shares Codex's persisted task history, so
voice turns remain visible in Codex Desktop.

## User outcome

After one click or hotkey, Patrick can converse with the selected Codex task
without touching the keyboard:

```text
Listening -> Processing speech -> Codex working -> Speaking -> Listening
     ^                                  |              |
     +---------- user interruption -----+--------------+
```

The full technical response remains in the Codex task. Codex Voice speaks a
concise, conversational rendering and returns automatically to listening.

## Scope

### MVP

- Native macOS menu-bar app with a non-activating floating conversation orb.
- One-click or global-hotkey start for a continuous voice session.
- Discover local Codex tasks and select one by title and working directory.
- Local microphone capture and Apple Speech transcription.
- Voice activity detection to end an utterance after configurable silence.
- Submit transcribed text to the selected task using `turn/start`.
- Stream Codex progress and final agent-message events.
- Speak the final answer with an installed Apple system voice.
- Return automatically to listening after speech completes.
- Barge-in: speech during playback stops synthesis and becomes the next turn.
- Local commands: `stop speaking`, `cancel that`, and `end voice session`.
- Visible approval card for Codex actions that require confirmation.
- No audio retention and no storage of credentials or authentication tokens.

### Deferred

- Always-on wake-word detection.
- Whisper and Parakeet selection inside Codex Voice.
- Remote-host audio capture or speech playback.
- iPhone, iPad, and Apple Watch clients.
- Multi-speaker recognition.
- Voice-only authorization of destructive or externally visible actions.
- A frontend control embedded inside the Codex Desktop window.

## Architecture

```text
┌──────────────────────── Native Codex Voice app ────────────────────────┐
│                                                                        │
│  Microphone                                                            │
│      │                                                                 │
│      ▼                                                                 │
│  AudioCapture -> VoiceActivityDetector -> AppleSpeechTranscriber       │
│                                              │                         │
│                                              ▼                         │
│                                     ConversationCoordinator            │
│                                      │       │        │                │
│                           local cmd ──┘       │        └── UI state     │
│                                              ▼                         │
│                                      CodexAppServerClient              │
│                                   JSONL over child-process stdio       │
│                                              │                         │
│                   streamed events/approvals  │  thread and turn RPCs   │
│                                              ▼                         │
│  Speaker <- AppleSpeechSynthesizer <- SpokenResponseFormatter          │
│                                                                        │
└───────────────────────────────────────┬────────────────────────────────┘
                                        │
                                        ▼
                              Codex app-server
                                        │
                              ~/.codex task history
                                        │
                              Codex Desktop displays task
```

### Process boundary

Codex Voice launches the Codex binary's documented `app-server` command as a
child process using JSONL over standard input/output. It resolves the binary in
this order:

1. The Codex Desktop bundled binary.
2. A user-configured absolute path.
3. `codex` found through a constrained executable search path.

The app never reads or copies Codex login credentials. Authentication and
provider configuration remain owned by Codex.

### Task ownership

Codex Voice lists persisted tasks with `thread/list`, resumes the selected task,
and submits one voice turn at a time. The coordinator enforces a single in-flight
turn and never writes directly to rollout JSONL or Codex's SQLite state.

Live simultaneous control of one task by two independent app-server processes is
not assumed safe. The first implementation milestone must prove this behavior on
a disposable task. If cross-process ownership is not reliable, Codex Voice will
own the task while a voice session is active; Codex Desktop remains the history
viewer and can resume control after the voice session ends.

## Components

### `CodexVoiceApp`

Owns menu-bar lifecycle, settings, permissions, launch-at-login behavior, and
the non-activating overlay. The Dock icon remains hidden during normal use.

### `ConversationCoordinator`

Implements an explicit state machine:

```text
idle
  -> listening
  -> transcribing
  -> waitingForCodex
  -> speaking
  -> listening

Any state -> failed -> listening or idle
Any active state -> ending -> idle
waitingForCodex -> awaitingApproval -> waitingForCodex
speaking + detected user speech -> listening
```

Only the coordinator may start or end audio capture, submit a Codex turn, or
start speech synthesis. State transitions are serialized on the main actor.

### `AudioCapture`

Uses `AVAudioEngine` with the current macOS default input. It follows live device
changes instead of pinning a stale device. It produces normalized mono frames
for transcription and voice activity detection.

The implementation reuses the behavior and tests proven in Murmr where they can
be extracted without coupling the two executable applications. The first shared
surface is deliberately small: input-device policy, audio frames, level
metering, and media ducking.

### `VoiceActivityDetector`

Uses energy thresholds plus minimum speech and trailing-silence windows. It must
not submit empty, sub-minimum, or synthesis-echo utterances. Thresholds are
deterministic and unit tested.

### `AppleSpeechTranscriber`

Uses Apple's installed local speech assets. Partial text is displayed only in
the volatile overlay. Only finalized text is sent to Codex. The MVP does not
retain recordings or partial transcripts.

### `CodexAppServerClient`

Responsibilities:

- Launch and monitor the app-server child process.
- Perform `initialize` and `initialized` handshakes.
- Correlate request IDs with responses.
- Decode notifications independently from responses.
- Expose task list, resume, turn start, steer, interrupt, and approval responses.
- Accumulate `item/agentMessage/delta` into one final assistant message.
- Emit a terminal event only after `turn/completed` arrives.
- Restart safely after a child-process crash without replaying a submitted turn.

Protocol bindings are generated from the installed Codex binary during
development and checked in, so implementation and tests use the schema matching
the supported local Codex version.

### `SpokenResponseFormatter`

The task receives a voice-turn instruction requesting concise spoken prose and
full technical work in files or the task transcript. The formatter removes
Markdown syntax, URLs, code fences, and file paths that should not be spoken.
It does not invent or summarize facts independently.

If the final response is too long, the MVP speaks the first bounded prose
section and says that full details are available in Codex Desktop.

### `AppleSpeechSynthesizer`

Wraps the system speech synthesizer and exposes start, stop, pause, and
completion events. Media volume is captured before microphone or Bluetooth mode
changes, following Murmr's ordering. The selected output follows the macOS
system default.

### `ApprovalPresenter`

Converts app-server approval requests into a compact native card containing:

- Requested action.
- Target command or file operation.
- Why Codex requested it, when available.
- Approve once and deny controls.

Codex Voice may announce that approval is needed, but it does not accept spoken
approval for destructive, external-facing, sensitive, or financially
consequential actions.

## Conversation behavior

### Starting a session

The user selects a task once, then clicks the orb or presses the global hotkey.
Codex Voice confirms the task title visually and starts listening. It does not
read the task history aloud.

### End of utterance

After real speech begins, trailing silence finalizes the utterance. The default
target is natural conversation rather than dictation punctuation. Empty or
low-confidence captures return to listening without contacting Codex.

### While Codex works

The overlay shows tool and turn state without reading raw tool logs. For a long
turn, short predefined status cues may be spoken at bounded intervals. Codex
Voice does not claim completion until `turn/completed` is received.

### Speaking and barge-in

Speech begins only after a final agent message is available. Audio output is
prevented from becoming user input using voice-processing echo cancellation
when supported, plus synthesis-state gating. User speech above the barge-in
threshold stops synthesis immediately and begins a new utterance.

If reliable acoustic echo cancellation is unavailable for the current route,
the app falls back to half-duplex playback and enables interruption through the
global hotkey. The UI must disclose that fallback rather than silently claiming
hands-free barge-in.

### Steering and cancellation

If Codex is still running when a finalized user utterance arrives, the user can
choose between steering the active turn and cancelling it. Local phrases map as
follows:

- `cancel that` -> `turn/interrupt`.
- `stop speaking` -> stop synthesis only.
- `end voice session` -> stop capture and synthesis, leaving the task intact.

Other speech during an active turn defaults to `turn/steer`.

## Error handling

- **Microphone permission denied:** show System Settings guidance and remain
  idle.
- **Speech asset unavailable:** show the missing language/asset and do not send
  audio elsewhere.
- **Codex binary missing:** show every attempted path and a settings control for
  an explicit path.
- **App-server initialization failure:** preserve the selected task, stop audio,
  and offer restart.
- **Malformed protocol line:** log redacted metadata, ignore the line, and keep
  the connection alive when possible.
- **Child process exits:** terminate the current local turn state, do not replay
  the utterance automatically, and tell the user whether Codex completion is
  unknown.
- **Task unavailable or archived:** stop the session and require another task.
- **Turn interrupted:** speak no stale buffered answer and return to listening.
- **Speech synthesis failure:** display the complete text and return to
  listening.

## Privacy and organizational guardrails

- Microphone audio and speech recognition stay on the Mac.
- Audio is held only in memory for the active utterance.
- Codex receives finalized text, not audio.
- The app uses existing Codex authentication and provider configuration.
- No browser cookies, tokens, JWTs, API keys, or Codex credentials are read,
  printed, logged, or copied.
- Logs default to event names, durations, and error categories; transcript and
  response bodies are excluded.
- This is a local speech interface around the approved Codex text protocol. It
  is not represented as a way to bypass organizational policy. Enterprise
  distribution requires the appropriate internal review and client identity.

## Test strategy

### Unit tests

- Conversation state transitions, including illegal-transition rejection.
- Voice activity start, trailing silence, empty audio, and echo rejection.
- JSON-RPC request correlation and notification decoding.
- Incremental assistant-message assembly.
- Markdown and code removal for spoken output.
- Local command recognition and precedence.
- Device-following and media-volume ordering inherited from Murmr behavior.

### Protocol tests

- Launch the installed Codex app-server and complete initialization.
- List tasks and locate a known disposable task.
- Resume and read the disposable task.
- Submit one turn and wait for explicit `turn/completed`.
- Interrupt a running disposable turn.
- Exercise an approval request without approving a destructive action.
- Kill the child process and verify non-replay recovery.

### Installed-app tests

- Build, sign, install, and relaunch the application.
- Verify microphone and Accessibility permission behavior.
- Verify menu-bar and overlay behavior across spaces and displays.
- Verify system-default microphone, speaker, and Bluetooth-route changes.
- Complete a real voice exchange against a disposable local Codex task.
- Confirm the transcript and response appear in Codex Desktop.
- Confirm automatic listen-after-speak behavior.
- Confirm barge-in or the disclosed half-duplex fallback on built-in speakers and
  AirPods.
- Confirm no audio files or transcript-bearing logs are created.

## Acceptance criteria

The MVP is complete only when all of the following are freshly verified:

1. One click or hotkey begins a session with the selected Codex task.
2. A spoken utterance is transcribed locally and submitted without paste or UI
   automation.
3. Codex reaches explicit `turn/completed`; its response appears in Desktop.
4. The response is spoken and the app automatically returns to listening.
5. Interruption stops speech and starts the next user utterance, or the UI
   truthfully exposes the tested half-duplex fallback for that audio route.
6. Approval-required actions pause behind a visible confirmation control.
7. Ending the voice session leaves the Codex task intact and resumable.
8. No command, test, child process, or live Codex turn remains unresolved when
   completion is reported.

## Delivery sequence

1. Prove shared-task read/resume and safe turn ownership with a disposable task.
2. Implement the app-server protocol client and deterministic tests.
3. Implement the conversation state machine with fake audio and Codex clients.
4. Add local capture, Apple Speech, and synthesis.
5. Add overlay, task selection, hotkey, approvals, and route diagnostics.
6. Install and verify the complete live workflow with Codex Desktop.

