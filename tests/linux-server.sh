#!/usr/bin/env bash
# What ./bootstrap.sh builds on a new Debian or Ubuntu server, checked on one.
#
# Not a test-*.sh suite, so tests/run.sh, the hooks and `make test` never run
# it. It installs packages, generates a locale, changes a login shell and, with
# --as-user, creates an account, which is only acceptable on a machine that is
# thrown away afterwards: it refuses to start anywhere but a container. CI runs
# it in one per release and account (.github/workflows/ci.yml). By hand, from
# the repo root, with any docker:
#
#   tar -cf - . | docker run -i --rm debian:13 bash -c \
#     'mkdir /src && tar -xf - -C /src && bash /src/tests/linux-server.sh'
#
# Two accounts, because those are the two a cloud image hands you:
#
#   --as-root  root, with no sudo installed, as on a stock Debian image. The
#              default.
#   --as-user  a new user who has passwordless sudo and no password
#
# Each starts from the untouched image, so the packages, the locale and the
# login shell are all still to do when bootstrap.sh runs.

case "${OSTYPE:-}" in
  linux*) : ;;
  *)
    echo "tests/linux-server.sh: for a Linux container; this is ${OSTYPE:-an unknown system}" >&2
    exit 1
    ;;
esac
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ] && [ "${DOTFILES_THROWAWAY_MACHINE:-}" != 1 ]; then
  echo "tests/linux-server.sh: REFUSING TO RUN outside a container. It installs packages and" >&2
  echo "changes a login shell. On a VM you will delete, set DOTFILES_THROWAWAY_MACHINE=1." >&2
  exit 1
fi

case "${1:---as-root}" in
  --as-root) : ;;
  --as-user)
    # Still root here: make the account, hand it a copy of the repo where the
    # README's one command would have cloned it, and start again as that user.
    # env -i, so nothing of root's environment comes along.
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq sudo >/dev/null || exit 1
    useradd --create-home --shell /bin/bash dev || exit 1
    echo 'dev ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/dev
    cp -R "$src" /home/dev/dotfiles && chown -R dev: /home/dev/dotfiles || exit 1
    exec runuser -u dev -- env -i HOME=/home/dev USER=dev LOGNAME=dev \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      bash /home/dev/dotfiles/tests/linux-server.sh
    ;;
  *)
    echo "usage: tests/linux-server.sh [--as-root | --as-user]" >&2
    exit 2
    ;;
esac

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

me="$(id -un)"
repo="$HOME/dotfiles"
log="$TEST_TMP/bootstrap.log"

# Follows no link, so a dangling one still counts as there.
exists() { [ -e "$1" ] || [ -L "$1" ]; }

if exists "$HOME/.zshrc"; then
  echo "tests/linux-server.sh: $HOME/.zshrc already exists, so this is not a fresh machine" >&2
  exit 1
fi

# Ubuntu's container image tells dpkg to leave out /usr/share/doc; its server
# image does not. apt's fzf keeps its zsh scripts there and .zshrc sources
# them, so the rule goes before anything is installed.
if [ -f /etc/dpkg/dpkg.cfg.d/excludes ]; then
  if [ "$EUID" -eq 0 ]; then rm /etc/dpkg/dpkg.cfg.d/excludes; else sudo rm /etc/dpkg/dpkg.cfg.d/excludes; fi
fi

# Where the README's one command clones it.
if [ "$REPO_ROOT" != "$repo" ]; then
  cp -R "$REPO_ROOT" "$repo" || exit 1
fi

echo "== bootstrap.sh on a fresh machine, as $me =="
"$repo/bootstrap.sh" >"$log" 2>&1
rc=$?

# A release whose git is too old for the stowed git config is refused, which
# is the right outcome there and the whole of what there is to check: that it
# really is too old, and that the refusal left nothing half done.
if [ "$rc" -ne 0 ] && grep -q 'needs 2.35 or newer' "$log"; then
  echo "  (refused: $(grep -m1 'needs 2.35 or newer' "$log"))"
  # sort -C -V succeeds when the two are in version order, 2.35 first.
  here="$(git version | cut -d' ' -f3)"
  if printf '%s\n' 2.35 "$here" | sort -C -V; then too_old=no; else too_old=yes; fi
  assert "git $here really is older than 2.35" [ "$too_old" = yes ]
  refute "nothing was linked: no ~/.zshrc" exists "$HOME/.zshrc"
  refute "and no git config" exists "$HOME/.config/git"
  refute "the login shell was left alone" \
    [ "$(getent passwd "$me" | cut -d: -f7)" = "$(command -v zsh)" ]
  finish
  exit
