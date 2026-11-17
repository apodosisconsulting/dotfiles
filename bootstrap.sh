#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOMEBREW_NO_ANALYTICS=1

log() { printf "\n==> %s\n" "$*"; }
warn() { printf "\nWARN: %s\n" "$*" >&2; }
die() {
  printf "\nERROR: %s\n" "$*" >&2
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

is_macos() { [[ "${OSTYPE:-}" == darwin* ]]; }

install_homebrew_macos() {
  if command -v brew >/dev/null 2>&1; then
    log "Homebrew already installed"
    return
  fi

  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Ensure brew is on PATH for this script run (Apple Silicon default)
  local brew_path=""
  if [[ -x /opt/homebrew/bin/brew ]]; then
    brew_path="/opt/homebrew/bin/brew"
  elif [[ -x /usr/local/bin/brew ]]; then
    brew_path="/usr/local/bin/brew"
  else
    die "brew installed but not found in expected locations"
  fi

  # For the rest of this run only. Nothing is written to ~/.zprofile any more:
  # .zshrc sets Homebrew's environment itself in every interactive shell, and
  # tmux.conf sets PATH for run-shell. The eval this appended there ran brew
  # again in every login shell, and every tmux pane is one; its whole-line
  # check also missed an eval already there inside an if, and appended another.
  eval "$("$brew_path" shellenv)" || die "Failed to initialize Homebrew environment"
}

brew_install_pkgs() {
  local pkgs=(
    git
    git-lfs
    stow
    neovim
    # nvim-treesitter's main branch builds every parser with this CLI. The
    # tree-sitter formula is now the library alone, without the command.
    tree-sitter-cli
    tmux
    ripgrep
    fd
    node
    go
    docker
    starship
    fzf
    zsh-autosuggestions
    zsh-syntax-highlighting
    prettier
    stylua
    black
    shfmt
    shellcheck
    clang-format
  )

  log "Updating Homebrew"
  brew update

  log "Installing packages: ${pkgs[*]}"
  brew install "${pkgs[@]}"

  # WezTerm is a cask (GUI)
  log "Installing WezTerm (cask)"
  brew install --cask wezterm || warn "WezTerm cask install failed (rerun later)"

  # wezterm.lua asks for "JetBrainsMono Nerd Font" and starship/lualine are full
  # of glyphs. Without the font both fall back to Menlo and every icon renders
  # as tofu — which looks like a config bug rather than a missing font.
  log "Installing JetBrainsMono Nerd Font (cask)"
  brew install --cask font-jetbrains-mono-nerd-font || warn "Nerd Font install failed (rerun later)"
}

install_go_tools() {
  # conform.lua formats Go with goimports: gofmt, plus adding and removing
  # imports on save. It is no Homebrew formula; go install builds it into
  # GOBIN, or GOPATH/bin (~/go/bin by default), which .zshrc puts on PATH. So
  # this runs after brew_install_pkgs, which installs go. Warn rather than die:
  # without it format-on-save falls back to gopls, which leaves imports alone.
  if ! command -v go >/dev/null 2>&1; then
    warn "go is not installed, so neither is goimports (later: go install golang.org/x/tools/cmd/goimports@latest)"
    return 0
  fi
  log "Installing goimports (go install)"
  go install golang.org/x/tools/cmd/goimports@latest ||
    warn "Could not install goimports (later: go install golang.org/x/tools/cmd/goimports@latest)"
}

install_rust() {
  # Rust is rustup-managed (lsp.lua uses the rustup-provided rust-analyzer),
  # so install via rustup rather than brew. Guarded: no-op if already present.
  if command -v rustup >/dev/null 2>&1 || command -v cargo >/dev/null 2>&1; then
    log "Rust toolchain already present"
  else
    log "Installing Rust via rustup"
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  fi

  # lsp.lua runs rust-analyzer from $CARGO_HOME/bin (~/.cargo/bin) by path,
  # not from PATH, where nvim finds Mason's first: this is the one it runs.
  if command -v rustup >/dev/null 2>&1; then
    log "Ensuring rust-analyzer component"
    rustup component add rust-analyzer >/dev/null 2>&1 ||
      warn "Could not add rust-analyzer (add later: rustup component add rust-analyzer)"
  fi
}

stow_packages() {
  log "Stowing dotfiles packages"
  cd "$DOTFILES_DIR"

  local packages=(nvim wezterm tmux zsh home starship)
  if [[ -d "$DOTFILES_DIR/gitconfig" ]]; then
    packages+=(gitconfig)
  elif [[ -d "$DOTFILES_DIR/git" ]]; then
    packages+=(git)
  else
    warn "No git/gitconfig package directory found; skipping git config stow"
  fi

  # Create the target directories BEFORE stowing. Stow folds a directory into a
  # single symlink when the target does not exist and exactly one package
  # supplies it. Only the tmux package supplies .local/, so on a fresh machine
  # ~/.local would become a symlink to ~/dotfiles/tmux/.local — and then nvim
  # would write its plugins, treesitter parsers and Mason binaries, and
  # tmux-resurrect its session saves, inside this git repo. `make unstow` would
  # then remove that symlink and strand the lot.
  #
  # (.config is supplied by five packages so stow already unfolds it, but make
  # it explicit rather than depend on that staying true.)
  #
  # Note: --no-folding would also prevent this, but it is the wrong cure — it
  # expands ~/.config/nvim into one symlink per file, so a newly added lua file
  # would not appear until the next restow.
  mkdir -p "$HOME/.local/bin" "$HOME/.config"

  # Dry run first
  log "Stow dry-run (no changes)"
  stow -n -t "$HOME" "${packages[@]}"

  log "Stow apply (restow to clean dead symlinks)"
  stow -R -t "$HOME" "${packages[@]}"
}

install_tmux_plugins() {
  # tmux.conf clones tpm on its first start, but tpm installs nothing by
  # itself: until someone presses prefix I, resurrect, continuum and the
  # navigator are absent, so prefix s runs a save.sh that is not there and
  # nothing is ever saved. So every `set -g @plugin` line in tmux.conf is
  # cloned here, read from the file itself so the list cannot drift from it,
  # into the directory tpm would use: the repo's basename. Plain git rather
  # than tpm's bin/install_plugins, which starts a tmux server on the default
  # socket to read one environment variable. CI runs this too.
  #
  # Already there is skipped, and a failed clone only warns: the network is the
  # likeliest thing to fail on a fresh machine, and prefix I can finish the job.
  local conf="$DOTFILES_DIR/tmux/.config/tmux/tmux.conf"
  local dir="$HOME/.config/tmux/plugins"
  local plugins p
  plugins="$(sed -n "s/^[[:space:]]*set -g @plugin '\([^']*\)'.*/\1/p" "$conf")"
  if [[ -z "$plugins" ]]; then
    warn "Read no @plugin lines out of $conf; no tmux plugins installed (prefix I in tmux later)"
    return 0
  fi
  mkdir -p "$dir"
  for p in $plugins; do
    [[ -d "$dir/${p##*/}" ]] && continue
    log "Installing tmux plugin $p"
    git clone -q --depth 1 "https://github.com/$p" "$dir/${p##*/}" ||
      warn "Could not clone $p (press prefix I in tmux later)"
  done
}

