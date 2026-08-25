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
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-archive-validation.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

mkdir "$temporary_directory/tampered"
cp "$archive" "$temporary_directory/tampered/${archive:t}"
cp "$checksum" "$temporary_directory/tampered/${checksum:t}"
printf 'tampered\n' >> "$temporary_directory/tampered/${archive:t}"
if "$script_directory/smoke-release-archive.sh" \
  "$temporary_directory/tampered/${archive:t}" \
  "$temporary_directory/tampered/${checksum:t}" \
  "$revision" > /dev/null 2>&1; then
  print -u2 "archive validation accepted a checksum mismatch"
  exit 1
fi

mkdir "$temporary_directory/malformed" "$temporary_directory/unpacked"
/usr/bin/tar -xzf "$archive" -C "$temporary_directory/unpacked"
package_name=${archive:t:r:r}
rm "$temporary_directory/unpacked/$package_name/share/doc/macarchy/LICENSE"
COPYFILE_DISABLE=1 /usr/bin/tar -czf \
  "$temporary_directory/malformed/${archive:t}" \
  -C "$temporary_directory/unpacked" \
  "$package_name"
(
  cd "$temporary_directory/malformed"
  /usr/bin/shasum -a 256 "${archive:t}" > "${checksum:t}"
)
if "$script_directory/smoke-release-archive.sh" \
  "$temporary_directory/malformed/${archive:t}" \
  "$temporary_directory/malformed/${checksum:t}" \
  "$revision" > /dev/null 2>&1; then
  print -u2 "archive validation accepted a missing release resource"
  exit 1
fi

print "release archive rejection tests passed"