fi

[ "$rc" -eq 0 ] || tail -n 40 "$log"
assert "bootstrap.sh exits 0" [ "$rc" -eq 0 ]

echo
echo "== what it linked =="
assert "$HOME/.zshrc is a link into the repo" \
  [ "$(readlink -f "$HOME/.zshrc")" = "$repo/zsh/.zshrc" ]
assert "so is tmux.conf" \
  [ "$(readlink -f "$HOME/.config/tmux/tmux.conf")" = "$repo/tmux/.config/tmux/tmux.conf" ]
assert "and git's config" \
  [ "$(readlink -f "$HOME/.config/git/config")" = "$repo/git/.config/git/config" ]
assert "the tmux helper scripts are in ~/.local/bin" [ -x "$HOME/.local/bin/tmux-sessionizer" ]
refute "$HOME/.local is not one link into the repo" [ -L "$HOME/.local" ]
refute "nor is $HOME/.config" [ -L "$HOME/.config" ]
refute "the nvim package is not stowed" exists "$HOME/.config/nvim"
refute "nor the wezterm package" exists "$HOME/.config/wezterm"
assert "zsh is $me's login shell" \
  [ "$(getent passwd "$me" | cut -d: -f7)" = "$(command -v zsh)" ]

echo
echo "== an interactive zsh =="
# As sshd starts one: next to nothing in the environment but a terminal type
# and SSH_CONNECTION, and a terminal, which script(1) supplies. Without one zsh
# cannot switch its line editor on, and fzf's scripts, which switch it off and
# on around themselves, draw a complaint that no login ever sees. $1 is a file
# of zsh to run once .zshrc has, $2... are extra variables.
in_zsh() {
  local file="$1"
  shift
  env -i HOME="$HOME" USER="$me" LOGNAME="$me" TERM=xterm-256color \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@" \
    script -qec "zsh -i $file" /dev/null </dev/null | tr -d '\r'
}
ssh_conn="SSH_CONNECTION=192.0.2.1 50000 192.0.2.2 22"
# "started" is printed first, so anything above it is something .zshrc wrote
# on its way up; the terminal carries stdout and stderr alike.
cat >"$TEST_TMP/probe.zsh" <<'PROBE'
print -r -- "started"
print -r -- "autosuggest=${+functions[_zsh_autosuggest_start]}"
print -r -- "highlight=${+functions[_zsh_highlight]}"
print -r -- "ctrl_r=$(bindkey "^R")"
print -r -- "tab=$(bindkey "^I")"
print -r -- "editor=$EDITOR visual=$VISUAL git=$(git var GIT_EDITOR)"
print -r -- "vim_alias=${+aliases[vim]}"
print -r -- "prompt=[$PROMPT]"
print -r -- "locale_errors=$(locale 2>&1 | grep -c "Cannot set")"
PROBE
out="$(in_zsh "$TEST_TMP/probe.zsh" "$ssh_conn")"
[ "$(printf '%s\n' "$out" | head -n 1)" = started ] || printf '%s\n' "$out" | sed 's/^/    /'
assert "it starts without printing anything, error or otherwise" \
  [ "$(printf '%s\n' "$out" | head -n 1)" = started ]
assert "zsh-autosuggestions is loaded" contains "$out" "autosuggest=1"
assert "zsh-syntax-highlighting is loaded" contains "$out" "highlight=1"
assert "Ctrl-R is fzf's history search" \
  contains "$(printf '%s\n' "$out" | grep '^ctrl_r=')" fzf-history-widget
assert "Tab goes through fzf's completion" \
  contains "$(printf '%s\n' "$out" | grep '^tab=')" fzf-completion
assert "EDITOR and VISUAL are vi, there being no nvim, and git follows them" \
  contains "$out" "editor=vi visual=vi git=vi"
