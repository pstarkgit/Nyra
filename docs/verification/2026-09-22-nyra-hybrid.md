# Nyra Apple-to-Codex-to-Polly verification

Date: 2026-09-22 (America/Denver)

## Verified

- The runtime binary is wired as `AppleSpeechSession` → `CodexAppServerClient`
  → `PollySpeechSynthesizer`.
- Amazon Transcribe is absent from the Swift package and runtime binary.
- The full Xcode 27 gate passed 81 tests, including focused CoreAudio input,
  sentence accumulation, serial playback, cancellation, and reset coverage.
- A live Swift AWS SDK canary assumed the `nyra-polly` profile and returned its
  first playable Polly Generative PCM chunk in 1820 ms, with 4.361 seconds total.
- The Terra Codex app-server canary returned the exact `NYRA_PROTOCOL_OK` marker
  (`marker: true`) at 6812 ms TTFT and 6955 ms total.
- CloudFormation stack `NyraVoiceRuntime` reached `CREATE_COMPLETE` and created
  only the `NyraPollyRuntime` IAM role.
- The runtime role can describe and synthesize Polly voices in `us-west-2`; a
  negative S3 list probe returned `AccessDenied`.
- Installed Nyra 0.5.0 build 6 is Developer ID signed with hardened runtime and
  its executable matches the packaged build byte-for-byte.
- Direct visual inspection showed `Ready`, Codex connected, Terra, System
  Default microphone active, unchanged output controls, and green permissions.

## Intentionally pending

The microphone-to-speaker acceptance requires Patrick to physically speak and
hear the requested three cycles. No physical voice pass is claimed here.

## Voice selection extension

Nyra exposes a persisted Apple On-Device / AWS Polly provider selector plus
provider-specific voice pickers. The Polly list is loaded from the live
Generative catalog; Apple voices come from the installed macOS catalog. The
installed-app visual check is complete; physical voice acceptance remains
pending.

## Microphone selection extension

- Nyra enumerates only input-capable CoreAudio devices and deduplicates them by
  stable device UID off the main thread.
- Transient internal names or UIDs beginning `CADefaultDeviceAggregate-` are
  filtered while legitimate physical and virtual inputs remain.
- The selected UID and last-known display name persist across launches. Nyra
  resolves and validates that UID when activating the shared `AVAudioEngine`.
- A missing saved device remains selected in preferences while capture falls
  back to the actual System Default input with a visible warning.
- The installed picker rendered System Default with MacBook Pro Microphone
  active; the previous transient process aggregate is excluded by normalization.

## Latency extension

- Complete speakable sentences are extracted across Codex delta boundaries and
  queued before `turnCompleted`; the final fragment flushes at completion.
- The serial speech queue is nonblocking for delta receipt, preserves playback
  order, and prevents listening reset until Codex completion plus speech drain.
- Interruption, explicit cancellation, failed/cancelled status, runtime failure,
  and session end clear queued and in-flight speech without duplicate playback.
- The full untruncated Codex response remains available as the UI transcript.
- This materially advances first audio for multi-sentence replies when sentence
  one completes before the turn. For one-sentence replies whose only sentence
  arrives near completion, the measured 6812 ms Codex TTFT still dominates and
  this change cannot materially reduce that pre-token latency.
- Polly bidirectional streaming returned its first live PCM chunk in 1820 ms
  and completed in 4.361 seconds, compared with 3.62 seconds for the prior
  whole-file CLI request.
- Nyra defaults to Terra for voice conversations while retaining Luna and Sol
  as selectable models.
- End-of-speech trailing silence is 0.60 seconds and the post-playback reset is
  0.60 seconds.
- The installed Codex host advertises native realtime voice support and Maple,
  but direct v1/Maple and v2/Cedar probes both returned `realtime conversation
  requires API key auth`. Native ChatGPT Voice may still work through the
  desktop subscription UI when the workspace exposes **Start voice chat**.

## Nova 2 Sonic natural realtime extension

### Verified live prerequisites

