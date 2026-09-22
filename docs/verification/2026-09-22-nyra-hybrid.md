# Nyra Apple-to-Codex-to-Polly verification

Date: 2026-09-22 (America/Denver)

## Verified

- The runtime binary is wired as `AppleSpeechSession` → `CodexAppServerClient`
  → `PollySpeechSynthesizer`.
- Amazon Transcribe is absent from the Swift package and runtime binary.
- The full Xcode 27 gate passed 70 tests, including five focused CoreAudio
  input-device tests plus Polly fallback and stop-during-synthesis coverage.
- A live Swift AWS SDK canary assumed the `nyra-polly` profile and returned its
  first playable Polly Generative PCM chunk in 1820 ms, with 4.361 seconds total.
- The Terra Codex app-server canary returned the exact `NYRA_PROTOCOL_OK` marker
  (`marker: true`) at 6812 ms TTFT and 6955 ms total.
- CloudFormation stack `NyraVoiceRuntime` reached `CREATE_COMPLETE` and created
  only the `NyraPollyRuntime` IAM role.
- The runtime role can describe and synthesize Polly voices in `us-west-2`; a
  negative S3 list probe returned `AccessDenied`.
- Installed Nyra 0.4.1 build 5 is Developer ID signed with hardened runtime.
- The installed menu-bar UI rendered `Ready` with Codex connected, Terra, the
  unchanged output voice controls, and green microphone and hotkey permissions.

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
- The selected UID and last-known display name persist across launches. Nyra
  resolves and validates that UID when activating the shared `AVAudioEngine`.
- A missing saved device remains selected in preferences while capture falls
  back to the actual System Default input with a visible warning.
- The installed picker rendered System Default plus five current physical or
  virtual inputs. Its green status showed `Active: MacBook Pro Microphone ·
  System Default`, and its refresh action was visible.

## Latency extension

- Polly bidirectional streaming returned its first live PCM chunk in 1820 ms
  and completed in 4.361 seconds, compared with 3.62 seconds for the prior
  whole-file CLI request.
- Nyra now defaults to Terra for voice conversations while retaining Luna and
  Sol as selectable models.
- End-of-speech trailing silence is 0.60 seconds and the post-playback reset is
  0.60 seconds.
- The installed Codex host advertises native realtime voice support and Maple,
  but direct v1/Maple and v2/Cedar probes both returned `realtime conversation
  requires API key auth`. Native ChatGPT Voice may still work through the
  desktop subscription UI when the workspace exposes **Start voice chat**.
