#!/bin/zsh

set -eu

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 <release-layout>"
  exit 64
fi

layout=${1:A}
binary="$layout/bin/macarchy"
metadata="$layout/share/macarchy/build-info.json"
resources="$layout/share/macarchy"
script_directory=${0:A:h}
repository_root=${script_directory:h}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/macarchy-layout-smoke.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
home="$temporary_directory/home"
work="$home/work"
runtime_tmp="$home/tmp"
snapshot_source="$script_directory/keybindings-portability-snapshot.swift"
snapshot_helper="$temporary_directory/keybindings-portability-snapshot"
mkdir -p "$work" "$runtime_tmp"

[[ -x "$binary" ]]
[[ -f "$metadata" ]]
[[ -d "$layout/share/macarchy/themes" ]]
[[ -f "$layout/share/macarchy/keybindings/defaults.skhdrc" ]]
[[ -f "$layout/share/macarchy/keybindings/metadata.toml" ]]
[[ -f "$layout/share/macarchy/desktop/yabai/defaults.toml" ]]
[[ -f "$layout/share/macarchy/desktop/sketchybar/defaults.toml" ]]
[[ -f "$layout/share/macarchy/environment/kitty/defaults.conf" ]]
[[ -f "$layout/share/macarchy/environment/zsh/defaults.zsh" ]]
[[ -f "$layout/share/macarchy/environment/starship/behavior.toml" ]]
[[ -f "$layout/share/macarchy/environment/atuin/config.toml" ]]
[[ -f "$layout/share/macarchy/environment/bat/config" ]]
[[ -f "$layout/share/macarchy/environment/eza/defaults.zsh" ]]
[[ -f "$layout/share/macarchy/environment/btop/btop.conf" ]]
[[ -f "$layout/share/macarchy/environment/yazi/yazi.toml" ]]
[[ -f "$layout/share/macarchy/environment/yazi/theme.toml" ]]
[[ -f "$layout/share/macarchy/environment/yazi/defaults.zsh" ]]
[[ -f "$layout/share/macarchy/environment/neovim/default/init.lua" ]]
[[ -f "$layout/share/macarchy/environment/neovim/theme/lua/config/macarchy-theme.lua" ]]
[[ -f "$layout/share/doc/macarchy/CHANGELOG.md" ]]
[[ -f "$layout/share/doc/macarchy/theme-json.md" ]]
[[ -f "$layout/share/doc/macarchy/LICENSE" ]]
[[ -f "$snapshot_source" ]]
[[ -z "$(find -P "$layout" ! -type f ! -type d -print)" ]]
/usr/bin/codesign --verify --strict "$binary"
signature=$(/usr/bin/codesign -dv --verbose=2 "$binary" 2>&1)
print -r -- "$signature" | grep -q '^Signature=adhoc$'

{
  print "bin/macarchy"
  print "share/macarchy/build-info.json"
  print "share/doc/macarchy/CHANGELOG.md"
  print "share/doc/macarchy/theme-json.md"
  print "share/doc/macarchy/LICENSE"
  git -C "$repository_root" ls-files -- Themes \
    | sed 's#^Themes/#share/macarchy/themes/#'
  git -C "$repository_root" ls-files -- Keybindings \
    | sed 's#^Keybindings/#share/macarchy/keybindings/#'
  git -C "$repository_root" ls-files -- Desktop \
    | sed 's#^Desktop/#share/macarchy/desktop/#'
  git -C "$repository_root" ls-files -- Environment \
    | sed 's#^Environment/#share/macarchy/environment/#'
} | LC_ALL=C sort > "$temporary_directory/expected-inventory.txt"
(
  cd "$layout"
  find -P . -type f -print | sed 's#^\./##' | LC_ALL=C sort
) > "$temporary_directory/actual-inventory.txt"
diff -u \
  "$temporary_directory/expected-inventory.txt" \
  "$temporary_directory/actual-inventory.txt"

