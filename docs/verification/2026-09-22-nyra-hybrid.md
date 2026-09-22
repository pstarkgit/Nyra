# Nyra Apple-to-Codex-to-Polly verification

Date: 2026-09-22 (America/Denver)

## Verified

- The runtime binary is wired as `AppleSpeechSession` → `CodexAppServerClient`
  → `PollySpeechSynthesizer`.
- Amazon Transcribe is absent from the Swift package and runtime binary.
- The full Xcode 27 gate passed 65 tests, including Polly fallback and
  stop-during-synthesis cancellation coverage.
- A live Swift AWS SDK canary assumed the `nyra-polly` profile and returned its
  first playable Polly Generative PCM chunk in 1820 ms, with 4.361 seconds total.
- The Terra Codex app-server canary returned the exact `NYRA_PROTOCOL_OK` marker
  (`marker: true`) at 6812 ms TTFT and 6955 ms total.
- CloudFormation stack `NyraVoiceRuntime` reached `CREATE_COMPLETE` and created
  only the `NyraPollyRuntime` IAM role.
- The runtime role can describe and synthesize Polly voices in `us-west-2`; a
  negative S3 list probe returned `AccessDenied`.
- Installed Nyra 0.4.0 build 4 is Developer ID signed with hardened runtime and
  its executable matches the packaged build byte-for-byte.
- The installed menu-bar UI rendered `Ready` with Codex connected, Terra,
  `AWS Polly Generative · Danielle`, and green microphone and hotkey indicators.

## Intentionally pending

The microphone-to-speaker acceptance requires Patrick to physically speak and
hear the requested three cycles. No physical voice pass is claimed here.

## Voice selection extension

Nyra now exposes a persisted Apple On-Device / AWS Polly provider selector plus
provider-specific voice pickers. The Polly list is loaded from the live
Generative catalog; Apple voices come from the installed macOS catalog. The
installed-app visual check is complete; physical voice acceptance remains
pending.

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
