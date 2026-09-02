# Macarchy's package-owned Yazi shell integration.
function y() {
  local tmp cwd exit_status
  tmp="$(mktemp -t "yazi-cwd.XXXXXX")" || return 1
  command yazi "$@" --cwd-file="$tmp"
  exit_status=$?
  IFS= read -r -d '' cwd < "$tmp" || true
  if [[ -n "$cwd" && "$cwd" != "$PWD" ]]; then
    builtin cd -- "$cwd"
  fi
  command rm -f -- "$tmp" || return 1
  return $exit_status
}
