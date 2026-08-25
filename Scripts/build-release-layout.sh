#!/bin/zsh

set -eu

if [[ $# -ne 3 ]]; then
  print -u2 "usage: $0 <macarchy-binary> <destination> <git-revision>"
  exit 64
fi

binary=${1:A}
destination=${2:A}
revision=$3
script_directory=${0:A:h}
repository_root=${script_directory:h}
version_file="$repository_root/VERSION.txt"
destination_parent=${destination:h}

if [[ ! -x "$binary" ]]; then
  print -u2 "macarchy binary is not executable: $binary"
  exit 66
fi
if ! IFS= read -r version < "$version_file"; then
  print -u2 "VERSION.txt must contain one newline-terminated semantic version"
  exit 65
fi
version_bytes=$(wc -c < "$version_file" | tr -d ' ')
expected_version_bytes=$((${#version} + 1))
if [[ "$version_bytes" -ne "$expected_version_bytes" ]] \
  || ! print -r -- "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
then
  print -u2 "VERSION.txt must contain a stable semantic version"
  exit 65
fi
if ! print -r -- "$revision" | grep -Eq '^[0-9a-f]{40}$'; then
  print -u2 "git revision must be a 40-character lowercase object ID"
  exit 65
fi
if [[ "$(/usr/bin/lipo -archs "$binary")" != "arm64" ]]; then
  print -u2 "release binary must contain only the arm64 architecture"
  exit 65
fi
if [[ ! -d "$destination_parent" ]]; then
  print -u2 "destination parent does not exist: $destination_parent"
  exit 73
fi

if ! mkdir -m 0755 "$destination"; then
  print -u2 "destination already exists or cannot be created: $destination"
  exit 73
fi
trap 'rm -rf "$destination"' EXIT HUP INT TERM

mkdir -p "$destination/bin" "$destination/share/macarchy" \
  "$destination/share/doc/macarchy"
install -m 0755 "$binary" "$destination/bin/macarchy"
/usr/bin/codesign --force --sign - --timestamp=none "$destination/bin/macarchy"
/usr/bin/ditto "$repository_root/Themes" "$destination/share/macarchy/themes"
install -m 0644 \
  "$repository_root/Documentation/theme-json.md" \
  "$destination/share/doc/macarchy/theme-json.md"
install -m 0644 "$repository_root/LICENSE" "$destination/share/doc/macarchy/LICENSE"
printf '{"schema_version":1,"version":"%s","revision":"%s"}\n' \
  "$version" "$revision" > "$destination/share/macarchy/build-info.json"
chmod 0644 "$destination/share/macarchy/build-info.json"
chmod -R a+rX "$destination"

trap - EXIT HUP INT TERM
print -r -- "$destination"
