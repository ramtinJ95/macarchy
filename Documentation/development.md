# Development

[Back to Macarchy](../README.md) · [User guide](user-guide.md)

Development builds require Swift 6.2 or newer on the supported Mac:

```sh
git clone https://github.com/ramtinJ95/macarchy.git
cd macarchy
swift build
.build/debug/macarchy theme list
```

Use `.build/debug/macarchy` in place of `macarchy` to run the current code.
It uses your normal configuration unless you supply alternate paths; building
alone does not install or activate anything.

```sh
swift format lint --strict --recursive Package.swift Sources Tests
swift test
swift build -c release
```

Tests use temporary roots, not your live Macarchy state. CI also validates the
release archive and installed layout. The theme format is documented in
[theme-json.md](theme-json.md).

### CI behavior

PRs run the complete Swift suite and release archive checks unless their entire
diff changes only the root `README.md` and/or `AGENTS.md`. Shipped documentation,
themes, defaults, scripts and unknown paths still require full verification.
Classification failures fail CI; an intentionally skipped build still produces
the final `macOS 26 arm64` check. New pushes cancel older runs of the same PR.
Pushes to `main` always run the full checks and do not cancel each other.

Ordinary CI caches SwiftPM dependency checkouts and debug/release build state,
matched to the OS, architecture, compiler, SDK, package manifests and workflow.
Source/test Git trees identify cache entries, so safe documentation commits do not
upload duplicate build state. Other tracked inputs also constrain cache
compatibility: changing root files, resources or scripts starts a cold build.
This prevents cached native dependencies from hiding new header-name collisions.
Debug builds use Swift's native incremental file hashing
to recognize unchanged inputs despite fresh checkout timestamps; real edits
still require compilation. No source timestamps are rewritten.
It always invokes the builds and tests after restoring a cache; a cache hit is
not verification. The job summary reports cache reuse, and Actions step timings
show its actual benefit. Stable release publication remains an uncached build
with the full tests, archive validation and provenance checks.

The lightweight change-classification tests run without Swift:

```sh
python3 -B Scripts/test-ci-changes.py
```
