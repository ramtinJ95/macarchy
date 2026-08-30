#!/bin/zsh

set -eu

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 <macarchy-binary>"
  exit 64
fi

binary=${1:A}
script_directory=${0:A:h}
repository_root=${script_directory:h}
fixture="$repository_root/Tests/Fixtures/Keybindings/Portability/portable"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-keybindings-portability.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
snapshot_source="$script_directory/keybindings-portability-snapshot.swift"
snapshot_helper="$temporary_directory/keybindings-portability-snapshot"

if [[ ! -x "$binary" ]]; then
  print -u2 "macarchy binary is not executable: $binary"
  exit 66
fi
if [[ ! -f "$fixture/profile.toml" ]]; then
  print -u2 "portable keybinding fixture is missing: $fixture"
  exit 66
fi
if [[ ! -f "$snapshot_source" ]]; then
  print -u2 "portability snapshot helper is missing: $snapshot_source"
  exit 66
fi

xcrun swiftc "$snapshot_source" -o "$snapshot_helper"

home="$temporary_directory/home"
dotfiles="$home/dotfiles/keybindings"
state_root="$home/.config/macarchy"
mkdir -p "$dotfiles" "$temporary_directory/work"
cp "$fixture/profile.toml" "$fixture/keybindings.skhdrc" \
  "$fixture/keybindings-metadata.toml" "$dotfiles/"

snapshot_home() {
  local destination=$1
  local root=$2
  "$snapshot_helper" "$root" > "$destination"
}

assert_snapshot_rejected() {
  local label=$1
  local root=$2
  local expected=$3
  if "$snapshot_helper" "$root" \
    > "$temporary_directory/$label.json" \
    2> "$temporary_directory/$label.stderr"; then
    print -u2 "unsafe snapshot fixture was accepted: $label"
    exit 1
  fi
  grep -qF "$expected" "$temporary_directory/$label.stderr"
}

overflow_root="$temporary_directory/snapshot-overflow"
mkdir -p "$overflow_root"
for index in {1..256}; do
  : > "$overflow_root/entry-$index"
done
assert_snapshot_rejected \
  overflow "$overflow_root" "isolated HOME inventory exceeds 256 entries"

fifo_root="$temporary_directory/snapshot-fifo"
mkdir -p "$fifo_root"
mkfifo "$fifo_root/entry"
assert_snapshot_rejected \
  fifo "$fifo_root" "not a pinned regular file or directory"

symlink_root="$temporary_directory/snapshot-symlink"
mkdir -p "$symlink_root"
ln -s missing "$symlink_root/entry"
assert_snapshot_rejected \
  symlink "$symlink_root" "not a pinned regular file or directory"

write_expected_identities() {
  cat > "$1" <<'EOF'
alt+shift-1
alt+shift-2
alt+shift-3
alt+shift-4
alt+shift-5
alt+shift-6
alt+shift-7
alt+shift-a
alt+shift-d
alt+shift-e
alt+shift-g
alt+shift-h
alt+shift-j
alt+shift-k
alt+shift-l
alt+shift-m
alt+shift-n
alt+shift-p
alt+shift-r
alt+shift-s
alt+shift-t
alt+shift-w
alt+shift-x
alt+shift-y
alt-a
alt-h
alt-j
alt-l
cmd+ctrl+alt+shift-x
cmd+shift-a
cmd+shift-d
cmd+shift-f
cmd+shift-s
cmd+shift-t
cmd+shift-w
cmd-1
cmd-2
cmd-3
cmd-4
cmd-5
cmd-6
cmd-7
cmd-k
cmd-x
ctrl+alt-h
ctrl+alt-j
ctrl+alt-k
ctrl+alt-l
EOF
}

write_actual_identities() {
  local report=$1
  local destination=$2
  local unsorted="$destination.unsorted"
  local count index
  count=$(/usr/bin/plutil -extract bindings raw -o - "$report")
  : > "$unsorted"
  for (( index = 0; index < count; index += 1 )); do
    /usr/bin/plutil -extract "bindings.$index.identity" raw -o - "$report" \
      >> "$unsorted"
  done
  LC_ALL=C sort "$unsorted" > "$destination"
}

assert_untouched_packaged_binding() {
  local report=$1
  local count index identity
  count=$(/usr/bin/plutil -extract bindings raw -o - "$report")
  for (( index = 0; index < count; index += 1 )); do
    identity=$(/usr/bin/plutil -extract "bindings.$index.identity" raw -o - "$report")
    if [[ "$identity" == "alt-h" ]]; then
      [[ "$(/usr/bin/plutil -extract "bindings.$index.command_source" raw -o - "$report")" \
        == "packaged_default" ]]
      [[ "$(/usr/bin/plutil -extract "bindings.$index.command" raw -o - "$report")" \
        == "yabai -m window --focus west" ]]
      return
    fi
  done
  print -u2 "known untouched packaged binding alt-h is missing"
  exit 1
}

snapshot_home "$temporary_directory/home-before.txt" "$home"
cd "$temporary_directory/work"

for run in first second; do
  HOME="$home" CFFIXED_USER_HOME="$home" \
    "$binary" keybindings plan \
      --profile "$dotfiles/profile.toml" \
      --state-root "$state_root" \
      --json > "$temporary_directory/$run.json"
done

cmp "$temporary_directory/first.json" "$temporary_directory/second.json"
snapshot_home "$temporary_directory/home-after.txt" "$home"
cmp "$temporary_directory/home-before.txt" "$temporary_directory/home-after.txt"

[[ "$(/usr/bin/plutil -extract outcome raw -o - "$temporary_directory/first.json")" == "ready" ]]
[[ "$(/usr/bin/plutil -extract mutated raw -o - "$temporary_directory/first.json")" == "false" ]]
[[ "$(/usr/bin/plutil -extract summary.effective raw -o - "$temporary_directory/first.json")" == "48" ]]
[[ "$(/usr/bin/plutil -extract summary.packaged_defaults raw -o - "$temporary_directory/first.json")" == "48" ]]
[[ "$(/usr/bin/plutil -extract summary.user_replacements raw -o - "$temporary_directory/first.json")" == "1" ]]
[[ "$(/usr/bin/plutil -extract summary.user_additions raw -o - "$temporary_directory/first.json")" == "1" ]]
[[ "$(/usr/bin/plutil -extract summary.disabled_defaults raw -o - "$temporary_directory/first.json")" == "1" ]]
write_expected_identities "$temporary_directory/expected-identities.txt"
write_actual_identities "$temporary_directory/first.json" "$temporary_directory/actual-identities.txt"
diff -u "$temporary_directory/expected-identities.txt" "$temporary_directory/actual-identities.txt"
assert_untouched_packaged_binding "$temporary_directory/first.json"
rendered=$(/usr/bin/plutil -extract rendered_skhdrc raw -o - "$temporary_directory/first.json")
print -r -- "$rendered" | grep -q '^alt - j : personal focus south$'
print -r -- "$rendered" | grep -q '^cmd - x : personal open extra$'
if print -r -- "$rendered" | grep -q '^alt - k :'; then
  print -u2 "disabled packaged binding appeared in effective output"
  exit 1
fi

if [[ -e "$state_root" || -L "$state_root" ]]; then
  print -u2 "read-only planning created generated state: $state_root"
  exit 1
fi

print "isolated keybinding portability verification passed"