- AWS account identity was rechecked in `us-west-2` through short-lived sandbox
  credentials. `amazon.nova-2-sonic-v1:0` is `ACTIVE`, `ON_DEMAND`, accepts
  speech, emits speech and text, and reports `AUTHORIZED` with agreement,
  entitlement, and region availability all `AVAILABLE`.
- The pinned `aws-sdk-swift` 1.7.71 checkout exposes
  `AWSBedrockRuntime.invokeModelWithBidirectionalStream` and its generated
  bidirectional input/output event types.
- Official Nova 2 documentation was rechecked for ordered input events,
  continuous approximately 32 ms audio frames, 16 kHz mono 16-bit LPCM input,
  24 kHz mono 16-bit LPCM output, `HIGH` endpointing sensitivity, server
  `userSpeechStart`/`INTERRUPTED` barge-in, final transcript stages, and the
  supported voice IDs.

### Bounded Swift canary

- The standalone Swift canary used the pinned SDK and its deterministic 16 kHz
  raw speech fixture in 1,024-byte / 32 ms frames.
- Success required a final recognized user transcript, assistant text, and the
  first nonempty 24 kHz audio chunk. It then sent `promptEnd` and `sessionEnd`,
  finished the input continuation, flushed JSON, and explicitly terminated.
- Final direct-binary run: connection 333.738792 ms, first audio 4,351.052875
  ms, 3,840 audio bytes observed, process exit 0 in 4.37 seconds, no SIGINT, and
  no residual canary process.
- This is first-audio viability evidence only. It is not a claim about complete
  spoken-turn latency.

### Runtime and UI

- `Natural Realtime · Nova 2 Sonic` is the persisted default conversation
  engine and Tiffany is the default supported Sonic voice.
- Natural mode opens one persistent bidirectional stream, keeps one audio
  content container open, continuously sends selected-microphone frames, plays
  response chunks as they arrive, assembles user and assistant transcripts,
  and returns to listening after playback drains.
- Server `userSpeechStart` and `INTERRUPTED` events immediately clear queued and
  in-flight playback. Session and playback generations suppress late events and
  old-turn audio.
- Capture and playback share one `AVAudioEngine`. Voice Processing is enabled on
  its input and output nodes, providing Apple's acoustic echo cancellation,
  noise suppression, and automatic gain control signal path. No claim of zero
  physical echo is made.
- `Codex Agent · Task-aware (slower)` remains selectable with the existing task
  picker, Terra/Luna/Sol choices, visible approvals, and Apple On-Device/AWS
  Polly output controls.

### Tests, release, and installed state

- The final Xcode 27 gate passed 97 tests in 0.496 seconds, including 16 focused
  Nova/default/legacy tests, then completed the production build and all Nyra
  verification checks.
- Installed bundle: `/Applications/Nyra.app`, identifier `dev.starkpat.nyra`,
  version 0.6.0, build 7, arm64, minimum macOS 26.0.
- Installed signature: Developer ID Application Patrick Stark
  (`P2M5LH6CVA`), hardened runtime flag `0x10000`, Apple timestamp 2026-09-22
  13:22:55 America/Denver, valid designated requirement.
- Installed and packaged executable SHA-256 values match:
  `e444426a332b76fea98bb13214ceb95d04752e8f2f51a66e677bc3db9045a463`.
- Direct visual inspection verified Natural Realtime, active MX Brio, Tiffany,
  the echo-control caveat, green Microphone/Hotkey permissions, and Start
  Natural Conversation. A separate persisted-mode restart verified the exact
  legacy label, task picker, Terra, Connected to Codex, Apple/Polly controls,
  and Start Legacy Codex Session. Natural Realtime was restored afterward.

### Deployment and acceptance boundary

- `infra/nyra-nova.yaml` passed CloudFormation `ValidateTemplate`. It grants
  only `bedrock:InvokeModelWithBidirectionalStream` on the exact regional Nova 2
  Sonic foundation-model ARN.
- Infrastructure was not deployed. Operator handoff:
  `NYRA_SOURCE_PROFILE=<mcs-backed-profile> ./Scripts/deploy-nova-runtime.sh`.
- Three real open-speaker microphone-to-Nova-to-speaker cycles, including
  physical echo and interruption assessment, remain intentionally pending.
