#!/bin/zsh
# Invoked only inside the guest by run-tests.py; no host fallback.
set -euo pipefail
cd "${0:A:h:h:h}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export MACARCHY_TEST_VM=1
export HOMEBREW_NO_ANALYTICS=1
temporary=$(/usr/bin/mktemp -d /private/tmp/macarchy-guest-tests.XXXXXXXX)
trap '/bin/rm -rf "$temporary"' EXIT
export TMPDIR="$temporary/"
safety="$temporary/test-safety"
/usr/bin/xcrun swiftc -parse-as-library -D MACARCHY_TEST_SAFETY_CLI \
  Tests/TestSafety/IsolatedTestEnvironment.swift -o "$safety"
"$safety" --check-directory "$PWD"
"$safety" --check-directory "$temporary"

test_arguments=()
portability=false
while (( $# )); do
  case "$1" in
    --filter)
      (( $# >= 2 )) || exit 64
      test_arguments+=(--filter "$2")
      shift 2
      ;;
    --portability) portability=true; shift ;;
    *) print -u2 "Unknown guest-test option: $1"; exit 64 ;;
  esac
done
/usr/bin/swift test --disable-xctest "${test_arguments[@]}"
if [[ "$portability" == true ]]; then
  /usr/bin/swift build --product macarchy
  /bin/zsh Scripts/verify-keybindings-portability.sh .build/debug/macarchy
fi
