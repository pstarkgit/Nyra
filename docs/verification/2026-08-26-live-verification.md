# Codex Voice Live Verification — 2026-08-26

## Verified

- `./test.sh`: 52 tests passed; release build, plist, signature, bundle, privacy,
  credential-access, and child-process checks passed.
- Installed bundle: `/Applications/Codex Voice.app`.
- Bundle identifier: `dev.starkpat.codexvoice`.
- Signing: Developer ID Application: Patrick Stark (`P2M5LH6CVA`), hardened
  runtime, Apple timestamp, valid authority chain.
- UI: macOS status item reports `Codex Voice: Ready`; menu reports
  `Connected to Codex` and lists persisted Desktop tasks.
- Permissions: System Settings shows Codex Voice enabled for Microphone and
  Accessibility.
- Audio route: built-in MacBook Pro microphone and speakers follow the macOS
  system defaults; a session reached the live `Listening` state.
- Protocol: `Scripts/protocol-smoke.sh` generated the installed app-server
  schema, created a disposable task, received streamed agent output, and waited
  for explicit `turn/completed`.
- Final protocol evidence: thread `01a041b2-af76-7943-a009-8b3dc82d4cfe`, turn
  `01a041b2-b1b9-7022-b676-ff588782ba8b`, status `completed`, response marker
  `CODEX_VOICE_PROTOCOL_OK`; Codex Desktop readback confirmed the same task and
  final response. The disposable task was archived afterward.
- Process closure: no protocol-smoke or fake app-server processes remained.
- Branding: the canonical seven-bar Murmr signal is rendered inside a dark
  glass voice orb and packaged as `Resources/AppIcon.icns`.

## Tested fallback

Playback is intentionally half-duplex. Right Option stops speech and can open a
steering utterance while a Codex turn is active. Synthetic `say` output was not
accepted as microphone speech because macOS suppresses self-generated speaker
audio; this is expected acoustic echo behavior, not evidence of a failed human
microphone path.
