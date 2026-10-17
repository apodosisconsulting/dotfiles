#!/usr/bin/env bash
# The keybindings in tmux.conf, exercised by PRESSING them.
#
# Verifying a binding by running its command sequence from the CLI is a
# different path, and that gap produced three wrong answers in this repo:
# send-keys appeared to do nothing (it writes to the pane, not the client), a
# CLI run-shell resolved #{session_name} to a session it had not targeted and
# nearly produced a false bug report about prefix+Q, and the messaging test fell
# back to a stubbed tmux because no client could be attached.
#
# The bindings are loaded from the REAL tmux.conf, with tpm stripped. Retyping
# them here would test a copy, and the copy is what drifts.
#
# Private socket, scratch resurrect dir, fake project dirs. Never the live
# server.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Declared slow: tens of seconds, because it drives a real terminal, editor or
# language server, or repeats an expensive command many times. `tests/run.sh
# --fast` skips these, and so does the pre-push hook; CI runs the complete set,
# so what the hook skips is caught on the way in rather than on the way out.
# Read by run.sh with grep, not by this shell.
# shellcheck disable=SC2034
SUITE_SLOW=1

CONF="$REPO_ROOT/tmux/.config/tmux/tmux.conf"
RDIR="$TEST_TMP/resurrect"
TEST_CONF="$TEST_TMP/tmux.conf"
MARKER_FILE="${TMPDIR:-/tmp}/tmux-resurrect-guard-$(id -u).pending"

# shellcheck disable=SC2034  # used by t(), press_keys() and the teardown
TMUX_SOCK="$(tmux_test_socket bindings)"
require_private_socket
cleanup_bindings() {
  rm -f "$MARKER_FILE"
  cleanup_tmux_suite
}
trap cleanup_bindings EXIT

mkdir -p "$RDIR" "$TEST_TMP/work"
rm -f "$MARKER_FILE"

# tpm removed: it clones plugins, and continuum would auto-save and auto-restore
# against whatever directory it found. Everything else in the file is real. The
# run line is matched with or without the -b tmux.conf gives it.
awk '
  /^if "test ! -d ~\/\.config\/tmux\/plugins\/tpm"/ { skip = 2; next }
  skip > 0 { skip--; next }
  /^run (-b )?.~\/\.config\/tmux\/plugins\/tpm\/tpm./ { next }
  { print }
' "$CONF" >"$TEST_CONF"

# And the strip has to have WORKED, which nothing else would notice. Adding -b
# to the run line was enough to stop the old pattern matching it: the line
# would have stayed in, and this suite would have loaded the real plugins
# against the real HOME -- the exact thing the strip exists to prevent. So stop
# before a server starts.
if grep -qE '^[[:space:]]*run(-shell)?[[:space:]].*tpm/tpm' "$TEST_CONF"; then
  no "tpm's run line survived the strip, so the test server would load the real plugins"
  finish
  exit 1
fi

# The system clipboard, shimmed. tmux.conf sends every copy-mode copy to
# copy-command and prefix+] reads pbpaste, both by name -- and its
# set-environment -g PATH replaces the PATH tmux's jobs see outright, so a shim
# on this shell's PATH would never be found. build_server puts it back in front
# after sourcing. Without that, pressing y here would overwrite the clipboard of
# whoever ran the suite, and ] would paste it into a test pane.
CLIP_BIN="$TEST_TMP/clip-bin"
CLIP_FILE="$TEST_TMP/clipboard"
mkdir -p "$CLIP_BIN"
printf '#!/bin/sh\ncat >"%s"\n' "$CLIP_FILE" >"$CLIP_BIN/pbcopy"
printf '#!/bin/sh\ncat "%s" 2>/dev/null\n' "$CLIP_FILE" >"$CLIP_BIN/pbpaste"
chmod +x "$CLIP_BIN/pbcopy" "$CLIP_BIN/pbpaste"

# A server carrying the real bindings, pointed at scratch storage. $1 is
# another copy of the config, for a control that needs one changed.
build_server() {
  t kill-server 2>/dev/null
  sleep 0.4
  t -f /dev/null new-session -d -s work -c "$TEST_TMP/work" || return 1
  t source-file "${1:-$TEST_CONF}" || return 1
  t set-environment -g PATH "$CLIP_BIN:$(t show-environment -g PATH | cut -d= -f2-)" || return 1
  # After sourcing, so the bindings write here and not to the real save dir.
  t set -g @resurrect-dir "$RDIR"
  t set -g @continuum-save-interval 0 # no timer firing mid-test
  return 0
}

