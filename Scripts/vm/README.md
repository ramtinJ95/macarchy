# Local GUI VM lab

Opt-in developer tooling for a **real macOS desktop**, driven by code and
inspectable by a person or agent. Nothing here is included in Macarchy products,
release archives or Homebrew dependencies. Ordinary builds/tests/CI never start
a VM. The existing release-layout exact-inventory check enforces that boundary.

## First slice: qualify installer control

This is not yet a complete Macarchy setup test. First prove the guest display
can be controlled and captured safely, without weakening guest security or
capturing the host desktop. SSH, guest reboot, fresh-Mac onboarding and
existing-dotfiles scenarios remain unqualified until exercised separately.

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
Space key to that PID after activating it, not to the global keyboard stream.

The probe rejects any TCP listener on the Tart process. A blocked run exits
nonzero. A screenshot run reports
`requires_visual_review`, not "passed": compare `01-before.png` and
`02-after-space.png` to establish whether input had the expected visible effect.
This initial probe is deliberately bounded; it does not accept macOS terms,
create a guest account or approve privacy prompts.

Avoid concurrent keyboard/mouse use during the short input step: the Tart window
is activated. Screenshots include its title bar and possible letterboxing, not
other host windows. Host window management affects PNG dimensions even with a
fixed guest display; these are semantic visual checkpoints, not pixel goldens.

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

SIP, Gatekeeper and TCC stay unchanged. No host-home mounts, clipboard sharing,
USB passthrough, SSH-agent forwarding, bridged networking or inherited tracing.
Default guest NAT permits networking; this is not a sandbox for hostile code.
Do not use personal Apple Accounts or real secrets in test guests.

The standard upstream "vanilla" template disables Gatekeeper, so it is **not**
our baseline. Packer's default installer-control path also uses the rejected
experimental VNC; do not introduce it without revisiting that boundary.
Tart uses FSL-1.1-ALv2 (internal use permitted); it is downloaded, not redistributed
as a Macarchy dependency.

## After the control path is qualified

The reference interaction model is Oligarchy's small guest-control client:
explicit sessions, guest screenshots, input actions and fresh/prepared disks.
Its Linux QEMU/QMP implementation is not a macOS backend; fleet/server/issue
tracking infrastructure is intentionally outside this local lab's scope.

Add the smallest versioned image recipe and scenario that completes real
onboarding. Keep Packer bootstrap prerequisites separate from what Macarchy
must install. Preserve explicit permission/consent checkpoints. Then add seeded
dotfiles (including symlink ownership), repeat/reboot and recovery scenarios.
Keep screenshots and visual judgments distinct from machine-readable assertions.
Do not confuse a candidate-build test with the published Homebrew install path,
or a VM check with physical display/sleep/hardware qualification.
