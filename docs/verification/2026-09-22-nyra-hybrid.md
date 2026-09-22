# Nyra Apple-to-Codex-to-Polly verification

Date: 2026-09-22 (America/Denver)

## Verified

- The runtime binary is wired as `AppleSpeechSession` → `CodexAppServerClient`
  → `PollySpeechSynthesizer`.
- Amazon Transcribe is absent from the Swift package and runtime binary.
- The full Xcode 27 gate passed 61 tests, including Polly fallback and
  stop-during-synthesis cancellation coverage.
- A live Swift AWS SDK canary assumed the `nyra-polly` profile and returned
  playable Polly Generative audio in 2.260 seconds.
- The Codex app-server smoke completed with the exact `NYRA_PROTOCOL_OK` marker.
- CloudFormation stack `NyraVoiceRuntime` reached `CREATE_COMPLETE` and created
  only the `NyraPollyRuntime` IAM role.
- The runtime role can describe and synthesize Polly voices in `us-west-2`; a
  negative S3 list probe returned `AccessDenied`.
- `/Applications/Nyra.app` is Developer ID signed with hardened runtime and its
  executable matches the packaged build byte-for-byte.
- The installed menu-bar UI rendered `Connected to Codex` and
  `AWS Polly Generative · Danielle`.

## Intentionally pending

The microphone-to-speaker acceptance requires Patrick to grant microphone
permission to the new `dev.starkpat.nyra` bundle identity and physically speak
and hear the requested three cycles. No physical voice pass is claimed here.

## Voice selection extension

Nyra now exposes a persisted Apple On-Device / AWS Polly provider selector plus
provider-specific voice pickers. The Polly list is loaded from the live
Generative catalog; Apple voices come from the installed macOS catalog. This
extension requires a fresh installed-app visual check and physical voice
acceptance before it is considered complete.
