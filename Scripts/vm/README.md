# Local GUI VM lab

Opt-in developer tooling for a **real macOS desktop**, driven by code and
inspectable by a person or agent. Nothing here is included in Macarchy products,
release archives or Homebrew dependencies. Ordinary builds/tests/CI never start
a VM. The existing release-layout exact-inventory check enforces that boundary.

## Installer and guest GUI control

Keyboard sessions and private credential input are implemented. Mouse and
unattended OS bootstrap remain unqualified; SSH/prepared baselines follow.

The native-window path has been observed on host macOS 26.7 with Tart 2.39.0 and
guest macOS 26.6.2: a screenshot of Welcome, a targeted Space keystroke, then a
screenshot of the language-selection screen. No TCP listener or new permission
grant was needed in that existing launch context. This is installer-control
evidence, not a complete desktop or clean-user permission qualification.

**No VNC is used.** The experimental path was rejected after its listener bound
all interfaces despite advertising a localhost URL. There is no VNC fallback,
host firewall change, sandbox wrapper or modified Tart build.

Prerequisites: an Apple Silicon Mac on the supported macOS 26 host, a logged-in
GUI session, Command Line Tools (`swiftc`), Python 3.12 and
[uv](https://docs.astral.sh/uv/). No system-wide Tart or Packer installation is
necessary. The Python runner has no third-party dependencies.

From the repository root:

```sh
# Pure checks: no VM, downloads or permission changes.
python3 -B Scripts/vm/test_lab.py

# Compile the isolated window helper and inspect existing permissions. No prompts.
uv run --project Scripts/vm --locked python Scripts/vm/lab.py preflight

# Explicit downloads: ~20 GB Apple installer + pinned Tart; verify SHA-256 and signing.
uv run --project Scripts/vm --locked python Scripts/vm/lab.py prepare

# Restore once, clone, boot a visible VM, check for listeners, then take window-only
# screenshots and one Space keystroke. Stop the owned VM and retain evidence.
uv run --project Scripts/vm --locked python Scripts/vm/lab.py probe
```

`inputs.json` pins the macOS version/build/installer digest, Tart archive digest
and virtual hardware. The adjacent Python version/lock defines the runner. The default
VM has 4 CPUs, 8 GiB RAM and a 100 GB virtual disk. A stopped, post-restore
installer baseline is cloned for each probe; it is never the running test target.

The probe checks existing host Accessibility and Screen Recording permission
before starting a VM and refuses to request either automatically. Permission
attribution depends on the launching app; a working terminal is not proof for
another agent host. The helper validates the owned PID, exact Tart executable
and unique window title; missing/ambiguous windows never fall back to desktop
capture. Apple's `screencapture -l` captures that window; CoreGraphics posts the
Space key to that PID, not to the global keyboard stream. The helper never
activates or raises Tart, changes Spaces, or moves the host pointer. Window
lookup includes the exact owned window on other Spaces. A foreground-app change
during input is reported as failure, never repaired by reactivating the VM.

The probe rejects any TCP listener on the Tart process. A blocked run exits
nonzero. A screenshot run reports
`requires_visual_review`, not "passed": compare `01-before.png` and
`02-after-space.png` to establish whether input had the expected visible effect.
This initial probe is deliberately bounded; it does not accept macOS terms,
create a guest account or approve privacy prompts.

Launching Tart's native GUI may initially take focus; schedule VM startup when
that is acceptable. Subsequent actions do not activate it. Do not manually interact
with the **guest** while a recipe controls it. Screenshots include its title bar and possible letterboxing, not
other host windows. Host window management affects PNG dimensions even with a
fixed guest display; these are semantic visual checkpoints, not pixel goldens.

## GUI actions and bootstrap limitations

`session` reuses the same isolated clone/lifecycle and accepts one JSON action per
line. A bounded recipe can be invoked without an interactive shell:

```sh
uv run --project Scripts/vm --locked python Scripts/vm/lab.py session \
  < Scripts/vm/recipes/language-probe.jsonl
```

Actions: `capture`, `key` with `key` (space/return/tab/backtab/escape/arrows or
`keyboard-navigation` for guest Control-F7, `spotlight` for guest Command-Space), `click`
with normalized window `x`/`y`, `click-text` with an exact `text` label,
`expect-text` to wait for that label without clicking, `type` with public `text`
(1–100 lowercase US letters/digits/spaces only), `wait` with integer `seconds`
(1–60), and `stop`. EOF, invalid input, idle timeout
(10 minutes), or inspection failure stops only the owned process. This interface
does not accept literal passwords, arbitrary shortcuts or shell commands. Do not
put secrets in recipes. Input/capture results stay in the private run report.

`type-secret` with `secret: "guest-password"` references a run-local mode0600 file.
The default is a generated 24-character random credential; an explicitly supplied
disposable fixture may contain 4–100 lowercase letters/digits, without a newline.
It travels to the native helper
through stdin only; action records retain the reference, not its value, and helper
failure diagnostics are withheld. Inspect a captured secure field first; matching
window geometry does not prove field focus. The private file/native-input path
created a real guest account with a user-approved test password; complete recipe
replay is still unqualified. Never use personal credentials.

The session allows up to five seconds for the verified VM's
window geometry to settle. Capture and click check window identity/bounds;
movement or resizing during capture/input is a failure, not coordinate guessing.
Raw click coordinates refer to the entire captured window, including its chrome
and letterboxing; they are not portable guest-screen coordinates.

`click-text` waits up to 60 seconds for a unique exact label recognized locally
by Apple's Vision in **window-only** PNGs, then targets that label's center.
Missing/ambiguous text blocks input. OCR confidence and screenshots are evidence,
not proof of a correct UI state or a successful click. Text matching is not
authorization to accept licenses, permissions or other consequential choices.

**Observed limit:** the current language probe reaches language selection, but
PID-targeted mouse events did not select English, even with a visible OCR anchor.
The probe is retained as a reproducer, **not a passing bootstrap recipe**. Native
Space/Down/Return input selected English and reached the country picker using
`recipes/guest-bootstrap.jsonl` after the user chose keyboard-first qualification.
That recipe now stops at the country picker: a human click was needed before
scripted country selection worked. With that prerequisite, inspected keyboard
steps reached Transfer, US language defaults, Accessibility, Data & Privacy, and
Create a Mac Account. Background typing subsequently created the local account,
with Apple Account password recovery unchecked. No Apple Account sign-in or
terms acceptance occurred. `backtab` moved focus but reverse navigation is not
qualified; do not assume its direction.

Repeated activation interrupted the host user's other workspace. It was removed,
not made optional or retried. On the existing guest, window-only captures worked
with Tart not foreground, and a PID-targeted Tab elicited password validation
without changing the foreground application. This qualifies that background
interaction only, not fresh bootstrap, mouse, every key, or VM startup behavior.
After account creation, Apple Account navigation stalled: Control-F7 plus Tab
visibly focused a link, but subsequent Tab/backtab did not move its focus.
The lab paused instead of reactivating Tart. This is an unresolved input seam,
not proof that keyboard navigation alone completes setup. Modifiers now include
the public IOLLEvent.h left-device flags as well as aggregate flags.
The user subsequently completed setup manually. Saving the configured desktop
and qualifying SSH/reboot/reset follow; full account-creation replay is unqualified.
Do not repeatedly run this unchanged or silently use global mouse events.

Tart's `--no-usb-accessories` flag was removed: its source shows that it removes
the **emulated** USB keyboard/mouse, not host-device passthrough. Standard virtual
input devices are required for mouse qualification; this attaches no physical
host USB device. Restoring them alone did not resolve the observed click failure.
The current helper does not warp the host cursor or post global mouse events.

## Storage and security

All generated state lives in the already ignored `artifacts/vm/`:

- `downloads/` and `tools/`: verified installer, local Tart app and window helper;
- `tart/`: isolated `TART_HOME`, never the user's normal `~/.tart` store;
- `runs/<id>/`: screenshots, private logs and a result report;
- `prepared.json` / `baseline.json`: local input receipts, not credentials.

The lab root is private to the host user. **Retained logs from the rejected VNC
experiment contain passwords; never paste or publish them.** Current runs do not
start VNC or create its credentials. Clones and evidence are
retained for inspection; there is no automatic pruning or broad cleanup. Do not
delete state while a lab operation is active. An interrupted restoration is an
explicit incomplete baseline, not a successful cached image.

The lab does not disable SIP/Gatekeeper or grant guest TCC permissions. No host-home mounts, clipboard sharing,
USB passthrough, SSH-agent forwarding, bridged networking or inherited tracing.
Default guest NAT permits networking; this is not a sandbox for hostile code.
Do not use personal Apple Accounts or real secrets in test guests.

The standard upstream "vanilla" template disables Gatekeeper, so it is **not**
our baseline. Packer's default installer-control path also uses the rejected
experimental VNC; do not introduce it without revisiting that boundary.
Tart uses FSL-1.1-ALv2 (internal use permitted); it is downloaded, not redistributed
as a Macarchy dependency.
