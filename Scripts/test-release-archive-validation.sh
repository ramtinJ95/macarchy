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
package_name=${archive:t:r:r}
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

# Repacks the archive after running <command...> inside its layout, with a valid
# checksum, and fails unless validation rejects it.
expect_layout_rejected() {
  local fixture=$1 description=$2
  shift 2
  mkdir "$temporary_directory/$fixture" "$temporary_directory/$fixture/unpacked"
  /usr/bin/tar -xzf "$archive" -C "$temporary_directory/$fixture/unpacked"
  (
    cd "$temporary_directory/$fixture/unpacked/$package_name"
    "$@"
  )
  COPYFILE_DISABLE=1 /usr/bin/tar -czf "$temporary_directory/$fixture/${archive:t}" \
    -C "$temporary_directory/$fixture/unpacked" "$package_name"
  (
    cd "$temporary_directory/$fixture"
    /usr/bin/shasum -a 256 "${archive:t}" > "${checksum:t}"
  )
  expect_rejected "$fixture" "$description"
}

mkdir "$temporary_directory/tampered"
cp "$archive" "$temporary_directory/tampered/${archive:t}"
cp "$checksum" "$temporary_directory/tampered/${checksum:t}"
printf 'tampered\n' >> "$temporary_directory/tampered/${archive:t}"
expect_rejected tampered "a checksum mismatch"

expect_layout_rejected malformed "a missing release resource" \
  rm share/doc/macarchy/LICENSE

# Independently corrupt the new helper.
expect_layout_rejected focus-missing "a missing focus helper" rm bin/macarchy-focus-ring
expect_layout_rejected focus-mode "a focus helper with invalid mode" \
  chmod 0744 bin/macarchy-focus-ring
expect_layout_rejected focus-signature "a focus helper with an invalid signature" \
  /usr/bin/codesign --remove-signature bin/macarchy-focus-ring

print "release archive rejection tests passed"
