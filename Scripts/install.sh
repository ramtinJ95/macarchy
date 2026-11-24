#!/bin/bash
# Thin public bootstrap: Homebrew owns trust, archive checksums and installation;
# the tapped formula owns installed-release tests; Macarchy owns guided setup.
set -euo pipefail

formula=ramtinj95/tap/macarchy
tap=ramtinj95/tap

fail() {
  printf 'Macarchy installer: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local answer
  printf '%s [y/N] ' "$1"
  IFS= read -r answer || return 1
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

[[ $# == 0 ]] || fail 'No arguments supported. Run this installer in an interactive terminal.'
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] ||
  fail 'Requires Apple Silicon (arm64) and macOS 26. Intel, Rosetta and other platforms are unsupported.'
[[ "$(sw_vers -productVersion)" == 26.* ]] || fail 'Requires macOS 26; other macOS versions are unsupported.'

command -v brew >/dev/null 2>&1 || fail 'Homebrew is missing from PATH. Install it yourself using the official instructions at https://brew.sh/ then rerun this command. If already installed, run: eval "$(/opt/homebrew/bin/brew shellenv)"'
brew --version >/dev/null || fail 'Homebrew cannot run. Repair it using https://docs.brew.sh/Troubleshooting then rerun this command.'
brew_prefix=$(brew --prefix) || fail 'Cannot determine the Homebrew prefix. Inspect: brew --prefix'
[[ "$brew_prefix" == /opt/homebrew ]] || fail "Requires native Apple Silicon Homebrew at /opt/homebrew, not $brew_prefix. No tap or trust changes were requested. Use https://brew.sh/ for the supported installation; if it already exists, run: eval \"\$(/opt/homebrew/bin/brew shellenv)\" then rerun this command. Do not move or change ownership of an existing Homebrew."
xcode-select -p >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1 ||
  fail 'Working Xcode Command Line Tools are required. Run: xcode-select --install (https://developer.apple.com/xcode/resources/), finish installation, then rerun this command.'
[[ -t 0 && -t 1 ]] || fail 'Use an interactive terminal; trust and guided setup require your input. No unattended installation is supported.'

# Process-local only. Never change the users global Homebrew settings.
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_AUTOREMOVE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALL_UPGRADE=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
export MACARCHY_DISABLE_UPDATE_CHECKS=1

installed=$(brew list --formula --full-name) || fail 'Cannot inspect installed Homebrew formulae; no installation attempted. Run: brew doctor'
existing=false
while IFS= read -r name; do
  case "$name" in
    "$formula") existing=true ;;
    macarchy|*/macarchy) fail "A different or unidentified Macarchy formula is installed ($name). Resolve its ownership in Homebrew before continuing; nothing was replaced." ;;
  esac
done <<< "$installed"

if [[ "$existing" == true ]]; then
  prefix=$(brew --prefix "$formula") || fail "Cannot locate the installed formula. Inspect: brew info $formula"
  path_macarchy=$(command -v macarchy || true)
  [[ -n "$path_macarchy" && "$path_macarchy" -ef "$prefix/bin/macarchy" ]] ||
    fail "PATH does not select the Homebrew-owned Macarchy ($path_macarchy). Remove any shadowing alias/wrapper or fix PATH with: eval \"\$(/opt/homebrew/bin/brew shellenv)\". If the Homebrew command link is missing, inspect: brew info $formula and deliberately restore its link. Nothing was replaced or executed."
fi

