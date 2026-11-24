# One-command installer

Requires an interactive terminal on **Apple Silicon, macOS 26**, with working
[Homebrew](https://brew.sh/) and Xcode Command Line Tools (`xcode-select --install`).
The installer checks these prerequisites; it never installs them for you.

Run this single command:

```sh
(/bin/bash -c 'set -eu; f="$(mktemp -t macarchy-install)"; trap '\''rm -f "$f"'\'' EXIT; curl --fail --silent --show-error --location https://raw.githubusercontent.com/ramtinJ95/macarchy/main/Scripts/install.sh -o "$f"; /bin/bash "$f"')
```

This downloads the complete script successfully before executing it, and removes
the temporary download on exit. It does **not** authenticate the script separately
from GitHub HTTPS: you are trusting this repository's **mutable `main` branch as
executable code**. To inspect first, download that URL to a file, read it, then
run `/bin/bash /path/to/your/download` from your terminal. The script is not piped
to Bash, so prompts and guided setup retain terminal input.

## What it does

1. Checks platform, Homebrew, developer tools and interactive input before mutation.
2. Asks before downloading `ramtinj95/tap`, then displays the exact Macarchy formula
   for review, including the archive URL, SHA-256, installation code and tests.
3. Asks default-no consent to persist trust for **only**
   `ramtinj95/tap/macarchy` and install it. Trust covers future revisions of that
   formula, not the whole tap. Homebrew verifies the downloaded archive's checksum.
   Existing release tooling verifies checksums and GitHub attestations before
   publishing the tap update; the bootstrap does not add a second archive channel.
4. Runs the existing Homebrew formula test against the installed release and shows
   its version, Git revision, platform and Homebrew ownership.
5. Starts `macarchy setup guided`. Its package/configuration approvals and manual
   native permission decisions are separate; installer approval does not grant them.

Homebrew owns the installation. Automatic Homebrew metadata refresh, package
upgrades, dependent checks, autoremove and cleanup are disabled for this process;
no global Homebrew settings are changed. An already-present tap is not refreshed
implicitly. To refresh metadata deliberately, use `brew update` separately.

## Cancellation, reruns and recovery

- Declining tap download changes nothing. Declining formula trust/install leaves
  the fetched tap but requests no trust or package installation. Homebrew may keep
  download/cache files after a failure; the installer does not claim rollback.
- Rerunning verifies an existing exact Homebrew-owned Macarchy without upgrading,
  reinstalling, changing trust or starting setup again. It prints the next commands:
  `macarchy setup guided`, or `macarchy setup guided --resume` for a saved profile.
  Use `macarchy update` for upgrades. A different/unmanaged installation is refused.
- After failed or partial installation, inspect Homebrew's error and `brew doctor`.
  If Macarchy is absent, rerun the installer. If installed but verification fails,
  review the formula (`brew cat --formula ramtinj95/tap/macarchy`) and deliberately
  repair **only Macarchy**, with no automatic cleanup/dependent upgrades:

  ```sh
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
    HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
    brew reinstall --formula ramtinj95/tap/macarchy
  ```

  Then rerun the installer for verification. No downgrade or automatic rollback
  is promised. Existing configuration and saved profiles are not deleted.
- A guided-setup failure leaves Macarchy installed. Follow its diagnostics and use
  `macarchy setup guided --resume` once a profile has been saved; otherwise use
  `macarchy setup guided`. Re-running installation is not a permission repair.

The README quickstart will adopt this entry point in the beta-documentation slice.
