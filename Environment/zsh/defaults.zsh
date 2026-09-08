# Macarchy's package-owned zsh baseline.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"

setopt INTERACTIVE_COMMENTS
setopt SHARE_HISTORY

alias ..='cd ..'
alias ...='cd ../..'

alias vim='nvim'
alias n='nvim'
alias gs='git status'
alias gp='git push'
alias gpl='git pull'
alias gaa='git add .'
alias gc='git commit --verbose'
alias gcm='git checkout main && git pull'
alias cr='cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON && cmake --build build && ./build/main'
alias py='python3'
alias decompress='tar -xvf'
alias compress='tar -cvf'

# User-installed tools remain outside package/configuration ownership.
typeset -U path
path+=("$HOME/.local/bin" "$HOME/go/bin")
export PATH

# These selected-shell prerequisites are installed and checked by setup.
# Load fzf before Atuin so the selected history provider owns history bindings.
if [[ -o interactive ]]; then
  autoload -Uz compinit
  compinit || return 1
  source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh || return 1
  bindkey '^y' autosuggest-accept || return 1
  source /opt/homebrew/opt/fzf/shell/key-bindings.zsh || return 1
  source /opt/homebrew/opt/fzf/shell/completion.zsh || return 1
  MACARCHY_ZOXIDE_INIT="$(/opt/homebrew/bin/zoxide init zsh)" || return 1
  eval "$MACARCHY_ZOXIDE_INIT" || return 1
  unset MACARCHY_ZOXIDE_INIT
fi
