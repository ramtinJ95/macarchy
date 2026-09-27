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
import signal
import subprocess
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
        info = json.loads(run_tart(inputs, "get", BASE, "--format", "json", capture_output=True, text=True).stdout)
        if info["State"] != "stopped":
            raise LabError("The installer baseline must be stopped, never a running test target.")
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


def control(helper, action, process=None, inputs=None, name=None):
    command = [str(helper), action]
    if process is not None:
        if process.poll() is not None:
            raise LabError("The owned VM exited before GUI control.")
        command += [str(process.pid), str(binary(inputs)), name]
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    if result.returncode == 75 and action == "window":
        return None
    if result.returncode != 0:
        raise LabError(f"Window control failed: {result.stdout.strip() or result.stderr.strip()}")
    return json.loads(result.stdout)


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


def probe(inputs):
    run_id = "window-" + uuid.uuid4().hex[:12]
    directory = STATE / "runs" / run_id
    directory.mkdir(parents=True)
    report = {
        "run": run_id, "status": "in_progress", "inputs": inputs,
        "host": platform.mac_ver()[0], "scope": "installer GUI control only",
        "transport": "native-window",
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
            run_tart(inputs, "clone", BASE, run_id, stdout=restore_log, stderr=restore_log, timeout=120)
        log_path = directory / "tart.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(
                [str(binary(inputs)), "run", run_id,
                 "--no-clipboard", "--no-audio", "--no-usb-accessories"],
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
    parser.add_argument("command", choices=("prepare", "preflight", "probe"))
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
        return probe(inputs)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (LabError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"VM lab blocked: {error}") from None