# Predicates, so assertions can wait for the thing to happen rather than sleep a
# number of seconds chosen on this laptop.
session_gone() { ! t has-session -t "=$1" 2>/dev/null; }
session_exists() { t has-session -t "=$1" 2>/dev/null; }
window_count_is() { [ "$(t list-windows -t "$1" 2>/dev/null | wc -l | tr -d ' ')" = "$2" ]; }
window_index_is() { [ "$(t display-message -p -t "$1" '#{window_index}' 2>/dev/null)" = "$2" ]; }
last_is_not() { [ "$(readlink "$RDIR/last" 2>/dev/null)" != "$1" ]; }
save_exists() { [ -e "$RDIR/last" ]; }

# tmux.conf invokes helper scripts by absolute path under ~/.local/bin, and the
# save bindings invoke tmux-resurrect. Neither exists on a machine where the
# dotfiles have not been stowed and tpm has not run — a CI runner, for instance.
# The bindings that need them are skipped there, by name, rather than failing for
# a reason that has nothing to do with the binding.
KILL_SESSION="$HOME/.local/bin/tmux-kill-session"
CLEAR_SCROLLBACK="$HOME/.local/bin/tmux-clear-scrollback"
RESURRECT_SAVE="$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh"

section_skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

build_server || skip_suite "could not start a test tmux server with the real config"

assert "the real bindings are loaded" \
  [ "$(t list-keys -T prefix 2>/dev/null | grep -cE ' (Q|q|s|M-s|BSpace|c|h|l) ')" -ge 7 ]

# ---------------------------------------------------------------- prefix+Q

echo
echo "== prefix+Q kills the session the CLIENT is attached to, and no other =="
if [ ! -x "$KILL_SESSION" ]; then
  section_skip "prefix+Q and prefix+q: $KILL_SESSION is not stowed"
