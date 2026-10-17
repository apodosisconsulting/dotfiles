#!/usr/bin/env bash
# check.sh itself.
#
# MUTATION TESTS, not smoke tests. For each assertion: introduce the defect it
# claims to catch, and prove the assertion FAILS. Watching check.sh pass proves
# nothing — it has already passed while asserting the opposite of the truth,
# reporting a colour scheme that was present as missing, because
# `strings | grep -q` under pipefail reports failure on a match. A check that
# silently stops checking is the thing this repo exists to prevent.
#
# Everything runs against a COPY of the repo. check.sh reads the working tree it
# lives in, so mutating the real one would be both destructive and useless.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Declared slow: tens of seconds, because it drives a real terminal, editor or
# language server, or repeats an expensive command many times. `tests/run.sh
# --fast` skips these, and so does the pre-push hook; CI runs the complete set,
# so what the hook skips is caught on the way in rather than on the way out.
# Read by run.sh with grep, not by this shell.
# shellcheck disable=SC2034
SUITE_SLOW=1

WORK="$TEST_TMP/repo"

# A pristine copy, remade before every mutation so they cannot interact.
reset_repo() {
  rm -rf "$WORK"
  mkdir -p "$WORK"
  # Tracked files, at their WORKING-TREE content — not `git archive HEAD`, which
  # exports the last commit. As a pre-commit hook this suite must judge what is
  # about to be committed; testing HEAD would have quietly tested stale code
  # forever, and did: two fixes to check.sh appeared to change nothing.
  (cd "$REPO_ROOT" && git ls-files -z | tar -c --null -T - -f -) | tar -x -C "$WORK"
  # check.sh runs git commands against the tree it is in.
  (
    cd "$WORK" || exit 1
    git init -q -b main .
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m copy
    git config core.hooksPath .githooks
  )
}

# Two modes, because check.sh has two halves. The repo half holds on any machine
# and is what CI exercises; the machine half needs WezTerm, fonts, a stow tree
# and a git identity, so on a runner its baseline cannot pass and a mutation
# against it would prove nothing.
run_check() { (cd "$WORK" && ./check.sh --repo-only 2>&1); }
run_check_full() { (cd "$WORK" && ./check.sh 2>&1); }

# The core of this suite: a mutation must turn a specific ✓ into a ✗.
# Passing `check.sh` output is not evidence; a mutation that does NOT break it is.
mutate() { # $1=description  $2=marker text of the assertion  $3...=command to apply the mutation
  local desc="$1" marker="$2"
  shift 2
  _mutate repo "$desc" "$marker" "" "$@"
}

# Same, but for an assertion that lives in checks/machine.sh.
mutate_machine() {
  local desc="$1" marker="$2"
  shift 2
  _mutate machine "$desc" "$marker" "" "$@"
}

# For a mutation that ADDS a failing item to a list rather than turning one of
# the list's existing passes red.
#
# The default verdict is "fewer passing lines carry the marker than before",
# which needs nothing written twice and no call site changed. It cannot see an
# additive defect: appending `.PHONY: ghost` to the Makefile leaves all 13
# "make X has a recipe" lines green and adds a fourteenth entry that fails, so
# the count is 13 both times while the assertion did exactly its job. One
# mutation here is that shape, so it — and only it — names the failure text.
mutate_adds() { # $1=description  $2=marker  $3=failure text  $4...=command
  local desc="$1" marker="$2" failtext="$3"
  shift 3
  _mutate repo "$desc" "$marker" "$failtext" "$@"
}

