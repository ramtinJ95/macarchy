#!/bin/zsh

set -eu

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 <release-layout>"
  exit 64
fi

layout=${1:A}
binary="$layout/bin/macarchy"
metadata="$layout/share/macarchy/build-info.json"
script_directory=${0:A:h}
repository_root=${script_directory:h}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-layout-smoke.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
mkdir -p "$temporary_directory/home" "$temporary_directory/work"

[[ -x "$binary" ]]
[[ -f "$metadata" ]]
[[ -d "$layout/share/macarchy/themes" ]]
[[ -f "$layout/share/macarchy/keybindings/defaults.skhdrc" ]]
[[ -f "$layout/share/macarchy/keybindings/metadata.toml" ]]
[[ -f "$layout/share/doc/macarchy/CHANGELOG.md" ]]
[[ -f "$layout/share/doc/macarchy/theme-json.md" ]]
[[ -f "$layout/share/doc/macarchy/LICENSE" ]]
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
} | LC_ALL=C sort > "$temporary_directory/expected-inventory.txt"
(
  cd "$layout"
  find -P . -type f -print | sed 's#^\./##' | LC_ALL=C sort
) > "$temporary_directory/actual-inventory.txt"
diff -u \
  "$temporary_directory/expected-inventory.txt" \
  "$temporary_directory/actual-inventory.txt"

version=$(/usr/bin/plutil -extract version raw -o - "$metadata")
cd "$temporary_directory/work"

[[ "$(HOME="$temporary_directory/home" "$binary" --version)" == "$version" ]]
HOME="$temporary_directory/home" "$binary" version --json \
  > "$temporary_directory/version.json"
grep -q "\"version\" : \"$version\"" "$temporary_directory/version.json"
grep -q '"installation" : "unmanaged"' "$temporary_directory/version.json"

themes=$(HOME="$temporary_directory/home" "$binary" theme list)
[[ "$(print -r -- "$themes" | wc -l | tr -d ' ')" == "3" ]]
print -r -- "$themes" | grep -q '^catppuccin-mocha'
print -r -- "$themes" | grep -q '^kanagawa-wave'
print -r -- "$themes" | grep -q '^tokyo-night'

print "release layout smoke test passed"
