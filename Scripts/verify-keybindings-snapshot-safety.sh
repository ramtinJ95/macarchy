#!/bin/zsh

# Adversarial self-test of the keybinding portability snapshot helper. It creates a FIFO, so it
# runs only where the TestSafety guard accepts the machine (CI runners and disposable guests).

set -eu

if [[ $# -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 64
fi

script_directory=${0:A:h}
repository_root=${script_directory:h}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-keybindings-snapshot-safety.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
# Compile the same test-only guard used by Swift fixtures. There is no host bypass.
safety_helper="$temporary_directory/test-safety"
xcrun swiftc -parse-as-library -D MACARCHY_TEST_SAFETY_CLI \
  "$repository_root/Tests/TestSafety/IsolatedTestEnvironment.swift" -o "$safety_helper"
"$safety_helper" --check-directory "$temporary_directory"
snapshot_source="$script_directory/keybindings-portability-snapshot.swift"
snapshot_helper="$temporary_directory/keybindings-portability-snapshot"
if [[ ! -f "$snapshot_source" ]]; then
  print -u2 "portability snapshot helper is missing: $snapshot_source"
  exit 66
fi
xcrun swiftc "$snapshot_source" -o "$snapshot_helper"

snapshot_home() {
  local destination=$1
  local root=$2
  if [[ ${destination:A} == ${root:A} || ${destination:A} == ${root:A}/* ]]; then
    print -u2 "snapshot output must be outside its root: $destination"
    exit 64
  fi
  "$snapshot_helper" "$root" > "$destination"
}

assert_snapshot_rejected() {
  local label=$1
  local root=$2
  local expected=$3
  if "$snapshot_helper" "$root" \
    > "$temporary_directory/$label.json" \
    2> "$temporary_directory/$label.stderr"; then
    print -u2 "unsafe snapshot fixture was accepted: $label"
    exit 1
  fi
  grep -qF "$expected" "$temporary_directory/$label.stderr"
}
overflow_root="$temporary_directory/snapshot-overflow"
mkdir -p "$overflow_root"
for index in {1..256}; do
  : > "$overflow_root/entry-$index"
done
assert_snapshot_rejected \
  overflow "$overflow_root" "snapshot inventory exceeds 256 entries"

fifo_root="$temporary_directory/snapshot-fifo"
mkdir -p "$fifo_root"
"$safety_helper" --create-fifo "$fifo_root/entry"
assert_snapshot_rejected \
  fifo "$fifo_root" "snapshot entry is not a pinned regular file or directory"

symlink_root="$temporary_directory/snapshot-symlink"
mkdir -p "$symlink_root"
ln -s missing "$symlink_root/entry"
assert_snapshot_rejected \
  symlink "$symlink_root" "snapshot entry is not a pinned regular file or directory"

evidence_root="$temporary_directory/snapshot-evidence"
payload="$temporary_directory/snapshot-payload"
mkdir -p "$evidence_root"
print -rn -- "unchanged payload" > "$payload"
cp "$payload" "$evidence_root/entry"
chmod 600 "$evidence_root/entry"
snapshot_home "$temporary_directory/evidence-original.json" "$evidence_root"
cp "$payload" "$evidence_root/replacement"
chmod 600 "$evidence_root/replacement"
mv -f "$evidence_root/replacement" "$evidence_root/entry"
snapshot_home "$temporary_directory/evidence-replaced.json" "$evidence_root"
[[ "$(/usr/bin/plutil -extract 1.digest raw -o - \
  "$temporary_directory/evidence-original.json")" \
  == "$(/usr/bin/plutil -extract 1.digest raw -o - \
    "$temporary_directory/evidence-replaced.json")" ]]
[[ "$(/usr/bin/plutil -extract 1.mode raw -o - \
  "$temporary_directory/evidence-original.json")" \
  == "$(/usr/bin/plutil -extract 1.mode raw -o - \
    "$temporary_directory/evidence-replaced.json")" ]]
[[ "$(/usr/bin/plutil -extract 1.device raw -o - \
  "$temporary_directory/evidence-original.json")" \
  == "$(/usr/bin/plutil -extract 1.device raw -o - \
    "$temporary_directory/evidence-replaced.json")" ]]
[[ "$(/usr/bin/plutil -extract 1.inode raw -o - \
  "$temporary_directory/evidence-original.json")" \
  != "$(/usr/bin/plutil -extract 1.inode raw -o - \
    "$temporary_directory/evidence-replaced.json")" ]]
if cmp -s \
  "$temporary_directory/evidence-original.json" \
  "$temporary_directory/evidence-replaced.json"
then
  print -u2 "same-byte same-mode replacement was absent from snapshot evidence"
  exit 1
fi

cp "$temporary_directory/evidence-replaced.json" \
  "$temporary_directory/evidence-before-rewrite.json"
cat "$payload" > "$evidence_root/entry"
touch -t 200101010101.01 "$evidence_root/entry"
snapshot_home "$temporary_directory/evidence-rewritten.json" "$evidence_root"
[[ "$(/usr/bin/plutil -extract 1.digest raw -o - \
  "$temporary_directory/evidence-before-rewrite.json")" \
  == "$(/usr/bin/plutil -extract 1.digest raw -o - \
    "$temporary_directory/evidence-rewritten.json")" ]]
[[ "$(/usr/bin/plutil -extract 1.mode raw -o - \
  "$temporary_directory/evidence-before-rewrite.json")" \
  == "$(/usr/bin/plutil -extract 1.mode raw -o - \
    "$temporary_directory/evidence-rewritten.json")" ]]
[[ "$(/usr/bin/plutil -extract 1.device raw -o - \
  "$temporary_directory/evidence-before-rewrite.json")" \
  == "$(/usr/bin/plutil -extract 1.device raw -o - \
    "$temporary_directory/evidence-rewritten.json")" ]]
[[ "$(/usr/bin/plutil -extract 1.inode raw -o - \
  "$temporary_directory/evidence-before-rewrite.json")" \
  == "$(/usr/bin/plutil -extract 1.inode raw -o - \
    "$temporary_directory/evidence-rewritten.json")" ]]
if cmp -s \
  "$temporary_directory/evidence-before-rewrite.json" \
  "$temporary_directory/evidence-rewritten.json"
then
  print -u2 "same-byte same-mode rewrite was absent from snapshot evidence"
  exit 1
fi

print "keybinding snapshot helper self-test passed"
