#!/usr/bin/env python3
"""
Vibe Notch — Codex CLI hook
- Sends Codex session state to Vibe Notch via the shared Unix socket.
- For PermissionRequest: blocks waiting for the user's allow/deny decision.

Events are tagged agent="codex" so the app routes them to the Codex code path
and never confuses a Codex session with a Claude Code one.
"""
import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = "/tmp/claude-island.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


def get_tty():
    """Get the TTY of the Codex process (parent)."""
    ppid = os.getppid()
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty not in ("??", "-"):
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    for stream in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(stream.fileno())
        except (OSError, AttributeError):
            pass
    return None


def send_event(state):
    """Send event to the app; return the decoded response for permission events."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()
        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def stringify(value):
    """Flatten a tool_response / message value to a string for the app."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value, ensure_ascii=False)
    except (TypeError, ValueError):
        return str(value)


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    event = data.get("hook_event_name", "")
    tool_input = data.get("tool_input", {})

    state = {
        "session_id": data.get("session_id", "unknown"),
        "cwd": data.get("cwd", ""),
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "agent": "codex",
    }

    if event == "SessionStart":
        state["status"] = "waiting_for_input"

    elif event == "UserPromptSubmit":
        # User sent a message — Codex is now processing.
        state["status"] = "processing"
        prompt = data.get("prompt")
        if prompt:
            state["message"] = prompt

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            # Cached app-side to correlate with the PermissionRequest below.
            state["tool_use_id"] = tool_use_id

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id
        response = stringify(data.get("tool_response"))
        if response:
            state["message"] = response

    elif event == "PermissionRequest":
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id is resolved app-side from the PreToolUse cache.

        decision_response = send_event(state)
        if decision_response:
            decision = decision_response.get("decision", "ask")
            reason = decision_response.get("reason", "")

            if decision == "allow":
                print(json.dumps({
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }))
                sys.exit(0)

            elif decision == "deny":
                print(json.dumps({
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via Vibe Notch",
                        },
                    }
                }))
                sys.exit(0)

        # No response or "ask" — let Codex run its normal approval flow.
        sys.exit(0)

    elif event == "Stop":
        state["status"] = "waiting_for_input"
        last_message = data.get("last_assistant_message")
        if last_message:
            state["message"] = last_message

    else:
        state["status"] = "unknown"

    # Fire-and-forget for non-permission events.
    send_event(state)


if __name__ == "__main__":
    main()
