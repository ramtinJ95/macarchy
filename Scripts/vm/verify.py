#!/usr/bin/env python3
"""Drive the current Macarchy source build inside an owned, disposable lab guest.

Developer verification only; see .cursor/skills/verify-macarchy/SKILL.md. Reuses the
lab clone records, pinned Tart, guest SSH boundary and run-tests source snapshot.
Macarchy is built and executed only inside the guest, never on the host. Journeys
are a closed list of CLI paths, not a command executor. Evidence stays under
artifacts/vm/runs/<run>/verify-<session>/ and survives cleanup.
"""

import argparse
import base64
import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import uuid

import guest
import lab

_spec = importlib.util.spec_from_file_location("run_tests", lab.HERE / "run-tests.py")
run_tests = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(run_tests)

GUEST_HOME = "/Users/omarchy"
STATE_ROOT = GUEST_HOME + "/.config/macarchy"
DEVELOPER_DIR = "DEVELOPER_DIR=/Library/Developer/CommandLineTools"
# A clean, user-like environment; update checks and Homebrew auto-update stay off.
STEP_ENV = ("HOME=" + GUEST_HOME, "USER=omarchy", "LOGNAME=omarchy", "LANG=en_US.UTF-8",
            "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "MACARCHY_DISABLE_UPDATE_CHECKS=1", "HOMEBREW_NO_AUTO_UPDATE=1",
            "HOMEBREW_NO_ANALYTICS=1")
# Product-owned locations a read-only journey must not touch. Not a whole-disk audit.
WATCHED = (".config", ".cache", ".local", ".zshrc", ".zprofile", ".zshenv", ".pi", ".codex",
           "Library/LaunchAgents", "Library/Application Support/Macarchy")
WATCHED_LIMIT = 50000  # A fresh guest holds far fewer; more means the snapshot scope is wrong.
# Type, mode, size, inode, mtime, ctime, then the path relative to the guest home.
STAT_FORMAT = "%HT%t%p%t%z%t%i%t%m%t%c%t%N"
NOT_COVERED = ["Homebrew-installed Macarchy or release archive", "guided setup or any apply",
               "theme set --dry-run or activation (fresh-guest preflight refusal not grounded)",
               "keybindings and setup inspection (fresh-guest outcomes not grounded)",
               "GUI menus, viewers or popups", "native permission prompts",
               "network, browser, processes and paths outside the watched roots (not observed)",
               "physical hardware"]
EXIT = {"passed": 0, "ready": 0, "cleaned": 0, "running": 0, "failed": 1, "blocked": 3}


class Blocked(lab.LabError):
    """Precondition, ownership or transport problem: no product verdict was reached."""


class Failed(lab.LabError):
    """The product under test reached a wrong result."""


def now():
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def session_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"verify-[0-9a-f]{12}", value):
        raise Blocked("Session must be the verify-<12 hex> name printed by launch.")
    return value


def guest_directory(session):
    return f"{GUEST_HOME}/macarchy-{session_name(session)}"


def read_pins():
    """Read-only counterpart of lab.initialize for doctor and evidence."""
    if lab.STATE.is_symlink() or not lab.STATE.is_dir():
        raise Blocked("Lab state directory is missing or a symlink.")
    return json.loads((lab.HERE / "inputs.json").read_text())


def test_clone(inputs, run):
    directory = guest.run_directory(run)
    report = json.loads((directory / "report.json").read_text())
    if report.get("inputs") != inputs or report.get("baseline") != "test":
        raise Blocked("Run must be a recorded test-base clone with matching input pins.")
    return directory


def vm_state(inputs, run):
    return json.loads(lab.run_tart(inputs, "get", run, "--format", "json",
                                   capture_output=True, text=True, timeout=10).stdout)["State"]


class RunLock:
    """One verify operation per run: refuses concurrent double-driving."""

    def __init__(self, directory):
        self.path = directory / "verify.lock"

    def __enter__(self):
        self.stream = self.path.open("a")
        try:
            fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.stream.close()
            raise Blocked("Another verify.py operation is driving this run.") from None
        return self

    def __exit__(self, *exception):
        self.stream.close()


def lock_busy(directory):
    path = directory / "verify.lock"
    if not path.exists():  # Never create the lock from a read-only check.
        return False
    with path.open("r") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
    return False


