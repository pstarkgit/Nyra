#!/usr/bin/env python3
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


for raw in sys.stdin:
    try:
        message = json.loads(raw)
    except json.JSONDecodeError:
        continue

    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        send({"id": request_id, "result": {"userAgent": "fake", "codexHome": "/tmp/fake"}})
    elif method == "initialized":
        continue
    elif method == "thread/list":
        send({
            "id": request_id,
            "result": {
                "data": [
                    {
                        "id": "thread-1",
                        "name": "First task",
                        "cwd": "/tmp/one",
                        "updatedAt": 42,
                        "status": {"type": "idle"},
                    },
                    {
                        "id": "thread-2",
                        "preview": "Second task preview",
                        "cwd": "/tmp/two",
                        "updatedAt": 41,
                        "status": {"type": "notLoaded"},
                    },
                ],
                "nextCursor": None,
            },
        })
    elif method == "thread/start":
        send({"id": request_id, "result": {"thread": {"id": "thread-1"}}})
    elif method == "thread/resume":
        send({"id": request_id, "result": {"thread": {"id": params.get("threadId")}}})
    elif method == "thread/fork":
        send({"id": request_id, "result": {"thread": {"id": params.get("threadId")}}})
    elif method == "turn/start":
        turn_id = "turn-approval" if any(
            item.get("text") == "approval" for item in params.get("input", [])
        ) else "turn-1"
        send({"id": request_id, "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
        if turn_id == "turn-approval":
            send({
                "id": "approval-1",
                "method": "item/commandExecution/requestApproval",
                "params": {
                    "threadId": params.get("threadId"),
                    "turnId": turn_id,
                    "itemId": "item-approval",
                    "reason": "Needs access",
                    "command": "echo hello",
                },
            })
        else:
            for delta in ("hello ", "world"):
                send({
                    "method": "item/agentMessage/delta",
                    "params": {
                        "threadId": params.get("threadId"),
                        "turnId": turn_id,
                        "itemId": "item-1",
                        "delta": delta,
                    },
                })
            send({
                "method": "turn/completed",
                "params": {
                    "threadId": params.get("threadId"),
                    "turn": {"id": turn_id, "status": "completed", "items": []},
                },
            })
    elif method == "turn/steer":
        send({"id": request_id, "result": {"turnId": params.get("turnId", "turn-1")}})
    elif method == "turn/interrupt":
        send({"id": request_id, "result": {}})
        send({
            "method": "turn/completed",
            "params": {
                "threadId": params.get("threadId"),
                "turn": {"id": params.get("turnId"), "status": "interrupted", "items": []},
            },
        })
    elif request_id == "approval-1" and "result" in message:
        send({
            "method": "turn/completed",
            "params": {
                "threadId": "thread-1",
                "turn": {"id": "turn-approval", "status": "completed", "items": []},
            },
        })
    elif request_id is not None:
        send({"id": request_id, "error": {"code": -32601, "message": "unknown method"}})
