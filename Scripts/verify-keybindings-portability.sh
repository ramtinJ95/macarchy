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

snapshot() {
  local destination=$1
  (
    cd "$dotfiles"
    find -P . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      /usr/bin/shasum -a 256 "$file"
    done
  ) > "$destination"
}

snapshot "$temporary_directory/portable-before.sha256"
cd "$temporary_directory/work"

for run in first second; do
  HOME="$home" CFFIXED_USER_HOME="$home" \
    "$binary" keybindings plan \
      --profile "$dotfiles/profile.toml" \
      --state-root "$state_root" \
      --json > "$temporary_directory/$run.json"
done

cmp "$temporary_directory/first.json" "$temporary_directory/second.json"
snapshot "$temporary_directory/portable-after.sha256"
cmp "$temporary_directory/portable-before.sha256" "$temporary_directory/portable-after.sha256"

[[ "$(/usr/bin/plutil -extract mutated raw -o - "$temporary_directory/first.json")" == "false" ]]
[[ "$(/usr/bin/plutil -extract summary.user_replacements raw -o - "$temporary_directory/first.json")" == "1" ]]
[[ "$(/usr/bin/plutil -extract summary.user_additions raw -o - "$temporary_directory/first.json")" == "1" ]]
[[ "$(/usr/bin/plutil -extract summary.disabled_defaults raw -o - "$temporary_directory/first.json")" == "1" ]]
rendered=$(/usr/bin/plutil -extract rendered_skhdrc raw -o - "$temporary_directory/first.json")
print -r -- "$rendered" | grep -q '^alt - j : personal focus south$'
print -r -- "$rendered" | grep -q '^cmd - x : personal open extra$'
if print -r -- "$rendered" | grep -q '^alt - k :'; then
  print -u2 "disabled packaged binding appeared in effective output"
  exit 1
fi

if [[ -e "$state_root" ]]; then
  print -u2 "read-only planning created generated state: $state_root"
  exit 1
fi

print "isolated keybinding portability verification passed"
