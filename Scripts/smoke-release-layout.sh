#!/bin/zsh

set -eu

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 <release-layout>"
  exit 64
fi

layout=${1:A}
binary="$layout/bin/macarchy"
metadata="$layout/share/macarchy/build-info.json"
resources="$layout/share/macarchy"
script_directory=${0:A:h}
repository_root=${script_directory:h}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-layout-smoke.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
home="$temporary_directory/home"
work="$home/work"
runtime_tmp="$home/tmp"
snapshot_source="$script_directory/keybindings-portability-snapshot.swift"
snapshot_helper="$temporary_directory/keybindings-portability-snapshot"
mkdir -p "$work" "$runtime_tmp"

[[ -x "$binary" ]]
[[ -f "$metadata" ]]
[[ -d "$layout/share/macarchy/themes" ]]
[[ -f "$layout/share/macarchy/keybindings/defaults.skhdrc" ]]
[[ -f "$layout/share/macarchy/keybindings/metadata.toml" ]]
[[ -f "$layout/share/macarchy/desktop/yabai/defaults.toml" ]]
[[ -f "$layout/share/doc/macarchy/CHANGELOG.md" ]]
[[ -f "$layout/share/doc/macarchy/theme-json.md" ]]
[[ -f "$layout/share/doc/macarchy/LICENSE" ]]
[[ -f "$snapshot_source" ]]
[[ -z "$(find -P "$layout" ! -type f ! -type d -print)" ]]
/usr/bin/codesign --verify --strict "$binary"
signature=$(/usr/bin/codesign -dv --verbose=2 "$binary" 2>&1)
print -r -- "$signature" | grep -q '^Signature=adhoc$'

{
  print "bin/macarchy"
  print "share/macarchy/build-info.json"
  print "share/doc/macarchy/CHANGELOG.md"
  print "share/doc/macarchy/theme-json.md"
  print "share/doc/macarchy/LICENSE"
  git -C "$repository_root" ls-files -- Themes \
    | sed 's#^Themes/#share/macarchy/themes/#'
  git -C "$repository_root" ls-files -- Keybindings \
    | sed 's#^Keybindings/#share/macarchy/keybindings/#'
  git -C "$repository_root" ls-files -- Desktop \
    | sed 's#^Desktop/#share/macarchy/desktop/#'
} | LC_ALL=C sort > "$temporary_directory/expected-inventory.txt"
(
  cd "$layout"
  find -P . -type f -print | sed 's#^\./##' | LC_ALL=C sort
) > "$temporary_directory/actual-inventory.txt"
diff -u \
  "$temporary_directory/expected-inventory.txt" \
  "$temporary_directory/actual-inventory.txt"

xcrun swiftc "$snapshot_source" -o "$snapshot_helper"
snapshot_tree() {
  local destination=$1
  local root=$2
  if [[ ${destination:A} == ${root:A} || ${destination:A} == ${root:A}/* ]]; then
    print -u2 "snapshot output must be outside its root: $destination"
    exit 64
  fi
  "$snapshot_helper" "$root" > "$destination"
}

version=$(/usr/bin/plutil -extract version raw -o - "$metadata")
snapshot_tree "$temporary_directory/home-before.json" "$home"
snapshot_tree "$temporary_directory/resources-before.json" "$resources"
cd "$work"

[[ "$(HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" --version)" == "$version" ]]
HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" version --json \
  > "$temporary_directory/version.json"
grep -q "\"version\" : \"$version\"" "$temporary_directory/version.json"
grep -q '"installation" : "unmanaged"' "$temporary_directory/version.json"

themes=$(HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" theme list)
[[ "$(print -r -- "$themes" | wc -l | tr -d ' ')" == "3" ]]
print -r -- "$themes" | grep -q '^catppuccin-mocha'
print -r -- "$themes" | grep -q '^kanagawa-wave'
print -r -- "$themes" | grep -q '^tokyo-night'

HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" keybindings list \
  --skhd-config "$layout/share/macarchy/keybindings/defaults.skhdrc" \
  --catalog "$layout/share/macarchy/keybindings/metadata.toml" \
  --json > "$temporary_directory/keybindings-list.json"
grep -q '"schema_version" : 1' "$temporary_directory/keybindings-list.json"
[[ "$(grep -c '"identity" :' "$temporary_directory/keybindings-list.json")" == "48" ]]

"$script_directory/verify-keybindings-portability.sh" "$binary"

HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" desktop plan --json > "$temporary_directory/desktop-plan.json"
grep -q '"operation" : "desktop_plan"' "$temporary_directory/desktop-plan.json"
grep -q '"mutated" : false' "$temporary_directory/desktop-plan.json"
grep -q '"desktop_provider" : "yabai-skhd"' "$temporary_directory/desktop-plan.json"

snapshot_tree "$temporary_directory/home-after.json" "$home"
snapshot_tree "$temporary_directory/resources-after.json" "$resources"
cmp "$temporary_directory/home-before.json" "$temporary_directory/home-after.json"
cmp "$temporary_directory/resources-before.json" "$temporary_directory/resources-after.json"

print "release layout smoke test passed"
