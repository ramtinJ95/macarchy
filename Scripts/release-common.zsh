# Shared release input checks. Source after `set -eu`; failures exit 65.

# ttfx v0.5.0 (MIT), the screensaver engine bundled in the release archive. The full
# commit ID is the integrity pin: Scripts/build-ttfx.sh refuses any other checkout.
ttfx_repository=https://github.com/omacom/ttfx.git
ttfx_revision=112ebb310b848d8f1251a5c2919a9cd5a5c78e18
ttfx_version=0.5.0

# Reads the stable semantic version from VERSION.txt into $version.
read_release_version() {
  local version_file=$1
  if ! IFS= read -r version < "$version_file"; then
    print -u2 "VERSION.txt must contain one newline-terminated semantic version"
    exit 65
  fi
  local version_bytes
  version_bytes=$(wc -c < "$version_file" | tr -d ' ')
  if [[ "$version_bytes" -ne $((${#version} + 1)) ]] \
    || ! print -r -- "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
  then
    print -u2 "VERSION.txt must contain a stable semantic version"
    exit 65
  fi
}

require_release_revision() {
  if ! print -r -- "$1" | grep -Eq '^[0-9a-f]{40}$'; then
    print -u2 "git revision must be a 40-character lowercase object ID"
    exit 65
  fi
}
