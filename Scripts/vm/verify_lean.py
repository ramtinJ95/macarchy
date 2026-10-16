"""Closed, guest-only managed-focus lifecycle journey; no package installs or TCC changes."""
import base64
import json
from pathlib import PurePosixPath
import shlex

import verify_borders as borders

LABEL = "io.github.ramtinj95.macarchy.focus-ring"
PLIST = "/Users/omarchy/Library/LaunchAgents/" + LABEL + ".plist"
DISABLED = ("desktop", "top_bar", "terminal", "shell", "prompt", "history", "editor")
PERSIST_SECONDS = 305
MISSING_DEFAULTS = {name: "failed" for name in (
    "atuin", "bat", "btop", "eza", "neovim", "sketchybar", "starship", "wallpaper", "yazi")}
MISSING_DEFAULTS["kitty"] = "drifted"
q = shlex.quote


def profile(provider):
    if provider not in ("lean", "disabled"):
        raise ValueError("This journey does not install or adopt Borders.")
    return "\n".join(
        ["schema_version = 1", "", "[focus_ring]", 'provider = "' + provider + '"', ""]
        + [line for name in DISABLED for line in ("[" + name + "]", 'provider = "disabled"', "")]
        + ["[tools]", "bat = false", "eza = false", "btop = false", "yazi = false", ""]
    )


def assess_runtime(before, after, *, changed_theme=False, persisted=False):
    """Identity + elapsed runloop proof, not pixels or a broad stability qualification."""
    failures = []
    if any(before.get(key) != after.get(key) for key in ("pid", "started", "executablePath")):
        failures.append("the helper restarted or changed executable")
    if changed_theme:
        if before.get("generationID") == after.get("generationID"):
            failures.append("canonical theme generation did not change")
        if (before.get("accent"), after.get("accent")) != ("#cba6f7", "#7aa2f7"):
            failures.append("the helper did not acknowledge the expected canonical accents")
    if persisted:
        elapsed = after.get("updated", 0) - before.get("updated", 0)
        if elapsed <= 300:
            failures.append("no same-process main-runloop acknowledgement beyond 300 seconds")
    return failures


def assess_restoration(result):
    """Accept only the pre-existing missing-default-consumer failure, not any exit 1."""
    expected = dict(MISSING_DEFAULTS, **{"lean-focus-ring": "applied", "macos-appearance": "applied"})
    rows = result.get("theme", [])
    actual = {row.get("adapter_id"): row.get("status") for row in rows}
    message = "Required theme reconciliation of the default consumer set failed; run 'macarchy reconcile'."
    return (
        result.get("outcome") == "blocked" and result.get("mutated") is True
        and result.get("transaction_status") == "clear"
        and result.get("message", "").endswith(message)
        and len(rows) == len(expected) and actual == expected
        and all(row.get("requirement") == "required" for row in rows)
        and next((row.get("message") for row in rows if row.get("adapter_id") == "lean-focus-ring"), "")
        == "Stopped and unregistered owned lean; no Borders state was adopted or changed."
    )


