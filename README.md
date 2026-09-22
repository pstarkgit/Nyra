# Nyra

Nyra is a native macOS menu-bar companion with two persisted conversation
engines:

- **Natural Realtime · Nova 2 Sonic** is the default. It opens one persistent
  Amazon Bedrock bidirectional session, continuously streams the selected
  CoreAudio microphone as 16 kHz mono 16-bit LPCM, and plays 24 kHz speech as
  chunks arrive. Nova supplies user and assistant transcripts, server-side turn
  detection, and barge-in.
- **Codex Agent · Task-aware (slower)** preserves the previous Apple
  SpeechAnalyzer → Codex task → Apple/Polly response path. It remains the mode
  for task context, commands, files, and visible approvals.

```text
Natural: microphone ⇄ Nova 2 Sonic ⇄ speakers
Legacy:  microphone → Apple SpeechAnalyzer → Codex → Apple / Polly → speakers
```

Natural mode defaults to the supported Tiffany voice. Its picker contains only
Nova 2 Sonic voice IDs documented by AWS. Legacy mode retains the independent
Apple On-Device / AWS Polly output picker and Terra, Luna, and Sol Codex model
choices.

The microphone picker lists System Default plus currently available physical
and virtual CoreAudio inputs. Nyra persists the selected device by stable UID,
shows the active device, and visibly falls back to System Default if the saved
device disappears.

## Natural realtime behavior

1. Choose **Natural Realtime · Nova 2 Sonic** and a supported Sonic voice.
2. Click **Start Natural Conversation** or press **Right Option**.
3. Speak naturally. The microphone remains open for the persistent session.
4. Nova's server turn detection uses high endpointing sensitivity for responsive
   conversation.
5. User and assistant transcript text remains visible in the menu.
6. Speech is scheduled as 24 kHz LPCM chunks arrive. If the server reports user
   speech or an interrupted output, Nyra immediately stops playback, clears
   queued and in-flight audio, and suppresses late chunks from the old turn.
7. Nyra returns to listening after output drains. End the session explicitly or
   start a new one when the bounded session limit is reached.

Natural audio capture and playback share one `AVAudioEngine` with Voice
Processing enabled. Apple's voice-processing pipeline provides acoustic echo
cancellation, noise suppression, and automatic gain control. This is an
evidence-backed echo guard, not a claim that physical speaker echo is absent.
The required three-cycle open-speaker acceptance remains pending.

## Legacy task-aware behavior

1. Choose **Codex Agent · Task-aware (slower)** and a Codex task.
2. Select Terra, Luna, or Sol and an Apple/Polly output voice.
3. Speak an utterance. Apple on-device recognition finalizes text before Codex
   receives it.
4. Codex works in the selected persisted task. Complete response sentences are
   spoken in order as they stream.
5. Legacy playback is half-duplex. Right Option interrupts output or opens a
   steering utterance while a turn is active. Command and file approvals always
   require a visible click.

## Privacy and access boundary

- Natural mode sends continuous microphone audio to Amazon Nova 2 Sonic only
  while its session is open. Audio remains memory-only in Nyra.
- Natural mode is not connected to Codex credentials, browser sessions, task
  files, commands, or approvals.
- Legacy Apple recognition remains forced to the on-device `SpeechAnalyzer`
  path. Codex receives finalized text, never microphone audio.
- Legacy Polly receives response text only. Apple output sends no speech content
  to AWS.
- Nyra uses separate assumed-role profiles: `nyra-nova` for the exact Nova 2
  Sonic bidirectional action and `nyra-polly` for Polly synthesis.
- No account ID, long-lived credential, browser token, or cookie is stored in
  this repository.

## Requirements

- macOS 26 or later and Xcode 27 for the verified build gate.
- Microphone permission. Accessibility is needed only for the global Right
  Option hotkey.
- A configured `nyra-nova` profile for Natural Realtime.
- Codex Desktop or a supported local `codex` executable for legacy mode.
- A configured `nyra-polly` profile only when legacy AWS Polly output is used.

## Provision runtime access

Each CloudFormation template creates one same-account assumed role and no
standing compute. Set the MCS-backed source profile explicitly.

Nova 2 Sonic:

```bash
NYRA_SOURCE_PROFILE=my-admin-profile ./Scripts/deploy-nova-runtime.sh
```

The Nova role permits only
`bedrock:InvokeModelWithBidirectionalStream` on the exact regional
`amazon.nova-2-sonic-v1:0` foundation-model ARN. The script configures the local
`nyra-nova` profile. Infrastructure is not deployed by the build or installer.

Legacy Polly:

```bash
NYRA_SOURCE_PROFILE=my-admin-profile ./Scripts/deploy-polly-runtime.sh
```

## Bounded live canary

The standalone Swift canary uses the pinned AWS SDK and its deterministic 16 kHz
speech fixture. It succeeds after observing a final user transcript, assistant
text, and the first nonempty 24 kHz audio chunk, then closes the stream and
terminates explicitly. It does not claim full spoken-turn completion latency.

```bash
AWS_CONFIG_FILE=/Users/starkpat/.aws/config \
AWS_PROFILE=your-authorized-profile \
AWS_REGION=us-west-2 \
.build/debug/NovaSonicCanary
```

The verified run connected in 333.74 ms, observed first audio at 4,351.05 ms,
returned 3,840 audio bytes at the bounded success point, and exited zero in 4.37
seconds without SIGINT.

## Build, verify, and install

```bash
./test.sh
./install.sh
```

The installer requires the Developer ID identity, signs with hardened runtime
and timestamping, and installs `/Applications/Nyra.app` alongside any existing
Codex Voice installation.

## Troubleshooting

- **Natural mode fails to connect:** deploy/configure `nyra-nova`, refresh the
  MCS/ADA source profile, and verify the assumed role outside Nyra.
- **No listening:** use **Grant or Refresh Permissions**, then relaunch.
- **Saved microphone missing:** choose another available input or System Default.
- **No Codex tasks in legacy mode:** open Codex Desktop once, then choose
  **Refresh Tasks**.
- **Polly fallback in legacy mode:** refresh the source profile behind
  `nyra-polly`; local Apple speech remains the audible fallback.
