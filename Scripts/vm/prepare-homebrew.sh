#!/bin/bash
# Explicit guest-only preparation. Called over scoped SSH; never run on the host.
set -euo pipefail
[[ "${MACARCHY_VM_PREPARE-}" == "disposable-guest" ]] || exit 64
[[ "$(/usr/bin/id -un)" == "omarchy" ]] || exit 65
[[ ! -e /opt/homebrew && ! -L /opt/homebrew ]] || exit 66

revision=0a396a4ee5b538f409de666af904fa0570b53949
digest=f31a38f097f3b5bbfdc110658e4a9876d0c023ccc9ef2e70527f5b8a762e505e
umask 077
temporary=$(/usr/bin/mktemp -d /tmp/macarchy-brew.XXXXXXXX)
cleanup() {
  /bin/rm -f "$temporary/password" "$temporary/askpass" "$temporary/install.sh"
  /bin/rmdir "$temporary"
  /usr/bin/sudo -k
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# A private temporary credential is the installer's supported SUDO_ASKPASS input.
# No sudoers changes, root installation, host agent, or command-line secret.
IFS= read -r password
printf '%s\n' "$password" > "$temporary/password"
unset password
printf '#!/bin/sh\nexec /bin/cat "%s/password"\n' "$temporary" > "$temporary/askpass"
/bin/chmod 700 "$temporary/askpass"
/usr/bin/curl --fail --location --silent --show-error \
  "https://raw.githubusercontent.com/Homebrew/install/$revision/install.sh" \
  --output "$temporary/install.sh"
[[ "$(/usr/bin/shasum -a 256 "$temporary/install.sh" | /usr/bin/awk '{print $1}')" == "$digest" ]]
export SUDO_ASKPASS="$temporary/askpass" NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1
/bin/bash "$temporary/install.sh"
/opt/homebrew/bin/brew analytics off
/opt/homebrew/bin/brew --version
/usr/bin/git -C /opt/homebrew rev-parse HEAD
/usr/bin/xcode-select -p
/usr/sbin/pkgutil --pkg-info com.apple.pkg.CLTools_Executables
