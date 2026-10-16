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

# Fails unless the archive smoke check rejects the artifacts staged in <directory>.
expect_rejected() {
  if "$script_directory/smoke-release-archive.sh" \
    "$temporary_directory/$1/${archive:t}" \
    "$temporary_directory/$1/${checksum:t}" \
    "$revision" > /dev/null 2>&1; then
    print -u2 "archive validation accepted $2"
    exit 1
  fi
}

mkdir "$temporary_directory/tampered"
cp "$archive" "$temporary_directory/tampered/${archive:t}"
cp "$checksum" "$temporary_directory/tampered/${checksum:t}"
printf 'tampered\n' >> "$temporary_directory/tampered/${archive:t}"
expect_rejected tampered "a checksum mismatch"

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
expect_rejected malformed "a missing release resource"

# Independently corrupt the new helper, preserving valid archive checksums.
for defect in missing mode signature; do
  fixture="$temporary_directory/focus-$defect"
  mkdir "$fixture" "$fixture/unpacked"
  /usr/bin/tar -xzf "$archive" -C "$fixture/unpacked"
  helper="$fixture/unpacked/$package_name/bin/macarchy-focus-ring"
  case "$defect" in
    missing) rm "$helper" ;;
    mode) chmod 0744 "$helper" ;;
    signature) /usr/bin/codesign --remove-signature "$helper" ;;
  esac
  COPYFILE_DISABLE=1 /usr/bin/tar -czf "$fixture/${archive:t}" \
    -C "$fixture/unpacked" "$package_name"
  (
    cd "$fixture"
    /usr/bin/shasum -a 256 "${archive:t}" > "${checksum:t}"
  )
  expect_rejected "focus-$defect" "a focus helper with invalid $defect"
done

print "release archive rejection tests passed"