xcrun swiftc "$snapshot_source" -o "$snapshot_helper"
snapshot_tree() {
  local destination=$1
  local root=$2
  if [[ ${destination:A} == ${root:A} || ${destination:A} == ${root:A}/* ]]; then
    print -u2 "snapshot output must be outside its root: $destination"
    exit 64
  fi
  "$snapshot_helper" "$root" > "$destination"
}

version=$(/usr/bin/plutil -extract version raw -o - "$metadata")
snapshot_tree "$temporary_directory/home-before.json" "$home"
snapshot_tree "$temporary_directory/resources-before.json" "$resources"
cd "$work"

[[ "$(HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" --version)" == "$version" ]]
HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" version --json \
  > "$temporary_directory/version.json"
grep -q "\"version\" : \"$version\"" "$temporary_directory/version.json"
grep -q '"installation" : "unmanaged"' "$temporary_directory/version.json"

themes=$(HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" theme list)
[[ "$(print -r -- "$themes" | wc -l | tr -d ' ')" == "3" ]]
print -r -- "$themes" | grep -q '^catppuccin-mocha'
print -r -- "$themes" | grep -q '^kanagawa-wave'
print -r -- "$themes" | grep -q '^tokyo-night'

HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" setup plan --json > "$temporary_directory/setup-plan.json"
grep -q '"operation" : "setup_plan"' "$temporary_directory/setup-plan.json"
grep -q '"outcome" : "ready"' "$temporary_directory/setup-plan.json"
grep -q '"mutated" : false' "$temporary_directory/setup-plan.json"
grep -q '"id" : "catppuccin-mocha"' "$temporary_directory/setup-plan.json"
grep -q '"operation" : "desktop_plan"' "$temporary_directory/setup-plan.json"
grep -q '"operation" : "environment_plan"' "$temporary_directory/setup-plan.json"
print "unified setup plan smoke passed"

HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" keybindings list \
  --skhd-config "$layout/share/macarchy/keybindings/defaults.skhdrc" \
  --catalog "$layout/share/macarchy/keybindings/metadata.toml" \
  --json > "$temporary_directory/keybindings-list.json"
grep -q '"schema_version" : 1' "$temporary_directory/keybindings-list.json"
[[ "$(grep -c '"identity" :' "$temporary_directory/keybindings-list.json")" == "48" ]]

"$script_directory/verify-keybindings-portability.sh" "$binary"

desktop_plan_status=0
HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" desktop plan --json > "$temporary_directory/desktop-plan.json" \
  || desktop_plan_status=$?
(( desktop_plan_status == 0 || desktop_plan_status == 1 ))
grep -q '"operation" : "desktop_plan"' "$temporary_directory/desktop-plan.json"
grep -q '"mutated" : false' "$temporary_directory/desktop-plan.json"
grep -q '"desktop_provider" : "yabai-skhd"' "$temporary_directory/desktop-plan.json"
if (( desktop_plan_status == 1 )); then
  grep -q '"code" : "desktop_prerequisite_missing"' \
    "$temporary_directory/desktop-plan.json"
  unexpected_desktop_diagnostic="$(
    grep '"code" :' "$temporary_directory/desktop-plan.json" \
      | grep -Ev '"code" : "(desktop_prerequisite_missing|keybindings_blocked)"' || true
  )"
  if [[ -n "$unexpected_desktop_diagnostic" ]]; then
    cat "$temporary_directory/desktop-plan.json"
    exit 1
  fi
  if grep -q '"code" : "keybindings_blocked"' "$temporary_directory/desktop-plan.json"; then
    grep -q '"source" : "skhd"' "$temporary_directory/desktop-plan.json"
    grep -q '"provider_status" : "install_required"' \
      "$temporary_directory/desktop-plan.json"
    grep -q '"ownership" : "absent"' "$temporary_directory/desktop-plan.json"
  fi
fi
print "desktop plan smoke passed"

cat > "$temporary_directory/desktop-disabled.toml" <<'EOF'
schema_version = 1
[desktop]
provider = "disabled"
[top_bar]
provider = "disabled"
EOF
desktop_doctor_status=0
HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" desktop doctor \
  --profile "$temporary_directory/desktop-disabled.toml" \
  --json > "$temporary_directory/desktop-doctor.json" \
  || desktop_doctor_status=$?
(( desktop_doctor_status == 0 || desktop_doctor_status == 1 ))
grep -q '"operation" : "desktop_doctor"' "$temporary_directory/desktop-doctor.json"
if (( desktop_doctor_status == 0 )); then
  grep -q '"outcome" : "healthy"' "$temporary_directory/desktop-doctor.json"
else
  grep -q '"outcome" : "unhealthy"' "$temporary_directory/desktop-doctor.json"
  awk '
    /"id" :/ { finding = $0 }
    /"status" : "failure"/ && finding !~ /"desktop\.prerequisite\./ { exit 1 }
  ' "$temporary_directory/desktop-doctor.json"
fi
print "desktop doctor smoke passed"

environment_plan_status=0
HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
  "$binary" environment plan --json > "$temporary_directory/environment-plan.json" \
  || environment_plan_status=$?
(( environment_plan_status == 0 || environment_plan_status == 1 ))
grep -q '"operation" : "environment_plan"' "$temporary_directory/environment-plan.json"
grep -q '"mutated" : false' "$temporary_directory/environment-plan.json"
grep -q '"terminal_provider" : "kitty"' "$temporary_directory/environment-plan.json"
grep -q '"shell_provider" : "zsh"' "$temporary_directory/environment-plan.json"
if (( environment_plan_status == 0 )); then
  grep -q '"outcome" : "ready"' "$temporary_directory/environment-plan.json"
else
  grep -q '"outcome" : "blocked"' "$temporary_directory/environment-plan.json"
fi
print "environment plan smoke passed"

cat > "$temporary_directory/environment-disabled.toml" <<'EOF'
schema_version = 1
[terminal]
provider = "disabled"
[shell]
provider = "disabled"
[editor]
provider = "disabled"
[tools]
bat = false
eza = false
btop = false
yazi = false
EOF
for operation in apply status doctor teardown; do
  if [[ $operation == teardown ]]; then
    HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
      "$binary" environment teardown --json \
      > "$temporary_directory/environment-$operation.json"
  else
    HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$runtime_tmp" \
      "$binary" environment "$operation" \
      --profile "$temporary_directory/environment-disabled.toml" \
      --json > "$temporary_directory/environment-$operation.json"
  fi
  grep -q "\"operation\" : \"environment_$operation\"" \
    "$temporary_directory/environment-$operation.json"
  grep -q '"mutated" : false' "$temporary_directory/environment-$operation.json"
done
print "environment lifecycle smoke passed"

snapshot_tree "$temporary_directory/home-after.json" "$home"
snapshot_tree "$temporary_directory/resources-after.json" "$resources"
cmp "$temporary_directory/home-before.json" "$temporary_directory/home-after.json"
cmp "$temporary_directory/resources-before.json" "$temporary_directory/resources-after.json"
print "release layout immutability smoke passed"

print "release layout smoke test passed"
