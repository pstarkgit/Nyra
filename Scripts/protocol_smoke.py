#!/usr/bin/env python3
import json
import os
import selectors
import subprocess
import sys
import time


def fail(message):
    raise RuntimeError(message)


def send(process, message):
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def receive(process, selector, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        fail("timed out waiting for Codex app-server")
    if not selector.select(remaining):
        fail("timed out waiting for Codex app-server")
    line = process.stdout.readline()
    if not line:
        fail(f"Codex app-server exited early with status {process.poll()}")
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return {}


def answer_server_request(process, message):
    if "id" not in message or "method" not in message:
        return False
    method = message["method"]
    if method.endswith("/requestApproval"):
        send(process, {"id": message["id"], "result": {"decision": "decline"}})
    elif method == "tool/requestUserInput":
        send(process, {"id": message["id"], "result": {"answers": {}}})
    else:
        send(process, {"id": message["id"], "error": {"code": -32601, "message": "unsupported in smoke test"}})
    return True


def main():
    if len(sys.argv) != 3:
        fail("usage: protocol_smoke.py CODEX_BINARY WORKSPACE")
    codex_binary = os.path.realpath(sys.argv[1])
    workspace = os.path.realpath(sys.argv[2])
    if not os.path.isfile(codex_binary) or not os.access(codex_binary, os.X_OK):
        fail("Codex binary is missing or not executable")

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
    deadline = time.monotonic() + 180
    thread_id = None
    turn_id = None
    completed_status = None
    response_text = ""

    try:
        send(process, {
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {
                "name": "codex_voice_smoke",
                "title": "Codex Voice Smoke",
                "version": "0.1.0",
            }},
        })
        while True:
            message = receive(process, selector, deadline)
            if message.get("id") == 1:
                if "error" in message:
                    fail(f"initialize failed: {message['error'].get('message', 'unknown')}")
                break
            answer_server_request(process, message)
        send(process, {"method": "initialized", "params": {}})

        send(process, {
            "id": 2,
            "method": "thread/start",
            "params": {"cwd": workspace},
        })
        while thread_id is None:
            message = receive(process, selector, deadline)
            if message.get("id") == 2:
                if "error" in message:
                    fail(f"thread/start failed: {message['error'].get('message', 'unknown')}")
                thread_id = message.get("result", {}).get("thread", {}).get("id")
                if not thread_id:
                    fail("thread/start returned no thread id")
            else:
                answer_server_request(process, message)

        send(process, {
            "id": 3,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "input": [{
                    "type": "text",
                    "text": "Reply exactly CODEX_VOICE_PROTOCOL_OK. Do not call tools.",
                }],
            },
        })

        while completed_status is None:
            message = receive(process, selector, deadline)
            if answer_server_request(process, message):
                continue
            if message.get("id") == 3:
                if "error" in message:
                    fail(f"turn/start failed: {message['error'].get('message', 'unknown')}")
                turn_id = message.get("result", {}).get("turn", {}).get("id")
            method = message.get("method")
            params = message.get("params", {})
            if method == "item/agentMessage/delta" and params.get("threadId") == thread_id:
                response_text += params.get("delta", "")
            elif method == "turn/completed" and params.get("threadId") == thread_id:
                turn = params.get("turn", {})
                turn_id = turn_id or turn.get("id")
                completed_status = turn.get("status")

        marker = "CODEX_VOICE_PROTOCOL_OK" in response_text
        print(json.dumps({
            "threadId": thread_id,
            "turnId": turn_id,
            "status": completed_status,
            "marker": marker,
        }, separators=(",", ":")))
        if completed_status != "completed" or not marker:
            fail("Codex turn did not complete with the expected marker")
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
        print(f"protocol smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
