#!/usr/bin/env python3
"""Opt-in, host-isolated first slice: restore -> clone -> real GUI -> evidence.

Not imported by Macarchy, ordinary tests, or CI. Run with the adjacent uv lock.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import math
import re
import select
import secrets
import signal
import stat
import subprocess
import sys
import tarfile
import time
from urllib.parse import urlsplit
import uuid


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
STATE = ROOT / "artifacts" / "vm"
BASE = "installer-base"


class LabError(Exception):
    pass


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def lab_environment(state=STATE, source=None):
    env = dict(os.environ if source is None else source)
    for key in list(env):
        if key.startswith(("TART_", "OTEL_")) or key in (
            "TRACEPARENT", "TRACESTATE", "SSH_AUTH_SOCK"
        ):
            del env[key]
    env.update(TART_HOME=str(state / "tart"), TART_NO_AUTO_PRUNE="1", CI="true")
    return env


def initialize():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise LabError("The VM lab requires an Apple Silicon Mac.")
    os.umask(0o077)
    for path in (STATE.parent, STATE):
        if path.is_symlink():
            raise LabError(f"Lab storage must not be a symlink: {path}")
        path.mkdir(exist_ok=True)
    STATE.chmod(0o700)
    return json.loads((HERE / "inputs.json").read_text())


def binary(inputs):
    return STATE / "tools" / f"tart-{inputs['tart']['version']}" / "tart.app/Contents/MacOS/tart"


def run_tart(inputs, *args, **kwargs):
    return subprocess.run(
        [str(binary(inputs)), *args], env=lab_environment(), check=True, **kwargs
    )


def verify_hash(path, expected):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise LabError(f"SHA-256 mismatch: {path.name}; refusing to use it.")


def download(url, path, sha256):
    if not path.exists():
        partial = path.with_suffix(path.suffix + ".partial")
        subprocess.run([
            "/usr/bin/curl", "--fail", "--location", "--retry", "2",
            "--output", str(partial), url,
        ], check=True)
        verify_hash(partial, sha256)
        partial.rename(path)
    else:
        verify_hash(path, sha256)


def prepare(inputs):
    downloads = STATE / "downloads"
    downloads.mkdir(exist_ok=True)
    tart = inputs["tart"]
    archive = downloads / f"tart-{tart['version']}.tar.gz"
    download(tart["url"], archive, tart["sha256"])
    destination = binary(inputs).parents[3]
    if not destination.exists():
        destination.mkdir(parents=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter="data")
    app = binary(inputs).parents[2]
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)], check=True)
    check_version(inputs)
    macos = inputs["macos"]
    download(macos["url"], downloads / Path(urlsplit(macos["url"]).path).name, macos["sha256"])
    write_json(STATE / "prepared.json", inputs)
    print("Pinned Tart and Apple installer verified; no VM has been started.")


def check_version(inputs):
    actual = run_tart(inputs, "--version", capture_output=True, text=True, timeout=10).stdout.strip()
    if actual != inputs["tart"]["version"]:
        raise LabError("Tart version differs from inputs.json; run prepare.")


def require_stopped(inputs, name):
    info = json.loads(run_tart(inputs, "get", name, "--format", "json",
                               capture_output=True, text=True, timeout=10).stdout)
    if info["State"] != "stopped":
        raise LabError(f"VM {name} must be stopped before baseline use; never clone live state.")
    return info


def ensure_base(inputs, log):
    prepared = STATE / "prepared.json"
    if not prepared.exists() or json.loads(prepared.read_text()) != inputs:
        raise LabError("Inputs have not been prepared; run prepare explicitly first.")
    check_version(inputs)
    receipt = STATE / "baseline.json"
    path = STATE / "tart/vms" / BASE
    if path.exists():
        if not receipt.exists() or json.loads(receipt.read_text()) != inputs:
            raise LabError("Baseline is incomplete or has different inputs; inspect it before retrying.")
        require_stopped(inputs, BASE)
        return
    ipsw = STATE / "downloads" / Path(urlsplit(inputs["macos"]["url"]).path).name
    print("Restoring the pinned installer into a clean baseline (this can take several minutes).", flush=True)
    run_tart(inputs, "create", BASE, "--from-ipsw", str(ipsw), "--disk-size",
             str(inputs["machine"]["disk_gb"]), stdout=log, stderr=log, timeout=1800)
    machine = inputs["machine"]
    run_tart(inputs, "set", BASE, "--cpu", str(machine["cpu"]), "--memory",
             str(machine["memory_mb"]), "--display", machine["display"],
             "--no-display-refit", stdout=log, stderr=log, timeout=30)
    write_json(receipt, inputs)


def audit_no_listener(pid):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
        capture_output=True, text=True, timeout=10,
    )
    # lsof returns 1 with no output when the process has no matching sockets.
    if result.returncode != 1 or result.stdout or result.stderr:
        raise LabError("Unexpected TCP listener or failed inspection; refusing GUI interaction.")


def build_controller():
    helper = STATE / "tools/window-control"
    helper.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/xcrun", "swiftc", str(HERE / "window-control.swift"),
                    "-o", str(helper)], check=True, timeout=120)
    return helper


def control(helper, action, process=None, inputs=None, name=None, payload=None, sensitive=False):
    command = [str(helper), action]
    if process is not None:
        if process.poll() is not None:
            raise LabError("The owned VM exited before GUI control.")
        command += [str(process.pid), str(binary(inputs)), name]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True, timeout=20 if action == "type" else 10)
    if result.returncode == 75 and action == "window":
        return None
    if result.returncode != 0:
        if sensitive:
            raise LabError("Private credential input failed; helper diagnostics withheld.")
        raise LabError(f"Window control failed: {result.stdout.strip() or result.stderr.strip()}")
    return json.loads(result.stdout)


def guest_password(directory, create=True):
    """One disposable credential per run; never put this value in action records."""
    path = directory / "guest-password"
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | (os.O_CREAT if create else 0), 0o600)
    with os.fdopen(descriptor, "r+") as stream:
        metadata = os.fstat(stream.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o077):
            raise LabError("Guest credential must be a private, owned regular file.")
        password = stream.read(101)
        alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        if not password and create:
            password = "".join(secrets.choice(alphabet) for _ in range(24))
            stream.write(password)
        # An explicitly supplied disposable fixture may be short; random is the default.
        if not 4 <= len(password) <= 100 or any(char not in alphabet for char in password):
            raise LabError("Stored guest credential is invalid; refusing to replace it.")
        return password


def write_password(directory, password):
    descriptor = os.open(directory / "guest-password", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(password)


def type_guest_password(helper, process, inputs, run_id, directory):
    # The native helper accepts text only through stdin and never echoes it.
    return control(helper, "type", process, inputs, run_id,
                   {"text": guest_password(directory)}, sensitive=True)


def capture(helper, process, inputs, name, path):
    target = control(helper, "window", process, inputs, name)
    if target is None:
        raise LabError("The exact owned VM window is not ready for capture.")
    if path.exists():
        raise LabError("Refusing to replace an existing screenshot.")
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(target["window_id"]),
                    "-t", "png", str(path)], check=True, timeout=15)
    with path.open("rb") as image:
        if image.read(8) != b"\x89PNG\r\n\x1a\n":
            raise LabError("Native window capture did not produce a PNG.")
    return target


def stop_owned_process(process):
    if process.poll() is not None:
        return "already_exited"
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=20)
        return "stopped"
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
        return "force_stopped_after_timeout"


def validate_action(request):
    if not isinstance(request, dict):
        raise LabError("Session action must be a JSON object.")
    action = request.get("action")
    fields = {"capture": {"action"}, "stop": {"action"},
              "key": {"action", "key"}, "click": {"action", "x", "y"},
              "click-text": {"action", "text"},
              "expect-text": {"action", "text"},
              "type": {"action", "text"},
              "type-secret": {"action", "secret"},
              "wait": {"action", "seconds"}}
    if not isinstance(action, str) or action not in fields or set(request) != fields[action]:
        raise LabError("Unknown action or fields; use only the documented session actions.")
    if action == "type-secret" and request["secret"] != "guest-password":
        raise LabError("Only the run-local guest-password reference is supported.")
    if action == "key" and request["key"] not in (
            "space", "return", "tab", "backtab", "escape", "up", "down", "left", "right",
            "keyboard-navigation", "spotlight"):
        raise LabError("Unsupported key; no arbitrary host shortcuts.")
    if action == "click" and any(
            type(request[key]) not in (int, float) or not math.isfinite(request[key])
            or not 0 < request[key] < 1 for key in ("x", "y")):
        raise LabError("Click coordinates must be finite normalized window coordinates inside (0,1).")
    if action == "wait" and (type(request["seconds"]) is not int or not 1 <= request["seconds"] <= 60):
        raise LabError("Wait must be an integer from 1 through 60 seconds.")
    if action in ("click-text", "expect-text") and (not isinstance(request["text"], str) or not 1 <= len(request["text"]) <= 100):
        raise LabError("Text anchor must have 1 through 100 characters.")
    if action == "type" and (not isinstance(request["text"], str) or not 1 <= len(request["text"]) <= 100
                             or any(char not in "abcdefghijklmnopqrstuvwxyz0123456789 " for char in request["text"])):
        raise LabError("Public typing supports only 1–100 lowercase US letters, digits and spaces; never use it for secrets.")
    return action


def settle_window(helper, process, inputs, run_id):
    """Bounded window readiness without activation or a retry of guest input."""
    previous = None
    stable = 0
    for _ in range(25):
        current = control(helper, "window", process, inputs, run_id)
        stable = stable + 1 if current is not None and current == previous else 0
        if stable == 3:
            return
        previous = current
        time.sleep(0.2)
    raise LabError("VM window did not settle within 5 seconds; no focus change attempted.")


def checked_capture(helper, process, inputs, run_id, path):
    target = capture(helper, process, inputs, run_id, path)
    current = control(helper, "window", process, inputs, run_id)
    if current is None or any(current[key] != target[key] for key in ("bounds", "window_id")):
        raise LabError("Window changed during capture; screenshot coordinates are not trustworthy.")
    return target


def text_anchor(helper, path, text):
    result = subprocess.run([str(helper), "text", str(path)], check=True,
                            capture_output=True, text=True, timeout=20)
    # Vision scores are observations, not calibrated probabilities. Require an exact,
    # unique label and retain its score; screenshots still require visual review.
    matches = [line for line in json.loads(result.stdout)["lines"] if line["text"] == text]
    if len(matches) > 1:
        raise LabError("Text anchor is ambiguous; refusing to choose a click target.")
    return matches[0] if matches else None


def session(helper, process, inputs, run_id, directory, report):
    """One owned process, line-oriented actions; EOF/error always returns to shutdown."""
    report["actions"] = []
    target = None
    settle_window(helper, process, inputs, run_id)
    print(json.dumps({"ready": run_id, "evidence": str(directory),
                      "actions": ["capture", "key", "type", "type-secret", "click", "click-text", "expect-text", "wait", "stop"]}), flush=True)
    while True:
        # Leave time for visual inspection/user takeover, but don't orphan an idle guest.
        if not select.select([sys.stdin], [], [], 600)[0]:
            raise LabError("Session idle for 10 minutes; stopping the owned guest.")
        line = sys.stdin.readline(4096)
        if not line:
            return
        try:
            request = json.loads(line)
        except ValueError:
            raise LabError("Invalid session JSON; stopping rather than guessing input.") from None
        action = validate_action(request)
        if action == "stop":
            return
        report["pending_action"] = request
        write_json(directory / "report.json", report)
        audit_no_listener(process.pid)
        anchor = None
        if action in ("click-text", "expect-text"):
            deadline = time.monotonic() + 60
            attempt = 0
            while time.monotonic() < deadline:
                attempt += 1
                path = directory / f"{len(report['actions']) + 1:03d}-anchor-{attempt:02d}.png"
                target = checked_capture(helper, process, inputs, run_id, path)
                anchor = text_anchor(helper, path, request["text"])
                if anchor is not None:
                    break
                time.sleep(2)
            if anchor is None:
                raise LabError("Expected guest text did not appear within 60 seconds; no click sent.")
        if action in ("click", "click-text"):
            if target is None:
                raise LabError("Capture and inspect the window before clicking.")
            point = anchor if anchor is not None else request
            control(helper, "click", process, inputs, run_id, {
                "x": point["x"], "y": point["y"],
                "bounds": target["bounds"], "window_id": target["window_id"],
            })
        elif action == "key":
            control(helper, action, process, inputs, run_id, {"key": request["key"]})
        elif action == "type":
            control(helper, action, process, inputs, run_id, {"text": request["text"]})
        elif action == "type-secret":
            if target is None:
                raise LabError("Capture and inspect the secure guest field before credential input.")
            current = control(helper, "window", process, inputs, run_id)
            if current is None or any(current[key] != target[key] for key in ("bounds", "window_id")):
                raise LabError("Window changed since secure-field inspection; no credential sent.")
            type_guest_password(helper, process, inputs, run_id, directory)
        elif action == "wait":
            time.sleep(request["seconds"])
        if action != "capture":
            time.sleep(2)
        path = directory / f"{len(report['actions']) + 1:03d}-{action}.png"
        target = checked_capture(helper, process, inputs, run_id, path)
        report["actions"].append({**request, "screenshot": path.name, "window": target,
                                  "anchor": anchor})
        del report["pending_action"]
        write_json(directory / "report.json", report)
        print(json.dumps({"screenshot": str(path), "window": target}), flush=True)


def probe(inputs, interactive=False, baseline="installer"):
    run_id = ("setup-" if interactive else "window-") + uuid.uuid4().hex[:12]
    directory = STATE / "runs" / run_id
    directory.mkdir(parents=True)
    report = {
        "run": run_id, "status": "in_progress", "inputs": inputs,
        "host": platform.mac_ver()[0], "scope": "guest setup session" if interactive else "installer GUI control only",
        "transport": "native-window", "baseline": baseline,
        "unqualified": ["SSH", "guest reboot", "Macarchy setup", "dotfiles", "first-use permissions"],
    }
    process = None
    try:
        helper = build_controller()
        report["permissions"] = control(helper, "preflight")
        if not all(report["permissions"].values()):
            raise LabError("Host Accessibility and Screen Recording approval required; no VM started, no prompt requested.")
        with (directory / "restore.log").open("w") as restore_log:
            ensure_base(inputs, restore_log)
            source = BASE
            run_tart(inputs, "clone", source, run_id, stdout=restore_log, stderr=restore_log, timeout=120)
        log_path = directory / "tart.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(
                [str(binary(inputs)), "run", run_id,
                 "--no-clipboard", "--no-audio"],
                env=lab_environment(), stdout=log, stderr=log,
            )
            deadline = time.monotonic() + 60
            target = None
            while time.monotonic() < deadline and process.poll() is None:
                target = control(helper, "window", process, inputs, run_id)
                if target:
                    break
                time.sleep(0.2)
            if not target:
                raise LabError("No unique owned VM window within 60s; inspect the local Tart log.")
            audit_no_listener(process.pid)
            report["tcp_listeners"] = "none"
            time.sleep(60)
            if interactive:
                session(helper, process, inputs, run_id, directory, report)
            else:
                report["window"] = capture(helper, process, inputs, run_id, directory / "01-before.png")
                control(helper, "space", process, inputs, run_id)
                time.sleep(5)
                capture(helper, process, inputs, run_id, directory / "02-after-space.png")
            report["status"] = "requires_visual_review"
            report["note"] = "Input was sent; inspect screenshots to establish its actual effect."
    except KeyboardInterrupt:
        report["status"] = "interrupted"
    except (LabError, OSError, subprocess.SubprocessError, TimeoutError) as error:
        report["status"] = "blocked"
        # Unknown subprocess failures remain explicit; raw diagnostics stay local.
        report["reason"] = str(error) if isinstance(error, LabError) else type(error).__name__
    finally:
        if process is not None:
            report["shutdown"] = stop_owned_process(process)
        write_json(directory / "report.json", report)
    print(json.dumps(report, indent=2))
    print(f"Local evidence: {directory}")
    return 0 if report["status"] == "requires_visual_review" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "preflight", "probe", "session"))
    args = parser.parse_args()
    inputs = initialize()
    with (STATE / "lab.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise LabError("Another lab operation is active.") from None
        if args.command == "prepare":
            prepare(inputs)
            return 0
        if args.command == "preflight":
            result = control(build_controller(), "preflight")
            print(json.dumps(result))
            return 0 if all(result.values()) else 1
        return probe(inputs, interactive=args.command == "session")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (LabError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"VM lab blocked: {error}") from None
