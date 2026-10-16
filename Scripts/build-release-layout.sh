#!/bin/zsh

set -eu

if [[ $# -ne 3 ]]; then
  print -u2 "usage: $0 <macarchy-binary> <destination> <git-revision>"
  exit 64
fi

binary=${1:A}
menu_binary="${binary:h}/macarchy-menu"
focus_binary="${binary:h}/macarchy-focus-ring"
destination=${2:A}
revision=$3
script_directory=${0:A:h}
repository_root=${script_directory:h}
version_file="$repository_root/VERSION.txt"
destination_parent=${destination:h}
source "$script_directory/release-common.zsh"

if [[ ! -x "$binary" ]]; then
  print -u2 "macarchy binary is not executable: $binary"
  exit 66
fi
if [[ ! -x "$menu_binary" || "$(/usr/bin/lipo -archs "$menu_binary")" != "arm64" ]]; then
  print -u2 "matching arm64 macarchy-menu helper is missing beside the release binary"
  exit 66
fi
if [[ ! -x "$focus_binary" || "$(/usr/bin/lipo -archs "$focus_binary")" != "arm64" ]]; then
  print -u2 "matching arm64 macarchy-focus-ring helper is missing beside the release binary"
  exit 66
fi
read_release_version "$version_file"
require_release_revision "$revision"
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
install -m 0755 "$menu_binary" "$destination/bin/macarchy-menu"
install -m 0755 "$focus_binary" "$destination/bin/macarchy-focus-ring"
for executable in macarchy macarchy-menu macarchy-focus-ring; do
  /usr/bin/codesign --force --sign - --timestamp=none "$destination/bin/$executable"
done
for resource in Themes Keybindings Desktop Environment; do
  /usr/bin/ditto "$repository_root/$resource" "$destination/share/macarchy/${resource:l}"
done
for document in Documentation/theme-json.md CHANGELOG.md LICENSE; do
  install -m 0644 "$repository_root/$document" "$destination/share/doc/macarchy/${document:t}"
done
printf '{"schema_version":1,"version":"%s","revision":"%s"}\n' \
  "$version" "$revision" > "$destination/share/macarchy/build-info.json"
chmod 0644 "$destination/share/macarchy/build-info.json"
chmod -R a+rX "$destination"

trap - EXIT HUP INT TERM
print -r -- "$destination"