def load_session(directory, session):
    path = directory / session_name(session) / "session.json"
    if path.parent.is_symlink() or not path.is_file():
        raise Blocked("Unknown session for this run; use the name printed by launch.")
    record = json.loads(path.read_text())
    if (record.get("tool"), record.get("session"), record.get("run")) != (
            "verify.py", session, directory.name):
        raise Blocked("Session record belongs to another run or tool; refusing it.")
    return record


def write_askpass(temporary):
    askpass = Path(temporary) / "askpass"
    askpass.write_text("#!/bin/sh\nexec " + shlex.join(
        [sys.executable, str(lab.HERE / "guest.py"), "--askpass"]) + "\n")
    askpass.chmod(0o700)
    return askpass


def require_vm(client):
    # Even a misaddressed connection cannot build or run Macarchy on a physical Mac.
    result = client.command("/usr/sbin/sysctl -n kern.hv_vmm_present", timeout=15)
    if result.stdout.strip() != "1":
        raise Blocked("SSH target is not a virtual machine; refusing to continue.")


def connect(inputs, run, askpass, strict=False):
    client = guest.Guest(inputs, run, askpass)
    if strict:  # Read-only checks never add a host key; launch performs trust on first use.
        client.argv = ["StrictHostKeyChecking=yes" if value == "StrictHostKeyChecking=accept-new"
                       else value for value in client.argv]
    require_vm(client)
    return client


def wait_for_guest(inputs, run, askpass, seconds):
    deadline = time.monotonic() + seconds
    while True:
        try:
            return connect(inputs, run, askpass)
        except Blocked:
            raise
        except (lab.LabError, subprocess.SubprocessError, ValueError, KeyError):
            if time.monotonic() >= deadline:
                raise Blocked(f"Guest SSH not ready within {seconds}s; is the clone running?") from None
            time.sleep(5)


def host_source():
    def git(*arguments):
        return subprocess.run(["git", "--no-optional-locks", "-C", str(lab.ROOT), *arguments],
                              check=True, capture_output=True, text=True, timeout=30).stdout
    return {"head": git("rev-parse", "HEAD").strip(),
            "status_entries": len(git("status", "--porcelain=v1").splitlines())}


def step_command(binary, arguments):
    return f"cd {GUEST_HOME} && " + shlex.join(["/usr/bin/env", "-i", *STEP_ENV, binary, *arguments])


