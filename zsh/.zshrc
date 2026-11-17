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
  # brew trims a set MANPATH's colons from both ends and puts one back in
  # front, the empty element man reads as its default path. These are brew's
  # own two expressions. The Homebrew this was written against also ran
  # path_helper, which left a trailing colon and no repeats; 7.0.9 does not,
  # and tests/test-zshrc.sh failed until this matched again.
  if [[ -n ${MANPATH-} ]]; then
    MANPATH=${MANPATH%"${MANPATH##*[!:]}"}
    export MANPATH=:${MANPATH#"${MANPATH%%[!:]*}"}
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
# nvm's default node first on PATH from the start, found from its alias file
# and a glob rather than by loading nvm.sh. Before, a shell ran Homebrew's node
# until the first node, npm or npx typed in it, and nvm's after, so anything
# that reaches node through PATH -- a global npm CLI, a language server nvim
# starts -- got whichever was current. (n) sorts the matches numerically, so a
# default of 20 picks v20.10.0 over v20.9.0; plain sorting picks v20.9.0.
#
# What that gives up: the wrappers ran a bare `nvm use`, which also applied a
# .nvmrc in the directory of the first node typed. Now `nvm use` there does.
#
# A default that is not a version (lts/*, node, another alias) names no
# directory, so it keeps the wrappers: they load nvm.sh, which resolves it, on
# the first node, npm or npx.
() {
  local v=""
  local -a d
  [[ -r $NVM_DIR/alias/default ]] && read -r v <$NVM_DIR/alias/default
  [[ -n $v ]] && d=($NVM_DIR/versions/node/v${v#v}(|.*)(Nn/))
  if (( $#d )); then
    path=($d[-1]/bin $path)
  else
    node() { nvm use --silent >/dev/null 2>&1; unset -f node; command node "$@"; }
    npm()  { nvm use --silent >/dev/null 2>&1; unset -f npm;  command npm  "$@"; }
    npx()  { nvm use --silent >/dev/null 2>&1; unset -f npx;  command npx  "$@"; }
  fi
}

# -------------------------
# Line editing: emacs keys, whatever $EDITOR says
# -------------------------
# With no keymap chosen, zle starts in vi mode when $EDITOR or $VISUAL mentions
# vi. This file exports EDITOR as nvim or vi, so a fresh terminal got emacs
# keys while any shell started from one (exec zsh, a nested zsh, nvim's
# :terminal, a tmux server started from a shell) got vi insert mode, where
# Ctrl-A, Ctrl-E and Ctrl-Y type themselves. Chosen before compinit, which
# binds its ^X keys into whichever keymap is current. /etc/zshrc has already
# bound Delete, Home, End, Up and Down into that keymap, so those five are
# bound again in emacs.
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

# Tab offers dotfiles; a * on the command line does not match them. globdots
# goes on compinit's own option list, which every completion widget sets as
# local options on entry and nothing else reads. `setopt globdots` here made
# every glob in every shell match dotfiles, so `rm -rf *` and `mv * ..` took
# .git and .env with them. After compinit, which sets the list afresh.
_comp_options+=(globdots)

# Tab matches either case, so `cd de<Tab>` offers Desktop as well as dev. The
# Mac's file system already ignores case (`ls desktop` lists Desktop), so a
# prefix in the wrong case named the file everywhere except completion.
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# -------------------------
# Environment
# -------------------------

# Editor: nvim where it is installed. A server set up by bootstrap.sh's Linux
# branch has none, and there git, crontab -e and everything else that reads
# these would be told to run a program that does not exist; Debian's and
# Ubuntu's cloud images both come with a vi. git's own config names no editor,
# so that it follows these too.
if (( $+commands[nvim] )); then
  export EDITOR="nvim" VISUAL="nvim"
else
  export EDITOR="vi" VISUAL="vi"
fi

# Locale. bootstrap.sh's Linux branch reads LANG off the line below and
# generates that locale on a server that does not have it yet.
export LANG="en_GB.UTF-8"
export LC_ALL="en_GB.UTF-8"

# Rust toolchain
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Go: the bin dir `go install` writes to, after everything else on PATH. The
# default GOPATH is spelled out rather than asked of `go env GOPATH`, which
# forked go on every shell (about 7ms measured) and printed "command not found"
# on a machine without go.
if (( $+commands[go] )); then
  path+=("${GOPATH:-$HOME/go}/bin")
fi

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
# Only where there is an nvim: on a server without one this would turn a vim
# that works into a command that is not found.
if (( $+commands[nvim] )); then
  alias vim='nvim'
fi

# -------------------------
# Shell options
# -------------------------
setopt autocd
setopt no_beep
# A # that starts a word on the command line starts a comment, as in a script.
# Off by default in an interactive shell, so a line pasted from the README with
# its trailing comment ran the comment as arguments: `make stow  # Apply
# symlinks (with dry-run)` read "(with dry-run)" as glob qualifiers and died,
# and the line for make check opened a quote at "setup's". a#b is unaffected.
setopt interactive_comments

# -------------------------
# fzf shell integration (Ctrl-R history, Ctrl-T files, Alt-C cd)
# -------------------------
# `fzf --zsh` prints the integration, in fzf 0.48 and later. An older fzf,
# which is what Debian 12 and Ubuntu 24.04 package, rejects the flag: it wrote
# "unknown option: --zsh" into every new shell and bound nothing. apt installs
# the same two scripts as files instead, so those are sourced there. Where the
# flag works this is one fzf process per shell, as it was.
if (( $+commands[fzf] )); then
  if fzf_zsh="$(fzf --zsh 2>/dev/null)"; then
    eval "$fzf_zsh"
  else
    for fzf_zsh in /usr/share/doc/fzf/examples/{key-bindings,completion}.zsh; do
      if [[ -r $fzf_zsh ]]; then
        source $fzf_zsh
      fi
    done
  fi
  unset fzf_zsh
fi

# -------------------------
# Zsh plugins
# -------------------------
# Under Homebrew's share on a Mac, and under /usr/share where apt puts the same
# two packages; the first that has the file is sourced. They were looked for
# under Homebrew alone, so on Linux neither loaded and nothing said so. At the
# top level, not in a function, so what the plugins declare stays global.
#
# Syntax highlighting must be sourced last (after all widgets are defined),
# which is why it is second.
for zsh_plugin in zsh-autosuggestions zsh-syntax-highlighting; do
  for zsh_plugin_dir in ${HOMEBREW_PREFIX:+$HOMEBREW_PREFIX/share} /usr/share; do
    if [[ -r $zsh_plugin_dir/$zsh_plugin/$zsh_plugin.zsh ]]; then
      source $zsh_plugin_dir/$zsh_plugin/$zsh_plugin.zsh
      break
    fi
  done
done
unset zsh_plugin zsh_plugin_dir

# -------------------------
# Prompt (Starship) — must be last
# -------------------------
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
  # The init sets RPROMPT to a second `starship prompt --right`, run before
  # every prompt. starship.toml has no right_format, so that process draws
  # nothing; clearing RPROMPT saves the fork. Delete this line if starship.toml
  # gains a right_format: checks/repo.sh fails until the two agree.
  RPROMPT=''
else
  # No starship, which is every server bootstrap.sh's Linux branch sets up. A
  # prompt there has to say which machine it is: user@host first, over ssh
  # only, which is when starship's own hostname module would show it.
  PROMPT="${SSH_CONNECTION:+%n@%m }%1~ %# "
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
