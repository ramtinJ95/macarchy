#!/bin/zsh

set -eu

if [[ $# -ne 3 ]]; then
  print -u2 "usage: $0 <macarchy-binary> <destination-directory> <git-revision>"
  exit 64
fi

binary=${1:A}
destination=${2:A}
revision=$3
script_directory=${0:A:h}
repository_root=${script_directory:h}
version=$(<"$repository_root/VERSION")
package_name="macarchy-${version}-arm64-apple-darwin"
archive_name="${package_name}.tar.gz"
checksum_name="${archive_name}.sha256"

if [[ ! -d ${destination:h} ]]; then
  print -u2 "destination parent does not exist: ${destination:h}"
  exit 73
fi
if ! mkdir -m 0755 "$destination"; then
  print -u2 "destination already exists or cannot be created: $destination"
  exit 73
fi
trap 'rm -rf "$destination"' EXIT HUP INT TERM

staging="$destination/.staging"
mkdir -m 0755 "$staging"
layout="$staging/$package_name"
"$script_directory/build-release-layout.sh" "$binary" "$layout" "$revision"

archive="$destination/$archive_name"
checksum="$destination/$checksum_name"
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$archive" -C "$staging" "$package_name"
(
  cd "$destination"
  /usr/bin/shasum -a 256 "$archive_name" > "$checksum_name"
)
rm -rf "$staging"

"$script_directory/smoke-release-archive.sh" "$archive" "$checksum" "$revision"

trap - EXIT HUP INT TERM
print -r -- "$archive"
print -r -- "$checksum"
