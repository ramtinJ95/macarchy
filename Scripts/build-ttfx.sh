#!/bin/zsh

set -eu

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 <destination-directory>"
  exit 64
fi

destination=${1:A}
destination_parent=${destination:h}
script_directory=${0:A:h}
target=aarch64-apple-darwin
source "$script_directory/release-common.zsh"

for tool in git cargo rustc python3; do
  if ! command -v "$tool" > /dev/null; then
    print -u2 "$tool is required to build ttfx"
    exit 69
  fi
done
if [[ ! -d "$destination_parent" ]]; then
  print -u2 "destination parent does not exist: $destination_parent"
  exit 73
fi

if ! mkdir -m 0755 "$destination"; then
  print -u2 "destination already exists or cannot be created: $destination"
  exit 73
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-ttfx.XXXXXX")
trap 'rm -rf "$destination" "$work"' EXIT HUP INT TERM

checkout="$work/ttfx"
git init --quiet "$checkout"
git -C "$checkout" remote add origin "$ttfx_repository"
GIT_TERMINAL_PROMPT=0 git -C "$checkout" fetch --quiet --depth 1 origin "$ttfx_revision"
git -C "$checkout" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
if [[ "$(git -C "$checkout" rev-parse HEAD)" != "$ttfx_revision" ]]; then
  print -u2 "ttfx checkout does not match the pinned commit $ttfx_revision"
  exit 65
fi

rustc --version
cargo --version
(
  cd "$checkout"
  CARGO_TARGET_DIR="$work/target" cargo build --release --locked --target "$target"
  cargo metadata --format-version 1 --locked --filter-platform "$target" \
    > "$work/metadata.json"
)

binary="$work/target/$target/release/ttfx"
if [[ "$(/usr/bin/lipo -archs "$binary")" != "arm64" ]]; then
  print -u2 "ttfx must contain only the arm64 architecture"
  exit 65
fi
if [[ "$("$binary" --version)" != "ttfx $ttfx_version" ]]; then
  print -u2 "the pinned ttfx commit does not report version $ttfx_version"
  exit 65
fi
install -m 0755 "$binary" "$destination/ttfx"
install -m 0644 "$checkout/LICENSE" "$checkout/NOTICE" "$destination/"
mkdir -m 0755 "$destination/third-party"

# Normal dependencies are the crates compiled into the binary. Build-script and
# dev-only crates are not, and --filter-platform already dropped other targets.
python3 -I - "$work/metadata.json" "$destination/third-party" <<'EOF'
import json
import pathlib
import re
import shutil
import sys

metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
destination = pathlib.Path(sys.argv[2])
packages = {package["id"]: package for package in metadata["packages"]}
nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
linked, pending = set(), [metadata["resolve"]["root"]]
while pending:
    for dependency in nodes[pending.pop()]["deps"]:
        normal = any(kind["kind"] is None for kind in dependency["dep_kinds"])
        if normal and dependency["pkg"] not in linked:
            linked.add(dependency["pkg"])
            pending.append(dependency["pkg"])

licence = re.compile(r"(LICENSE|COPYING|NOTICE)", re.IGNORECASE)
unlicensed = []
for package in sorted((packages[i] for i in linked), key=lambda p: (p["name"], p["version"])):
    source = pathlib.Path(package["manifest_path"]).parent
    files = sorted(p for p in source.iterdir() if p.is_file() and licence.match(p.name))
    if not files:
        unlicensed.append(f"{package['name']} {package['version']}")
        continue
    directory = destination / f"{package['name']}-{package['version']}"
    directory.mkdir()
    for path in files:
        shutil.copyfile(path, directory / path.name)
if unlicensed:
    sys.exit("no LICENSE, COPYING or NOTICE file in crate(s): " + ", ".join(unlicensed))
print(f"copied the licences of {len(linked)} crates compiled into ttfx")
EOF

trap - EXIT HUP INT TERM
rm -rf "$work"
print -r -- "$destination"
