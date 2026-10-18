# Focus borders

The event-driven own-outline-transaction helper passed motion, eight-window
behavior/theming and 24-window scaling. Measured p95 tracking matches JankyBorders
with much lower helper memory. This is NOT managed replacement acceptance or
blanket hardware/app parity. User accepted this bounded preview on 2026-10-14.
Release packaging and the opt-in managed lifecycle (`--managed`) landed on
2026-10-16 with real helper changes; see [lean.md](lean.md). The accepted
motion/1/8/24 evidence below predates them. The 2026-10-18 re-run did not
re-qualify the 8/24-window or motion cases.

## Sub-features

- One reusable active outline: 6 pt accent stroke centered on the window edge,
  corner radius from the window's native radius (9 pt fallback), transparent interior.
- Same-app/cross-app focus, movement, resize, minimize/restore, close and fullscreen.
- Real canonical theme activation/repaint, without native appearance consumers.
- Physical footprint and CPU for renderer and system-wide WindowServer separately.
- Owned-Tart-window-only PNGs and ScreenCaptureKit video.

## How to get to it (user POV)

An active canonical theme and the sibling helper executable are required:

```sh
macarchy desktop borders preview --renderer lean --seconds 30
```

Existing Borders processes, Homebrew service registrations or another running
`macarchy-focus-ring` refuse the lean preview. The default renderer remains
JankyBorders; no managed service is selected.

