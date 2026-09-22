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

    command = [codex_binary]
    if os.environ.get("NYRA_FAST_CONTEXT") == "1":
        command.extend([
            "--disable", "memories",
            "--enable", "skip_host_skill_discovery",
        ])
    elif os.environ.get("NYRA_DISABLE_MEMORIES") == "1":
        command.extend(["--disable", "memories"])
    command.extend(["app-server", "--listen", "stdio://"])
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=0,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    timeout = float(os.environ.get("NYRA_SMOKE_TIMEOUT", "180"))
    deadline = time.monotonic() + timeout
    requested_model = os.environ.get("NYRA_CODEX_MODEL")
    memory_mode = os.environ.get("NYRA_MEMORY_MODE")
    thread_id = None
    turn_id = None
    completed_status = None
    response_text = ""
    turn_started_at = None
    first_delta_at = None
    completed_at = None

    try:
        send(process, {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "nyra_smoke",
                    "title": "Nyra Smoke",
                    "version": "0.4.0",
                },
                "capabilities": {"experimentalApi": True},
            },
        })
        while True:
            message = receive(process, selector, deadline)
            if message.get("id") == 1:
                if "error" in message:
                    fail(f"initialize failed: {message['error'].get('message', 'unknown')}")
                break
            answer_server_request(process, message)
        send(process, {"method": "initialized", "params": {}})

        turn_started_at = time.monotonic()
        thread_params = {"cwd": workspace}
        if requested_model:
            thread_params["model"] = requested_model
        send(process, {
            "id": 2,
            "method": "thread/start",
            "params": thread_params,
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

        if memory_mode:
            send(process, {
                "id": 20,
                "method": "thread/memoryMode/set",
                "params": {"threadId": thread_id, "mode": memory_mode},
            })
            while True:
                message = receive(process, selector, deadline)
                if message.get("id") == 20:
                    if "error" in message:
                        fail(f"memory mode failed: {message['error'].get('message', 'unknown')}")
                    break
                answer_server_request(process, message)

        send(process, {
            "id": 3,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "input": [{
                    "type": "text",
                    "text": "Reply exactly NYRA_PROTOCOL_OK. Do not call tools.",
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
                if first_delta_at is None:
                    first_delta_at = time.monotonic()
                response_text += params.get("delta", "")
            elif method == "turn/completed" and params.get("threadId") == thread_id:
                turn = params.get("turn", {})
                turn_id = turn_id or turn.get("id")
                completed_status = turn.get("status")
                completed_at = time.monotonic()

        marker = "NYRA_PROTOCOL_OK" in response_text
        print(json.dumps({
            "threadId": thread_id,
            "turnId": turn_id,
            "status": completed_status,
            "marker": marker,
            "model": requested_model,
            "memoryMode": memory_mode,
            "ttftMs": round((first_delta_at - turn_started_at) * 1000) if first_delta_at else None,
            "totalMs": round((completed_at - turn_started_at) * 1000) if completed_at else None,
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