else
  # The path that runs when you actually press it has never been executed by a
  # test. tmux-kill-session reads #{client_session}, which only has a value when a
  # client is attached — so this cannot be checked any other way.
  build_server
  t new-session -d -s keepme
  t new-session -d -s alsokeep
  press_keys work C-a Q
  assert "the attached session is gone" wait_until 20 session_gone work
  assert "an unrelated session survives" session_exists keepme
  assert "...and so does the other one" session_exists alsokeep

  echo
  echo "== ...and on the last session it creates a replacement first =="
  # Otherwise the client has nowhere to go and WezTerm closes with it.
  build_server
  n_before="$(t list-sessions | wc -l | tr -d ' ')"
  assert "there is exactly one session to start with" [ "$n_before" -eq 1 ]
  press_keys work C-a Q
  assert "the session was killed" wait_until 20 session_gone work
  assert "but a replacement exists, so the client has somewhere to go" \
    [ "$(t list-sessions 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]

  # ---------------------------------------------------------------- prefix+q

  echo
  echo "== prefix+q kills a window when there is more than one =="
  build_server
  t new-window -t work -n second
  t new-window -t work -n third
  w_before="$(t list-windows -t work | wc -l | tr -d ' ')"
  # confirm-before puts up a "(y/n)" prompt; y answers it.
  press_keys work C-a q y
  assert "one window was killed" wait_until 20 window_count_is work "$((w_before - 1))"
  assert "the session is still there" session_exists work

  echo
  echo "== ...and falls through to kill-session on the last window =="
  build_server
  t new-session -d -s bystander
  press_keys work C-a q y
  assert "the single-window session was killed rather than emptied" wait_until 20 session_gone work
  assert "the bystander session is untouched" session_exists bystander
fi

# ---------------------------------------------------------------- prefix+s

echo
echo "== prefix+s saves, and says so truthfully =="
if [ ! -x "$RESURRECT_SAVE" ]; then
  section_skip "prefix+s and prefix+M-s: tmux-resurrect is not installed"
else
  build_server
  t new-window -t work -n two
  t new-window -t work -n three
  screen="$(press_keys_until work "saved" C-a s)"
  assert "a save was written" wait_until 20 save_exists
  saved="$(readlink "$RDIR/last")"
  assert "the status line reports the save" contains "$screen" "saved"
  refute "and does not claim a refusal" contains "$screen" "refused"

  echo
  echo "== ...and when the guard vetoes, it says THAT, not 'saved' =="
  # The bug this binding was rewritten for: it used to print "Session saved"
  # unconditionally, on top of the guard's veto notice, telling you the opposite
  # of what happened.
  for w in $(t list-windows -t work -F '#{window_index}' | tail -n +2); do
    t kill-window -t "work:$w"
  done
  sleep 0.5
  screen="$(press_keys_until work "refused" C-a s)"
  assert "'last' did not move — the throwaway state was refused" \
    [ "$(readlink "$RDIR/last")" = "$saved" ]
  assert "the status line says it was refused" contains "$screen" "refused"
  refute "and does NOT claim the session was saved" contains "$screen" "saved —"

  echo
  echo "== prefix+M-s forces past the guard =="
  press_keys work C-a M-s
  assert "the forced save moved 'last'" wait_until 25 last_is_not "$saved"
  assert "the force flag cleared itself" [ -z "$(t show-option -gqv @resurrect-guard-force)" ]
fi

# ---------------------------------------------------------------- prefix+M-r

echo
echo "== prefix+M-r restores, in both encodings a terminal sends it =="
# Restore was on C-S-r, which WezTerm's own key table keeps for
# ReloadConfiguration, so pressing it there never reached tmux. tmux.conf
# moved it to M-r. resurrect binds that key itself, reading @resurrect-restore,
# so its .tmux file is run against this server after the config, as tpm would
# run it. What it restores is a synthetic save in the scratch dir, holding a
# session nothing else here creates.
#
# Both encodings, because which one arrives depends on the terminal: ESC r
# from one that sends Meta as an ESC prefix, CSI 27;3;114~ from one that tmux
# has put in modifyOtherKeys mode. The control is the same press on a server
# whose config still says C-S-r, which must restore nothing, so it is the
# binding tmux.conf asks for that restores and not something else.
RESURRECT_TMUX="$HOME/.config/tmux/plugins/tmux-resurrect/resurrect.tmux"
CSI_M_R="$(printf '\033[27;3;114~')"
restore_server() { # $1 = config to load; leaves a save of session sess1 as last
  build_server "$1" || return 1
  t run-shell "$RESURRECT_TMUX" || return 1
  t set -g @resurrect-dir "$RDIR"
  rm -f "$RDIR"/tmux_resurrect_*.txt "$RDIR/last"
  make_save "$RDIR/tmux_resurrect_20260101T000000.txt" 2 1
  ln -s tmux_resurrect_20260101T000000.txt "$RDIR/last"
}
if [ ! -x "$RESURRECT_TMUX" ]; then
  section_skip "prefix+M-r: tmux-resurrect is not installed"
else
  for enc in ESC-r CSI; do
    key="M-r"
    [ "$enc" = CSI ] && key="$CSI_M_R"
    restore_server "$TEST_CONF"
    refute "($enc) the session in the save does not exist yet (guards a vacuous test)" \
      session_exists sess1
    assert "($enc) resurrect bound restore to tmux.conf's M-r" \
      contains "$(t list-keys -T prefix M-r 2>/dev/null)" "restore.sh"
    press_keys work C-a "$key"
    assert "($enc) prefix then M-r restores the saved session" wait_until 20 session_exists sess1
  done

  sed "s/^set -g @resurrect-restore 'M-r'$/set -g @resurrect-restore 'C-S-r'/" \
    "$TEST_CONF" >"$TEST_TMP/restore-c-s-r.conf"
  refute "a copy of the config with restore on C-S-r really is different" \
    cmp -s "$TEST_CONF" "$TEST_TMP/restore-c-s-r.conf"
  restore_server "$TEST_TMP/restore-c-s-r.conf"
  press_keys work C-a M-r
  refute "...and on a server loading it, prefix then M-r restores nothing, so the test can fail" \
    wait_until 5 session_exists sess1
fi

# ---------------------------------------------------------------- prefix+BSpace

echo
echo "== prefix+BSpace does not type into whatever owns the pane =="
if [ ! -x "$CLEAR_SCROLLBACK" ]; then
  section_skip "prefix+BSpace: $CLEAR_SCROLLBACK is not stowed"
else
  build_server
  VICTIM="$TEST_TMP/victim.txt"
  printf 'hello world\nsecond line\n' >"$VICTIM"
  cp "$VICTIM" "$TEST_TMP/expected.txt"
  t send-keys -t work "vi $VICTIM" Enter
  sleep 2
  assert "an editor really is running (guards against a vacuous test)" \
    contains "$(t display-message -p '#{pane_current_command}')" vi
  press_keys work C-a BSpace
  t send-keys -t work Escape ':q!' Enter
  # Wait for the editor to actually exit, so the file on disk is settled before it
  # is compared. Quitting is asynchronous; comparing too early would read the file
  # while vi still held it.
  editor_gone() { ! contains "$(t display-message -p '#{pane_current_command}' 2>/dev/null)" vi; }
  assert "the editor exited" wait_until 20 editor_gone
  assert "the editor's buffer is untouched" cmp -s "$VICTIM" "$TEST_TMP/expected.txt"
fi

# ---------------------------------------------------------------- navigation

echo
echo "== window and session navigation =="
build_server
press_keys work C-a c
assert "prefix+c opens a window" wait_until 20 window_count_is work 2
# pane_current_path is the resolved path: on macOS /tmp is a symlink to
# /private/tmp, so comparing against the string passed to -c fails for the wrong
# reason.
assert "...in the current pane's directory" \
  [ "$(t display-message -p -t work '#{pane_current_path}')" = "$(cd "$TEST_TMP/work" && pwd -P)" ]

build_server
t new-window -t work
t new-window -t work
# The session exists before the config is sourced, so base-index 1 never applies
# to it and the windows start at 0. Ask rather than assume.
last_idx="$(t list-windows -t work -F '#{window_index}' | tail -1)"
prev_idx="$(t list-windows -t work -F '#{window_index}' | tail -2 | head -1)"
t select-window -t "work:$last_idx"
press_keys work C-a h
assert "prefix+h goes to the previous window" wait_until 20 window_index_is work "$prev_idx"
press_keys work C-a l
assert "prefix+l goes to the next window" wait_until 20 window_index_is work "$last_idx"

build_server
t new-window -t work
first_idx="$(t list-windows -t work -F '#{window_index}' | head -1)"
next_idx="$(t list-windows -t work -F '#{window_index}' | sed -n 2p)"
t select-window -t "work:$first_idx"
press_keys work C-a L
assert "prefix+L swaps the window rightwards and follows it" \
  wait_until 20 window_index_is work "$next_idx"

# switch-client moves the CLIENT, so #{client_session} is empty again the moment
# the helper detaches — querying it afterwards says nothing. The status line is
# the honest place to look: tmux.conf renders "#S" in status-left, so the
# session's name is on screen. Distinctive names, so a match cannot come from
# anywhere else on the line.
build_server
t rename-session -t work sessone
t new-session -d -s sesstwo
screen="$(press_keys_until sessone "sesstwo" C-a j)"
assert "prefix+j switches to the other session" contains "$screen" "sesstwo"

screen="$(press_keys_until sesstwo "sessone" C-a k)"
assert "prefix+k switches back" contains "$screen" "sessone"

# ---------------------------------------------------------------- clipboard

echo
echo "== copy-mode y copies to the system clipboard, and prefix+] pastes from it =="
# y is the one copy binding tmux.conf declares. Enter and the mouse are tmux's
# own bindings and reach pbcopy through the same copy-command, which is why the
# config sets copy-command rather than giving y a command of its own.
#
# The shims are checked before anything is pressed: if a tmux job resolved the
# real pbcopy, pressing y would overwrite the clipboard of whoever ran this.
#
# The pane prints the word to copy and then hands its input to cat, which writes
# what is pasted into it to a file -- so what ] pasted is read from there rather
# than scraped off a screen. The pane's terminal is in line mode, so cat only
# receives a line once it ends: the clipboard text below ends in a newline for
# that reason, and anything pasted before it without one arrives in front of it,
# in the same line, which is how a stray paste of tmux's buffer would show.
clipboard_is() { [ "$(cat "$CLIP_FILE" 2>/dev/null)" = "$1" ]; }
pasted_has() { contains "$(cat "$TEST_TMP/pasted" 2>/dev/null)" "$1"; }
pane_shows() { contains "$(t capture-pane -p -t clip 2>/dev/null)" "$1"; }

build_server
t new-session -d -s clip -c "$TEST_TMP/work" \
  "printf 'COPYME please\n'; exec cat >'$TEST_TMP/pasted'"
t run-shell "command -v pbcopy >'$TEST_TMP/resolved'; command -v pbpaste >>'$TEST_TMP/resolved'"
if [ "$(tr '\n' ' ' <"$TEST_TMP/resolved" 2>/dev/null)" = "$CLIP_BIN/pbcopy $CLIP_BIN/pbpaste " ]; then
  ok "tmux's jobs resolve pbcopy and pbpaste to this suite's shims"
  assert "the pane shows the word to copy (guards a vacuous test)" wait_until 20 pane_shows COPYME

  printf 'untouched' >"$CLIP_FILE"
  # [ into copy mode, g to the top, 0 to column 0, v to start selecting, e to
  # the end of the word, y to copy it.
  press_keys clip C-a '[' g 0 v e y
  assert "copy-mode y puts the selection on the system clipboard" \
    wait_until 10 clipboard_is "COPYME"

  # The y above left COPYME as tmux's newest buffer, which is exactly what
  # tmux's default ] would paste. With the clipboard empty, ] must paste
  # nothing at all -- not fall back to that buffer.
  : >"$CLIP_FILE"
  press_keys clip C-a ']'
  printf 'from another app\n' >"$CLIP_FILE"
  press_keys clip C-a ']'
  assert "prefix+] pastes the system clipboard" \
    wait_until 10 pasted_has "from another app"
  # Read only after the second paste has landed. Had the empty-clipboard ]
  # pasted tmux's buffer, that COPYME -- no newline of its own -- would be the
  # start of the same line cat has just written.
  refute "...and with the clipboard empty it pasted nothing, not tmux's newest buffer" \
    pasted_has "COPYME"
  refute "...and leaves no 'system' buffer behind" quietly t show-buffer -b system
else
  no "tmux's jobs did not resolve pbcopy/pbpaste to the shims; y and ] were NOT pressed"
fi

# ---------------------------------------------------------------- reload

echo
echo "== loading tmux.conf again does not lengthen terminal-features =="
# prefix S sources the whole file again, and terminal-features is a list that
# `set -sa` appends to. tmux.conf resets it first; without that, every reload
# added another copy. Loaded here from the stripped copy rather than by pressing
# S, which sources the REAL file and tpm with it (see S in the list below).
#
# The control proves the count can see growth at all: the same copy with the
# reset taken out has to get longer, or a length that stayed put would mean
# nothing.
features_count() { t show -sv terminal-features 2>/dev/null | wc -l | tr -d ' '; }
build_server
assert "the list carries tmux.conf's own entry (guards a vacuous count)" \
  contains "$(t show -sv terminal-features 2>/dev/null)" "hyperlinks"
n_before="$(features_count)"
t source-file "$TEST_CONF"
t source-file "$TEST_CONF"
n_after="$(features_count)"
assert "two more loads leave it the same length ($n_before entries)" \
  [ "${n_after:-0}" -eq "${n_before:--1}" ]
grep -v '^set -su terminal-features$' "$TEST_CONF" >"$TEST_TMP/no-reset.conf"
t source-file "$TEST_TMP/no-reset.conf"
t source-file "$TEST_TMP/no-reset.conf"
assert "...while without the reset the same two loads lengthen it, so the count can see growth" \
  [ "$(features_count)" -gt "${n_after:-0}" ]

# ---------------------------------------------------------------- coverage

echo
echo "== every binding is either pressed here or explained =="
# NOT DRIVEN, and why. Each of these needs sustained interaction with a UI whose
# output would have to be scraped from the client's screen, and a scraper racing
# a redraw is exactly the flaky test that teaches people to re-run rather than
# read.
#
#   prefix+w   choose-tree: a full-screen chooser
#   prefix+r   command-prompt: rename-window, needs typed input then Enter
#   prefix+R   command-prompt: rename-session, same
#   prefix+C   new-session: leaves the client on a new session mid-suite
#   prefix+f   display-popup running the fzf sessionizer
#   prefix+S   source-file: re-sources the config under the suite's feet
#   prefix+H   mirror of L, which is covered
#   prefix+C-a send-prefix: only observable by a program reading the pane
undriven="w r R C f S H C-a"
driven="Q q s M-s BSpace c h l L j k v y ]"
# That these two lists between them cover every key tmux.conf binds is asserted
# in checks/repo.sh, which reads them out of here and compares the SETS. It was
# asserted here and compared the COUNTS — eleven plus ten against twenty-one
# `bind` lines — and a count cannot tell `bind w` being renamed to `bind W` from
# nothing having happened. It is a fact about two files, so it belongs in a
# check that runs on every commit rather than in a suite that needs a terminal.
printf '    %s pressed here, %s documented as not driven (checks/repo.sh asserts that is all of them)\n' \
  "$(printf '%s' "$driven" | wc -w | tr -d ' ')" \
  "$(printf '%s' "$undriven" | wc -w | tr -d ' ')"

finish