def run_journey(client, record, evidence, report):
    import verify as v
    report["not_covered"] = [
        "Homebrew-installed Macarchy or release archive",
        "guided setup or providers other than the isolated lean-only profile",
        "theme set --dry-run, native pixels or consumers other than lean acknowledgement",
        "keybindings, GUI menus, viewers, popups and native permission prompts",
        "network, browser and paths outside the declared mutation scope",
        "physical hardware",
    ]
    source = record["guest"]["source"]
    binary = record["guest"]["binary"]
    helper = str(PurePosixPath(binary).parent / "macarchy-focus-ring")
    scratch = source + "/" + evidence.name
    root = scratch + "/state"
    path = scratch + "/profile.toml"
    flags = ["--state-root", root, "--json"]
    section = report["lean"] = {"known_limits": [
        "Retina/multiple displays", "ordinary Spaces", "broad real apps", "long-running stability",
        "native managed Borders handoff (covered by injected ownership/recovery tests)",
        "release archive/install provenance",
        "full teardown convergence: absent default consumers fail after owned lean removal",
    ], "mutation_scope": {"state": root, "profile": path, "launch_agent": PLIST,
                           "native_appearance": "guest-only canonical theme preference"}}
    sh = borders._runner(client, evidence, report)

    def cli(name, *arguments, expected=0):
        command = v.step_command(binary, list(arguments))
        if expected:
            command = "/bin/zsh -c " + q(command + "; rc=$?; test $rc -eq " + str(expected))
        raw = sh(name, command, timeout=60)
        value = json.loads(raw)
        if not expected and borders._blockers(value):
            raise v.Failed(name + " reported blocked/adoption state; no auto-approval")
        return value

    def write_profile(provider, first=False):
        encoded = base64.b64encode(profile(provider).encode()).decode()
        sh("profile-" + provider,
           ("set -C; " if first else "") + "printf %s " + q(encoded)
           + " | /usr/bin/base64 -D > " + q(path))

    def runtime(name):
        return json.loads(sh(name, "/bin/cat " + q(root + "/environment/lean-focus-runtime.json")))

    def doctor(name, expected=0):
        result = cli(name, "environment", "doctor", "--profile", path, *flags, expected=expected)
        if not expected:
            if result.get("providers", {}).get("focus_ring") != "lean" \
                    or result.get("outcome") != "converged":
                raise v.Failed(name + " did not report the selected lean provider converged")
        elif result.get("outcome") not in ("drifted", "blocked"):
            raise v.Failed(name + " did not expose the stopped service")
        return result

    def absent(name):
        sh(name, "test ! -e " + q(PLIST) + " && test ! -L " + q(PLIST)
           + " && { /usr/bin/pgrep -u $(id -u) -x 'macarchy-focus.*'; rc=$?; test $rc -eq 1; }"
           + " && { /bin/launchctl print gui/$(id -u)/" + q(LABEL)
           + "; rc=$?; test $rc -eq 113; }"
           + " && " + " && ".join(
               "test ! -e " + q(root + "/environment/" + item)
               + " && test ! -L " + q(root + "/environment/" + item)
               for item in ("ownership.json", "transaction.json", "lean-focus-runtime.json")))

    def restored(name, *arguments):
        result = cli(name, *arguments, expected=1)
        if not assess_restoration(result):
            raise v.Failed(name + " did not show exact owned lean removal/default-consumer limitation")
        section[name] = {"owned_lean": "removed", "overall_outcome": "blocked",
                         "missing_default_consumers": MISSING_DEFAULTS}
        absent(name + "-service-absent")

    # Native session and ownership prerequisites precede every product mutation.
    borders.require_console_user(client, evidence, report)
    sh("scratch-absent", borders._absent(scratch), blocked=True)
    sh("lean-plist-absent", borders._absent(PLIST), blocked=True)
    sh("no-incumbents",
       "/usr/bin/pgrep -u $(id -u) -x 'borders|macarchy-focus.*'; rc=$?; test $rc -eq 1",
       blocked=True)
    for label in ("homebrew.mxcl.borders", "sh.brew.borders", LABEL):
        plist = "/Users/omarchy/Library/LaunchAgents/" + label + ".plist"
        sh("registration-absent-" + label,
           "test ! -e " + q(plist) + " && test ! -L " + q(plist)
           + " && { /bin/launchctl print gui/$(id -u)/" + q(label)
           + "; rc=$?; test $rc -eq 113; }", blocked=True)
    sh("helper-build", "cd " + q(source) + " && env " + borders.DEV
       + " swift build --product macarchy-focus-ring", timeout=180)
    section["helper_sha256"] = sh("helper-sha256", "shasum -a 256 " + q(helper)).split()[0]
    sh("scratch-create", "umask 077; mkdir " + q(scratch))
    write_profile("lean", first=True)
    may_own_service = False
    try:
        section["plan"] = cli("setup-plan", "setup", "plan", "--profile", path, *flags)
        may_own_service = True  # Apply can fail after registering; always use product teardown.
        section["apply"] = cli("setup-apply", "setup", "apply", "--profile", path, *flags)
        doctor("initial-doctor")
        # Set a known first theme through the real CLI; no synthetic runtime/palette files.
        cli("theme-catppuccin", "theme", "set", "catppuccin-mocha", *flags)
        doctor("catppuccin-doctor")
        before = runtime("before-theme")
        cli("theme-tokyo", "theme", "set", "tokyo-night", *flags)
        doctor("tokyo-doctor")
        changed = runtime("after-theme")
        section["theme_failures"] = assess_runtime(before, changed, changed_theme=True)
        if section["theme_failures"]:
            raise v.Failed("; ".join(section["theme_failures"]))

        # A deliberate stopped-owned-job fault, not a fabricated status receipt.
        sh("stop-owned-job", "/bin/launchctl bootout gui/$(id -u)/" + q(LABEL))
        doctor("stopped-doctor", expected=1)
        cli("repair-apply", "environment", "apply", "--profile", path, *flags)
        doctor("repaired-doctor")
        repaired = runtime("before-duration")
        sh("beyond-preview-duration", "/bin/sleep " + str(PERSIST_SECONDS),
           timeout=PERSIST_SECONDS + 10)
        doctor("persistent-doctor")
        persisted = runtime("after-duration")
        section["duration_failures"] = assess_runtime(repaired, persisted, persisted=True)
        if section["duration_failures"]:
            raise v.Failed("; ".join(section["duration_failures"]))
        section["runtime"] = {"before_theme": before, "after_theme": changed,
                              "before_duration": repaired, "after_duration": persisted}
        write_profile("disabled")
        restored("disable", "environment", "apply", "--profile", path, *flags)
        write_profile("lean")
        cli("re-enable", "environment", "apply", "--profile", path, *flags)
        doctor("re-enabled-doctor")
        restored("teardown", "environment", "teardown", *flags)
        may_own_service = False
        section["result"] = "passed"
        return "passed"
    finally:
        if may_own_service:
            try:
                cli("failure-teardown", "environment", "teardown", *flags)
                absent("failure-service-absent")
            except Exception as error:
                report.setdefault("cleanup_errors", []).append(str(error))
