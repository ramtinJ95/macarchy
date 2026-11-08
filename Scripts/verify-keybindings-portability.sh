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
binary_directory=${binary:h}
if [[ ${binary_directory:t} == "bin" \
  && -f "${binary_directory:h}/share/macarchy/build-info.json" ]]
then
  packaged_resources="${binary_directory:h}/share/macarchy"
else
  packaged_resources="$repository_root/Keybindings"
fi

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
if [[ ! -d "$packaged_resources" ]]; then
  print -u2 "packaged resources are missing: $packaged_resources"
  exit 66
fi

xcrun swiftc "$snapshot_source" -o "$snapshot_helper"

home="$temporary_directory/home"
dotfiles="$home/dotfiles/keybindings"
state_root="$home/.config/macarchy"
work="$home/work"
runtime_tmp="$home/tmp"
mkdir -p "$dotfiles" "$work" "$runtime_tmp"
cp "$fixture/profile.toml" "$fixture/keybindings.skhdrc" \
  "$fixture/keybindings-metadata.toml" "$dotfiles/"

snapshot_home() {
  local destination=$1
  local root=$2
  if [[ ${destination:A} == ${root:A} || ${destination:A} == ${root:A}/* ]]; then
    print -u2 "snapshot output must be outside its root: $destination"
    exit 64
  fi
  "$snapshot_helper" "$root" > "$destination"
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
ctrl+alt+shift-c
ctrl+alt-c
ctrl+alt-h
ctrl+alt-j
ctrl+alt-k
ctrl+alt-l
ctrl+alt-space
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

run_plan() {
  local destination=$1
  shift
  local exit_status
  if HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
    "$binary" keybindings plan \
      "$@" \
      --state-root "$state_root" \
      --json > "$destination"
  then
    exit_status=0
  else
    exit_status=$?
  fi

  local outcome
  outcome=$(/usr/bin/plutil -extract outcome raw -o - "$destination")
  if [[ "$exit_status" == "0" ]]; then
    [[ "$outcome" == "ready" ]]
    return
  fi
  if [[ "$exit_status" != "1" || "$outcome" != "blocked" ]]; then
    print -u2 "keybinding plan failed outside the supported lifecycle boundary"
    exit 1
  fi
  [[ "$(/usr/bin/plutil -extract diagnostics raw -o - "$destination")" == "1" ]]
  local prerequisite
  prerequisite=$(/usr/bin/plutil -extract diagnostics.0.code raw -o - "$destination")
  [[ "$prerequisite" == "skhd_process_prerequisite" \
    || "$prerequisite" == "skhd_service_prerequisite" ]]
  if [[ "$prerequisite" == "skhd_process_prerequisite" ]]; then
    [[ "$(/usr/bin/plutil -extract process.status raw -o - "$destination")" \
      == "not_running" ]]
  fi
  # A host process can be running while this isolated HOME has no matching
  # LaunchAgent. That is a service prerequisite, not authority to control it.
  [[ "$(/usr/bin/plutil -extract actions raw -o - "$destination")" == "0" ]]
}

snapshot_home "$temporary_directory/home-before.txt" "$home"
snapshot_home "$temporary_directory/resources-before.txt" "$packaged_resources"
cd "$work"

for run in default-first default-second; do
  run_plan "$temporary_directory/$run.json"
done

for run in first second; do
  run_plan "$temporary_directory/$run.json" --profile "$dotfiles/profile.toml"
done

cmp "$temporary_directory/default-first.json" "$temporary_directory/default-second.json"
cmp "$temporary_directory/first.json" "$temporary_directory/second.json"
snapshot_home "$temporary_directory/home-after.txt" "$home"
snapshot_home "$temporary_directory/resources-after.txt" "$packaged_resources"
cmp "$temporary_directory/home-before.txt" "$temporary_directory/home-after.txt"
cmp "$temporary_directory/resources-before.txt" "$temporary_directory/resources-after.txt"

[[ "$(/usr/bin/plutil -extract mutated raw -o - \
  "$temporary_directory/default-first.json")" == "false" ]]
[[ "$(/usr/bin/plutil -extract summary.effective raw -o - \
  "$temporary_directory/default-first.json")" == "51" ]]
[[ "$(/usr/bin/plutil -extract mutated raw -o - "$temporary_directory/first.json")" == "false" ]]
[[ "$(/usr/bin/plutil -extract summary.effective raw -o - "$temporary_directory/first.json")" == "51" ]]
[[ "$(/usr/bin/plutil -extract summary.packaged_defaults raw -o - "$temporary_directory/first.json")" == "51" ]]
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
