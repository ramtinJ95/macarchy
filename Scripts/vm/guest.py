#!/usr/bin/env python3
"""Opt-in SSH qualification of an already-running, recorded disposable guest."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

import lab


def run_directory(name):
    if not re.fullmatch(r"(?:setup-[0-9a-f]{12}|desktop-check-[0-9]{2})", name):
        raise lab.LabError("SSH target must be a disposable lab run, never a baseline.")
    directory = lab.STATE / "runs" / name
    if directory.is_symlink() or not directory.is_dir():
        raise lab.LabError("Missing private run directory.")
    return directory


def ssh_arguments(ip, name, directory):
    address = ipaddress.ip_address(ip)
    if address.version != 4 or not address.is_private or address.is_loopback or address.is_link_local:
        raise lab.LabError("Expected the owned Tart guest's private IPv4 address.")
    return [
        "/usr/bin/ssh", "-F", "/dev/null", "-T",
        "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
        "-o", "NumberOfPasswordPrompts=1", "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no", "-o", "IdentityAgent=none",
        "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", f"UserKnownHostsFile={directory / 'known_hosts'}",
        "-o", f"HostKeyAlias=macarchy-{name}", "-o", "StrictHostKeyChecking=accept-new",
        f"omarchy@{address}",
    ]


class Guest:
    def __init__(self, inputs, name, askpass):
        self.directory = run_directory(name)
        report = json.loads((self.directory / "report.json").read_text())
        if report["inputs"] != inputs:
            raise lab.LabError("Run input pins do not match.")
        info = json.loads(lab.run_tart(inputs, "get", name, "--format", "json",
                                      capture_output=True, text=True, timeout=10).stdout)
        if info["State"] != "running":
            raise lab.LabError("SSH qualification requires an already-running disposable guest.")
        ip = lab.run_tart(inputs, "ip", name, capture_output=True, text=True,
                          timeout=10).stdout.strip()
        self.argv = ssh_arguments(ip, name, self.directory)
        self.password = lab.guest_password(self.directory, create=False)
        self.env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home()),
                    "SSH_ASKPASS": str(askpass), "SSH_ASKPASS_REQUIRE": "force",
                    "MACARCHY_VM_RUN": name}

    def command(self, command, sudo=False, check=True, data=None, timeout=30):
        result = subprocess.run(self.argv + [command], env=self.env,
                                input=self.password + "\n" if sudo else (data or ""),
                                capture_output=True, text=True, timeout=timeout)
        if check and result.returncode:
            # No raw diagnostics on credential-bearing paths.
            raise lab.LabError(f"Guest SSH command failed (exit {result.returncode}).")
        return result

    def inspect(self, inputs, homebrew=False):
        checks = {
            "user": ("/usr/bin/id -un", "omarchy"),
            "version": ("/usr/bin/sw_vers -productVersion", inputs["macos"]["version"]),
            "build": ("/usr/bin/sw_vers -buildVersion", inputs["macos"]["build"]),
            "sip": ("/usr/bin/csrutil status", "System Integrity Protection status: enabled."),
            "gatekeeper": ("/usr/sbin/spctl --status", "assessments enabled"),
        }
        evidence = {}
        for name, (command, expected) in checks.items():
            actual = self.command(command).stdout.strip()
            evidence[name] = actual
            if actual != expected:
                raise lab.LabError(f"Guest {name} does not match the required baseline state.")
        self.command('for tool in macarchy yabai; do '
                     'if command -v "$tool" >/dev/null 2>&1; then exit 1; fi; done; '
                     'for path in /Applications/Macarchy.app '
                     '"$HOME/.config/macarchy" "$HOME/.config/yabai" "$HOME/.yabairc" '
                     '/Library/ScriptingAdditions/yabai.osax; do '
                     'if test -e "$path" || test -L "$path"; then exit 1; fi; done')
        evidence["tooling"] = "macarchy/yabai absent from PATH and checked standard locations"
        if homebrew:
            evidence["homebrew"] = self.command(
                'test "$(/opt/homebrew/bin/brew --prefix)" = /opt/homebrew && '
                '/opt/homebrew/bin/brew --version && /usr/bin/git -C /opt/homebrew rev-parse HEAD && '
                '/opt/homebrew/bin/brew analytics state').stdout.strip()
            if "InfluxDB analytics are disabled." not in evidence["homebrew"]:
                raise lab.LabError("Homebrew analytics are not confirmed disabled.")
        else:
            self.command('! command -v brew >/dev/null 2>&1 && '
                         'test ! -e /opt/homebrew && test ! -L /opt/homebrew && '
                         'test ! -e /usr/local/Homebrew && test ! -L /usr/local/Homebrew')
            evidence["homebrew"] = "absent from PATH and standard locations"
        evidence["filevault"] = self.command("/usr/bin/fdesetup status").stdout.strip()
        evidence["service_overrides"] = self.command("/bin/launchctl print-disabled system").stdout.strip()
        evidence["boot_session"] = self.boot_session()
        return evidence

    def boot_session(self):
        value = self.command("/usr/sbin/sysctl -n kern.bootsessionuuid").stdout.strip()
        return str(uuid.UUID(value))

    def mark(self):
        token = uuid.uuid4().hex
        self.command('test ! -e "$HOME/.macarchy-vm-reset-check" && '
                     'test ! -L "$HOME/.macarchy-vm-reset-check" && '
                     f'(umask 077; set -C; printf %s {token} > "$HOME/.macarchy-vm-reset-check")')
        return {"marker": token}

    def reboot(self):
        before = self.boot_session()
        marker = self.command('cat "$HOME/.macarchy-vm-reset-check"').stdout
        result = self.command("/usr/bin/sudo -S -p '' /sbin/shutdown -r now", sudo=True, check=False)
        if result.returncode not in (0, 255):
            raise lab.LabError("Guest rejected reboot.")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            time.sleep(3)
            try:
                after = self.boot_session()
            except (lab.LabError, subprocess.TimeoutExpired):
                continue
            if after != before:
                if self.command('cat "$HOME/.macarchy-vm-reset-check"').stdout != marker:
                    raise lab.LabError("Guest marker changed across reboot.")
                return {"before": before, "after": after, "ssh_reconnected": True,
                        "marker_preserved": True}
        raise lab.LabError("No verified new guest boot session within 180 seconds.")


def main():
    # OpenSSH invokes this through a short-lived private executable wrapper.
    if sys.argv[1:] == ["--askpass"]:
        sys.stdout.write(lab.guest_password(run_directory(os.environ["MACARCHY_VM_RUN"]),
                                           create=False) + "\n")
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("inspect", "install-homebrew", "mark", "reboot", "reset-check", "shutdown"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--expect-homebrew", action="store_true")
    args = parser.parse_args()
    if args.expect_homebrew and args.operation != "inspect":
        parser.error("--expect-homebrew is only valid with inspect")
    inputs = lab.initialize()
    lab.check_version(inputs)
    directory = run_directory(args.run)
    suffix = "-homebrew" if args.expect_homebrew else ""
    destination = directory / f"ssh-{args.operation}{suffix}.json"
    if destination.exists():
        raise lab.LabError("Qualification report already exists; inspect it rather than overwrite it.")
    report = {"operation": args.operation, "run": args.run, "status": "in_progress"}
    lab.write_json(destination, report)
    try:
        with tempfile.TemporaryDirectory(prefix="ssh-", dir=lab.STATE) as temporary:
            askpass = Path(temporary) / "askpass"
            askpass.write_text("#!/bin/sh\nexec " + shlex.join(
                [sys.executable, str(Path(__file__).resolve()), "--askpass"]) + "\n")
            askpass.chmod(0o700)
            guest = Guest(inputs, args.run, askpass)
            if args.operation == "inspect":
                report["evidence"] = guest.inspect(inputs, homebrew=args.expect_homebrew)
            elif args.operation == "install-homebrew":
                remote = "/tmp/macarchy-prepare-" + uuid.uuid4().hex + ".sh"
                guest.command(f"umask 077; set -C; cat > {remote}",
                              data=(lab.HERE / "prepare-homebrew.sh").read_text())
                try:
                    result = guest.command(f"MACARCHY_VM_PREPARE=disposable-guest /bin/bash {remote}",
                                           sudo=True, check=False, timeout=3600)
                    (directory / "homebrew-install.log").write_text(result.stdout + result.stderr)
                    if result.returncode:
                        raise lab.LabError("Homebrew preparation failed; inspect the private install log.")
                    report["evidence"] = {"installed": True, "log": "homebrew-install.log",
                                          "recipe_sha256": hashlib.sha256(
                                              (lab.HERE / "prepare-homebrew.sh").read_bytes()).hexdigest()}
                finally:
                    guest.command(f"/bin/rm -f {remote}")
            elif args.operation == "mark":
                report["evidence"] = guest.mark()
            elif args.operation == "reboot":
                report["evidence"] = guest.reboot()
            elif args.operation == "reset-check":
                guest.command('test ! -e "$HOME/.macarchy-vm-reset-check" && '
                              'test ! -L "$HOME/.macarchy-vm-reset-check"')
                report["evidence"] = {"previous_clone_marker_absent": True}
            else:
                result = guest.command("/usr/bin/sudo -S -p '' /sbin/shutdown -h now",
                                       sudo=True, check=False)
                if result.returncode not in (0, 255):
                    raise lab.LabError("Guest rejected shutdown.")
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    time.sleep(2)
                    try:
                        lab.require_stopped(inputs, args.run)
                        break
                    except lab.LabError:
                        continue
                else:
                    raise lab.LabError("Guest shutdown not observed within 60 seconds.")
                report["evidence"] = {"stopped": True}
            report["status"] = "passed"
    except Exception as error:
        report["status"] = "blocked"
        report["reason"] = str(error) if isinstance(error, lab.LabError) else type(error).__name__
        raise
    finally:
        lab.write_json(destination, report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (lab.LabError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f"VM SSH qualification blocked: {type(error).__name__}") from None
