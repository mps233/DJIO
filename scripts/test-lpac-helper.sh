#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
helper="$project_root/Packaging/Helpers/lpac/lpac"

HELPER="$helper" /usr/bin/python3 <<'PY'
import json
import os
import select
import subprocess
import sys
import time

helper = os.environ["HELPER"]
stdout_buffer = bytearray()


def receive(process, timeout=10):
    deadline = time.monotonic() + timeout
    while True:
        newline = stdout_buffer.find(b"\n")
        if newline >= 0:
            line = bytes(stdout_buffer[:newline])
            del stdout_buffer[: newline + 1]
            return json.loads(line.decode("utf-8"))

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("helper response timed out")
        ready, _, _ = select.select([process.stdout], [], [], remaining)
        if not ready:
            raise RuntimeError("helper response timed out")
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            raise RuntimeError("helper closed stdout unexpectedly")
        stdout_buffer.extend(chunk)


def send(process, payload):
    process.stdin.write((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))
    process.stdin.flush()


version = json.loads(subprocess.check_output([helper, "version"], text=True))
if version["payload"]["data"] != "v2.3.0-djio.1":
    raise RuntimeError(f"unexpected helper version: {version}")

environment = os.environ.copy()
environment.update(
    LPAC_APDU="stdio",
    LPAC_HTTP="curl",
    LPAC_CUSTOM_ES10X_MSS="120",
    DJIO_LPAC_STDIN_REQUEST="1",
)
activation_code = "LPA:1$example.invalid$DJIO-SELF-TEST"
process = subprocess.Popen(
    [helper, "profile", "download"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    bufsize=0,
    env=environment,
)

try:
    command_line = subprocess.check_output(
        ["/bin/ps", "-p", str(process.pid), "-o", "command="], text=True
    )
    if activation_code in command_line:
        raise RuntimeError("activation code leaked into helper process arguments")

    request = receive(process)
    if request.get("type") != "apdu" or request["payload"].get("func") != "connect":
        raise RuntimeError(f"unexpected first request: {request}")
    send(process, {"type": "apdu", "payload": {"ecode": 0}})

    request = receive(process)
    if request.get("type") != "apdu" or request["payload"].get("func") != "logic_channel_open":
        raise RuntimeError(f"unexpected channel request: {request}")
    if request["payload"].get("param", "").lower() != "a0000005591010ffffffff8900000100":
        raise RuntimeError(f"unexpected ISD-R AID: {request}")
    send(process, {"type": "apdu", "payload": {"ecode": 1}})

    request = receive(process)
    if request.get("type") != "djio" or request["payload"].get("func") != "download_request":
        raise RuntimeError(f"private request handshake missing: {request}")
    send(process, {"activationCode": activation_code})

    while True:
        request = receive(process)
        if request.get("type") == "apdu" and request["payload"].get("func") == "transmit":
            break

    process.terminate()
    process.wait(timeout=5)
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)

print("lpac helper self-test passed")
PY
