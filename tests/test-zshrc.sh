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
  nested() { # $1 = the typeset -U line to run first
    env -i HOME="$TEST_TMP" "$clean" MANPATH=/a:/b zsh -f -c \
      "$1; source $BLOCK; zsh -f -c '$1; source $BLOCK; $dump'"
  }
  once="$(env -i HOME="$TEST_TMP" "$clean" MANPATH=/a:/b zsh -f -c "$preamble; source $BLOCK; $dump")"
  assert "a shell nested in one that ran the block ends up with the same environment" \
    [ "$once" = "$(nested "$preamble")" ]
  # And the negative control for that: without fpath in the typeset -U line,
  # the nested shell gains a second copy of brew's site-functions.
  refute "...which it does not without fpath in the typeset -U line" \
    [ "$once" = "$(nested "typeset -U path PATH")" ]
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
