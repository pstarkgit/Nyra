#!/usr/bin/env python3
import base64
import json
import os
import selectors
import subprocess
import sys
import time

from protocol_smoke import answer_server_request, fail, receive, send


def wait_for_response(process, selector, deadline, request_id):
    while True:
        message = receive(process, selector, deadline)
        if message.get("id") == request_id:
            if "error" in message:
                error = message["error"]
                fail(f"request {request_id} failed: {error.get('message', 'unknown')}")
            return message.get("result", {})
        answer_server_request(process, message)


def main():
    if len(sys.argv) != 3:
        fail("usage: realtime-smoke.py CODEX_BINARY WORKSPACE")
    codex_binary = os.path.realpath(sys.argv[1])
    workspace = os.path.realpath(sys.argv[2])
    process = subprocess.Popen(
        [codex_binary, "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=0,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 90
    realtime_version = os.environ.get("NYRA_REALTIME_VERSION", "v1")
    realtime_voice = os.environ.get("NYRA_REALTIME_VOICE", "maple")

    try:
        send(process, {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "nyra_realtime_smoke",
                    "title": "Nyra Realtime Smoke",
                    "version": "0.4.0",
                },
                "capabilities": {"experimentalApi": True},
            },
        })
        wait_for_response(process, selector, deadline, 1)
        send(process, {"method": "initialized", "params": {}})

        send(process, {
            "id": 2,
            "method": "thread/realtime/listVoices",
            "params": {},
        })
        voices_result = wait_for_response(process, selector, deadline, 2)
        voices = voices_result.get("voices", {})
        all_voices = set(voices.get("v1", [])) | set(voices.get("v2", []))
        if realtime_voice not in all_voices:
            fail(f"Codex realtime did not advertise the {realtime_voice} voice")

        send(process, {
            "id": 3,
            "method": "thread/start",
            "params": {"cwd": workspace},
        })
        thread_result = wait_for_response(process, selector, deadline, 3)
        thread_id = thread_result.get("thread", {}).get("id")
        if not thread_id:
            fail("thread/start returned no thread id")

        started_at = time.monotonic()
        send(process, {
            "id": 4,
            "method": "thread/realtime/start",
            "params": {
                "threadId": thread_id,
                "outputModality": "audio",
                "version": realtime_version,
                "voice": realtime_voice,
                "transport": {"type": "websocket"},
                "includeStartupContext": False,
                "prompt": "Reply briefly and naturally. Do not call tools.",
            },
        })

        start_response_received = False
        realtime_started = False
        append_sent = False
        first_audio_at = None
        audio_bytes = 0
        sample_rate = None
        channels = None
        assistant_text = ""

        while True:
            message = receive(process, selector, deadline)
            if answer_server_request(process, message):
                continue
            if message.get("id") == 4:
                if "error" in message:
                    fail(f"realtime start failed: {message['error'].get('message', 'unknown')}")
                start_response_received = True

            method = message.get("method")
            params = message.get("params", {})
            if method == "thread/realtime/started" and params.get("threadId") == thread_id:
                realtime_started = True

            if start_response_received and realtime_started and not append_sent:
                send(process, {
                    "id": 5,
                    "method": "thread/realtime/appendText",
                    "params": {
                        "threadId": thread_id,
                        "role": "user",
                        "text": "Reply exactly: native voice probe successful.",
                    },
                })
                append_sent = True

            if method == "thread/realtime/outputAudio/delta" and params.get("threadId") == thread_id:
                audio = params.get("audio", {})
                if first_audio_at is None:
                    first_audio_at = time.monotonic()
                audio_bytes += len(base64.b64decode(audio.get("data", "")))
                sample_rate = audio.get("sampleRate", sample_rate)
                channels = audio.get("numChannels", channels)
            elif method == "thread/realtime/transcript/done" and params.get("threadId") == thread_id:
                if params.get("role") == "assistant":
                    assistant_text += params.get("text", "")
                    if audio_bytes > 0:
                        break
            elif method == "thread/realtime/error" and params.get("threadId") == thread_id:
                fail(f"realtime error: {params.get('message', 'unknown')}")

        send(process, {
            "id": 6,
            "method": "thread/realtime/stop",
            "params": {"threadId": thread_id},
        })
        wait_for_response(process, selector, deadline, 6)

        print(json.dumps({
            "threadId": thread_id,
            "voice": realtime_voice,
            "version": realtime_version,
            "audioBytes": audio_bytes,
            "sampleRate": sample_rate,
            "channels": channels,
            "firstAudioMs": round((first_audio_at - started_at) * 1000),
            "assistantText": assistant_text,
        }, separators=(",", ":")))
    finally:
        try:
            process.stdin.close()
        except Exception:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"realtime smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
