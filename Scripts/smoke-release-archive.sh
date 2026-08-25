#!/bin/zsh

set -eu

if [[ $# -ne 3 ]]; then
  print -u2 "usage: $0 <release-archive> <checksum-file> <git-revision>"
  exit 64
fi

archive=${1:A}
checksum=${2:A}
revision=$3
script_directory=${0:A:h}
repository_root=${script_directory:h}
version_file="$repository_root/VERSION.txt"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-archive-smoke.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

if ! IFS= read -r version < "$version_file"; then
  print -u2 "VERSION.txt must contain one newline-terminated semantic version"
  exit 65
fi
version_bytes=$(wc -c < "$version_file" | tr -d ' ')
if [[ "$version_bytes" -ne $((${#version} + 1)) ]] \
  || ! print -r -- "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
then
  print -u2 "VERSION.txt must contain a stable semantic version"
  exit 65
fi
if ! print -r -- "$revision" | grep -Eq '^[0-9a-f]{40}$'; then
  print -u2 "git revision must be a 40-character lowercase object ID"
  exit 65
fi

package_name="macarchy-${version}-arm64-apple-darwin"
archive_name="${package_name}.tar.gz"
checksum_name="${archive_name}.sha256"
if [[ ${archive:t} != "$archive_name" || ${checksum:t} != "$checksum_name" ]]; then
  print -u2 "release artifacts do not use the expected versioned names"
  exit 65
fi
if [[ ! -f "$archive" || ! -f "$checksum" ]]; then
  print -u2 "release archive and checksum must be regular files"
  exit 66
fi

expected_checksum=$(
  cd "${archive:h}"
  /usr/bin/shasum -a 256 "$archive_name"
)
if ! IFS= read -r actual_checksum < "$checksum"; then
  print -u2 "checksum must contain one newline-terminated SHA-256 record"
  exit 65
fi
checksum_bytes=$(wc -c < "$checksum" | tr -d ' ')
if [[ "$actual_checksum" != "$expected_checksum" \
  || "$checksum_bytes" -ne $((${#actual_checksum} + 1)) ]]; then
  print -u2 "release archive checksum does not match"
  exit 65
fi

/usr/bin/tar -tzf "$archive" > "$temporary_directory/archive-members.txt"
if [[ ! -s "$temporary_directory/archive-members.txt" ]]; then
  print -u2 "release archive is empty"
  exit 65
fi
while IFS= read -r member; do
  normalized=${member%/}
  if [[ "$normalized" != "$package_name" \
    && "$normalized" != "$package_name/"* ]]; then
    print -u2 "release archive contains a path outside $package_name: $member"
    exit 65
  fi
  relative=${normalized#"$package_name"}
  relative=${relative#/}
  if print -r -- "$relative" | grep -Eq '(^|/)\.\.?(/|$)'; then
    print -u2 "release archive contains an unsafe path: $member"
    exit 65
  fi
done < "$temporary_directory/archive-members.txt"

while IFS= read -r listing; do
  type=${listing[1]}
  if [[ "$type" != "-" && "$type" != "d" ]]; then
    print -u2 "release archive may contain only regular files and directories"
    exit 65
  fi
done < <(/usr/bin/tar -tvzf "$archive")

/usr/bin/tar -xzf "$archive" -C "$temporary_directory"
layout="$temporary_directory/$package_name"
"$script_directory/smoke-release-layout.sh" "$layout"

metadata="$layout/share/macarchy/build-info.json"
actual_version=$(/usr/bin/plutil -extract version raw -o - "$metadata")
actual_revision=$(/usr/bin/plutil -extract revision raw -o - "$metadata")
if [[ "$actual_version" != "$version" || "$actual_revision" != "$revision" ]]; then
  print -u2 "release metadata does not match the expected source"
  exit 65
fi

print "release archive smoke test passed"