# How many PASSING lines carry an assertion's marker. The marker names an
# assertion that is green in the baseline, so this is the number that has to go
# DOWN once the defect is introduced.
#
# A count rather than a presence test, because two markers are deliberately
# shared: "has a recipe" is one assertion per make target, and "runs exactly
# what" covers both git hooks. Breaking one recipe leaves the others green, so
# "is the marker still on a passing line" would report a working assertion as
# broken. Counting says 13 became 12, which is the claim actually being made.
green_hits() { # $1 = check.sh output, $2 = marker
  local n
  n="$(printf '%s\n' "$1" | grep '✓' | grep -cF -- "$2" || true)"
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Everything a mutation could plausibly change, as one string. Two mutations
# change only git config — core.hooksPath and user.email — and would be
# invisible to `git status` on its own, so the local config is part of the
# state.
work_state() {
  (
    cd "$WORK" || return 0
    git status --porcelain
    git config --local --list
  ) 2>/dev/null
}

_mutate() { # $1=repo|machine  $2=desc  $3=marker  $4=failure text or ""  $5...=mutation
  local mode="$1" desc="$2" marker="$3" failtext="$4"
  shift 4
  reset_repo
  local before after
  if [ "$mode" = machine ]; then
    before="$(run_check_full)"
  else
    before="$(run_check)"
  fi
  # The marker's absence means different things for the two halves. A machine
  # assertion is simply not present on a box without WezTerm, a stow tree or a
  # git identity — a CI runner, for instance — and skipping is honest. A REPO
  # assertion holds everywhere, so if its marker is gone it has been renamed or
  # deleted and the mutation would pass vacuously.
  local before_hits
  before_hits="$(green_hits "$before" "$marker")"
  if [ "$before_hits" -eq 0 ]; then
    if [ "$mode" = machine ]; then
      printf '  \033[33mSKIP\033[0m  %s (not asserted on this machine)\n' "$desc"
    else
      no "$desc — no passing line carries '$marker' (renamed, or already failing)"
    fi
    return
  fi
  # Prove the mutation did something. The command runs with its output
  # discarded, so a sed whose pattern has stopped matching applies no defect at
  # all and the verdict below would be judging an unmutated copy. Not
  # hypothetical: prettier padded the README's table cells, a sed written with
  # single spaces then matched nothing, and this suite reported that check.sh
  # had failed to catch a defect nobody had introduced.
  local state_before state_after
  state_before="$(work_state)"
  (cd "$WORK" && "$@") >/dev/null 2>&1
  state_after="$(work_state)"
  if [ "$state_before" = "$state_after" ]; then
    no "$desc — the mutation changed nothing, so nothing was tested"
    return
  fi
  if [ "$mode" = machine ]; then
    after="$(run_check_full)"
  else
    after="$(run_check)"
  fi
  # The assertion this mutation NAMES must have stopped passing.
  #
  # Looking for the failure glyph anywhere, which is what this did, accepts any
  # failure at all — so a mutation whose own check has gone blind still reported
  # PASS whenever something else tripped on the same defect. Demonstrated rather
  # than supposed: blank the deprecated= regex in checks/repo.sh and "a
  # deprecated Neovim API is caught" stayed green, because appending after a
  # top-level `return {` is also a lua syntax error and the parse check fired in
  # its place.
  #
  # Neither obvious fix was needed. Requiring the marker on the failure line
  # only works where the passing and failing wordings share it, which is 12 of
  # 59; giving every call a second failure marker means editing every call site
  # and leaves the two strings free to drift apart. The marker already names an
  # assertion that is GREEN in the baseline, so the question needing no new
  # information is whether it is still green now.
  local after_hits red
  after_hits="$(green_hits "$after" "$marker")"
  red="$(printf '%s\n' "$after" | grep '✗' || true)"
  if [ -n "$failtext" ]; then
    if contains "$red" "$failtext"; then
      ok "$desc"
    else
      no "$desc — nothing failed with '$failtext', so the assertion it names never fired"
    fi
  elif [ "$after_hits" -ge "$before_hits" ]; then
    no "$desc — '$marker' still passes ($after_hits of $before_hits), so the assertion it names never fired"
  elif [ -n "$red" ]; then
    ok "$desc"
  else
    no "$desc — '$marker' stopped passing but nothing reported a failure"
  fi
}

echo "== baseline =="
reset_repo
base="$(run_check)"
assert "a pristine copy passes the repository checks" contains "$base" "0 failure(s)"
refute "and reports no failures" contains "$base" "✗"
# Not asserted for the machine half: on a CI runner it cannot pass, and a
# baseline assertion that only holds on one laptop is not worth having.
if contains "$(run_check_full)" "0 failure(s)"; then
  ok "a pristine copy passes the machine checks too"
else
  printf '  \033[33mSKIP\033[0m  machine checks do not pass here — machine mutations will skip\n'
fi

echo
echo "== each assertion must actually fire =="

mutate_machine "a wrong wezterm colour scheme is caught" "colour scheme" \
  sed -i '' 's/color_scheme = "rose-pine-moon"/color_scheme = "Not A Real Scheme"/' wezterm/.config/wezterm/wezterm.lua

mutate "a missing usstyle is caught" "usstyle" \
  sed -i '' 's/:RGB:usstyle/:RGB/' tmux/.config/tmux/tmux.conf

# Declared, then thrown away: the line split in two with a reset between the
# halves. usstyle and extkeys are still written in the file, and sync,
# hyperlinks and overline come back after the reset, so only a check that reads
# what tmux ends up with can tell. Used again for extkeys below.
split_terminal_features() {
  sed -i '' 's/:RGB:usstyle:extkeys:sync:hyperlinks:overline"$/:RGB:usstyle:extkeys"\
set -su terminal-features\
set -sa terminal-features ",*:RGB:sync:hyperlinks:overline"/' tmux/.config/tmux/tmux.conf
}
mutate "usstyle declared and then reset away is caught" "usstyle" \
  split_terminal_features

# The defect this exists for: an append with no reset before it, so every
# prefix S adds another copy to the list.
mutate "terminal-features appended to with no reset is caught" "reset before it is appended to" \
  sed -i '' '/^set -su terminal-features$/d' tmux/.config/tmux/tmux.conf

mutate "a missing sync feature is caught" "declares sync, hyperlinks and overline" \
  sed -i '' '/^set -sa terminal-features/s/:sync//' tmux/.config/tmux/tmux.conf

mutate "a missing hyperlinks feature is caught" "declares sync, hyperlinks and overline" \
  sed -i '' '/^set -sa terminal-features/s/:hyperlinks//' tmux/.config/tmux/tmux.conf

mutate "a missing overline feature is caught" "declares sync, hyperlinks and overline" \
  sed -i '' '/^set -sa terminal-features/s/:overline//' tmux/.config/tmux/tmux.conf

# Last write wins: a reset further down throws away every append above it.
mutate "a later reset that discards the declared features is caught" "declares sync, hyperlinks and overline" \
  bash -c "printf '\nset -su terminal-features\n' >> tmux/.config/tmux/tmux.conf"

# The defect this exists for: restore back on the key a held Ctrl reaches.
mutate "restore left on resurrect's C-r default is caught" "restore is bound to" \
  sed -i '' "s/^set -g @resurrect-restore 'M-r'$/set -g @resurrect-restore 'C-r'/" tmux/.config/tmux/tmux.conf

# Restore is M-r, which needs no extended keys, so each of these first puts it
# back on C-S-r, the Shift-bearing key it was on: the requirement they break is
# one only that kind of key has.
restore_on_c_s_r() {
  sed -i '' "s/^set -g @resurrect-restore 'M-r'$/set -g @resurrect-restore 'C-S-r'/" tmux/.config/tmux/tmux.conf
}
c_s_r_without_extended_keys() {
  restore_on_c_s_r && sed -i '' '/^set -s extended-keys on$/d' tmux/.config/tmux/tmux.conf
}
c_s_r_without_extkeys() {
  restore_on_c_s_r && sed -i '' 's/:RGB:usstyle:extkeys/:RGB:usstyle/' tmux/.config/tmux/tmux.conf
}
c_s_r_with_extkeys_reset() { restore_on_c_s_r && split_terminal_features; }
c_s_r_with_extended_keys_off_later() {
  restore_on_c_s_r && printf '\nset -s extended-keys off\n' >>tmux/.config/tmux/tmux.conf
}

# Reads correct, cannot be pressed: C-S-r without extended-keys is just C-r.
mutate "a Shift-bearing restore key without extended-keys is caught" "restore is bound to" \
  c_s_r_without_extended_keys

mutate "a Shift-bearing restore key without the extkeys feature is caught" "restore is bound to" \
  c_s_r_without_extkeys

mutate "extkeys declared and then reset away is caught" "restore is bound to" \
  c_s_r_with_extkeys_reset

# Last write wins: a later extended-keys off is the value tmux applies.
mutate "a later extended-keys off is caught" "restore is bound to" \
  c_s_r_with_extended_keys_off_later

mutate "no @resurrect-restore at all fails rather than passing vacuously" "restore is bound to" \
  sed -i '' '/^set -g @resurrect-restore/d' tmux/.config/tmux/tmux.conf

# The defect the move to M-r fixed: restore on C-S-r, which WezTerm's own key
# table maps to ReloadConfiguration, so the key never reached tmux.
mutate_machine "restore back on a key WezTerm keeps for itself is caught" "so it reaches tmux" \
  restore_on_c_s_r

# The table read is the one with wezterm.lua loaded, so a key it assigns
# counts as much as one of WezTerm's defaults.
mutate_machine "a wezterm.lua key on the restore key is caught" "so it reaches tmux" \
  python3 -c 'p = "wezterm/.config/wezterm/wezterm.lua"; s = open(p).read()
k = "    keys = {\n"
open(p, "w").write(s.replace(k, k + "        { key = \"r\", mods = \"OPT\", action = wezterm.action.ReloadConfiguration },\n", 1))'

mutate_machine "a restore key machine.sh cannot read fails rather than passing vacuously" "so it reaches tmux" \
  sed -i '' "s/^set -g @resurrect-restore 'M-r'$/set -g @resurrect-restore \"M-r\"/" tmux/.config/tmux/tmux.conf

# A reader gone blind to WezTerm's table, which is what a change to show-keys'
# headings would do, reads no rows and has to fail rather than find no key.
mutate_machine "no rows read out of WezTerm's key table fails rather than passing vacuously" "so it reaches tmux" \
  sed -i '' 's|/^Default key table/|/^No such heading/|' checks/machine.sh

# The defect this exists for: Enter and a mouse drag copying into tmux's own
# buffer, which is a second clipboard.
mutate "no copy-command, so a tmux copy stays in tmux, is caught" "tmux copies to and pastes from" \
  sed -i '' '/^set -s copy-command/d' tmux/.config/tmux/tmux.conf

mutate "a copy-command other than pbcopy is caught" "tmux copies to and pastes from" \
  sed -i '' "s/^set -s copy-command 'pbcopy'$/set -s copy-command 'cat'/" tmux/.config/tmux/tmux.conf

# A command after copy-pipe-and-cancel overrides copy-command for that key.
mutate "a y binding with its own pipe command is caught" "tmux copies to and pastes from" \
  sed -i '' 's/^bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel$/bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "cat >\/dev\/null"/' tmux/.config/tmux/tmux.conf

mutate "prefix ] left on tmux's own buffer is caught" "tmux copies to and pastes from" \
  sed -i '' '/^bind \] /d' tmux/.config/tmux/tmux.conf

# Last write wins in tmux.conf too: a later override is the one tmux applies.
mutate "a later copy-command overriding pbcopy is caught" "tmux copies to and pastes from" \
  bash -c "printf '\nset -s copy-command '\''cat'\''\n' >> tmux/.config/tmux/tmux.conf"

mutate "a later y rebinding with its own command is caught" "tmux copies to and pastes from" \
  bash -c "printf '\nbind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel \"cat\"\n' >> tmux/.config/tmux/tmux.conf"

mutate "a prefix ] that never reads pbpaste is caught" "tmux copies to and pastes from" \
  sed -i '' 's/^bind \] run-shell "pbpaste | /bind ] run-shell "cat \/dev\/null | /' tmux/.config/tmux/tmux.conf

# The defect this exists for: status-right set after tpm runs, overwriting
# continuum's #(), so auto-save stops without a word.
mutate "status-right moved below the tpm run line is caught" "status-right is set before tpm runs" \
  bash -c "sed -i '' '/^set -g status-right /d' tmux/.config/tmux/tmux.conf && printf '\nset -g status-right \"x\"\n' >> tmux/.config/tmux/tmux.conf"

# The last write wins, so a second status-right below tpm does the damage even
# while the first still sits above it.
mutate "a second status-right below the tpm run line is caught" "status-right is set before tpm runs" \
  bash -c "printf '\nset -g status-right \"x\"\n' >> tmux/.config/tmux/tmux.conf"

mutate "no status-right to read fails rather than passing vacuously" "status-right is set before tpm runs" \
  sed -i '' '/^set -g status-right /d' tmux/.config/tmux/tmux.conf

# The defect this exists for: tpm back in the foreground, so every new server
# and every prefix S waits for all the plugins to load.
mutate "tpm run without -b is caught" "tpm loads in the background" \
  sed -i '' "s|^run -b '~/.config/tmux/plugins/tpm/tpm'$|run '~/.config/tmux/plugins/tpm/tpm'|" tmux/.config/tmux/tmux.conf

# tmux applies every run line, so one in the foreground is a wait however many
# backgrounded ones there are.
mutate "a second, foreground run of tpm is caught" "tpm loads in the background" \
  bash -c "printf '\nrun '\''~/.config/tmux/plugins/tpm/tpm'\''\n' >> tmux/.config/tmux/tmux.conf"

mutate "no tpm run line at all fails rather than passing vacuously" "tpm loads in the background" \
  sed -i '' '/^run -b .*plugins\/tpm\/tpm/d' tmux/.config/tmux/tmux.conf

mutate "an untracked lazy-lock.json is caught" "lazy-lock" \
  git rm -q --cached nvim/.config/nvim/lazy-lock.json

# Tracked but unreadable: lazy decodes it under pcall and carries on with no
# lock at all. A write cut off mid-entry is the shape this takes.
mutate "a lazy-lock.json that does not parse is caught" "parses the way lazy reads it" \
  bash -c 'head -c 200 nvim/.config/nvim/lazy-lock.json >lock.tmp && mv lock.tmp nvim/.config/nvim/lazy-lock.json'

mutate "a lazy-lock.json that parses and pins nothing is caught" "parses the way lazy reads it" \
  bash -c 'printf "{}\n" >nvim/.config/nvim/lazy-lock.json'

mutate "a lua syntax error is caught" "every lua file parses" \
  bash -c 'printf "\nthis is not lua((\n" >> nvim/.config/nvim/lua/rich/plugins/fidget.lua'

mutate "a deprecated Neovim API is caught" "deprecated" \
  bash -c 'printf "\nlocal _ = vim.lsp.get_active_clients\n" >> nvim/.config/nvim/lua/rich/plugins/fidget.lua'

mutate "a plugin file with no lazy spec is caught" "lazy spec" \
  sed -i '' 's/^return {/local _unused = {/' nvim/.config/nvim/lua/rich/plugins/fidget.lua

# The defect this exists for: 99 with no lazy trigger, which is how it loaded
# at every start. Renamed rather than deleted so the file still parses, and the
# only thing wrong is the one this assertion names.
mutate "99 with no lazy keys, so loading at every start, is caught" "99 waits for its keys" \
  sed -i '' 's/^    keys = {$/    _keys = {/' nvim/.config/nvim/lua/rich/plugins/99.lua

mutate "99 keys overridden by lazy = false are caught" "99 waits for its keys" \
  sed -i '' 's/^    config = function()$/    lazy = false, config = function()/' nvim/.config/nvim/lua/rich/plugins/99.lua

# The defect this exists for, replayed: a library in .luarc.json replaces the
# one lazydev sends, and vim.* loses its definitions.
# shellcheck disable=SC2016  # ${3rd} is lua_ls's placeholder, not the shell's
mutate "a .luarc.json that sets workspace.library again is caught" "leaves workspace.library to lazydev" \
  sed -i '' 's|"workspace.checkThirdParty": false,|"workspace.library": ["${3rd}/luv/library"], "workspace.checkThirdParty": false,|' nvim/.config/nvim/.luarc.json

# lua_ls reads the nested spelling, with a Lua. prefix, as the same key.
mutate "the same key spelled as nested objects is caught too" "leaves workspace.library to lazydev" \
  sed -i '' 's|"runtime.version": "LuaJIT"|"runtime.version": "LuaJIT", "Lua": {"workspace": {"library": []}}|' nvim/.config/nvim/.luarc.json

# The other half of the same defect: the key that hid it. Its own assertion,
# because it does its harm another way -- definitions resolve with it set.
mutate "a .luarc.json that silences undefined vim again is caught" "does not declare vim a global" \
  sed -i '' 's|"workspace.checkThirdParty": false,|"workspace.checkThirdParty": false, "diagnostics.globals": ["vim"],|' nvim/.config/nvim/.luarc.json

# Every entry of the list is read, not just the first, in the nested spelling
# too.
mutate "vim declared a global second in a nested list is caught too" "does not declare vim a global" \
  sed -i '' 's|"runtime.version": "LuaJIT"|"runtime.version": "LuaJIT", "Lua": {"diagnostics": {"globals": ["describe", "vim"]}}|' nvim/.config/nvim/.luarc.json

mutate "a missing .luarc.json fails rather than reading as one that sets nothing" "leaves workspace.library to lazydev" \
  rm nvim/.config/nvim/.luarc.json

# The defect this exists for, replayed: 0bdf224 flipped this line inside a
# commit about LSP errors, trailing space and all.
mutate "line wrap flipped off is caught" "line wrap is on" \
  sed -i '' 's/^vim\.opt\.wrap = true$/vim.opt.wrap = false /' nvim/.config/nvim/lua/rich/options.lua

# Set once and unset later: lua's last write wins, so reading options.lua alone
# would report this as fine.
mutate "wrap turned off again elsewhere in the lua config is caught" "line wrap is on" \
  bash -c 'printf "\nvim.wo.wrap = false\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

# The anti-vacuity guard: a value that cannot be read must fail, not compare
# equal to the nothing beside it.
mutate "an unreadable wrap setting fails rather than passing vacuously" "line wrap is on" \
  sed -i '' '/^vim\.opt\.wrap/d' nvim/.config/nvim/lua/rich/options.lua

mutate "a textwidth that is not 80 is caught" "textwidth is 80" \
  sed -i '' 's/^vim\.opt\.textwidth = 80$/vim.opt.textwidth = 100/' nvim/.config/nvim/lua/rich/options.lua

# The same last-write-wins shape as the wrap pair: set to 80 here, set to
# something else further along, and reading options.lua alone reports it fine.
mutate "textwidth set to something else elsewhere in the lua config is caught" "textwidth is 80" \
  bash -c 'printf "\nvim.opt_local.textwidth = 0\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "an unreadable textwidth fails rather than passing vacuously" "textwidth is 80" \
  sed -i '' '/^vim\.opt\.textwidth/d' nvim/.config/nvim/lua/rich/options.lua

# The defect this exists for: a yank that stays in a register only this nvim
# can see, so there are two clipboards again.
mutate "a clipboard that is not unnamedplus is caught" "nvim uses the system clipboard" \
  sed -i '' 's/^vim\.opt\.clipboard = "unnamedplus"$/vim.opt.clipboard = ""/' nvim/.config/nvim/lua/rich/options.lua

# Last write wins, as with wrap and textwidth.
mutate "the clipboard changed again elsewhere in the lua config is caught" "nvim uses the system clipboard" \
  bash -c 'printf "\nvim.opt.clipboard = \"\"\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "an unreadable clipboard setting fails rather than passing vacuously" "nvim uses the system clipboard" \
  sed -i '' '/^vim\.opt\.clipboard/d' nvim/.config/nvim/lua/rich/options.lua

# The defect this exists for, on each half of the pair: / case-sensitive again,
# or ignoring case even when the pattern has a capital.
mutate "a case-sensitive search is caught" "search ignores case unless the pattern has a capital" \
  sed -i '' 's/^vim\.opt\.ignorecase = true$/vim.opt.ignorecase = false/' nvim/.config/nvim/lua/rich/options.lua

mutate "a search that ignores even a capital is caught" "search ignores case unless the pattern has a capital" \
  sed -i '' 's/^vim\.opt\.smartcase = true$/vim.opt.smartcase = false/' nvim/.config/nvim/lua/rich/options.lua

# Last write wins, as with the options above: in lua, and as a :set under the
# short name.
mutate "ignorecase turned off again elsewhere in the lua config is caught" "search ignores case unless the pattern has a capital" \
  bash -c 'printf "\nvim.o.ignorecase = false\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "smartcase turned off by a :set noscs elsewhere is caught" "search ignores case unless the pattern has a capital" \
  bash -c 'printf "\nvim.cmd(\"set noscs\")\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "an unreadable smartcase setting fails rather than passing vacuously" "search ignores case unless the pattern has a capital" \
  sed -i '' '/^vim\.opt\.smartcase/d' nvim/.config/nvim/lua/rich/options.lua

# The defect this exists for: <leader>q and <leader>Q refusing again.
mutate "confirm turned off, so closing an unsaved buffer fails, is caught" "asks to save (confirm)" \
  sed -i '' 's/^vim\.opt\.confirm = true$/vim.opt.confirm = false/' nvim/.config/nvim/lua/rich/options.lua

# Last write wins, under the short name too.
mutate "confirm turned off by a :set nocf elsewhere is caught" "asks to save (confirm)" \
  bash -c 'printf "\nvim.cmd(\"set nocf\")\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "an unreadable confirm setting fails rather than passing vacuously" "asks to save (confirm)" \
  sed -i '' '/^vim\.opt\.confirm/d' nvim/.config/nvim/lua/rich/options.lua

# A server started and never installed: here it works, on a new machine it
# never attaches. Only the ensure_installed copy of the name goes.
mutate "a language server lsp.lua starts but Mason never installs is caught" "Mason installs every language server" \
  sed -i '' '/ensure_installed = {/,/}/{/"eslint",/d;}' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# The reverse: installed everywhere, and with automatic_enable off, never run.
mutate "a language server Mason installs but lsp.lua never starts is caught" "Mason installs every language server" \
  sed -i '' '/vim\.lsp\.enable({/,/})/{/"cssls",/d;}' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# Last write wins: a second call elsewhere can turn a listed server off.
mutate "a second vim.lsp.enable call elsewhere in the lua config is caught" "Mason installs every language server" \
  bash -c 'printf "\nvim.lsp.enable(\"cssls\", false)\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "an unreadable server list fails rather than passing vacuously" "Mason installs every language server" \
  sed -i '' 's/ensure_installed = {/ensure_installed_ = {/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# The defect this exists for: the key left out, so mason-lspconfig's default
# starts every server Mason has installed.
mutate "automatic_enable left to its default is caught" "only lsp.lua's enable list starts" \
  sed -i '' '/^[[:space:]]*automatic_enable = false,$/d' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# A table turns it on for the servers it names.
mutate "automatic_enable set to anything but false is caught" "only lsp.lua's enable list starts" \
  sed -i '' 's/automatic_enable = false,/automatic_enable = { "cssls" },/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# Last write wins: mason-lspconfig merges every setup() call into one.
mutate "automatic_enable turned back on elsewhere in the lua config is caught" "only lsp.lua's enable list starts" \
  bash -c 'printf "\nrequire(\"mason-lspconfig\").setup({ automatic_enable = true })\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "an unreadable mason-lspconfig setup fails rather than passing vacuously" "only lsp.lua's enable list starts" \
  sed -i '' 's/require("mason-lspconfig").setup({/require("mason-lspconfig").setup_({/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# The defect this exists for, replayed on each half: ]q back to a bare cnext,
# and ]d back to a hard-coded count of one.
mutate "a ]q that ignores its count is caught" "take a count" \
  sed -i '' "s/<cmd>exe v:count1 .. 'cnext'<cr>zz/<cmd>cnext<cr>zz/" nvim/.config/nvim/lua/rich/keymaps.lua

mutate "a ]d with a hard-coded count is caught" "take a count" \
  sed -i '' 's/count = vim\.v\.count1,/count = 1,/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# A trailing comment is not code, and must not lend the line its v:count1.
mutate "a count named only in a trailing comment is caught" "take a count" \
  sed -i '' "s/\"<cmd>exe v:count1 .. 'cprev'<cr>zz\",/\"<cmd>cprev<cr>zz\", -- v:count1/" nvim/.config/nvim/lua/rich/keymaps.lua

mutate "no diagnostic jump to read fails rather than passing vacuously" "take a count" \
  sed -i '' 's/vim\.diagnostic\.jump(/vim.diagnostic.goto(/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# The defect this exists for, replayed: Enter taking the first, unselected
# completion and swallowing the newline.
mutate "an Enter that accepts the first, unselected completion is caught" "Enter in the completion menu" \
  sed -i '' 's/\["<CR>"\] = cmp\.mapping\.confirm({ select = false })/["<CR>"] = cmp.mapping.confirm({ select = true })/' nvim/.config/nvim/lua/rich/plugins/cmp.lua

# A second mapping table replaces the key for its buffers, so the one in
# cmp.lua is not the whole story. Spelled the other way round on purpose:
# lower case, and cmp reached through require rather than a local.
mutate "Enter remapped to accept-first in a second cmp table is caught" "Enter in the completion menu" \
  bash -c 'printf "\nrequire(\"cmp\").setup.filetype(\"markdown\", { mapping = { [\"<cr>\"] = require(\"cmp\").mapping.confirm({ select = true }) } })\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

mutate "no Enter mapping to read fails rather than passing vacuously" "Enter in the completion menu" \
  sed -i '' '/\["<CR>"\] = cmp\.mapping/d' nvim/.config/nvim/lua/rich/plugins/cmp.lua

# The defect this exists for: gr back among lsp.lua's global keys.
mutate "a global gr in lsp.lua's keys is caught" "set per buffer when a server attaches" \
  sed -i '' 's/^\(        \){ "<leader>rn", vim\.lsp\.buf\.rename, desc = "Rename symbol" },$/&\
\1{ "gr", vim.lsp.buf.references, desc = "References" },/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

mutate "a gr that waits for Neovim's gr* maps is caught" "set per buffer when a server attaches" \
  sed -i '' 's/{ desc = "References", nowait = true }/{ desc = "References" }/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# A trailing comment is not code, and must not lend the line its nowait.
mutate "a nowait named only in a trailing comment is caught" "set per buffer when a server attaches" \
  sed -i '' 's/{ desc = "References", nowait = true })/{ desc = "References" }) -- nowait = true/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

mutate "no gr map to read fails rather than passing vacuously" "set per buffer when a server attaches" \
  sed -i '' 's/map("gr", vim\.lsp\.buf\.references,/map("gR", vim.lsp.buf.references,/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

mutate_machine "a tmux.conf path that does not exist is caught" "every path the configs hardcode" \
  sed -i '' 's|~/.local/bin/tmux-clear-scrollback|~/.local/bin/does-not-exist|' tmux/.config/tmux/tmux.conf

# The asymmetry this generalisation existed to close: tmux.conf's paths were
# asserted and wezterm's were not.
mutate_machine "a wezterm default_prog that is not on this machine is caught" "every path the configs hardcode" \
  sed -i '' 's|/opt/homebrew/bin/tmux|/opt/homebrew/bin/tmux-not-here|' wezterm/.config/wezterm/wezterm.lua

# Naming both Homebrew prefixes means "either will do", not "neither need be
# there". A rule that rescued this pair would rescue everything.
mutate_machine "a pair of Homebrew paths where neither exists is still caught" "every path the configs hardcode" \
  bash -c 'printf "\nprobe=/opt/homebrew/bin/nope\nprobe2=/usr/local/bin/nope\n" >> zsh/.zshrc'

mutate "a syntax error in wezterm.lua is caught" "every lua file parses" \
  bash -c 'printf "\nthis is not lua((\n" >> wezterm/.config/wezterm/wezterm.lua'

mutate "a .PHONY target with no recipe is caught" "has a recipe" \
  bash -c 'python3 - <<PY
s=open("Makefile").read()
s=s.replace("test:\n\t@./tests/run.sh\n","",1)
open("Makefile","w").write(s)
PY'

mutate "(#q...) without extendedglob is caught" "extendedglob" \
  sed -i '' 's/setopt localoptions extendedglob/setopt localoptions/' zsh/.zshrc

mutate "a broken .zshrc is caught" ".zshrc parses" \
  bash -c 'printf "\nif then fi done\n" >> zsh/.zshrc'

# The defect this exists for: the per-shell eval coming back, and with it the
# empty output that left HOMEBREW_PREFIX unset.
# The defect this exists for: an installer's line appended after the block.
mutate "code appended after the .zshrc.local block is caught" "ends with its .zshrc.local block" \
  bash -c 'printf "\n[ -s /nope ] && :\n" >> zsh/.zshrc'

# shellcheck disable=SC2016  # the $( ) is text appended to .zshrc, not run here
mutate "brew shellenv run from .zshrc again is caught" "rather than running brew shellenv" \
  bash -c 'printf "\neval \"\$(/opt/homebrew/bin/brew shellenv)\"\n" >> zsh/.zshrc'

# The defect this exists for: no keymap chosen, so EDITOR=nvim picks vi mode.
mutate "no bindkey -e in .zshrc is caught" "pins the emacs keymap" \
  sed -i '' '/^bindkey -e$/d' zsh/.zshrc

# Chosen after compinit, which has already bound its ^X keys elsewhere.
mutate "bindkey -e moved below compinit is caught" "pins the emacs keymap" \
  bash -c "sed -i '' '/^bindkey -e\$/d' zsh/.zshrc && printf '\nbindkey -e\n' >> zsh/.zshrc"

# Last write wins: a later bindkey -v is the keymap every shell gets.
mutate "a later bindkey -v is caught" "pins the emacs keymap" \
  bash -c 'printf "\nbindkey -v\n" >> zsh/.zshrc'

mutate "no findable compinit fails the keymap order rather than passing vacuously" "pins the emacs keymap" \
  sed -i '' 's/^\([[:space:]]*\)compinit/\1: compinit/' zsh/.zshrc

mutate "no interactive_comments in .zshrc is caught" "sets interactive_comments" \
  sed -i '' '/^setopt interactive_comments$/d' zsh/.zshrc

# Last write wins, in any of the spellings zsh accepts for turning it off.
mutate "interactive_comments unset again later is caught" "sets interactive_comments" \
  bash -c 'printf "\nunsetopt INTERACTIVE_COMMENTS\n" >> zsh/.zshrc'

mutate "interactive_comments negated again later is caught" "sets interactive_comments" \
  bash -c 'printf "\nsetopt autocd no_interactivecomments\n" >> zsh/.zshrc'

# The defect this exists for, replayed: setopt globdots back where the
# _comp_options line is, so every * matches .git and .env again.
mutate "setopt globdots back in .zshrc is caught" "leaves globdots off" \
  sed -i '' 's/^_comp_options+=(globdots)$/setopt globdots/' zsh/.zshrc

# In a spelling zsh also accepts, and by turning its negation off.
mutate "globdots set as GLOB_DOTS among other options is caught" "leaves globdots off" \
  bash -c 'printf "\nsetopt autocd GLOB_DOTS\n" >> zsh/.zshrc'

mutate "globdots set by unsetting no_globdots is caught" "leaves globdots off" \
  bash -c 'printf "\nunsetopt no_globdots\n" >> zsh/.zshrc'

mutate "no globdots in _comp_options, so Tab hides dotfiles, is caught" "Tab still offers dotfiles" \
  sed -i '' '/^_comp_options+=(globdots)$/d' zsh/.zshrc

# Before compinit, which assigns the list afresh and throws the append away.
mutate "globdots added to _comp_options before compinit is caught" "Tab still offers dotfiles" \
  python3 -c 'p = "zsh/.zshrc"; s = open(p).read().split("\n")
s.remove("_comp_options+=(globdots)"); s.insert(2, "_comp_options+=(globdots)"); open(p, "w").write("\n".join(s))'

# Last write wins: a later plain assignment replaces the list with the append.
mutate "_comp_options assigned again after the append is caught" "Tab still offers dotfiles" \
  bash -c 'printf "\n_comp_options=(extendedglob)\n" >> zsh/.zshrc'

mutate "no findable compinit fails the _comp_options order rather than passing vacuously" "Tab still offers dotfiles" \
  sed -i '' 's/^\([[:space:]]*\)compinit/\1: compinit/' zsh/.zshrc

# The defect this exists for: no matcher-list, so cd de<Tab> misses Desktop.
mutate "no case-insensitive matcher-list is caught" "Tab matches either case" \
  sed -i '' "/^zstyle ':completion:\*' matcher-list /d" zsh/.zshrc

# Last write wins: a later zstyle that empties the list or deletes it.
mutate "a later empty matcher-list is caught" "Tab matches either case" \
  bash -c "printf '\nzstyle %s matcher-list %s\n' \"':completion:*'\" \"''\" >> zsh/.zshrc"

mutate "a later zstyle -d of the matcher-list is caught" "Tab matches either case" \
  bash -c "printf '\nzstyle -d %s matcher-list\n' \"':completion:*'\" >> zsh/.zshrc"

# The defect this exists for: a starship forked before every prompt to draw an
# empty right prompt.
mutate "starship's RPROMPT left in place is caught" "clears RPROMPT after starship init" \
  sed -i '' "/^  RPROMPT=''$/d" zsh/.zshrc

# And the other way round: a right_format that .zshrc would hide. At the top of
# the file, because under a [table] header the key belongs to that module.
# shellcheck disable=SC2016  # $directory is starship's, written into the file
mutate "a right_format that .zshrc hides is caught" "clears RPROMPT after starship init" \
  bash -c '{ printf "right_format = \"\$directory\"\n"; cat starship/.config/starship.toml; } >toml.tmp &&
    mv toml.tmp starship/.config/starship.toml'

# The same key below format written as a """ string, the way every starship
# preset writes it. Its lines open with [text](style), and a reader that took
# those for a [table] header stopped there and never saw the key.
# shellcheck disable=SC2016  # $time is starship's, written into the file
mutate "a right_format below a multi-line format is caught" "clears RPROMPT after starship init" \
  python3 -c 'p = "starship/.config/starship.toml"; s = open(p).read().split("\n")
i = [n for n, l in enumerate(s) if l.startswith("format = \"")][0]
body = s[i][len("format = \""):-1]
s[i:i + 1] = ["format = \"\"\"", "[](cyan)\\", body + "\"\"\"", "right_format = \"$time\""]
open(p, "w").write("\n".join(s))'

# And below a comment that mentions """, which must not open a string that
# swallows the rest of the file.
mutate "a right_format below a comment quoting \"\"\" is caught" "clears RPROMPT after starship init" \
  bash -c '{ printf "# format can be a \"\"\" string\nright_format = \"x\"\n"; cat starship/.config/starship.toml; } >toml.tmp &&
    mv toml.tmp starship/.config/starship.toml'

# Cleared before the init, which sets it again.
mutate "RPROMPT cleared before starship init is caught" "clears RPROMPT after starship init" \
  python3 -c 'p = "zsh/.zshrc"; q = chr(39) * 2; s = open(p).read().split("\n")
s.remove("  RPROMPT=" + q); s.insert(2, "RPROMPT=" + q); open(p, "w").write("\n".join(s))'

# Last write wins: a later RPROMPT is the one every prompt runs.
mutate "a later RPROMPT assignment is caught" "clears RPROMPT after starship init" \
  bash -c "printf '\nRPROMPT=%s\n' \"'%T'\" >> zsh/.zshrc"

# The injected line is assembled from a format string rather than written
# literally: spelled out, it is itself the hazard, and check.sh would flag this
# file for containing its own test data.
mutate "a pipeline into a quiet grep under pipefail is caught" "quiet grep" \
  bash -c 'printf "\ncat /etc/hosts |%s localhost\n" "grep -q" >> tidy.sh'

mutate "tests/lib.sh gaining set -e is caught" "does not set -e" \
  sed -i '' 's/^set -uo pipefail/set -euo pipefail/' tests/lib.sh

# The defect this exists for: a bare ahead arrow, so the prompt read
# "⇡took 5s".
mutate "a git_status symbol with no trailing space is caught" "every git_status symbol ends in a space" \
  sed -i '' 's/^ahead = "\(.*\) "$/ahead = "\1"/' starship/.config/starship.toml

mutate "an unreadable [git_status] table fails rather than passing vacuously" "every git_status symbol ends in a space" \
  sed -i '' 's/^\[git_status\]$/[git_state]/' starship/.config/starship.toml

# The one the first fix missed: renamed not set at all, so starship drew its
# default, a bare "»", and a staged rename read "»took 5s". Once from the list
# repo.sh keeps, once from starship itself, which fills in the default.
mutate "a git_status symbol left to starship's default is caught" "every git_status symbol ends in a space" \
  sed -i '' '/^renamed = /d' starship/.config/starship.toml

mutate_machine "a bare default starship draws for an unset symbol is caught" "starship draws every git_status symbol" \
  sed -i '' '/^renamed = /d' starship/.config/starship.toml

# The defect this exists for: no override, so YAML gets the top-level 4 and
# every save re-indents it. Rewritten through json, not sed, so the file still
# parses and it is the width that fails rather than the read.
mutate "YAML left at .prettierrc's top-level tabWidth is caught" "prettier indents YAML by 2" \
  python3 -c 'import json; p = "home/.prettierrc"; c = json.load(open(p)); del c["overrides"]; open(p, "w").write(json.dumps(c))'

# Prettier applies overrides in order, so a later one is the one that counts.
mutate "a later override setting YAML back to 4 is caught" "prettier indents YAML by 2" \
  python3 -c 'import json; p = "home/.prettierrc"; c = json.load(open(p)); c["overrides"].append({"files": "*.yml", "options": {"tabWidth": 4}}); open(p, "w").write(json.dumps(c))'

mutate "an unreadable home/.prettierrc fails rather than passing vacuously" "prettier indents YAML by 2" \
  bash -c 'printf "not json\n" >> home/.prettierrc'

# Patterns a glob on the bare name cannot judge. Each of these had prettier
# re-indent ci.yml at 4 while the check, matching them as plain globs, read 2.
mutate "a later override for a path the check cannot judge is caught" "prettier indents YAML by 2" \
  python3 -c 'import json; p = "home/.prettierrc"; c = json.load(open(p)); c["overrides"].append({"files": ".github/**/*.yml", "options": {"tabWidth": 4}}); open(p, "w").write(json.dumps(c))'

mutate "an excludeFiles path the check cannot judge is caught" "prettier indents YAML by 2" \
  python3 -c 'import json; p = "home/.prettierrc"; c = json.load(open(p)); c["overrides"][0]["excludeFiles"] = ".github/workflows/ci.yml"; open(p, "w").write(json.dumps(c))'

mutate "a brace pattern the check cannot judge is caught" "prettier indents YAML by 2" \
  python3 -c 'import json; p = "home/.prettierrc"; c = json.load(open(p)); c["overrides"].append({"files": "*.{yml,yaml}", "options": {"tabWidth": 4}}); open(p, "w").write(json.dumps(c))'

# The defect this exists for: the 99 pattern anchored to the repo root again,
# so nvim started in a subdirectory leaks its scratch files.
mutate "a root-anchored 99 pattern in the global ignore is caught" "the global ignore covers what it claims" \
  sed -i '' 's|^\*\*/tmp/99-\*$|tmp/99-*|' git/.config/git/ignore

mutate "a build directory the global ignore no longer covers is caught" "the global ignore covers what it claims" \
  sed -i '' '/^node_modules\/$/d' git/.config/git/ignore

# The other direction: .env.* hides the template once its negation is gone.
mutate "a .env template the global ignore hides is caught" "the global ignore covers what it claims" \
  sed -i '' '/^!\.env\.example$/d' git/.config/git/ignore

mutate_machine "a missing git hook is caught" "hooks installed" \
  rm -f .githooks/pre-commit

mutate_machine "hooks pointing nowhere is caught" "hooks installed" \
  git config core.hooksPath .nonexistent-hooks

mutate_machine "a git identity that disagrees with the repo is caught" "keys the repo's git config sets" \
  git config --local user.email someone-else@example.com

# Not just the identity: ANY key git resolves to something else makes the
# repo's line for it dead. The repo's side is changed here rather than the live
# side, so this needs nothing written outside the copy.
mutate_machine "any other key that disagrees with what git uses is caught" "keys the repo's git config sets" \
  sed -i '' 's/algorithm = histogram/algorithm = patience/' git/.config/git/config

mutate_machine "a git config with no keys fails rather than passing vacuously" "keys the repo's git config sets" \
  bash -c ': >git/.config/git/config'

# The defect this exists for, replayed: a guard.log the guard wrote into the
# repo, committed. -f because .gitignore now refuses it, which is the point.
mutate "a tracked guard.log is caught" "no runtime file the guard or the 99 plugin writes" \
  sh -c 'echo x >guard.log && git add -f guard.log'

# The 99 plugin's state, anywhere in the tree.
mutate "a tracked 99 scratch file is caught" "no runtime file the guard or the 99 plugin writes" \
  sh -c 'mkdir -p tmp && echo x >tmp/99-state && git add -f tmp/99-state'

# ------------------------------------------------------ what the linters can see

mutate "a shell script with no shebang is caught, because lint would skip it" "declare an interpreter" \
  bash -c 'tail -n +2 checks/lib.sh > checks/lib.tmp && mv checks/lib.tmp checks/lib.sh'

mutate "CI no longer running the linters is caught" "CI runs 'make lint'" \
  sed -i '' 's/^        run: make lint$/        run: true/' .github/workflows/ci.yml

# The defect this exists for: CI priming with sync, which updates every plugin
# past the lock before the suites run.
mutate "CI priming the plugins with sync is caught" "at the commits lazy-lock.json pins" \
  sed -i '' 's/"+Lazy! restore"/"+Lazy! sync"/' .github/workflows/ci.yml

# A restore that a later update undoes is no restore at all.
mutate "an update after the restore is caught" "at the commits lazy-lock.json pins" \
  sed -i '' 's/"+Lazy! restore" +qa/"+Lazy! restore" "+Lazy! update" +qa/' .github/workflows/ci.yml

mutate "CI never running restore at all is caught" "at the commits lazy-lock.json pins" \
  sed -i '' 's/"+Lazy! restore" +qa/+qa/' .github/workflows/ci.yml

# The defect this exists for, replayed: CI cloning plugins by a list of its
# own, which left vim-tmux-navigator out.
# shellcheck disable=SC2016  # the $( ) and $HOME are text in ci.yml
mutate "CI hand-cloning the tmux plugins again is caught" "CI installs the tmux plugins with" \
  python3 -c 'p = ".github/workflows/ci.yml"; s = open(p).read()
old = "plugins_log=\"$(bash -c '"'"'. ./bootstrap.sh && install_tmux_plugins'"'"' 2>&1)\""
assert old in s
open(p, "w").write(s.replace(old, "git clone --depth 1 https://github.com/tmux-plugins/tpm \"$HOME/.config/tmux/plugins/tpm\"", 1))'

# A second list beside the function's is still a second list.
# shellcheck disable=SC2016  # $HOME is text written into ci.yml
mutate "a hand clone beside install_tmux_plugins is caught" "CI installs the tmux plugins with" \
  sed -i '' 's|^          make stow$|          make stow\
          git clone --depth 1 https://github.com/christoomey/vim-tmux-navigator "$HOME/x"|' .github/workflows/ci.yml

mutate "CI calling an install_tmux_plugins bootstrap.sh does not define is caught" "CI installs the tmux plugins with" \
  sed -i '' 's/^install_tmux_plugins() {$/install_plugins_for_tmux() {/' bootstrap.sh

# Off the brew line only: the comment above it still names tree-sitter-cli,
# and must not be what satisfies the check.
mutate "CI without the tree-sitter CLI is caught" "CI installs tree-sitter-cli" \
  sed -i '' 's/neovim tree-sitter-cli tmux/neovim tmux/' .github/workflows/ci.yml

# ------------------------------------- assertions that could pass while being wrong

# The old version of this compared COUNTS: renaming a binding kept the total at
# twenty-one and passed.
mutate "a binding renamed out of test-bindings.sh's accounting is caught" "pressed or explained" \
  sed -i '' 's/^bind w choose-tree/bind W choose-tree/' tmux/.config/tmux/tmux.conf

mutate "a stow package list that disagrees with the others is caught" "copies of the stow package list" \
  sed -i '' 's/local packages=(nvim wezterm tmux zsh home starship)/local packages=(nvim wezterm tmux zsh home)/' bootstrap.sh

# The copy the first version of this check could not see, because it named its
# four sources by hand and there were six.
mutate "a copy in a test suite disagreeing is caught too" "copies of the stow package list" \
  sed -i '' 's/nvim wezterm tmux zsh home starship git/nvim wezterm tmux zsh home git/' tests/test-fresh-machine.sh

# make accepts any number of .PHONY lines; reading only the first left
# everything on a second one unchecked.
mutate_adds "a recipeless target on a SECOND .PHONY line is caught" "has a recipe" \
  "declared .PHONY but has no recipe" \
  bash -c 'printf "\n.PHONY: ghost\n" >> Makefile'

# ---------------------------------------------------- what a fresh machine gets

# A formatter conform runs that bootstrap never installs, and the linter the
# same: shellcheck, which bashls runs.
mutate "a formatter bootstrap does not install is caught" "formatters and linters the nvim config runs" \
  sed -i '' '/^    black$/d' bootstrap.sh

mutate "the shellcheck bashls runs, not installed by bootstrap, is caught" "formatters and linters the nvim config runs" \
  sed -i '' '/^    shellcheck$/d' bootstrap.sh

# Whether bashls runs is read out of lsp.lua's enable list, so an enable list
# that cannot be read must fail rather than mean no linter at all.
mutate "an unreadable enable list fails rather than dropping the linter vacuously" "formatters and linters the nvim config runs" \
  sed -i '' 's/vim\.lsp\.enable({/vim.lsp.enable_({/' nvim/.config/nvim/lua/rich/plugins/lsp.lua

# The named exceptions have to stay conditional on what provides them, or
# naming them would excuse them for good. go is what runs go install, so
# goimports, built that way, goes with it.
mutate "goimports without go to build it is caught" "formatters and linters the nvim config runs" \
  sed -i '' '/^    go$/d' bootstrap.sh

mutate "rustfmt without the rustup install is caught" "formatters and linters the nvim config runs" \
  sed -i '' '/sh\.rustup\.rs/d' bootstrap.sh

# A tool conform runs that bootstrap was to go install, and does not.
mutate "a go-installed formatter bootstrap never installs is caught" "formatters and linters the nvim config runs" \
  sed -i '' '/^  go install golang\.org\/x\/tools\/cmd\/goimports@latest ||$/d' bootstrap.sh

# The warnings quote the command too; only a line that runs it counts.
mutate "a go install left only in a comment is caught" "formatters and linters the nvim config runs" \
  sed -i '' 's/^  go install golang\.org/  # go install golang.org/' bootstrap.sh

mutate "a go install in a function main() never calls is caught" "formatters and linters the nvim config runs" \
  sed -i '' '/^  install_go_tools$/d' bootstrap.sh

# Before brew_install_pkgs, a fresh machine has no go to run it with.
mutate "a go install run before Homebrew installs go is caught" "formatters and linters the nvim config runs" \
  perl -0pi -e 's/  brew_install_pkgs\n  install_go_tools\n/  install_go_tools\n  brew_install_pkgs\n/' bootstrap.sh

# The guard that is load-bearing: no formatters read means the loop runs zero
# times, and "all 0 installed" would otherwise pass.
mutate "no formatters read out of conform.lua fails rather than passing vacuously" "formatters and linters the nvim config runs" \
  sed -i '' 's/formatters_by_ft = {/formatters_for = {/' nvim/.config/nvim/lua/rich/plugins/conform.lua

# An entry written over three lines, a layout stylua keeps, with bootstrap's
# line for one tool gone. The grep this check used to be read neither the name
# on the inner line nor any entry after the first such one, and passed.
spread_and_drop() { # $1=plugin file  $2=filetype to spread  $3=package to drop
  FT="$2" perl -pi -e \
    's/^(\s*)\Q$ENV{FT}\E = \{ ("[^"]+") \},$/$1$ENV{FT} = {\n$1    $2,\n$1},/' "$1" &&
    sed -i '' "/^    $3\$/d" bootstrap.sh
}

mutate "a formatter on the inner line of a multi-line entry is read" "formatters and linters the nvim config runs" \
  spread_and_drop nvim/.config/nvim/lua/rich/plugins/conform.lua python black

mutate "the entries after a multi-line one are read too" "formatters and linters the nvim config runs" \
  spread_and_drop nvim/.config/nvim/lua/rich/plugins/conform.lua python clang-format

# A filetype that yields no name is reported, not counted as nothing to install.
mutate "a filetype whose formatters are not a list of names is caught" "formatters and linters the nvim config runs" \
  sed -i '' 's/lua = { "stylua" },/lua = function() return { "stylua" } end,/' nvim/.config/nvim/lua/rich/plugins/conform.lua

# The defect this exists for: a fresh machine with no tmux plugins until
# someone knows to press prefix I.
mutate "bootstrap's main() not installing the tmux plugins is caught" "installs the tmux plugins, so a fresh machine" \
  sed -i '' '/^  install_tmux_plugins$/d' bootstrap.sh

mutate "the call left only as a comment in main() is caught" "installs the tmux plugins, so a fresh machine" \
  sed -i '' 's/^  install_tmux_plugins$/  # install_tmux_plugins/' bootstrap.sh

# nvim-treesitter's main branch builds every parser with the CLI.
mutate "a fresh machine without the tree-sitter CLI is caught" "bootstrap.sh installs tree-sitter-cli" \
  sed -i '' '/^    tree-sitter-cli$/d' bootstrap.sh

# The formula that looks right and is not: tree-sitter is the library alone.
mutate "the tree-sitter library in the CLI's place is caught" "bootstrap.sh installs tree-sitter-cli" \
  sed -i '' 's/^    tree-sitter-cli$/    tree-sitter/' bootstrap.sh

mutate "a branch that cannot be read out of the lock fails rather than passing" "bootstrap.sh installs tree-sitter-cli" \
  sed -i '' 's/"nvim-treesitter": { "branch": "main"/"nvim-treesitter": { "branch": ""/' nvim/.config/nvim/lazy-lock.json

# ------------------------------------------- constants written down more than once

# The pair the comments named: the guard's floor and prune's idea of degenerate.
# shellcheck disable=SC2016  # ${...} and $logfile are text in the target file
mutate "the guard's floor drifting from prune's is caught" "minimum window count" \
  sed -i '' 's/^MIN_WINDOWS="${MIN_WINDOWS:-2}"/MIN_WINDOWS="${MIN_WINDOWS:-3}"/' tmux/.local/bin/tmux-resurrect-saves

# The other pair: resurrect's own backup deletion against prune's retention.
mutate "the two retention windows drifting apart is caught" "retention window in days" \
  sed -i '' "s/@resurrect-delete-backup-after '90'/@resurrect-delete-backup-after '60'/" tmux/.config/tmux/tmux.conf

# A default documented in prose is a third copy of the number.
mutate "the guard's header disagreeing with its own default is caught" "minimum window count" \
  sed -i '' 's/rule 1 floor       (default 2)/rule 1 floor       (default 3)/' tmux/.local/bin/tmux-resurrect-guard

mutate "the guard's fallback drifting from tmux.conf is caught" "collapse percentage" \
  sed -i '' "s/tmux_opt '@resurrect-guard-collapse-pct' '50'/tmux_opt '@resurrect-guard-collapse-pct' '40'/" tmux/.local/bin/tmux-resurrect-guard

# shellcheck disable=SC2016  # ${...} and $logfile are text in the target file
mutate "a log trim that no longer matches its own header is caught" "guard.log is trimmed to" \
  sed -i '' 's/tail -n 200 "$logfile"/tail -n 100 "$logfile"/' tmux/.local/bin/tmux-resurrect-guard

# A comment quoting another file is a copy, and this proves the copy is read.
mutate "a comment quoting a tmux.conf line that changed is caught" "line a comment quotes" \
  sed -i '' "s|@resurrect-hook-post-save-all '~/.local/bin/tmux-resurrect-guard|@resurrect-hook-post-save-all '~/.local/bin/tmux-guard|" tmux/.config/tmux/tmux.conf

# And the anti-vacuity guard: a value that cannot be read must fail, not compare
# equal to the nothing beside it.
mutate "a constant that cannot be read at all fails rather than comparing empty" "minimum window count" \
  sed -i '' '/^MIN_WINDOWS=/d' tmux/.local/bin/tmux-resurrect-saves

# The defect this exists for, replayed: both files said -i 2 -ci, and every save
# still re-indented to 4, because conform appends its own -i after prepend_args.
mutate "shfmt flags passed as prepend_args are caught" "run shfmt with the same flags" \
  sed -i '' 's/^\( *\)args = { "-i"/\1prepend_args = { "-i"/' nvim/.config/nvim/lua/rich/plugins/conform.lua

mutate "make lint and format-on-save running shfmt differently is caught" "run shfmt with the same flags" \
  sed -i '' 's/shfmt -i 2 -ci -d/shfmt -i 4 -ci -d/' Makefile

# A later definition replaces the first, so reading conform.lua alone would
# report flags format-on-save no longer uses.
mutate "a second shfmt definition elsewhere in the lua config is caught" "run shfmt with the same flags" \
  bash -c 'printf "\nrequire(\"conform\").formatters.shfmt = { args = { \"-i\", \"4\" } }\n" >> nvim/.config/nvim/lua/rich/keymaps.lua'

# A second conform spec, which lazy deep-merges into conform.lua's opts: args
# stay as they were, -i 4 goes after them, and a save re-indents to 4. The
# bracketed key once hid it from the definition count entirely.
mutate "a second conform spec merging append_args into shfmt is caught" "run shfmt with the same flags" \
  bash -c 'printf "%s\n" "return { \"stevearc/conform.nvim\", opts = { formatters = { [\"shfmt\"] = { append_args = { \"-i\", \"4\" } } } } }" > nvim/.config/nvim/lua/rich/plugins/conform_extra.lua'

# The same bracketed key with no extra args at all, so only the count sees it.
mutate "a second shfmt definition under a bracketed key is caught" "run shfmt with the same flags" \
  bash -c 'printf "%s\n" "return { \"stevearc/conform.nvim\", opts = { formatters = { [\"shfmt\"] = { args = { \"-i\", \"4\" } } } } }" > nvim/.config/nvim/lua/rich/plugins/conform_extra.lua'

# And the other way lazy lets a spec change opts: a function that edits them.
mutate "append_args set on shfmt from an opts function is caught" "run shfmt with the same flags" \
  bash -c 'printf "%s\n" "return {" "    \"stevearc/conform.nvim\"," "    opts = function(_, opts)" "        opts.formatters.shfmt.append_args = { \"-i\", \"4\" }" "    end," "}" > nvim/.config/nvim/lua/rich/plugins/conform_extra.lua'

# A scan that matches nothing would count no second definition anywhere. It
# has to find conform.lua's own, or fail.
# shellcheck disable=SC2016  # $shfmt_def is repo.sh's text, edited, not expanded
mutate "a shfmt definition scan gone blind fails rather than counting none" "run shfmt with the same flags" \
  sed -i '' 's/SHFMT_DEF="\$shfmt_def" xargs/SHFMT_DEF="x^" xargs/' checks/repo.sh

mutate "unreadable shfmt args fail rather than passing vacuously" "run shfmt with the same flags" \
  sed -i '' '/^ *args = { "-i"/d' nvim/.config/nvim/lua/rich/plugins/conform.lua

# ---------------------------------------------------- what the repo says of itself

# A hook and the make target that describes it are two copies of one command.
mutate "a pre-push hook that no longer runs its make target is caught" "runs exactly what" \
  sed -i '' 's|/tests/run.sh" --fast|/tests/run.sh"|' .githooks/pre-push

mutate "a file advertising the hooks with the wrong target is caught" "advertises the hooks" \
  sed -i '' 's/test-fast on push/test on push/' Makefile

# A slow suite's header must agree with what the hook really does.
mutate "a slow suite claiming the hook runs it is caught" "say who runs them" \
  sed -i '' 's/and so does the pre-push hook/and the pre-push hook still runs everything/' tests/test-restore.sh

mutate "losing the SUITE_SLOW marker entirely is caught" "say who runs them" \
  sed -i '' 's/^SUITE_SLOW=1/SUITE_BRISK=1/' tests/test-restore.sh tests/test-nvim.sh tests/test-check.sh \
  tests/test-bindings.sh tests/test-integration.sh tests/test-helpers.sh tests/test-sessionizer.sh \
  tests/test-continuum.sh tests/test-performance.sh

# Everything below rolls up into one ✓, so each mutation names the specific
# claim it breaks. They are separate assertions inside checks/repo.sh; a single
# marker is what the roll-up costs.
mutate "a make target the README invents is caught" "describes nothing that is not here" \
  bash -c 'printf "\nRun make nonesuch for luck.\n" >> README.md'

mutate "a make target the README never mentions is caught" "describes nothing that is not here" \
  sed -i '' '/^make doctor/d' README.md

# shellcheck disable=SC2016  # backticks are markdown, not substitution
mutate "a path the README references that is not here is caught" "describes nothing that is not here" \
  sed -i '' 's|`checks/repo.sh`|`checks/nope.sh`|' README.md

mutate "a package in the README table that is not a package is caught" "describes nothing that is not here" \
  sed -i '' 's/^| \*\*starship\*\*/| **stargazer**/' README.md

# shellcheck disable=SC2016  # backticks are markdown, not substitution
mutate "a helper script the README documents but that is gone is caught" "describes nothing that is not here" \
  sed -i '' 's/^\*\*`tmux-resurrect-saves`\*\*/**`tmux-resurrect-savez`**/' README.md

mutate "a subcommand the README shows but the script rejects is caught" "describes nothing that is not here" \
  sed -i '' 's/tmux-resurrect-saves list/tmux-resurrect-saves inventory/' README.md

# The drift in the direction it really happens: the config changes, the README
# does not.
mutate "a tmux binding the README documents but tmux.conf no longer binds is caught" "describes nothing that is not here" \
  sed -i '' '/^bind w choose-tree/d' tmux/.config/tmux/tmux.conf

# shellcheck disable=SC2016  # backticks are markdown, not substitution
mutate "a leader mapping the README documents but nothing asserts is caught" "describes nothing that is not here" \
  sed -i '' 's/`<leader>ff`/`<leader>zz`/' README.md

# shellcheck disable=SC2016  # backticks are markdown, not substitution
# The pattern tolerates the padding a markdown formatter adds. It was written
# with single spaces, and prettier — which this repo runs on save for markdown —
# pads table cells to align them, after which the sed matched nothing, applied
# no defect, and this mutation reported that check.sh had failed to catch a
# defect that was never introduced. mutate() runs the command with output
# discarded and cannot tell "the sed did nothing" from "the check did nothing".
mutate "a Neovim binding the README documents but the lua config lacks is caught" "describes nothing that is not here" \
  sed -i '' -E 's/\| `gd`([[:space:]]*)\|/| `gz`\1|/' README.md

# shellcheck disable=SC2016  # the $names are starship modules, not variables
mutate "a prompt module the README's row does not mention is caught" "describes nothing that is not here" \
  sed -i '' 's/\$git_status\$python/$git_status$hostname$python/' starship/.config/starship.toml

mutate "a timing quoted in the prose is caught" "describes nothing that is not here" \
  bash -c 'printf "\nThe hook takes about 19s.\n" >> README.md'

mutate "a suite count that no longer matches tests/ is caught" "describes nothing that is not here" \
  sed -i '' 's/18 suites/17 suites/' .githooks/pre-push

# The anti-vacuity guards. An extractor that quietly returns nothing would turn
# every comparison above into "" = "", which passes while asserting nothing.
mutate "an unreadable save interval fails rather than permitting every figure" "describes nothing that is not here" \
  sed -i '' '/@continuum-save-interval/d' tmux/.config/tmux/tmux.conf

mutate "unreadable leader sets fail rather than passing vacuously" "describes nothing that is not here" \
  sed -i '' 's/^EXPECTED_LEADER_[NV]=.*/EXPECTED_LEADER_X=""/' tests/test-nvim.sh

echo
echo "== a figure in the prose must match the config that owns it =="
# The README says continuum saves every 15 minutes because tmux.conf says 15.
# Change one and the other is a lie with nothing to notice it — which is the
# whole reason the permitted figures are read out of the config rather than
# listed in the check.
reset_repo
sed -i '' "s/@continuum-save-interval '15'/@continuum-save-interval '20'/" \
  "$WORK/tmux/.config/tmux/tmux.conf"
out="$(run_check)"
refute "changing the interval without the README is caught" contains "$out" "0 failure(s)"
assert "and the message names the figure that stopped matching" contains "$out" "15 minutes"

echo
echo "== a filetype's second formatter is checked too =="
# The extraction read one formatter per filetype. Every entry has exactly one
# today, so nothing was being missed — but a fallback, which is the ordinary way
# conform is configured, would have gone unchecked from the moment it was added.
reset_repo
sed -i '' 's/lua = { "stylua" }/lua = { "stylua", "not-a-real-formatter" }/' \
  "$WORK/nvim/.config/nvim/lua/rich/plugins/conform.lua"
out="$(run_check_full | sed 's/\x1b\[[0-9;]*m//g')"
assert "the second formatter in a filetype's list is checked as well as the first" \
  contains "$out" "formatter not-a-real-formatter is not on PATH"

echo
echo "== a go-installed formatter off PATH is found, and said to be off PATH =="
# goimports lives where go install put it, which .zshrc adds to PATH. With
# that directory taken off PATH, the machine check has to find it there and
# say nvim would not, rather than call it missing or call it available. Only
# meaningful where goimports was go-installed.
gobin="${GOBIN:-${GOPATH:-$HOME/go}}"
[ -n "${GOBIN:-}" ] || gobin="${gobin%%:*}/bin"
if [ ! -x "$gobin/goimports" ]; then
  printf '  \033[33mSKIP\033[0m  there is no goimports in %s\n' "$gobin"
else
  reset_repo
  off_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$gobin" | grep -vxF "$gobin/" | paste -sd: -)"
  out="$(PATH="$off_path" run_check_full | sed 's/\x1b\[[0-9;]*m//g')"
  assert "goimports off PATH is reported as found in $gobin" \
    contains "$out" "formatter goimports is in $gobin, which is not on PATH here"
  refute "...not as available" contains "$out" "formatter goimports is available"
  refute "...nor as missing" contains "$out" "formatter goimports is not on PATH or in mason"
  case ":$PATH:" in
    *":$gobin:"* | *":$gobin/:"*)
      out="$(run_check_full | sed 's/\x1b\[[0-9;]*m//g')"
      assert "and with it on PATH, as .zshrc puts it, it is available" \
        contains "$out" "formatter goimports is available"
      ;;
    *) printf '  \033[33mSKIP\033[0m  %s is not on this PATH, so the on-PATH half cannot be asked\n' "$gobin" ;;
  esac
fi

echo
echo "== naming both Homebrew prefixes means only one has to exist =="
# .zshrc and bootstrap.sh try /opt/homebrew and then /usr/local. No machine has
# a Homebrew binary under both, so without this rule the path scan would report
# a missing path on every machine there is. Only meaningful where exactly one of
# the two has tmux, which is every normal machine.
prefixes=0
[ -e /opt/homebrew/bin/tmux ] && prefixes=$((prefixes + 1))
[ -e /usr/local/bin/tmux ] && prefixes=$((prefixes + 1))
reset_repo
if ! contains "$(run_check_full)" "every path the configs hardcode"; then
  printf '  \033[33mSKIP\033[0m  the machine half does not pass here\n'
elif [ "$prefixes" -ne 1 ]; then
  printf '  \033[33mSKIP\033[0m  this machine has tmux under %s Homebrew prefixes, not one\n' "$prefixes"
else
  absent=/usr/local/bin/tmux
  [ -e "$absent" ] && absent=/opt/homebrew/bin/tmux
  printf '\nprobe=/opt/homebrew/bin/tmux\nprobe2=/usr/local/bin/tmux\n' >>"$WORK/zsh/.zshrc"
  out="$(run_check_full)"
  refute "the absent prefix is not reported when the file names both" \
    contains "$out" "$absent, which does not exist"
fi

echo
echo "== a git -c for one command is not the repo's git config going dead =="
# `git -c core.editor=true commit --amend` is the usual non-interactive amend,
# and git hands that setting to the pre-commit hook, so to check.sh, through the
# environment: GIT_CONFIG_PARAMETERS for -c, GIT_CONFIG_COUNT for the same set
# from outside. It lasts one command and overrides no file, and the comparison
# of the repo's git config with what git uses called the repo's value dead for
# it and refused the commit. Driven through a real commit in the copy, so the
# hook gets the override the way git delivers it rather than the way this file
# assumes it does. Only meaningful where the machine half passes.
reset_repo
full="$(run_check_full)"
if ! contains "$full" "0 failure(s)" || ! contains "$full" "keys the repo's git config sets"; then
  printf '  \033[33mSKIP\033[0m  the machine half does not pass here\n'
else
  rc=0
  out="$(cd "$WORK" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.verbose GIT_CONFIG_VALUE_0=false \
    git -c core.editor=a-one-off-editor commit -q --allow-empty -m probe 2>&1)" || rc=$?
  # The refusals below pass on silence, so first: the hook ran the comparison.
  assert "the hook still compares every key the repo's git config sets" \
    contains "$out" "keys the repo's git config sets are what git actually uses"
  refute "a git -c override is not reported as the repo's value going dead" \
    contains "$out" "core.editor: repo says"
  refute "nor is one passed in GIT_CONFIG_COUNT" contains "$out" "commit.verbose: repo says"
  assert "and the commit goes through" [ "$rc" -eq 0 ]
fi

echo
echo "== check.sh's own exit status =="
reset_repo
(cd "$WORK" && ./check.sh --repo-only >/dev/null 2>&1)
assert "a clean repo exits 0" [ $? -eq 0 ]
(cd "$WORK" && git rm -q --cached nvim/.config/nvim/lazy-lock.json)
rc=0
(cd "$WORK" && ./check.sh --repo-only >/dev/null 2>&1) || rc=$?
assert "a repo with a defect exits non-zero, so a hook or CI can act on it" [ "$rc" -ne 0 ]

echo
echo "== status-right must be set before tpm runs =="
# Continuum appends #(continuum_save.sh) to status-right when tpm loads it.
# Setting status-right after that point overwrites the addition and every
# automatic save stops, with no error and no missing file — the exact shape of
# failure this repo exists to catch.
reset_repo
python3 - "$WORK/tmux/.config/tmux/tmux.conf" <<'MOVE'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(True)
sr = [i for i, l in enumerate(lines) if l.lstrip().startswith("set ") and "status-right" in l]
tpm = [i for i, l in enumerate(lines) if l.lstrip().startswith("run ") and "tpm" in l]
line = lines.pop(sr[0])
lines.insert(tpm[-1], line)  # now below the tpm run line
open(p, "w").write("".join(lines))
MOVE
out="$(run_check)"
refute "moving status-right below tpm is caught" contains "$out" "0 failure(s)"
assert "and the message names the ordering, not just a missing setting" \
  contains "$out" "overwrites continuum"

# ------------------------------------------------------- the checks themselves

echo
echo "== a missing half must not read as a clean pass =="
# The worst failure check.sh can have, and it was live. `.` on a file that is
# not there prints one line to stderr and carries on, so deleting checks/repo.sh
# produced "0 ok, 0 warning(s), 0 failure(s)" and exit 0 — CI green, pre-commit
# hook green, nothing being checked at all.
reset_repo
rm -f "$WORK/checks/repo.sh"
out="$(run_check)"
rc=$?
assert "it exits non-zero rather than reporting nothing wrong" [ "$rc" -ne 0 ]
# check.sh's OWN message, not bash's "No such file or directory". Both mention
# the path, so asserting on the path alone passes with the guard removed — the
# no-checks-ran guard below would still catch the missing file, but only after
# the fact and without saying what was unreadable.
assert "and says itself that it could not read the file" \
  contains "$out" "cannot read ./checks/repo.sh"
refute "it does not print a summary that looks like success" contains "$out" "0 failure(s)"

echo
echo "== ...nor must a half that exists but asserts nothing =="
# The same failure with a better disguise: a truncated file, a syntax error
# partway through, an early return. A run that checked nothing is not a pass.
reset_repo
: >"$WORK/checks/repo.sh"
out="$(run_check)"
rc=$?
assert "an empty half is a failure, not a clean run" [ "$rc" -ne 0 ]
assert "and says so plainly" contains "$out" "no checks ran"

echo
echo "== --repo-only does not depend on the machine half =="
# Deliberate: CI has no WezTerm, fonts or stow tree, so requiring machine.sh
# there would either fail the run or push someone to disable the check.
reset_repo
rm -f "$WORK/checks/machine.sh"
out="$(run_check)"
rc=$?
assert "the repo half still runs and passes" [ "$rc" -eq 0 ]
assert "and reports the checks it did run" contains "$out" "ok,"

finish
