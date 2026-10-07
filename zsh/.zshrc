# ~/.zshrc (interactive shells)
[[ $- != *i* ]] && return

# Keep $PATH and $fpath free of duplicates. Without this, re-sourcing .zshrc or
# starting a shell inside a shell stacks another copy of every entry below,
# because they all prepend unconditionally. `path` is tied to PATH and `fpath`
# to FPATH, so marking each pair -U covers both spellings.
typeset -U path PATH fpath FPATH

# -------------------------
# Homebrew — must be early for PATH
# -------------------------
# What `brew shellenv` prints, written out rather than run. Running it cost a
# bash process on every shell, and a path_helper on top whenever it printed
# anything. And it prints NOTHING when PATH already starts with brew's bin and
# sbin, so a shell handed such a PATH without HOMEBREW_PREFIX (env -i, or any
# launcher that sets PATH itself) never got the prefix and silently skipped
# both plugins below. tests/test-zshrc.sh compares this block with `brew
# shellenv zsh` itself, so a Homebrew release that changes what it sets fails a
# test instead of drifting.
#
# Unlike brew's output, it is safe to run twice. A shell started from a shell
# has ~/.local/bin ahead of brew's bin, so the early return never fired there,
# and every nested shell gained another copy of brew's fpath and INFOPATH
# entries. typeset -U above now covers fpath, MANPATH is rebuilt rather than
# prepended to, and INFOPATH gains the entry only when it is missing.
if [[ -x /opt/homebrew/bin/brew ]]; then
  export HOMEBREW_PREFIX=/opt/homebrew
  export HOMEBREW_REPOSITORY=$HOMEBREW_PREFIX
elif [[ -x /usr/local/bin/brew ]]; then
  export HOMEBREW_PREFIX=/usr/local
  # Through the variable: checks/machine.sh requires every literal Homebrew
  # path to exist under one prefix or the other, and this one has no twin
  # under /opt/homebrew, so on Apple Silicon it would be reported missing.
  export HOMEBREW_REPOSITORY=$HOMEBREW_PREFIX/Homebrew
fi
if [[ -n ${HOMEBREW_PREFIX-} ]]; then
  export HOMEBREW_CELLAR=$HOMEBREW_PREFIX/Cellar
  path=($HOMEBREW_PREFIX/bin $HOMEBREW_PREFIX/sbin $path)
  fpath[1,0]=$HOMEBREW_PREFIX/share/zsh/site-functions
  export FPATH
  # brew leaves a set MANPATH with a leading colon and path_helper with a
  # trailing one and no repeats. The empty first and last elements are those
  # two colons.
  if [[ -n $MANPATH ]]; then
    manpath=('' ${(u)manpath} '')
    export MANPATH
  fi
  if [[ :${INFOPATH-}: != *:$HOMEBREW_PREFIX/share/info:* ]]; then
    export INFOPATH=$HOMEBREW_PREFIX/share/info:${INFOPATH-}
  fi
fi

# Local scripts
export PATH="$HOME/.local/bin:$PATH"

# -------------------------
# NVM lazy-loading
# -------------------------
export NVM_DIR="$HOME/.nvm"
nvm() {
  unset -f nvm
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
  nvm "$@"
}
node() { nvm use --silent >/dev/null 2>&1; unset -f node; command node "$@"; }
npm()  { nvm use --silent >/dev/null 2>&1; unset -f npm;  command npm  "$@"; }
npx()  { nvm use --silent >/dev/null 2>&1; unset -f npx;  command npx  "$@"; }

# -------------------------
# Line editing: emacs keys, whatever $EDITOR says
# -------------------------
# With no keymap chosen, zle starts in vi mode when $EDITOR or $VISUAL mentions
# vi. This file exports EDITOR=nvim, so a fresh terminal got emacs keys while
# any shell started from one (exec zsh, a nested zsh, nvim's :terminal, a tmux
# server started from a shell) got vi insert mode, where Ctrl-A, Ctrl-E and
# Ctrl-Y type themselves. Chosen before compinit, which binds its ^X keys into
# whichever keymap is current. /etc/zshrc has already bound Delete, Home, End
# and the arrows into that keymap, so those five are bound again in emacs.
bindkey -e
() {
  local k w
  for k w in Delete delete-char Home beginning-of-line End end-of-line \
    Up up-line-or-search Down down-line-or-search; do
    if [[ -n ${key[$k]-} ]]; then
      bindkey "${key[$k]}" $w
    fi
  done
}

# -------------------------
# Completion (cached daily for speed)
# -------------------------
autoload -Uz compinit
# Run in an anonymous function so `localoptions` scopes extendedglob to just
# this test. The (#q...) glob-qualifier syntax REQUIRES extendedglob; without
# it zsh never expands the pattern, the -n test sees a non-empty literal
# string, and the "cached" branch below is unreachable — every shell paid for a
# full compinit. Verified: with extendedglob off, a dump created one second ago
# still took the rebuild branch.
() {
  setopt localoptions extendedglob
  # mh-24 = modified less than 24 hours ago. Phrased this way round so the
  # cached path is taken only when the dump provably exists AND is fresh; a
  # missing dump falls through to a full compinit that builds it properly.
  if [[ -n ~/.zcompdump(#qN.mh-24) ]]; then
    compinit -C # fresh: trust it and skip the security check
  else
    compinit # missing or over a day old: rebuild it
  fi
}

setopt globdots

# -------------------------
# Environment
# -------------------------

# Editor
export EDITOR="nvim"
export VISUAL="nvim"

# Locale
export LANG="en_GB.UTF-8"
export LC_ALL="en_GB.UTF-8"

# Rust toolchain
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# -------------------------
# History
# -------------------------
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt hist_ignore_dups
setopt hist_ignore_space
setopt sharehistory
setopt hist_verify
setopt inc_append_history

# -------------------------
# Aliases
# -------------------------
alias ll='ls -lah'
alias vim='nvim'

# -------------------------
# Shell options
# -------------------------
setopt autocd
setopt no_beep

# -------------------------
# fzf shell integration (Ctrl-R history, Ctrl-T files, Alt-C cd)
# -------------------------
if command -v fzf >/dev/null 2>&1; then
  eval "$(fzf --zsh)"
fi

# -------------------------
# Zsh plugins (installed via Homebrew)
# -------------------------
if [[ -d "${HOMEBREW_PREFIX:-}/share/zsh-autosuggestions" ]]; then
  source "$HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

# Syntax highlighting must be sourced last (after all widgets are defined)
if [[ -d "${HOMEBREW_PREFIX:-}/share/zsh-syntax-highlighting" ]]; then
  source "$HOMEBREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

# -------------------------
# Prompt (Starship) — must be last
# -------------------------
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
else
  PROMPT='%1~ %# '
fi

# Optional per-machine overrides (not committed).
#
# An `if` rather than `[[ ... ]] && source ...` because this is the LAST thing
# .zshrc does, and its exit status is what the first prompt sees in $?. With the
# && form and no override file present that status is 1, so starship draws its
# red error character before you have run a single command.
if [[ -f "$HOME/.zshrc.local" ]]; then
  source "$HOME/.zshrc.local"
fi