install_hooks() {
  # Local to this repo, not global: core.hooksPath in the stowed git config
  # would apply to every repo on this machine, none of which have a check.sh.
  log "Installing git hooks (check on commit, test-fast on push)"
  git -C "$DOTFILES_DIR" config core.hooksPath .githooks ||
    warn "Could not set core.hooksPath (run 'make hooks' later)"
}

# A fresh cloud server hands you root, or a user with sudo. Root needs nothing
# in front of a command, and a stock Debian image has no sudo for it to use.
as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_linux() {
  # What a hosting server gets: zsh, tmux and git, set up as on the Mac, from
  # apt alone. No Neovim, whose config assumes the Mac's toolchain around it (a
  # current Neovim, node, go, a compiler), no tmux plugins, no git hooks, and
  # nothing fetched from anywhere but the distribution's own archive. Debian
  # and Ubuntu, because every package name and path below is theirs.
  # tests/linux-server.sh runs this on a fresh one of each and checks what it
  # built; CI does that on every push.
  command -v apt-get >/dev/null 2>&1 ||
    die "On Linux this script supports Debian and Ubuntu only: there is no apt-get here."
  [[ $EUID -eq 0 ]] || need_cmd sudo

  # The two zsh plugins are the ones .zshrc sources from /usr/share, and
  # locales is what provides locale-gen. The lock timeout is for a server in
  # its first minutes, when unattended-upgrades holds dpkg's lock: apt-get
  # then waits for it instead of failing at once.
  local pkgs=(zsh tmux git stow fzf locales zsh-autosuggestions zsh-syntax-highlighting)
  log "Installing packages: ${pkgs[*]}"
  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=300 install -y "${pkgs[@]}"

  # The stowed git config sets merge.conflictstyle to zdiff3, which arrived in
  # git 2.35. An older git does not ignore the value: it dies on it, in every
  # checkout and every merge, and a diff3 in ~/.gitconfig does not rescue it,
  # because git stops at the first file that says zdiff3 (tried, on Ubuntu
  # 22.04, whose git is 2.34). So a release that old is refused here, before
  # anything is linked, rather than left with a git that cannot switch branch.
  # sort -C -V succeeds when the two are in version order, 2.35 first.
  local git_version
  git_version="$(git version | awk '{ print $3 }')"
  printf '%s\n' 2.35 "$git_version" | sort -C -V ||
    die "git here is $git_version, and this repo's git config needs 2.35 or newer. The packages are installed; nothing was linked."

  # The locale .zshrc sets, read from it so the two cannot disagree. The base
  # images this is tested on have generated C.UTF-8 and nothing else, and the
  # Mac's ssh sends its LANG along as well, so without this perl warns that
  # setting the locale failed every time it runs, and it is not the only thing
  # that looks. The line is uncommented in /etc/locale.gen rather than built
  # with localedef, so the next locale-gen run keeps it.
  # `locale -a` spells it en_GB.utf8. grep reads to the end rather than
  # stopping at a match (no -q): with pipefail, a writer cut off mid-list
  # would turn "found" into a failed pipeline.
  local lang listed
  lang="$(sed -n 's/^export LANG="\(.*\)"$/\1/p' "$DOTFILES_DIR/zsh/.zshrc")"
  listed="${lang/UTF-8/utf8}"
  if [[ -z "$lang" ]]; then
    warn "Read no LANG out of zsh/.zshrc, so no locale was generated"
  elif ! locale -a | grep -ixF "$listed" >/dev/null; then
    log "Generating the $lang locale"
    as_root sed -i "s/^# *\($lang \)/\1/" /etc/locale.gen
    as_root locale-gen
    locale -a | grep -ixF "$listed" >/dev/null ||
      warn "Could not generate $lang (is it listed in /etc/locale.gen?)"
  fi

  # Three packages, not the Mac's seven. nvim and wezterm configure programs
  # that are not installed here, and starship and home (the formatter configs)
  # likewise. The same mkdir as stow_packages, for the same reason: without it
  # stow folds the whole of .local into one link into this repo.
  log "Stowing zsh, tmux and git"
  mkdir -p "$HOME/.local/bin" "$HOME/.config"
  cd "$DOTFILES_DIR"
  stow -R -t "$HOME" zsh tmux git

  # The login shell of whoever ran this. Through as_root, because chsh run by
  # root asks for no password and the first user of a cloud image often has
  # none to give.
  local zsh_path user
  zsh_path="$(command -v zsh)"
  user="$(id -un)"
  if [[ "$(getent passwd "$user" | cut -d: -f7)" != "$zsh_path" ]]; then
    log "Making zsh the login shell of $user"
    as_root chsh -s "$zsh_path" "$user"
  fi

  log "OK: zsh, tmux and git are set up. Log in again, or run: exec zsh -l"
}