def parse_json(text):
    try:
        value = json.loads(text)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def build_in_guest(client, session, archive, evidence):
    remote = guest_directory(session)
    quoted = shlex.quote(remote)
    client.command(f"umask 077; /bin/mkdir {quoted} && /bin/echo {session} > {quoted}/.verify-owner")
    client.command(f"/usr/bin/base64 -D | /usr/bin/tar -xzf - -C {quoted}",
                   data=base64.b64encode(archive.read_bytes()).decode(), timeout=300)
    build = (f"cd {quoted} && /usr/bin/env {DEVELOPER_DIR} HOMEBREW_NO_ANALYTICS=1 "
             "/usr/bin/swift build --product macarchy")
    started = time.monotonic()
    result = client.command(build, check=False, timeout=2400)
    (evidence / "build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise Failed("Guest build of the current source failed; inspect build.log. No host fallback.")
    seconds = round(time.monotonic() - started)
    output = client.command(build + " --show-bin-path", timeout=300).stdout.strip().splitlines()
    binary = (output[-1] if output else "") + "/macarchy"
    if not binary.startswith(remote + "/.build/"):
        raise Blocked("Guest build reported an unexpected binary location.")
    digest = client.command("/usr/bin/shasum -a 256 " + shlex.quote(binary)).stdout.split()[0]
    version = parse_json(client.command(step_command(binary, ["version", "--json"])).stdout)
    if (not version or version.get("installation") != "development"
            or not str(version.get("version", "")).endswith("-dev")):
        raise Failed("Built binary does not identify itself as a development source build.")
    return {"source": remote, "binary": binary, "binary_sha256": digest, "version": version,
            "configuration": "debug", "build_seconds": seconds, "build_log": "build.log"}


def theme_packages(archive):
    """Expected built-in themes come from the same snapshot the guest built."""
    packages = {}
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            if re.fullmatch(r"Themes/[a-z0-9-]+/theme\.toml", member.name):
                data = tomllib.loads(bundle.extractfile(member).read().decode())
                packages[data["id"]] = {
                    "appearance": data["appearance"], "display_name": data["display_name"],
                    "backgrounds": sorted([item["id"], item["path"]]
                                          for item in data.get("backgrounds", []))}
    if not packages:
        raise Blocked("Source snapshot contains no built-in theme packages.")
    return packages


def theme_steps(packages):
    return ([("version", ["version", "--json"], 60), ("theme-list", ["theme", "list"], 60)]
            + [(f"backgrounds-{theme}", ["theme", "background", "list", theme], 60)
               for theme in sorted(packages)]
            + [("theme-status", ["theme", "status", "--json"], 60)])


# ThemeStatusCommandReport.swift renders exactly this, with exit 1, when no theme is active.
INACTIVE_STATUS = {"schema_version": 1, "operation": "theme_status", "outcome": "inactive",
                   "active": False}


def assess_theme(results, packages):
    failures = []
    lines = results["theme-list"]["stdout"].splitlines()
    rows = [line.split("\t") for line in lines]
    listed = {row[0]: {"appearance": row[1], "display_name": row[2]}
              for row in rows if len(row) == 3}
    expected = {theme: {"appearance": package["appearance"], "display_name": package["display_name"]}
                for theme, package in packages.items()}
    if results["theme-list"]["exit_code"] != 0 or len(listed) != len(lines) or listed != expected:
        failures.append("theme list did not exit 0 with exactly the snapshot built-in themes")
    for theme, package in packages.items():
        result = results[f"backgrounds-{theme}"]
        rows = [line.split("\t") for line in result["stdout"].splitlines()]
        found = sorted([row[0], row[2]] for row in rows if len(row) == 3)
        if result["exit_code"] != 0 or len(found) != len(rows) or found != package["backgrounds"]:
            failures.append(f"background list for {theme} did not exit 0 with its theme.toml entries")
    status = results["theme-status"]
    if status["exit_code"] != 1 or parse_json(status["stdout"]) != INACTIVE_STATUS:
        failures.append("theme status did not exit 1 with exactly the inactive report")
    return failures, {"themes_listed": sorted(listed), "status_exit_code": status["exit_code"]}


# Only journeys whose fresh-guest output is grounded in source. A journey whose path needs
# a prerequisite a fresh guest lacks must report blocked with the reason, never pass.
JOURNEYS = {
    "theme": {
        "steps": theme_steps, "assess": assess_theme,
        "claim": "The guest-built source CLI lists exactly the snapshot built-in themes and their "
                 "declared backgrounds and reports exactly the inactive theme state, without "
                 "creating, deleting or changing anything under the watched guest paths."},
}


def require_session_directory(client, session):
    remote = guest_directory(session)
    owner = client.command(f"/bin/cat {shlex.quote(remote)}/.verify-owner", check=False)
    if owner.returncode or owner.stdout.strip() != session:
        raise Blocked("Guest directory is missing or not owned by this session.")
    return remote


def state_root_present(client):
    code = client.command(f"/bin/test -e {STATE_ROOT} -o -L {STATE_ROOT}", check=False).returncode
    if code not in (0, 1):  # A failed probe is not evidence of absence.
        raise Blocked(f"Could not inspect ~/.config/macarchy in the guest (exit {code}).")
    return code == 0


def snapshot_command():
    """Native, bounded metadata listing of the watched roots; any failed read exits nonzero."""
    roots = " ".join(shlex.quote(path) for path in WATCHED)
    script = (f"cd {GUEST_HOME}; {{ for p in {roots}; do "
              "if [ -e \"$p\" ] || [ -L \"$p\" ]; then /usr/bin/find \"$p\" -exec /usr/bin/stat "
              f"-f {shlex.quote(STAT_FORMAT)} {{}} + || exit 4; fi; done; }} "
              f"| /usr/bin/awk -v limit={WATCHED_LIMIT} \"NR > limit {{ exit 3 }} {{ print }}\"")
    return "/bin/bash -euo pipefail -c " + shlex.quote(script)


def watched_snapshot(client, evidence, name):
    """Map each existing watched path to its metadata; raw output is kept as evidence."""
    try:
        result = client.command(snapshot_command(), check=False, timeout=120)
    except subprocess.TimeoutExpired:
        raise Blocked(f"Watched-path snapshot ({name}) exceeded 120s.") from None
    (evidence / f"watched-{name}.tsv").write_text(result.stdout)
    (evidence / f"watched-{name}.stderr").write_text(result.stderr)
    if result.returncode == 3:
        raise Blocked(f"Watched paths exceed {WATCHED_LIMIT} entries ({name}); not a fresh guest.")
    if result.returncode:
        raise Blocked(f"Watched-path snapshot ({name}) failed with exit {result.returncode}; "
                      f"see watched-{name}.stderr. No side-effect verdict.")
    entries = {}
    for line in result.stdout.splitlines():
        fields = line.split("\t", 6)
        if len(fields) != 7 or fields[6] in entries:
            raise Blocked(f"Unparseable watched-path snapshot line ({name}): {line!r}")
        entries[fields[6]] = fields[:6]
    return entries


def compare_snapshots(before, after):
    return {"created": sorted(after.keys() - before.keys()),
            "deleted": sorted(before.keys() - after.keys()),
            "modified": sorted(path for path in before.keys() & after.keys()
                               if before[path] != after[path])}


def run_journey(client, record, name, session_directory, evidence, report):
    journey = JOURNEYS[name]
    binary = record["guest"]["binary"]
    require_session_directory(client, record["session"])
    digest = client.command("/usr/bin/shasum -a 256 " + shlex.quote(binary),
                            check=False).stdout.split()
    if not digest or digest[0] != record["guest"]["binary_sha256"]:
        raise Blocked("Guest binary differs from the one launch built; launch a new session.")
    require_fresh_state(client)
    packages = theme_packages(session_directory / "source.tar.gz")
    before = watched_snapshot(client, evidence, "before")
    time.sleep(1.1)  # Times are whole seconds: any later write differs from the recorded ones.
    results = {}
    for index, (step, arguments, timeout) in enumerate(journey["steps"](packages), 1):
        entry = {"step": step, "command": shlex.join(["macarchy", *arguments]),
                 "timeout": timeout}
        report["steps"].append(entry)
        started = time.monotonic()
        try:
            result = client.command(step_command(binary, arguments), check=False,
                                    timeout=timeout)
        except subprocess.TimeoutExpired:
            entry["status"] = "timeout"
            raise Blocked(f"Step {step} exceeded {timeout}s and may still run in the guest; "
                          "run cleanup --shutdown before reusing this clone.") from None
        stem = f"{index:02d}-{step}"
        (evidence / f"{stem}.stdout").write_text(result.stdout)
        (evidence / f"{stem}.stderr").write_text(result.stderr)
        entry.update(exit_code=result.returncode, seconds=round(time.monotonic() - started, 2),
                     stdout=stem + ".stdout", stderr=stem + ".stderr")
        results[step] = {"exit_code": result.returncode, "stdout": result.stdout}
    failures, report["observations"] = journey["assess"](results, packages)
    if (results["version"]["exit_code"] != 0
            or parse_json(results["version"]["stdout"]) != record["guest"]["version"]):
        failures.insert(0, "version --json differs from the identity recorded at launch")
    changes = compare_snapshots(before, watched_snapshot(client, evidence, "after"))
    report["side_effects"] = {
        "watched_under_home": list(WATCHED),
        "method": "find + stat (type, mode, size, inode, mtime, ctime) before and after",
        "raw": ["watched-before.tsv", "watched-after.tsv"], "entries_before": len(before),
        **{kind: paths[:200] for kind, paths in changes.items()},
        "state_root_created": ".config/macarchy" in changes["created"]}
    if any(changes.values()):
        failures.append("Read-only journey created, deleted or changed watched guest paths; "
                        "see side_effects.")
    report["failures"] = failures
    return "failed" if failures else "passed"


def next_evidence(session_directory, journey):
    for index in range(1, 100):
        path = session_directory / f"drive-{journey}-{index:02d}"
        try:
            path.mkdir(mode=0o700)
            return path
        except FileExistsError:
            continue
    raise Blocked("Too many drive attempts in this session; launch a new one.")


def process_identity(pid):
    """Start time plus full command line; a reused PID cannot match a recorded identity."""
    result = subprocess.run(["/bin/ps", "-ww", "-o", "lstart=", "-o", "command=", "-p", str(pid)],
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def owned_tart(record):
    """True only for the exact process start recorded by verify.py start."""
    return bool(record.get("identity")) and process_identity(record["pid"]) == record["identity"]


def stop_owned(record):
    if not owned_tart(record):
        return "owned_process_not_running"
    os.kill(record["pid"], signal.SIGINT)  # Tart requests a VM stop on SIGINT, as lab.py does.
    for _ in range(20):
        time.sleep(1)
        if not owned_tart(record):
            return "stopped_owned_process"
    if owned_tart(record):  # Recheck identity immediately before escalating.
        os.kill(record["pid"], signal.SIGKILL)
        time.sleep(2)
    return "owned_process_still_running" if owned_tart(record) else "force_stopped_owned_process"


def start(inputs, run):
    """Thin detached form of the documented native Tart launch; records ownership."""
    directory = test_clone(inputs, run)
    with RunLock(directory):
        path = directory / "verify-tart.json"
        if path.exists():
            raise Blocked("verify.py already started this clone once; clone a fresh run instead.")
        lab.require_stopped(inputs, run)  # Never adopt a VM someone else is running.
        argv = [str(lab.binary(inputs)), "run", run, "--no-clipboard", "--no-audio"]
        with (directory / "verify-tart.log").open("x") as log:
            process = subprocess.Popen(argv, env=lab.lab_environment(), stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True)
        record = {"tool": "verify.py", "run": run, "pid": process.pid, "argv": argv,
                  "identity": None, "log": "verify-tart.log", "started": now(),
                  "status": "starting"}
        try:
            lab.write_json(path, record)
            record["identity"] = process_identity(process.pid)
            lab.write_json(path, record)
            if not record["identity"] or not record["identity"].endswith(" ".join(argv)):
                raise Blocked("Could not record the started Tart process identity.")
            deadline = time.monotonic() + 90
            while vm_state(inputs, run) != "running":
                if process.poll() is not None:
                    record["exit_code"] = process.returncode
                    raise Blocked("Tart exited during startup; inspect verify-tart.log.")
                if time.monotonic() >= deadline:
                    raise Blocked("Tart did not report running within 90s.")
                time.sleep(2)
            lab.audit_no_listener(process.pid)  # Same audit as the lab before guest interaction.
            record.update(tcp_listeners="none", status="running")
            lab.write_json(path, record)
            return record
        except BaseException as error:  # Never leave the owned child running after a failure.
            record["reason"] = describe(error)
            try:
                record["status"] = "stopped_after_failure: " + lab.stop_owned_process(process)
            except BaseException as stop_error:
                record["status"] = "stop_failed: " + describe(stop_error)
            lab.write_json(path, record)
            raise


def launch(inputs, run, wait):
    directory = test_clone(inputs, run)
    with RunLock(directory):
        session = "verify-" + uuid.uuid4().hex[:12]
        evidence = directory / session
        evidence.mkdir(mode=0o700)
        record = {"tool": "verify.py", "session": session, "run": run, "status": "in_progress",
                  "created": now(), "not_covered": NOT_COVERED}
        lab.write_json(evidence / "session.json", record)
        try:
            with tempfile.TemporaryDirectory(prefix="verify-", dir=lab.STATE) as temporary:
                client = wait_for_guest(inputs, run, write_askpass(temporary), wait)
                record["guest_baseline"] = guest_baseline(client, inputs)
                record["host_source"] = host_source()
                archive = evidence / "source.tar.gz"
                record["host_source"]["snapshot_sha256"] = run_tests.snapshot(lab.ROOT, archive)
                record["host_source"]["snapshot_roots"] = list(run_tests.SOURCE_ROOTS)
                record["guest"] = build_in_guest(client, session, archive, evidence)
            record["status"] = "ready"
        except Exception as error:
            record["status"] = "failed" if isinstance(error, Failed) else "blocked"
            record["reason"] = describe(error)
            raise
        finally:
            lab.write_json(evidence / "session.json", record)
            print(json.dumps({"evidence": str(evidence), **record}, indent=2))
        return record


def drive(inputs, run, session, journey):
    directory = test_clone(inputs, run)
    with RunLock(directory):
        record = session_ready(directory, session)
        evidence = next_evidence(directory / session, journey)
        report = {"tool": "verify.py", "run": run, "session": session, "journey": journey,
                  "status": "in_progress", "started": now(), "claim": JOURNEYS[journey]["claim"],
                  "not_covered": NOT_COVERED, "binary_sha256": record["guest"]["binary_sha256"],
                  "snapshot_sha256": record["host_source"]["snapshot_sha256"], "steps": []}
        lab.write_json(evidence / "report.json", report)
        try:
            with tempfile.TemporaryDirectory(prefix="verify-", dir=lab.STATE) as temporary:
                client = connect(inputs, run, write_askpass(temporary))
                report["guest_baseline"] = guest_baseline(client, inputs)
                report["status"] = run_journey(client, record, journey, directory / session,
                                               evidence, report)
        except Exception as error:
            report["status"] = "blocked"
            report["reason"] = describe(error)
        finally:
            report["finished"] = now()
            lab.write_json(evidence / "report.json", report)
            print(json.dumps({"evidence": str(evidence), **report}, indent=2))
        return report


def describe(error):
    return str(error) if isinstance(error, lab.LabError) else type(error).__name__


class Checks:
    def __init__(self):
        self.items = []

    def add(self, name, status, detail):
        self.items.append({"check": name, "status": status, "detail": detail})

    def run(self, name, function, summary=str):
        try:
            value = function()
        except Exception as error:
            self.add(name, "fail", describe(error))
            return None
        self.add(name, "pass", summary(value))
        return value


def session_ready(directory, session):
    record = load_session(directory, session)
    status = record.get("status")
    if status != "ready":
        raise Blocked(f"Session status is {status}; launch a new session.")
    return record


def verify_tart(inputs):
    lab.check_version(inputs)
    return inputs["tart"]["version"]


def require_running(inputs, run):
    state = vm_state(inputs, run)
    if state != "running":
        raise Blocked(f"VM state is {state}; start it with verify.py start.")
    return state


def tart_ownership(directory):
    path = directory / "verify-tart.json"
    if not path.exists():
        return "not started by verify.py; its launcher owns the VM lifecycle"
    record = json.loads(path.read_text())
    pid = record["pid"]
    alive = "alive" if owned_tart(record) else "not running"
    return f"started by verify.py as pid {pid}; {alive}"


def require_idle(directory):
    if lock_busy(directory):
        raise Blocked("Another verify.py operation holds this run.")
    return "idle"


def guest_baseline(client, inputs):
    user = client.command("/usr/bin/id -un").stdout.strip()
    build = client.command("/usr/bin/sw_vers -buildVersion").stdout.strip()
    if (user, build) != ("omarchy", inputs["macos"]["build"]):
        raise Blocked("Guest account or OS build differs from the prepared baseline.")
    return f"{user} on {build}"


def require_fresh_state(client):
    if state_root_present(client):
        raise Blocked("~/.config/macarchy exists; journeys need a fresh test-base clone.")
    return "~/.config/macarchy absent"


def guest_identity(client, record):
    require_session_directory(client, record["session"])
    binary = record["guest"]["binary"]
    digest = client.command("/usr/bin/shasum -a 256 " + shlex.quote(binary),
                            check=False).stdout.split()
    if not digest or digest[0] != record["guest"]["binary_sha256"]:
        raise Blocked("Guest binary differs from the identity recorded at launch.")
    version = parse_json(client.command(step_command(binary, ["version", "--json"]),
                                        check=False).stdout)
    if version != record["guest"]["version"]:
        raise Blocked("version --json differs from the identity recorded at launch.")
    return {"binary": binary, "sha256": digest[0], "version": version}


def doctor(run, session=None, record_report=False):
    """Read-only: no lab initialization, build, lock creation, host-key trust or guest writes."""
    checks = Checks()
    inputs = checks.run("lab pins", read_pins, lambda value: "inputs.json readable")
    directory = inputs and checks.run("recorded test-base clone", lambda: test_clone(inputs, run))
    record = running = None
    if directory:
        checks.run("pinned Tart", lambda: verify_tart(inputs))
        running = checks.run("vm running", lambda: require_running(inputs, run))
        checks.run("tart ownership", lambda: tart_ownership(directory))
        checks.run("no concurrent verify operation", lambda: require_idle(directory))
        if session:
            record = checks.run("session ready", lambda: session_ready(directory, session),
                                lambda value: "ready")
    if running and not (directory / "known_hosts").exists():
        checks.add("guest ssh", "fail" if session else "skip",
                   "no trusted guest host key yet; launch performs trust on first use")
    elif running:
        with tempfile.TemporaryDirectory(prefix="verify-doctor-") as temporary:
            client = checks.run("guest ssh (strict host key, VM identity)",
                                lambda: connect(inputs, run, write_askpass(temporary), strict=True),
                                lambda value: "virtual machine reachable")
            if client:
                checks.run("guest account and OS build", lambda: guest_baseline(client, inputs))
                if record:
                    checks.run("guest binary identity", lambda: guest_identity(client, record),
                               lambda value: value)
                # Every journey refuses an existing state root, so it blocks readiness here.
                checks.run("fresh-state precondition", lambda: require_fresh_state(client))
    status = "ready" if all(item["status"] != "fail" for item in checks.items) else "blocked"
    report = {"tool": "verify.py", "operation": "doctor", "run": run, "session": session,
              "scope": "session: ready to drive" if session else
                       "vm only: run with --session before driving",
              "status": status, "checked": now(), "checks": checks.items}
    if record_report:  # Explicitly requested evidence is the only write doctor performs.
        if not (directory and record):
            raise Blocked("--record needs a readable run and a ready session.")
        stamp = report["checked"].replace(":", "")
        lab.write_json(directory / session / f"doctor-{stamp}.json", report)
    print(json.dumps(report, indent=2))
    return report


def evidence_summary(run, session):
    """Read-only index of retained proof; cleanup never removes it."""
    directory = guest.run_directory(run)
    record = load_session(directory, session)
    root = directory / session
    drives = []
    for path in sorted(root.glob("drive-*/report.json")):
        report = json.loads(path.read_text())
        drives.append({"report": str(path.relative_to(root)), "journey": report.get("journey"),
                       "status": report.get("status"), "failures": report.get("failures"),
                       "reason": report.get("reason")})
    cleanup_path = root / "cleanup.json"
    statuses = [item["status"] for item in drives]
    summary = {"tool": "verify.py", "operation": "evidence", "run": run, "session": session,
               "evidence": str(root), "session_status": record.get("status"),
               "binary_sha256": (record.get("guest") or {}).get("binary_sha256"),
               "drives": drives,
               "cleanup": (json.loads(cleanup_path.read_text()).get("status")
                           if cleanup_path.exists() else None),
               "files": sorted(str(path.relative_to(root)) for path in root.rglob("*")
                               if path.is_file()),
               "status": ("passed" if statuses and all(item == "passed" for item in statuses)
                          else "failed" if "failed" in statuses else "blocked")}
    print(json.dumps(summary, indent=2))
    return summary


def remove_guest_directory(client, session):
    """Remove only this session directory, after checking its ownership marker."""
    remote = shlex.quote(guest_directory(session))
    owner = client.command(f"/bin/cat {remote}/.verify-owner", check=False)
    if owner.returncode:
        if client.command(f"/bin/test ! -e {remote} -a ! -L {remote}", check=False).returncode == 0:
            return "already_absent"
        raise Blocked("Guest directory lacks this session ownership marker; not removing it.")
    if owner.stdout.strip() != session:
        raise Blocked("Guest directory belongs to another session; not removing it.")
    client.command(f"/bin/test -d {remote} -a ! -L {remote} && /bin/rm -rf -- {remote}",
                   timeout=300)
    return "removed"


def shutdown_vm(inputs, run, directory):
    record_path = directory / "verify-tart.json"
    record = json.loads(record_path.read_text()) if record_path.exists() else None
    outcome = {}
    try:  # A failed or hung guest path must still fall through to the owned-process stop.
        if vm_state(inputs, run) == "stopped":
            return {"result": "already_stopped"}
        if (directory / "ssh-shutdown.json").exists():
            outcome["guest_shutdown"] = "skipped: an earlier ssh-shutdown.json exists"
        else:  # Reuse the supported guest shutdown and its retained report.
            result = subprocess.run([sys.executable, "-B", str(lab.HERE / "guest.py"), "shutdown",
                                     "--run", run], cwd=lab.ROOT, capture_output=True, text=True,
                                    timeout=180)
            outcome["guest_shutdown"] = {"exit_code": result.returncode,
                                         "report": "ssh-shutdown.json"}
    except Exception as error:
        outcome["guest_shutdown"] = {"error": describe(error), "report": "ssh-shutdown.json"}
    try:
        still_running = vm_state(inputs, run) != "stopped"
    except Exception as error:  # Unknown state: the identity-checked owned stop is still safe.
        outcome["state_error"] = describe(error)
        still_running = True
    if still_running:
        if record is None:
            raise Blocked("VM may still be running and was not started by verify.py; "
                          "stop it through its owner.")
        outcome["owned_process"] = stop_owned(record)
    if record is not None:
        for _ in range(30):  # Tart exits shortly after the guest powers off.
            if not owned_tart(record):
                break
            time.sleep(1)
        record["status"] = "running" if owned_tart(record) else "exited"
        lab.write_json(record_path, record)
        outcome["tart_process"] = record["status"]
    state = vm_state(inputs, run)
    if state != "stopped":
        raise Blocked(f"VM state is still {state} after ownership-bound shutdown; "
                      f"actions: {json.dumps(outcome)}")
    outcome["result"] = "stopped"
    return outcome


def cleanup(inputs, run, session, shutdown):
    directory = test_clone(inputs, run)
    with RunLock(directory):
        record = load_session(directory, session) if session else None
        stamp = now()
        path = (directory / session / "cleanup.json" if session
                else directory / ("verify-cleanup-" + stamp.replace(":", "") + ".json"))
        report = {"tool": "verify.py", "operation": "cleanup", "run": run, "session": session,
                  "started": stamp, "status": "in_progress", "actions": {}}
        errors = []
        try:
            if record:  # Each step runs even after an earlier failure; nothing is stranded.
                try:
                    if vm_state(inputs, run) == "running":
                        with tempfile.TemporaryDirectory(prefix="verify-", dir=lab.STATE) as temporary:
                            client = connect(inputs, run, write_askpass(temporary))
                            report["actions"]["guest_directory"] = remove_guest_directory(
                                client, session)
                    else:
                        report["actions"]["guest_directory"] = "vm stopped; left on its disposable disk"
                    record["status"] = "cleaned"
                    lab.write_json(directory / session / "session.json", record)
                except Exception as error:
                    errors.append("guest directory: " + describe(error))
            if shutdown:
                try:
                    report["actions"]["shutdown"] = shutdown_vm(inputs, run, directory)
                except Exception as error:
                    errors.append("shutdown: " + describe(error))
            report["status"] = "blocked" if errors else "cleaned"
            if errors:
                report["reason"] = "; ".join(errors)
        finally:
            if record:
                report["evidence_retained"] = str(directory / session)
            report["finished"] = now()
            lab.write_json(path, report)
            print(json.dumps(report, indent=2))
        return report


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="operation", required=True)
    for name, text in (("start", "Boot a recorded stopped test-base clone, detached and owned"),
                       ("launch", "Snapshot current source and build macarchy in the guest"),
                       ("doctor", "Read-only readiness and identity checks"),
                       ("drive", "Run one closed journey against the launched build"),
                       ("evidence", "Read-only index of retained evidence"),
                       ("cleanup", "Remove session guest scratch; optionally shut down")):
        command = commands.add_parser(name, help=text)
        command.add_argument("--run", required=True, help="Recorded clone: setup-<12 hex>")
        if name in ("doctor", "drive", "evidence", "cleanup"):
            command.add_argument("--session", required=name in ("drive", "evidence"),
                                 help="verify-<12 hex> printed by launch")
        if name == "launch":
            command.add_argument("--wait", type=int, default=300, choices=range(30, 901),
                                 metavar="SECONDS", help="Guest SSH readiness bound, 30-900")
        if name == "drive":
            command.add_argument("--journey", required=True, choices=sorted(JOURNEYS))
        if name == "doctor":
            command.add_argument("--record", action="store_true",
                                 help="Also retain this report in the session evidence")
        if name == "cleanup":
            command.add_argument("--shutdown", action="store_true",
                                 help="Shut down through guest.py, then the owned Tart process")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.operation == "cleanup" and not (args.session or args.shutdown):
        raise Blocked("cleanup needs --session, --shutdown, or both.")
    if args.operation == "doctor":
        return EXIT[doctor(args.run, args.session, args.record)["status"]]
    if args.operation == "evidence":
        return EXIT[evidence_summary(args.run, args.session)["status"]]
    inputs = lab.initialize()
    lab.check_version(inputs)
    if args.operation == "start":
        record = start(inputs, args.run)
        print(json.dumps(record, indent=2))
        return EXIT[record["status"]]
    if args.operation == "launch":
        return EXIT[launch(inputs, args.run, args.wait)["status"]]
    if args.operation == "drive":
        return EXIT[drive(inputs, args.run, args.session, args.journey)["status"]]
    return EXIT[cleanup(inputs, args.run, args.session, args.shutdown)["status"]]


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failed as error:
        print(f"verify failed: {error}", file=sys.stderr)
        raise SystemExit(EXIT["failed"]) from None
    except (lab.LabError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"verify blocked: {describe(error)}", file=sys.stderr)
        raise SystemExit(EXIT["blocked"]) from None
