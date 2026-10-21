#!/bin/zsh

set -eu

if [[ $# -ne 4 ]]; then
  print -u2 "usage: $0 <release-archive> <checksum-file> <git-revision> <destination-directory>"
  exit 64
fi

# Rebuilds a pull request's validated archive for the commit it landed as. The
# binaries and ttfx are reused unchanged; the layout, resources and build-info.json
# come from this checkout, which must hold the tree the pull request tested.
archive=${1:A}
checksum=${2:A}
revision=$3
destination=${4:A}
script_directory=${0:A:h}
repository_root=${script_directory:h}
source "$script_directory/release-common.zsh"
read_release_version "$repository_root/VERSION.txt"
require_release_revision "$revision"
package_name="macarchy-${version}-arm64-apple-darwin"
if [[ ${archive:t} != "$package_name.tar.gz" || ${checksum:t} != "$package_name.tar.gz.sha256" ]]; then
  print -u2 "release artifacts do not use the expected versioned names"
  exit 65
fi
require_archive_checksum "$archive" "$checksum"
if [[ -e "$destination" ]]; then
  print -u2 "destination already exists: $destination"
  exit 73
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-archive-restamp.XXXXXX")
trap 'rm -rf "$temporary_directory" "$destination"' EXIT HUP INT TERM
mkdir "$temporary_directory/tested" "$temporary_directory/rebuilt" "$temporary_directory/ttfx"
/usr/bin/tar -xzf "$archive" -C "$temporary_directory/tested"
tested="$temporary_directory/tested/$package_name"
ttfx="$temporary_directory/ttfx"
install -m 0755 "$tested/libexec/ttfx" "$ttfx/ttfx"
install -m 0644 "$tested/share/doc/macarchy/ttfx/LICENSE" "$tested/share/doc/macarchy/ttfx/NOTICE" "$ttfx/"
/usr/bin/ditto "$tested/share/doc/macarchy/ttfx/third-party" "$ttfx/third-party"

"$script_directory/build-release-archive.sh" "$tested/bin/macarchy" "$ttfx" "$destination" "$revision" > /dev/null

/usr/bin/tar -xzf "$destination/$package_name.tar.gz" -C "$temporary_directory/rebuilt"
if ! /usr/bin/diff -r -x build-info.json "$tested" "$temporary_directory/rebuilt/$package_name"; then
  print -u2 "the rebuilt archive differs from the tested one beyond build-info.json"
  exit 65
fi
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
print -r -- "$destination/$package_name.tar.gz"
print -r -- "$destination/$package_name.tar.gz.sha256"