if [[ "$existing" == false ]]; then
  if command -v macarchy >/dev/null 2>&1; then
    fail "Macarchy is already on PATH but is not owned by $formula. Resolve that installation first; nothing was replaced."
  fi
  printf '%s\n' \
    'This downloads the third-party tap https://github.com/ramtinJ95/homebrew-tap for review.' \
    'Homebrew will own Macarchy. No Homebrew installation, package upgrades or cleanup will run.'
  confirm "Fetch $tap for formula review?" || { printf 'Cancelled; no tap, trust or packages changed.\n'; exit 0; }
  brew tap "$tap" || fail 'Tap download failed; Homebrew may retain tap/cache files. No formula trust or installation was requested. Fix the reported error and rerun this command.'
  printf '\nReview the exact executable formula (including its release URL, SHA-256 and tests):\n\n'
  # `brew cat` enables persistent developer mode and may install an optional bat
  # pager. Read the known tapped formula as inert bytes instead.
  repository=$(brew --repository "$tap") || fail 'Cannot locate the tapped formula; no trust or installation requested.'
  [[ "$repository" == /* && "$repository" != *$'\n'* ]] || fail 'Homebrew returned an invalid tap repository; no trust or installation requested.'
  /bin/cat "$repository/Formula/macarchy.rb" || fail 'Formula review failed; no formula trust or installation was requested. Fix the reported error and rerun this command.'
  printf '\n%s\n' \
    'Approving persists Homebrew trust for this formula only (including future revisions), then installs it.' \
    'It does not trust the whole tap or approve configuration, permissions or other packages.' \
    'Homebrew verifies the archive against the formulas SHA-256; release provenance is checked before tap publication.'
  confirm "Trust and install $formula?" || { printf 'Cancelled; tap retained, no formula trust or installation requested.\n'; exit 0; }
  brew trust --formula "$formula" || fail 'Exact formula trust failed. No install was requested. Inspect Homebrews error and rerun this command when ready.'
  brew install --formula --no-ask "$formula" ||
    fail 'Installation failed or is partial; trust and Homebrew files may remain. No rollback, upgrade or cleanup was attempted. Inspect the error and run: brew doctor. Then rerun this command; if Homebrew reports Macarchy installed but broken, use the scoped repair in https://github.com/ramtinJ95/macarchy/blob/main/Documentation/install.md'
else
  printf 'Macarchy is already Homebrew-owned. Verifying without upgrading, reinstalling or changing trust.\n'
fi

if [[ "$existing" == false ]]; then
  prefix=$(brew --prefix "$formula") || fail "Cannot locate the installed formula. Inspect: brew info $formula"
fi
[[ "$prefix" == /* && "$prefix" != *$'\n'* && -x "$prefix/bin/macarchy" ]] ||
  fail 'Installed Macarchy executable is missing or its prefix is invalid. Use the scoped repair in https://github.com/ramtinJ95/macarchy/blob/main/Documentation/install.md'
if [[ "$existing" == true ]]; then
  # brew test requires the latest tapped version, even when the installed release
  # is healthy. Assert its same version/ownership/platform/revision/helper/theme
  # contract against this installed keg, never the new formula or a PATH command.
  printf '\nVerifying the installed release independently of the current tap version.\n'
  version=$("$prefix/bin/macarchy" --version) || fail 'Installed version reporting failed; no repair or upgrade attempted.'
  report=$("$prefix/bin/macarchy" version --json) || fail 'Installed version reporting failed; no repair or upgrade attempted.'
  field() { printf '%s' "$report" | plutil -extract "$1" raw -o - -; }
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] &&
    [[ "$(field schema_version)" == 1 && "$(field version)" == "$version" &&
       "$(field installation)" == homebrew && "$(field platform)" == macos-arm64 &&
       "$(field revision)" =~ ^[0-9a-f]{40}$ ]] || fail 'Installed-release verification failed: invalid version/ownership/platform/revision metadata. No repair or upgrade attempted.'
  [[ -x "$prefix/libexec/ttfx" ]] || fail 'Installed-release verification failed: bundled ttfx helper is missing. No repair or upgrade attempted.'
  themes=$("$prefix/bin/macarchy" theme list) || fail 'Installed-release verification failed: built-in themes could not be read. No repair or upgrade attempted.'
  [[ "$themes" == $'catppuccin-mocha\tdark\tCatppuccin Mocha\nkanagawa-wave\tdark\tKanagawa Wave\ntokyo-night\tdark\tTokyo Night' ]] ||
    fail 'Installed-release verification failed: built-in themes are incomplete. No repair or upgrade attempted.'
  printf '%s\n\nInstalled Macarchy %s verified.\n' "$report" "$version"
  # Named brew outdated returns 1 for an available update; errors must not be
  # confused with either an up-to-date or a broken installed release.
  update_status=0
  outdated=$(brew outdated --formula --quiet "$formula") || update_status=$?
  if [[ "$update_status" == 1 && ( "$outdated" == "$formula" || "$outdated" == macarchy ) ]]; then
    printf 'An update is available in the local tap. Run: macarchy update\n'
  elif [[ "$update_status" != 0 || -n "$outdated" ]]; then
    printf 'Update availability could not be checked; the installed release passed verification. To check and update deliberately, run: macarchy update\n'
  fi
  printf 'No upgrade or setup changes were made. For upgrades run: macarchy update\n'
  printf 'Next: macarchy setup guided\nIf you already saved a guided profile: macarchy setup guided --resume\n'
  exit 0
fi
printf '\nVerifying with the existing Homebrew formula test (version, ownership, platform, revision, helper and built-in themes).\n'
# Test is also a developer command. A command-local setting prevents Homebrew
# from persisting developer mode in its git config; do not export it to setup.
HOMEBREW_DEVELOPER=1 brew test "$formula" || fail 'Installed-release verification failed. Macarchy remains installed; guided setup was not started. Use the scoped repair in https://github.com/ramtinJ95/macarchy/blob/main/Documentation/install.md'
"$prefix/bin/macarchy" version --json || fail 'Installed version reporting failed; guided setup was not started. Use the scoped repair in https://github.com/ramtinJ95/macarchy/blob/main/Documentation/install.md'
printf '\nMacarchy installed and formula tests passed.\n'

printf 'Starting guided setup. Configuration, packages and native permissions require separate approval.\n'
printf 'If interrupted after saving a profile, run: macarchy setup guided --resume\n'
if "$prefix/bin/macarchy" setup guided; then
  exit 0
else
  result=$?
  printf 'Guided setup exited with status %s; Macarchy remains installed. Follow its diagnostics.\n' "$result" >&2
  printf 'Next: macarchy setup guided (or macarchy setup guided --resume if a profile was saved).\n' >&2
  exit "$result"
fi
