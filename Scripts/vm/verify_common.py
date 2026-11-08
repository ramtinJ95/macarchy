"""What verify.py and its journey modules share: verdicts, the clean guest step
environment, session records, Tart ownership and the logged guest-command runner.

Journey modules import this module, never verify.py, so verify.py imports them
without a cycle and every module raises the same Blocked and Failed classes.
"""
import functools
import json
import os
import pathlib
import re
import shlex
import subprocess
import time

import lab

q = shlex.quote
GUEST_USER = "omarchy"
GUEST_HOME = "/Users/" + GUEST_USER
DEVELOPER_DIR = "DEVELOPER_DIR=/Library/Developer/CommandLineTools"
# A clean, user-like environment; update checks and Homebrew auto-update stay off.
STEP_ENV = ("HOME=" + GUEST_HOME, "USER=omarchy", "LOGNAME=omarchy", "LANG=en_US.UTF-8",
            "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "MACARCHY_DISABLE_UPDATE_CHECKS=1", "HOMEBREW_NO_AUTO_UPDATE=1",
            "HOMEBREW_NO_ANALYTICS=1")


class Blocked(lab.LabError):
    """Precondition, ownership or transport problem: no product verdict was reached."""


class Failed(lab.LabError):
    """The product under test reached a wrong result."""


def verdict(error):
    return "failed" if isinstance(error, Failed) else "blocked"


def step_command(binary, arguments):
    return f"cd {GUEST_HOME} && " + shlex.join(["/usr/bin/env", "-i", *STEP_ENV, binary, *arguments])


def parse_json(text):
    try:
        value = json.loads(text)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def read_pins():
    """Read-only counterpart of lab.initialize for doctor and evidence."""
    if lab.STATE.is_symlink() or not lab.STATE.is_dir():
        raise Blocked("Lab state directory is missing or a symlink.")
    return json.loads((lab.HERE / "inputs.json").read_text())


def session_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"verify-[0-9a-f]{12}", value):
        raise Blocked("Session must be the verify-<12 hex> name printed by launch.")
    return value


def guest_directory(session):
    return f"{GUEST_HOME}/macarchy-{session_name(session)}"


def load_session(directory, session):
    path = directory / session_name(session) / "session.json"
    if path.parent.is_symlink() or not path.is_file():
        raise Blocked("Unknown session for this run; use the name printed by launch.")
    record = json.loads(path.read_text())
    if (record.get("tool"), record.get("session"), record.get("run")) != (
            "verify.py", session, directory.name):
        raise Blocked("Session record belongs to another run or tool; refusing it.")
    return record


def session_ready(directory, session):
    record = load_session(directory, session)
    status = record.get("status")
    if status != "ready":
        raise Blocked(f"Session status is {status}; launch a new session.")
    return record


def require_session_directory(client, session):
    remote = guest_directory(session)
    owner = client.command(f"/bin/cat {shlex.quote(remote)}/.verify-owner", check=False)
    if owner.returncode or owner.stdout.strip() != session:
        raise Blocked("Guest directory is missing or not owned by this session.")
    return remote


def recorded_binary(client, record):
    digest = client.command("/usr/bin/shasum -a 256 " + shlex.quote(record["guest"]["binary"]),
                            check=False).stdout.split()
    return bool(digest) and digest[0] == record["guest"]["binary_sha256"]


def guest_identity(client, record):
    require_session_directory(client, record["session"])
    binary = record["guest"]["binary"]
    if not recorded_binary(client, record):
        raise Blocked("Guest binary differs from the identity recorded at launch.")
    version = parse_json(client.command(step_command(binary, ["version", "--json"]),
                                        check=False).stdout)
    if version != record["guest"]["version"]:
        raise Blocked("version --json differs from the identity recorded at launch.")
    return {"binary": binary, "sha256": record["guest"]["binary_sha256"], "version": version}


def process_identity(pid):
    """Start time plus full command line; a reused PID cannot match a recorded identity."""
    result = subprocess.run(["/bin/ps", "-ww", "-o", "lstart=", "-o", "command=", "-p", str(pid)],
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def owned_tart(record):
    """True only for the exact process start recorded by verify.py start."""
    return bool(record.get("identity")) and process_identity(record["pid"]) == record["identity"]


def _text(value):
    if isinstance(value, bytes):
        return value.decode('utf-8', 'replace')
    return '' if value is None else str(value)


def run(client, evidence, report, name, command, timeout=30, data=None, blocked=False):
    '''Run one guest command, preserve its log, raise Failed (or Blocked) on error.'''
    evidence = pathlib.Path(evidence)
    log = evidence / ('%02d-%s.log' % (len(list(evidence.glob('*.log'))) + 1, name))
    started = time.monotonic()
    result, error = None, None
    try:
        result = client.command(command, check=False, data=data, timeout=timeout)
    except Exception as exc:  # timeout/transport: keep the log, then fail
        error = '%s: %s' % (type(exc).__name__, exc)
    seconds = round(time.monotonic() - started, 3)
    code = None if result is None else result.returncode
    out = '' if result is None else _text(result.stdout)
    err = '' if result is None else _text(result.stderr)
    lines = ['$ ' + command, 'exit: %s' % code, 'seconds: %s' % seconds,
             'error: %s' % error, '--- stdout', out, '--- stderr', err, '']
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write('\n'.join(lines))
    # Every journey's command index lives under report['borders']; borders preparation
    # reuse reads it back from earlier reports.
    report.setdefault('borders', {}).setdefault('commands', []).append(
        {'name': name, 'exit': code, 'seconds': seconds, 'log': log.name})
    if error is not None or code != 0:
        kind = Blocked if blocked or error is not None else Failed
        raise kind('%s failed (exit %s%s); see %s' % (name, code, ', ' + error if error else '', log))
    return out


def runner(client, evidence, report):
    return functools.partial(run, client, evidence, report)


def absent(path):
    return 'test ! -e %s && test ! -L %s' % (q(path), q(path))


def regular(paths):
    return ' && '.join('test -f %s && test ! -L %s' % (q(p), q(p)) for p in paths)


def blockers(payload, path='$'):
    found = []
    if isinstance(payload, dict):
        for key, value in payload.items():
            where, lowered = path + '.' + str(key), str(key).lower()
            # Inspection always carries this review digest, even for absent entries.
            # It is evidence identity, not a request/permission to adopt anything.
            if (lowered == 'blocked' or ('adopt' in lowered
                    and lowered != 'adoption_evidence_digest')) and value:
                found.append(where)
            elif lowered in ('status', 'outcome') and isinstance(value, str) \
                    and ('block' in value.lower() or 'adopt' in value.lower()):
                found.append(where + '=' + value)
            found += blockers(value, where)
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            found += blockers(value, '%s[%d]' % (path, index))
    return found


def guest_sha256(sh, name, paths):
    digests = {}
    for line in sh(name, 'shasum -a 256 ' + ' '.join(q(p) for p in paths)).splitlines():
        digest, _, path = line.partition('  ')
        digests[path] = digest
    missing = [p for p in paths if p not in digests]
    if missing:
        raise Failed('%s: no digest for %s' % (name, ', '.join(missing)))
    return digests


def require_console_user(client, evidence, report):
    # Call before launching any GUI process; prepare itself may run pre-login.
    owner = run(client, evidence, report, 'console-user',
                '/usr/bin/stat -f %Su /dev/console', blocked=True).strip()
    if owner != GUEST_USER:
        raise Blocked('console owner is %r, expected %r' % (owner, GUEST_USER))
