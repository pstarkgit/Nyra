# Nyra

Nyra is a native macOS menu-bar companion for hands-free conversation with
local Codex tasks. It keeps microphone audio and speech recognition on the Mac,
sends finalized text to Codex through `codex app-server`, and speaks Codex's
completed response with Amazon Polly Generative text-to-speech.

```text
microphone → Apple SpeechAnalyzer → Codex → Polly Generative → speakers
```

Amazon Transcribe is intentionally not part of this architecture. Polly receives
only Codex's response text; it never receives microphone audio or partial
transcripts. If Polly is unavailable, Nyra speaks through the installed local
Apple voice instead of silently dropping the response.

The menu-bar panel lets you switch at any time between **Apple On-Device** and
**AWS Polly** output. Each provider remembers its own selected voice. Nyra loads
the current Polly Generative catalog from AWS and the installed English Apple
voice catalog from macOS. Polly playback uses bidirectional PCM streaming so
audio can begin before the complete waveform is generated.

Nyra also lets you choose the Codex conversation model. Terra is the default
balanced voice model; Luna and Sol remain available for fast or deeper work.

The microphone picker lists System Default plus the Mac's currently available
physical and virtual CoreAudio inputs. Nyra persists a selected device by its
stable CoreAudio UID, shows the actual active microphone, and falls back to the
system default with a visible warning if the saved device disappears.

If **Start voice chat** appears in the ChatGPT desktop task, use that native
GPT-Live experience for the lowest latency and full-duplex interruption. Nyra's
direct Codex realtime probe advertises ChatGPT voices including Maple, but that
API requires OpenAI API-key authentication; a Bedrock-backed Codex session does
not supply it. Nyra therefore remains the no-OpenAI-key fallback.

## Conversation flow

1. Launch **Nyra** and choose a Codex task from the menu-bar picker.
2. Click **Start Voice Session** or press **Right Option**.
3. Speak naturally. Trailing silence ends the utterance.
4. Codex works in the selected persisted task.
5. The selected Apple or Polly voice speaks the result, then Nyra returns to
   listening.

Playback is half-duplex. Right Option interrupts speech. Command and file
approvals always require a visible click.

## Privacy and access boundary

- Apple recognition is forced to the on-device `SpeechAnalyzer` path.
- Audio and partial transcripts are memory-only.
- Codex receives finalized text, never microphone audio.
- Polly receives response text only.
- Nyra uses the `nyra-polly` AWS profile, which assumes the least-privilege
  `NyraPollyRuntime` role through an existing MCS-backed source profile.
- Nyra never reads Codex credentials, browser sessions, cookies, or tokens.

## Requirements

- macOS 26 or later.
- Codex Desktop or a supported local `codex` executable.
- Microphone permission; Accessibility permission is needed only for the global
  Right Option hotkey.
- An MCS-backed AWS source profile with permission to deploy and assume the
  Nyra runtime role.

## Provision Polly access

The CloudFormation stack creates only one IAM role and has no standing compute
cost. Set the source profile explicitly:

```bash
NYRA_SOURCE_PROFILE=my-admin-profile ./Scripts/deploy-polly-runtime.sh
```

The script creates the local `nyra-polly` role profile. No account ID or
credential is stored in this repository.

## Build, verify, and install

```bash
./test.sh
./install.sh
```

The installer signs and installs `/Applications/Nyra.app` alongside any existing
Codex Voice installation.

## Troubleshooting

- **No tasks:** Open Codex Desktop once, then choose **Refresh Tasks**.
- **No listening:** Use **Grant or Refresh Permissions** and relaunch.
- **Hotkey unavailable:** Grant Accessibility; the menu button still works.
- **Polly fallback shown:** Refresh the MCS/ADA source profile and verify
  `aws sts get-caller-identity --profile nyra-polly`.