post_checks() {
  log "Post-checks (fail fast)"

  need_cmd git
  need_cmd nvim
  need_cmd tmux
  need_cmd rg
  need_cmd fd
  need_cmd node
  need_cmd npm

  # Confirm key config paths exist (symlink or dir)
  [[ -e "$HOME/.config/nvim" ]] || die "$HOME/.config/nvim missing (stow failed?)"
  [[ -e "$HOME/.config/wezterm" ]] || warn "$HOME/.config/wezterm missing (if you skipped wezterm package, ignore)"
  [[ -e "$HOME/.config/tmux" ]] || warn "$HOME/.config/tmux missing (if you don't use tmux config, ignore)"

  log "Versions"
  nvim --version | head -n 2 || true
  tmux -V || true
  node -v || true
  npm -v || true

  log "OK: bootstrap complete"
}

main() {
  # Anything that is not a Mac gets the server setup and nothing below it.
  # Returned from here, rather than the Mac's steps nested in an else, so
  # every line under this one is still a step of the Mac's setup and
  # checks/repo.sh can go on reading main() as that list.
  if ! is_macos; then
    install_linux
    return
  fi

  install_homebrew_macos
  need_cmd brew

  brew_install_pkgs
  install_go_tools
  install_rust
  stow_packages
  install_tmux_plugins
  install_hooks
  post_checks
}

# Only run when executed, not when sourced. tests/test-fresh-machine.sh sources
# this file to call stow_packages() against a throwaway $HOME — the stow
# tree-folding bug only reproduces on a machine where ~/.local does not yet
# exist, so it cannot be caught any other way from a machine that already works.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
