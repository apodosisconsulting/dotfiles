#!/usr/bin/env bash
# .zshrc behaviour that is easy to get wrong and impossible to notice.
#
# The completion-cache branch was unreachable for months: `(#q...)` glob
# qualifiers need EXTENDED_GLOB, and without it zsh never expands the pattern,
# the -n test sees a non-empty literal string, and every shell paid for a full
# compinit. The only symptom was "shells feel a bit slow".

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ZSHRC="$REPO_ROOT/zsh/.zshrc"

command -v zsh >/dev/null 2>&1 || skip_suite "zsh is not installed"

echo "== the file is valid zsh =="
assert ".zshrc parses" zsh -n "$ZSHRC"

echo
echo "== the compinit cache branch is reachable =="
# Extracted rather than sourced: sourcing the real .zshrc would pull in nvm,
# Homebrew, plugins and completion dumps, and would write to the caller's
# $HOME. What matters is which branch the guard takes, so run just that.
probe() { # $1 = probe file to test against
  PROBE="$1" zsh -f -c '
    compinit() { print -r -- "compinit $*"; }
    () {
      setopt localoptions extendedglob
      if [[ -n ${PROBE}(#qN.mh-24) ]]; then compinit -C; else compinit; fi
    }
    [[ -o extendedglob ]] && print -r -- "LEAKED" || print -r -- "scoped"
  '
}

DUMP="$TEST_TMP/zcompdump"

touch "$DUMP"
out="$(probe "$DUMP")"
assert "a fresh dump takes the CACHED path (this is what was unreachable)" \
  contains "$out" "compinit -C"

touch -t "$(date -v-48H +%Y%m%d%H%M 2>/dev/null || date -d '48 hours ago' +%Y%m%d%H%M)" "$DUMP"
out="$(probe "$DUMP")"
assert "a day-old dump is rebuilt" contains "$out" "compinit"
refute "...and specifically NOT from cache" contains "$out" "compinit -C"

rm -f "$DUMP"
out="$(probe "$DUMP")"
assert "a MISSING dump is built properly rather than trusted" contains "$out" "compinit"
refute "...and specifically NOT from cache" contains "$out" "compinit -C"

assert "extendedglob does not leak out of the anonymous function" \
  contains "$out" "scoped"

# Why extendedglob is load-bearing, demonstrated rather than asserted. Note that
# a FRESH dump gives the right answer either way by coincidence — both branches
# say "use the cache" — so testing only that case would prove nothing. The
# missing-dump case is the one that separates them.
broken="$(PROBE="$TEST_TMP/definitely-absent" zsh -f -c '
  compinit() { print -r -- "compinit $*"; }
  () {
    setopt localoptions          # extendedglob deliberately NOT set
    if [[ -n ${PROBE}(#qN.mh-24) ]]; then compinit -C; else compinit; fi
  }
')"
assert "without extendedglob a MISSING dump wrongly takes the cached path" \
  contains "$broken" "compinit -C"

echo
echo "== the real .zshrc still contains that shape =="
# Anchored to the setopt line, not to any mention of extendedglob: the comment
# above it explains why it is needed, and matching that proves nothing. This is
# the same bug check.sh had.
assert "it enables extendedglob where it uses (#q...)" \
  grep -qE '^[[:space:]]*setopt[^#]*extendedglob' "$ZSHRC"
assert "it uses the mh-24 form, so a missing dump falls through to a full build" \
  grep -qE 'mh-24' "$ZSHRC"

echo
echo "== PATH cannot accumulate duplicates =="
# Every PATH entry in .zshrc prepends unconditionally, so without typeset -U a
# nested shell or a re-source stacks another copy of each.
assert "path and PATH are declared -U" \
  grep -qE '^[[:space:]]*typeset -U path PATH' "$ZSHRC"
dupes="$(zsh -f -c 'typeset -U path PATH; path=(/a /b /a /b /c); print -r -- $#path')"
assert "which really does collapse duplicates" [ "${dupes:-0}" -eq 3 ]

echo
echo "== the Homebrew block sets exactly what brew shellenv would =="
# .zshrc writes out what `brew shellenv` prints instead of running it, so brew's
# own output is the specification. Compared, not trusted: each side runs in a
# clean zsh after the file's own typeset -U line, and the comparison is of
# `typeset -p`, so export flags and types count as well as values.
brew_bin=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$b" ]; then
    brew_bin="$b"
    break
  fi
done
if [ -z "$brew_bin" ]; then
  printf '  \033[33mSKIP\033[0m  %s\n' "no Homebrew here, so there is no brew shellenv to compare the block with"
else
  prefix="${brew_bin%/bin/brew}"
  BLOCK="$TEST_TMP/brew-block.zsh"
  sed -n '/^# Homebrew/,/^# Local scripts/p' "$ZSHRC" >"$BLOCK"
  preamble="$(grep -m1 -E '^[[:space:]]*typeset -U path' "$ZSHRC")"
  assert "the file's typeset -U line can be read, to run before each side" \
    contains "$preamble" "typeset -U path PATH"
  dump='typeset -p PATH FPATH MANPATH INFOPATH HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY 2>&1'
  clean="PATH=/usr/bin:/bin:/usr/sbin:/sbin"
  brew_env() { # $1 = a block to source, or "brew"; $2... = the environment
    local what="$1" run
    shift
    if [ "$what" = brew ]; then
      run="eval \"\$($brew_bin shellenv zsh)\""
    else
      run="source $what"
    fi
    env -i HOME="$TEST_TMP" "$@" zsh -f -c "${preamble:-false}; $run; $dump"
  }

  # The vacuity guards. A block that is empty, or that still runs brew, would
  # agree with brew trivially. Comment lines are dropped first, because the
  # block's comment explains what it replaced.
  code="$(grep -vE '^[[:space:]]*#' "$BLOCK")"
  assert "the block can be read out of .zshrc, and sets HOMEBREW_PREFIX" \
    contains "$code" "HOMEBREW_PREFIX="
  refute "...and does not run brew shellenv itself, which would compare it with itself" \
    contains "$code" "shellenv"

  for extra in "" "MANPATH=/a:/b" "MANPATH=/a:/b INFOPATH=/i FPATH=/f"; do
    # shellcheck disable=SC2086  # split on purpose: one env assignment per word
    ours="$(brew_env "$BLOCK" $clean $extra)"
    # shellcheck disable=SC2086
    theirs="$(brew_env brew $clean $extra)"
    assert "with ${extra:-nothing else} set, the block leaves the same environment as brew shellenv" \
      [ "$ours" = "$theirs" ]
  done
  assert "...and that environment has brew's prefix in it, so the comparison was not of two failures" \
    contains "$ours" "HOMEBREW_PREFIX=$prefix"

  # Inline negative control: the comparison above can fail.
  sed "s| \$HOMEBREW_PREFIX/sbin||" "$BLOCK" >"$TEST_TMP/brew-block-nosbin.zsh"
  refute "a copy of the block without brew's sbin really is different" \
    cmp -s "$BLOCK" "$TEST_TMP/brew-block-nosbin.zsh"
  ours="$(brew_env "$TEST_TMP/brew-block-nosbin.zsh" "$clean")"
  theirs="$(brew_env brew "$clean")"
  refute "...and that copy fails the comparison" [ "$ours" = "$theirs" ]

  # The bug the block fixes. brew returns early when PATH already starts with
  # its bin and sbin, printing nothing, so HOMEBREW_PREFIX was never set and
  # both plugins were skipped without a word.
  first="PATH=$prefix/bin:$prefix/sbin:/usr/bin:/bin"
  printed="$(env -i HOME="$TEST_TMP" "$first" "$brew_bin" shellenv zsh)"
  rc=$?
  assert "brew shellenv prints nothing when PATH already starts with its bin and sbin" \
    [ "$rc:$printed" = "0:" ]
  got="$(env -i HOME="$TEST_TMP" "$first" zsh -f -c "$preamble; source $BLOCK; print -r -- \${HOMEBREW_PREFIX-unset}")"
  assert "...where the block still sets HOMEBREW_PREFIX, so the plugins load" \
    [ "$got" = "$prefix" ]

  # A nested shell inherits everything the block exported and runs it again.
  # brew's output did not survive that: .zshrc puts ~/.local/bin ahead of
  # brew's bin, so its early return never fired in a nested shell, and each one
  # added another copy of its fpath and INFOPATH entries. The block must not.
  #
  # So each shell runs the block AND the line after it that puts ~/.local/bin
  # first, read out of .zshrc in its own order. With the block alone, PATH in
  # the nested shell still starts with brew's bin and sbin, brew's early return
  # fires there, and the `brew shellenv` this block replaced passed the
  # comparison while real nested shells duplicated.
  upto_local_bin() { # $1 = a pattern for the .zshrc line to start at
    awk -v start="$1" '$0 ~ start { on = 1 } on { print }
      on && /^[^#]*\.local\/bin/ { exit }' "$ZSHRC"
  }
  TOP="$TEST_TMP/brew-top.zsh"
  upto_local_bin '^# Homebrew' >"$TOP"
  assert "the block can be read out with the ~/.local/bin line that follows it" \
    contains "$(tail -n 1 "$TOP")" '/.local/bin:'
  run_once() { # $1 = the typeset -U line to run first, $2 = the file to source
    env -i HOME="$TEST_TMP" "$clean" MANPATH=/a:/b zsh -f -c "$1; source $2; $dump"
  }
  nested() { # the same, run in a shell that ran it first
    env -i HOME="$TEST_TMP" "$clean" MANPATH=/a:/b zsh -f -c \
      "$1; source $2; zsh -f -c '$1; source $2; $dump'"
  }
  once="$(run_once "$preamble" "$TOP")"
  assert "a shell nested in one that ran the block ends up with the same environment" \
    [ "$once" = "$(nested "$preamble" "$TOP")" ]
  # The negative controls for that, each naming the copy it expects. Without
  # fpath in the typeset -U line, a second copy of brew's site-functions.
  site="$prefix/share/zsh/site-functions"
  assert "...but not without fpath in the typeset -U line: site-functions twice" \
    contains "$(nested "typeset -U path PATH" "$TOP")" "fpath=( $site $site "
  # And with brew shellenv run in the block's place, as .zshrc did, a second
  # copy of brew's INFOPATH entry, which a shell run once does not have. Named
  # rather than compared whole, so it holds whatever the typeset -U line says.
  OLD="$TEST_TMP/brew-top-eval.zsh"
  {
    # shellcheck disable=SC2016  # zsh code, written into the file
    printf 'eval "$(%s shellenv zsh)"\n' "$brew_bin"
    upto_local_bin '^# Local scripts'
  } >"$OLD"
  info="$prefix/share/info:"
  old_once="$(run_once "$preamble" "$OLD")"
  assert "with brew shellenv in the block's place, a shell run once has brew's INFOPATH entry" \
    contains "$old_once" "INFOPATH=$info"
  refute "...only once" contains "$old_once" "INFOPATH=$info$info"
  assert "...and a nested one has it twice, so the nested comparison can fail" \
    contains "$(nested "$preamble" "$OLD")" "INFOPATH=$info$info"
fi

# The whole file, run as a terminal runs it, in a scratch HOME: with ZDOTDIR
# unset zsh reads .zshrc from HOME, and the history, completion dump and
# starship cache it writes land there too, so nothing of the caller's is read
# or written. env -i keeps the caller's own EDITOR out. TERM is a real terminal
# type, because /etc/zshrc looks its keys up in terminfo and a dumb terminal
# has none. Run from the scratch dir, so nothing the prompt does looks at the
# caller's directory.
rc_home() { # $1 = a name; stdin = the .zshrc to run. Prints the new HOME.
  mkdir -p "$TEST_TMP/$1"
  cat >"$TEST_TMP/$1/.zshrc"
  printf '%s' "$TEST_TMP/$1"
}
in_rc() { # $1 = a HOME from rc_home, $2... = env assignments, then the command
  local home="$1"
  shift
  (cd "$TEST_TMP" && env -i HOME="$home" TERM=xterm-256color PATH=/usr/bin:/bin \
    STARSHIP_CONFIG="$REPO_ROOT/starship/.config/starship.toml" "$@")
}
real_home="$(rc_home real <"$ZSHRC")"

echo
echo "== the keymap is emacs whether or not EDITOR was inherited =="
# zle starts in vi insert mode when $EDITOR or $VISUAL mentions vi. .zshrc
# exports EDITOR=nvim, so a shell started from a shell (exec zsh, a nested zsh,
# nvim's :terminal) came up in vi mode, where Ctrl-A types itself, while a
# fresh terminal did not. One line per key: a name, then the widget it runs.
# shellcheck disable=SC2016  # zsh code, expanded by zsh
probe_keys='k() { local b; b=$(bindkey -- "$2"); print -r -- "$1 ${b##* }"; }
  print -r -- "main $(bindkey -lL main)"
  k ctrl-a "^A"
  k ctrl-x-h "^Xh"
  k delete "$terminfo[kdch1]"
  k home "$terminfo[khome]"
  k up "$terminfo[kcuu1]"'
keys="$(in_rc "$real_home" zsh -i -c "$probe_keys" 2>/dev/null)"
assert "a fresh terminal's shell gets emacs keys" \
  contains "$keys" "main bindkey -A emacs main"
keys="$(in_rc "$real_home" EDITOR=nvim VISUAL=nvim zsh -i -c "$probe_keys" 2>/dev/null)"
assert "so does one that inherited EDITOR=nvim" \
  contains "$keys" "main bindkey -A emacs main"
assert "...where Ctrl-A goes to the start of the line" \
  contains "$keys" "ctrl-a beginning-of-line"
assert "...and compinit's Ctrl-X h is bound, because emacs was chosen before it" \
  contains "$keys" "ctrl-x-h _complete_help"
if [ -r /etc/zshrc ]; then
  assert "...and Delete deletes, as /etc/zshrc binds it" \
    contains "$keys" "delete delete-char"
  assert "...and Home goes to the start of the line, as /etc/zshrc binds it" \
    contains "$keys" "home beginning-of-line"
  assert "...and Up searches on what is already typed, as /etc/zshrc binds it" \
    contains "$keys" "up up-line-or-search"
else
  printf '  \033[33mSKIP\033[0m  %s\n' "no /etc/zshrc, so there are no system key bindings to carry into emacs"
fi

# Inline negative control: the same file without bindkey -e comes up in vi
# mode, so the assertions above are about that line and not this environment.
no_emacs="$(sed '/^[[:space:]]*bindkey -e$/d' "$ZSHRC" | rc_home no-emacs)"
refute "a copy of .zshrc without bindkey -e really is different" \
  cmp -s "$ZSHRC" "$no_emacs/.zshrc"
keys="$(in_rc "$no_emacs" EDITOR=nvim VISUAL=nvim zsh -i -c "$probe_keys" 2>/dev/null)"
assert "...and with EDITOR=nvim inherited that copy comes up in vi insert mode" \
  contains "$keys" "main bindkey -A viins main"

echo
echo "== a # on the command line starts a comment =="
# Off by default in an interactive zsh, so a command pasted with its trailing
# comment, which is how the README writes its usage lines, ran with the
# comment's words as arguments. Typed on stdin, not passed with -c: a -c script
# treats # as a comment even under -i, so it could not tell the difference.
typed='print -r -- a # b
print -r -- c#d'
out="$(printf '%s\n' "$typed" | in_rc "$real_home" zsh -i 2>/dev/null)"
assert "a command typed with a trailing comment runs without it" \
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "a" ]
assert "...while a # inside a word is still just a character" \
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "c#d" ]

no_comments="$(sed '/^[[:space:]]*setopt interactive_comments$/d' "$ZSHRC" | rc_home no-comments)"
refute "a copy of .zshrc without interactive_comments really is different" \
  cmp -s "$ZSHRC" "$no_comments/.zshrc"
out="$(printf '%s\n' "$typed" | in_rc "$no_comments" zsh -i 2>/dev/null)"
assert "...and that copy passes the comment along as arguments, so the test can fail" \
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "a # b" ]

# What Tab offers, read from a real zle on a pseudo-terminal: completion runs
# nowhere else, so a `zsh -i -c` cannot see it. The recording is done by
# ~/.zshrc.local, which .zshrc sources last, after compinit, fzf's Tab binding
# and the plugins, so the candidates are the ones this .zshrc really offers.
# compadd -O does the matching without adding anything, which is how each
# candidate compadd ACCEPTS is written down rather than each one it is handed;
# a call that only filters (-O, -A, -D of its own) is passed straight through.
# The two markers are the driver's cue to type and to stop.
COMPLETE="$REPO_ROOT/tests/helpers/zsh-complete.py"
python_bin="$(command -v python3 2>/dev/null)"
CAPTURE_RC="$TEST_TMP/capture.zsh"
# shellcheck disable=SC2016  # zsh code, expanded by zsh
printf '%s\n' \
  'compadd() {' \
  '  if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then' \
  '    builtin compadd "$@"' \
  '    return' \
  '  fi' \
  '  local -a got' \
  '  builtin compadd -O got "$@"' \
  '  (( $#got )) && print -rl -- $got >>$CAPTURE' \
  '  builtin compadd "$@"' \
  '}' \
  'capture_ready() { : >$CAPTURE.ready; }' \
  'capture_done() { : >$CAPTURE.done; }' \
  'precmd_functions+=(capture_ready)' \
  'comppostfuncs+=(capture_done)' >"$CAPTURE_RC"
# Cleared first: called in a $( ), so nothing it did last time is known here,
# and markers left by an earlier call would end this one before Tab was read.
complete_in() { # $1 = a HOME from rc_home, $2 = dir, $3 = line typed before Tab
  local out="$1/offered"
  rm -f "$out" "$out.ready" "$out.done"
  cp "$CAPTURE_RC" "$1/.zshrc.local"
  in_rc "$1" CAPTURE="$out" "$python_bin" "$COMPLETE" "$2" "$3" "$out" >/dev/null 2>&1
  printf ' %s ' "$(sort -u "$out" 2>/dev/null | tr '\n' ' ')"
}

echo
echo "== a * on the command line skips dotfiles, and Tab still offers them =="
# `setopt globdots` made every glob in every shell match dotfiles, so `rm -rf *`
# took .git and .env with it. .zshrc puts globdots on compinit's _comp_options
# instead, which only completion runs under.
DOTS="$TEST_TMP/dots"
mkdir -p "$DOTS/.git" "$DOTS/src"
: >"$DOTS/.env"
: >"$DOTS/README"
glob_in() { in_rc "$1" zsh -i -c "cd '$DOTS' && print -r -- *" 2>/dev/null; }
assert "the scratch dir really holds a dotfile (guards a vacuous test)" [ -e "$DOTS/.env" ]
assert "* expands to everything but the dotfiles" [ "$(glob_in "$real_home")" = "README src" ]
set_dots="$(sed 's/^_comp_options+=(globdots)$/setopt globdots/' "$ZSHRC" | rc_home setopt-globdots)"
refute "a copy of .zshrc with setopt globdots in its place really is different" \
  cmp -s "$ZSHRC" "$set_dots/.zshrc"
assert "...and in that copy * matches .env and .git, so the test can fail" \
  [ "$(glob_in "$set_dots")" = ".env .git README src" ]

if [ -z "$python_bin" ]; then
  printf '  \033[33mSKIP\033[0m  %s\n' "no python3, so nothing can drive zle on a pseudo-terminal to press Tab"
else
  comp_home="$(rc_home complete <"$ZSHRC")"
  offered="$(complete_in "$comp_home" "$DOTS" 'cat ')"
  assert "Tab after 'cat ' offers the files (guards a vacuous capture)" \
    contains "$offered" " README "
  assert "...and the dotfiles too" contains "$offered" " .env "
  no_comp_dots="$(sed '/^_comp_options+=(globdots)$/d' "$ZSHRC" | rc_home no-comp-dots)"
  refute "a copy of .zshrc without the _comp_options line really is different" \
    cmp -s "$ZSHRC" "$no_comp_dots/.zshrc"
  offered="$(complete_in "$no_comp_dots" "$DOTS" 'cat ')"
  assert "...where Tab still offers the files" contains "$offered" " README "
  refute "...but not the dotfiles, so the test can fail" contains "$offered" " .env "
fi

echo
echo "== no prompt runs a starship to draw an empty right prompt =="
# starship's init sets RPROMPT to a second `starship prompt --right`, run before
# every prompt. starship.toml has no right_format, so .zshrc clears RPROMPT
# after the init, and checks/repo.sh keeps the two files in step. What that
# cannot see is the installed starship: whether its right prompt really is
# empty with this config, and whether it sets RPROMPT once at init or again
# from a hook before every prompt, which would undo the clearing unseen.
if ! command -v starship >/dev/null 2>&1; then
  printf '  \033[33mSKIP\033[0m  %s\n' "starship is not installed"
else
  # By its full path: env -i leaves no PATH to find it on, and a starship that
  # never ran prints nothing, which is what the right prompt is expected to do.
  starship_bin="$(command -v starship)"
  star() { (cd "$TEST_TMP" && env -i HOME="$TEST_TMP" PATH=/usr/bin:/bin \
    STARSHIP_CONFIG="$REPO_ROOT/starship/.config/starship.toml" "$starship_bin" prompt "$@"); }
  assert "with this repo's starship.toml the left prompt draws something" \
    [ -n "$(star)" ]
  right="$(star --right)"
  rc=$?
  assert "...and the right prompt draws nothing, so clearing it loses nothing" \
    [ "$rc:$right" = "0:" ]
  # shellcheck disable=SC2016  # zsh code, expanded by zsh
  after_precmd='for f in $precmd_functions; do $f; done; print -r -- "[$RPROMPT]"'
  rp="$(in_rc "$real_home" zsh -i -c "$after_precmd" 2>/dev/null)"
  assert "RPROMPT is still empty after starship init and a prompt's precmd hooks" \
    [ "$rp" = "[]" ]

  # Inline negative control: without the line, RPROMPT is starship's.
  no_clear="$(sed "/^[[:space:]]*RPROMPT=''\$/d" "$ZSHRC" | rc_home no-rprompt-clear)"
  refute "a copy of .zshrc that does not clear RPROMPT really is different" \
    cmp -s "$ZSHRC" "$no_clear/.zshrc"
  rp="$(in_rc "$no_clear" zsh -i -c "$after_precmd" 2>/dev/null)"
  assert "...and in that copy RPROMPT runs starship prompt --right, so the test can fail" \
    contains "$rp" "prompt --right"
fi

echo
echo "== a missing ~/.zshrc.local must not poison \$? =="
# It is the last statement in the file, so with `[[ -f x ]] && source x` and no
# override present the exit status is 1 and starship draws its error character
# before you have run a single command.
# shellcheck disable=SC2016  # a regex matching literal $HOME in the file text
assert "the override is sourced from an if, not a && chain" \
  grep -qE '^[[:space:]]*if \[\[ -f "\$HOME/\.zshrc\.local" \]\]' "$ZSHRC"
rc="$(zsh -f -c 'if [[ -f /definitely/not/here ]]; then :; fi; print -r -- $?')"
assert "so the shell starts with a clean status" [ "${rc:-1}" -eq 0 ]

finish
