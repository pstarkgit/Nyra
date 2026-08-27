# Codex Voice

Codex Voice is a native macOS menu-bar companion for hands-free conversation
with local Codex tasks. It captures and recognizes speech on the Mac, sends only
the finalized text through Codex's documented app-server protocol, speaks the
completed response with an Apple system voice, and automatically listens again.

## Conversation flow

1. Launch **Codex Voice** and choose a task from the menu-bar task picker.
2. Click **Start Voice Session** or press **Right Option**.
3. Speak naturally. Trailing silence ends the utterance.
4. Codex works in the selected persisted task.
5. After explicit turn completion, Codex Voice speaks the result and resumes
   listening.

Playback is currently half-duplex. Press Right Option while Codex is speaking to
stop playback. During an active Codex turn, Right Option opens a steering
utterance. Command and file approvals always require a visible click.

## Privacy boundary

- Apple recognition is forced to on-device mode.
- Audio and partial transcripts are memory-only.
- Codex receives finalized text, never microphone audio.
- Codex Voice delegates authentication to the installed Codex binary and does
  not read credentials, browser sessions, cookies, or tokens.

## Requirements

- macOS 26 or later.
- Codex Desktop installed in `/Applications/ChatGPT.app`, or a supported `codex`
  executable on the local path.
- Microphone, Speech Recognition, and Accessibility permission. Accessibility
  is used only for the global Right Option hotkey, not UI automation.

## Build and run

```bash
./test.sh
./script/build_and_run.sh --verify
```

The Codex desktop Run action is configured in
`.codex/environments/environment.toml` and invokes the same run script.

## Install

```bash
./install.sh
```

The installer builds and verifies an ad-hoc signed bundle, refuses to replace an
unrecognized application, moves a previous owned build to Trash, installs
`/Applications/Codex Voice.app`, and launches it.

## Troubleshooting

- **No tasks:** open Codex Desktop once, then choose **Refresh Tasks**.
- **No listening:** use **Grant or Refresh Permissions** and relaunch after macOS
  records the grant.
- **Hotkey unavailable:** grant Accessibility and press the permission button
  again so the event tap is re-created.
- **No spoken result:** confirm an English Apple system voice is installed. The
  complete response remains in Codex Desktop even if synthesis fails.