assert "vim is not aliased to an nvim that is not there" contains "$out" "vim_alias=0"
assert "over ssh the prompt names the user and the host" contains "$out" "prompt=[%n@%m %1~ %# ]"
assert "the locale .zshrc sets exists, so nothing warns about it" contains "$out" "locale_errors=0"
assert "without ssh the prompt is the directory alone" \
  contains "$(in_zsh "$TEST_TMP/probe.zsh")" "prompt=[%1~ %# ]"

echo
echo "== tmux =="
TMUX_SOCK="$(tmux_test_socket linux)"
require_private_socket
trap cleanup_tmux_suite EXIT
# A server started with a PATH of its own, then the stowed config sourced from
# a client: that way tmux reports every line it rejects, inside a block or not,
# on every release (a config read at start is reported only in the first pane,
# and not by every release).
server_path=/usr/local/bin:/usr/bin:/bin:/dotfiles-test-marker
env PATH="$server_path" tmux -L "$TMUX_SOCK" -f /dev/null new-session -d -x 80 -y 24
said="$(t source-file "$HOME/.config/tmux/tmux.conf" 2>&1)"
rc=$?
[ -n "$said" ] && printf '%s\n' "$said" | sed 's/^/    /'
# A function, because `assert "..." [ a ] && [ b ]` asserts only the first.
loaded_quietly() { [ "$rc" -eq 0 ] && [ -z "$said" ]; }
assert "tmux $(tmux -V | cut -d' ' -f2) loads tmux.conf without a complaint" loaded_quietly
assert "the config took effect (the prefix is C-a)" [ "$(t show -gv prefix)" = C-a ]
assert "no copy-command, there being no pbcopy to pipe to" [ -z "$(t show -sv copy-command)" ]
paste="$(t list-keys -T prefix | grep -E '[[:space:]]\][[:space:]]')"
assert "prefix ] pastes tmux's own buffer" contains "$paste" "paste-buffer -p"
refute "and never calls pbpaste" contains "$paste" pbpaste
assert "copies still go out by OSC 52 (set-clipboard on)" [ "$(t show -sv set-clipboard)" = on ]
assert "the server's PATH is left as it was started with" \
  [ "$(t show-environment -g PATH)" = "PATH=$server_path" ]
# The tpm line runs in the background; give it time to have complained.
sleep 2
refute "starting tmux fetched no plugin manager" exists "$HOME/.config/tmux/plugins/tpm"
assert "and put no error in the first window" [ "$(t display-message -p '#{pane_in_mode}')" = 0 ]

echo
echo "== git =="
g="$TEST_TMP/repo"
git init -q "$g"
assert "git reads the stowed config (a new repo starts on main)" \
  [ "$(git -C "$g" symbolic-ref --short HEAD 2>/dev/null)" = main ]
refute "the stowed config names no editor" git config --get core.editor
commit() { (cd "$g" && echo "$1" >f && git add f && git commit -q -m "$1") >/dev/null 2>&1; }
switch() { (cd "$g" && git checkout -q "$@") >/dev/null 2>&1; }
assert "a commit goes through with the stowed identity" commit one
# Checkout and merge are where a git too old for the stowed
# merge.conflictstyle dies, so both are run, and on the same file from two
# branches so the merge has a conflict to show in that style.
assert "git $(git version | cut -d' ' -f3) can make a branch and switch to it" switch -b side
commit two
assert "and switch back" switch main
commit three
merged="$(cd "$g" && git merge side 2>&1)"
assert "a merge runs as far as its conflict" contains "$merged" CONFLICT
assert "which shows the common ancestor, as the config asks" \
  contains "$(cat "$g/f")" "|||||||"

echo
echo "== a second run =="
links() { find "$HOME" -maxdepth 4 -type l -not -path "$repo/*" -printf '%p -> %l\n' | sort; }
before="$(links)"
"$repo/bootstrap.sh" >"$log.2" 2>&1
rc=$?
[ "$rc" -eq 0 ] || tail -n 40 "$log.2"
assert "it exits 0" [ "$rc" -eq 0 ]
assert "the first run left links to compare" [ -n "$before" ]
assert "and the second leaves exactly those" [ "$before" = "$(links)" ]
refute "it does not generate the locale again" grep -q 'Generating the' "$log.2"
refute "nor change the login shell again" grep -q 'Making zsh the login shell' "$log.2"

finish