## Driving it with verify.py

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py drive --run setup-<run-id> --session verify-<session-id> --journey borders
```

Requires an unlocked guest whose console owner is `omarchy` (the journey checks
only `stat -f %Su /dev/console`), existing host capture/AX grants and supported
zsh-only shell prerequisites. Do not auto-install or grant permissions. User
approval covers only fzf, zoxide, zsh-autosuggestions and zsh-syntax-highlighting in
`setup-650968813a9c`, not a new clone.

Preparation builds optimized CLI/helper and a guest-only native fixture, applies
a real zsh-only environment and activates Catppuccin in private state. It changes
the disposable guest's previously absent ~/.zshrc, not the host. Pinned incumbent:
JankyBorders1.9.0 commit a7297ca7d1933f3a30b12e8f10750e8d84eeee1e. An absent-only
guest /opt/homebrew/bin/borders link lets the existing preview drive it; cleanup
checks the exact target.

Later drives recheck preparation ownership, four artifact hashes and real status.
To test changed source, use `launch` for a new session in the SAME guest, then pass
`--candidate-session verify-<new-id>` to the prepared-session borders drive.
New release products and their snapshot/hashes are reported separately; no old
binary is overwritten while attributed to its previous snapshot.

`--border-count 1|8|24` selects an explicitly partial workload. Omit for all sizes.
Each size compares none/incumbent/lean, eight top samples; first CPU sample excluded.
Previews run 60 s (90 s for eight-window and motion cases). Each lean case must
report exactly completed/duration with no missing settled-action outline, and an
event-driven `update_driver` of `window-server-events` with enough geometry
refreshes (reports without a driver are accepted as `legacy-polling`). The
eight-window case also requires two theme generations, both Catppuccin and Tokyo
Night accents, and native-fullscreen hiding. Display geometry/scale must match
across cases; backing scale below 2 adds a Retina not-covered entry.
The eight-window case records20s plus later cross-app/fullscreen/theme PNGs.
A provisional24-window helper median<=half incumbent gate is not a universal
memory guarantee, total-system saving or leak-fix proof.

## Gotchas

### Qualified evidence and limitations

Evidence root on the Mac mini:
artifacts/vm/runs/setup-650968813a9c/verify-5d36b73c0e5b/.

- event-qualification.json: final candidate verify-a6343eea8a8b, snapshot
  f58746a7656e84e6e5daa9603046041da33bd66ad872212a9ed5fae73deaaf3a.
  Drives23(motion),24(8),25(24) passed without cleanup errors. Per-build artifact
  hashes are retained; same source is not a byte-reproducibility claim.
- Helper footprint medians: 1window19→10MiB, 8windows115→10MiB,
  24windows332→10MiB (97% lower). Sampled helper idleCPU0.1–0.2% versus
  incumbent0–0.1%, versus earlier polling2.5%. Not a memory-leak proof.
- WindowServer at24windows: none166/incumbent167/helper175MiB, CPU0.1% both
  bordered cases. Shared/noisy accounting; do not sum as attributable savings.
- One horizontal scanline: median0/p95 2px both; worst helper2 versus incumbent4.
  Actual active capture ~44.7fps both, not60/120fps. Single-edge detector misses:
  helper14/422 versus incumbent7/408; neither both missing. One sampled helper
  miss visibly contained the outline; do not assume every miss is detector noise.
  No-border negative control: zero accent detections in827 green frames.
- Same/cross-app focus, move/resize, minimize/restore, close, fullscreen hide/return
  and two canonical theme generations passed. Worst-motion/theme/fullscreen PNGs
  were inspected. Not exhaustive full-frame perceptual or pixel-identity proof.
- Videos: drive-borders-23/{borders,lean}-1/motion.mp4;
  drive-borders-24/lean-8/journey.mp4 (later actions have separate PNGs).
  Comparison: drive-borders-23/janky-left-macarchy-right-half-speed.mp4,
  Janky LEFT / Macarchy RIGHT, half speed, aligned first movement. Metrics use
  original variable-rate recordings, not the derived comparison.
- Guest1440×900/backing1; incumbent hidpi=on supersamples, helper uses native
  backing. Retina, ordinary Spaces, multiple displays, third-party apps,
  physical hardware and long-duration stability remain unqualified.
- At acceptance: 23 guarded helper Swift tests passed in 5 suites; earlier
  CLI-preview tests passed; 68 pure Python checks passed. No full/special-file
  suites on a physical Mac. The helper suites now hold 26 tests, and the helper
  and harness (`verify_borders.py`, `border_workload.py`, fixture) changed on
  2026-10-16, so this evidence does not describe current source.
- Supported guest shutdown passed. VM, helper, fixture and recorder stopped;
  approved temporary host/guest awake leases ended. No persistent setting changes,
  host provider switch, installation, release or commit.

### 2026-10-18 re-run at `0a499fff`

The same guest was restarted (`verify.py restart`, an approved same-guest
continuation) and run with candidate session `verify-86f4252f0b1d` against the
retained preparation (`drive-borders-26`, reused from `drive-borders-02`).
none-1, borders-1 and lean-1 passed. lean-1 reported `window-server-events`
with 91 geometry refreshes from 126 events, no missing outlines and the
Catppuccin accent. The no-border none-8 baseline then failed with recorder exit 1:
`short or sparse clip: 20.12 s, 29 frames`. No renderer runs in that case. The
cause is not established; the awake-lease `caffeinate` process had exited by the
time recovery checked it. No retry or motion drive ran. Evidence is in the mini's
primary checkout under `artifacts/vm/runs/setup-650968813a9c/`.

### Native capture constraints

Use --border-motion with --border-count1 for fixed14s guest-only motion and
requested60fps capture. Analysis reads existing video, never desktop pixels.

ScreenCaptureKit needs AppKit's physical main-thread run loop; dispatchMain
caused native privacy-UI failure. Never fall back to desktop capture. Display
sleep can freeze the stream despite live guest movement/screenshots. Keep sparse
video assertions. Awake leases require explicit approval; no silent renewal or
persistent settings changes. Guest-only caffeinate cannot keep host capture live.

Log in only with `verify.py login` (see ../SKILL.md, Drive); earlier SSH-credential
attempts did not establish a GUI login. Do not retry credentials, drive a locked
guest, send global input or steal host focus. Historical PIDs/windowIDs are not current kill targets.
