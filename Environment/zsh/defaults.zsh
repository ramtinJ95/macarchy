# Macarchy's package-owned zsh baseline.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"

setopt INTERACTIVE_COMMENTS

alias ..='cd ..'
alias ...='cd ../..'
