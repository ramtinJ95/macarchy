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

if [[ ! -x "$binary" ]]; then
  print -u2 "macarchy binary is not executable: $binary"
  exit 66
fi
if [[ ! -f "$fixture/profile.toml" ]]; then
  print -u2 "portable keybinding fixture is missing: $fixture"
  exit 66
fi

home="$temporary_directory/home"
dotfiles="$home/dotfiles/keybindings"
state_root="$home/.config/macarchy"
mkdir -p "$dotfiles" "$temporary_directory/work"
cp "$fixture/profile.toml" "$fixture/keybindings.skhdrc" \
  "$fixture/keybindings-metadata.toml" "$dotfiles/"

snapshot_home() {
  local destination=$1
  local root=$2
  local maximum_entries=256
  local maximum_regular_bytes=$((1024 * 1024))
  local entry_count=0
  local regular_bytes=0
  local entry_path mode type target digest size

  (
    cd "$root"
    while IFS= read -r entry_path; do
      (( ++entry_count ))
      if (( entry_count > maximum_entries )); then
        print -u2 "isolated HOME inventory exceeds $maximum_entries entries"
        exit 1
      fi

      mode=$(/usr/bin/stat -f '%Lp' "$entry_path")
      target=
      digest=
      if [[ -L "$entry_path" ]]; then
        type=symlink
        target=$(/usr/bin/readlink "$entry_path")
      elif [[ -d "$entry_path" ]]; then
        type=directory
      elif [[ -f "$entry_path" ]]; then
        type=regular
        size=$(/usr/bin/stat -f '%z' "$entry_path")
        (( regular_bytes += size ))
        if (( regular_bytes > maximum_regular_bytes )); then
          print -u2 "isolated HOME regular data exceeds $maximum_regular_bytes bytes"
          exit 1
        fi
        digest=$(/usr/bin/shasum -a 256 "$entry_path" | awk '{ print $1 }')
      elif [[ -p "$entry_path" ]]; then
        type=fifo
      elif [[ -S "$entry_path" ]]; then
        type=socket
      elif [[ -b "$entry_path" ]]; then
        type=block_device
      elif [[ -c "$entry_path" ]]; then
        type=character_device
      else
        type=unknown
      fi

      print -r -- \
        "path=${(qqq)entry_path} type=$type mode=$mode target=${(qqq)target} digest=$digest"
    done < <(find -P . -print | LC_ALL=C sort)
    if (( entry_count == 0 )); then
      print -u2 "isolated HOME inventory is unexpectedly empty"
      exit 1
    fi
  ) > "$destination"
}

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
