#!/usr/bin/env bash
# Assertions about the REPOSITORY, not about the machine it is checked out on.
#
# Everything here holds true on any machine with git and the usual text tools,
# which is what makes it runnable in CI. Anything that asks "is THIS laptop set
# up correctly" belongs in machine.sh instead — CI has no WezTerm, no fonts and
# no stow tree, and a check that cannot pass there would just be turned off.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO="$PWD"
# shellcheck source=/dev/null
. "$REPO/checks/lib.sh"

# ---------------------------------------------------------------- readers
#
# Values live in the file that owns them; these read them back out. An extractor
# that quietly returns nothing turns every comparison below into "" = "", which
# passes while asserting nothing — the shape of the seven assertions in this
# repo that turned out to be incapable of failing. Every caller rejects an empty
# result rather than comparing it.

GUARD="tmux/.local/bin/tmux-resurrect-guard"
SAVES="tmux/.local/bin/tmux-resurrect-saves"
TMUXCONF="tmux/.config/tmux/tmux.conf"
OPTIONS="nvim/.config/nvim/lua/rich/options.lua"
LSP="nvim/.config/nvim/lua/rich/plugins/lsp.lua"

# The value tmux.conf sets an option to:  set -g @option 'value'
tmux_setting() { # $1 = option name
  local line
  line="$(grep -m1 -E "^[[:space:]]*set .*$1 " "$TMUXCONF")"
  line="${line#*\'}"
  printf '%s' "${line%%\'*}"
}

# The V in a shell script's  NAME="${NAME:-V}"
sh_default() { # $1 = file, $2 = variable
  local line
  line="$(grep -m1 -E "^$2=" "$1")"
  case "$line" in
    *":-"*)
      line="${line#*:-}"
      printf '%s' "${line%%\}*}"
      ;;
  esac
}

# The guard's own fallback:  tmux_opt '@option' 'default'
guard_default() { # $1 = option name
  local line
  line="$(grep -m1 -F "tmux_opt '$1'" "$GUARD")"
  line="${line#*\' \'}"
  printf '%s' "${line%%\'*}"
}

# Every key tmux.conf binds. tmux's grammar is `bind [-flags] [-T table] KEY
# command`, so the key is the first argument that is neither a flag nor a flag's
# argument.
tmux_bound_keys() {
  awk '
    /^[[:space:]]*bind(-key)?[[:space:]]/ {
      for (i = 2; i <= NF; i++) {
        if ($i == "-T" || $i == "-t" || $i == "-N") { i++; continue }
        if ($i ~ /^-/) { continue }
        print $i
        break
      }
    }
  ' "$TMUXCONF"
}

# What the guard's header says that fallback is:  @option  ...  (default V)
guard_doc_default() { # $1 = option name
  local line
  line="$(grep -m1 -E "^#[[:space:]]+$1[[:space:]]" "$GUARD")"
  case "$line" in
    *"(default "*)
      line="${line#*\(default }"
      printf '%s' "${line%%\)*}"
      ;;
  esac
}

# The value options.lua assigns an option:  vim.opt.NAME = VALUE  -- comment
nvim_opt() { # $1 = option name
  local line
  line="$(grep -m1 -E "^[[:space:]]*vim\.opt\.$1[[:space:]]*=" "$OPTIONS")"
  line="${line#*=}"
  line="${line%%--*}"
  printf '%s' "$(printf '%s' "$line" | tr -d '[:space:]')"
}

# The server names in one of lsp.lua's lists, one per line, sorted. $1 is a sed
# address range that selects the list; comment lines inside it are skipped, so
# a server commented out is a server not listed.
lsp_list() { # $1 = sed address range
  sed -n "$1p" "$LSP" | grep -vE '^[[:space:]]*--' | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u
}

section "Lua config"
# These generalise past whatever anyone has read: a syntax error or a deprecated
# call in a plugin file nobody has opened shows up as "nvim starts a bit oddly".
#
# EVERY tracked lua file, not just nvim's. wezterm.lua is lua too and nothing
# parsed it — a syntax error there makes WezTerm fall back to its built-in
# defaults, which is the same silent-fallback shape as the colour scheme that
# matched nothing. nvim is only the parser here; the files need not be its own.
if command -v nvim >/dev/null 2>&1; then
  lua_files="$(git ls-files '*.lua')"
  lua_seen="$(printf '%s\n' "$lua_files" | grep -c .)"
  # One nvim for the whole set, not one per file. test-check.sh re-runs these
  # checks once per mutation, so an interpreter start per lua file was most of
  # that suite's wall clock. `nvim -l` puts the script arguments in `arg`.
  #
  # io.stdout:write, not print: under `nvim --headless -l` print goes to STDERR,
  # so discarding stderr to keep nvim quiet also discarded the filenames, and
  # this reported every file as parsing while parsing nothing. Found by feeding
  # it a file that does not parse, which is the only way that kind of bug shows.
  #
  # The probe is a plain string rather than a heredoc inside $( ). bash 3.2 —
  # the macOS system bash, which is what runs this — scans a command
  # substitution for its closing paren without understanding that a quoted
  # heredoc is quoted, so ONE apostrophe anywhere in the body, in a comment
  # even, loses the terminator and reports a syntax error thirty lines later.
  # Confirmed in isolation: the same file parses with the apostrophe removed.
  # shellcheck disable=SC2086  # deliberate word splitting: one argument per file
  lua_failures="$(printf '%s\n' 'for _, f in ipairs(arg) do
  if not loadfile(f) then io.stdout:write(f, "\n") end
end' | nvim --clean --headless -l /dev/stdin $lua_files 2>/dev/null)"
  if [ "${lua_seen:-0}" -eq 0 ]; then
    bad "found no lua files to parse — the scan has broken"
  elif [ -z "$lua_failures" ]; then
    ok "every lua file parses ($lua_seen of them, wezterm's included)"
  else
    bad "lua file(s) that fail to parse:"
    printf '%s\n' "$lua_failures" | sed 's/^/      /'
  fi
else
  meh "nvim not installed, cannot parse the lua config"
fi

# Renamed or removed in Neovim 0.10/0.11. The deprecated aliases still work, so
# nothing complains until the version that drops them.
deprecated="vim\.highlight\.|vim\.lsp\.buf_get_clients|vim\.lsp\.get_active_clients|vim\.tbl_add_reverse_lookup|vim\.lsp\.with\(|vim\.diagnostic\.is_disabled|vim\.validate\(\{"
hits="$(grep -rInE "$deprecated" nvim/.config/nvim --include='*.lua' 2>/dev/null | grep -vc '^\s*--' || true)"
if [ "${hits:-0}" -eq 0 ]; then
  ok "no deprecated Neovim APIs in the lua config"
else
  bad "$hits use(s) of deprecated Neovim APIs — they still work, until they do not:"
  grep -rInE "$deprecated" nvim/.config/nvim --include='*.lua' 2>/dev/null | sed 's/^/      /'
fi

# lazy.nvim only reads specs returned from lua/rich/plugins/*.lua. A file that
# returns nothing is loaded, runs, and contributes no plugin — silently.
specless=0
for f in nvim/.config/nvim/lua/rich/plugins/*.lua; do
  grep -qE '^\s*return\s*\{' "$f" || {
    bad "$(basename "$f") has no top-level 'return {' — lazy will load it and get no spec"
    specless=$((specless + 1))
  }
done
[ "$specless" -eq 0 ] && ok "every plugin file returns a lazy spec"

if git ls-files --error-unmatch nvim/.config/nvim/lazy-lock.json >/dev/null 2>&1; then
  ok "lazy-lock.json is tracked — plugin versions are reproducible"
else
  bad "lazy-lock.json is not tracked — a fresh machine gets whatever is newest that day"
fi

# Tracked is not the same as read. lazy loads the lock with a pcall'd
# vim.json.decode and, when that fails, carries on with an EMPTY lock: no error,
# no message, and every plugin installed or restored at the tip of its branch
# instead of the commit written here. A merge-conflict marker or a truncated
# write is enough. So decode it with the decoder lazy uses, and count what it
# pins. nvim only, like the parse check above: a machine without nvim has no use
# for the lock, and CI installs it.
if command -v nvim >/dev/null 2>&1; then
  lock_pins="$(printf '%s\n' 'local f = assert(io.open(arg[1]))
local ok, lock = pcall(vim.json.decode, f:read("*a"))
io.stdout:write(ok and type(lock) == "table" and tostring(vim.tbl_count(lock)) or "unparsed", "\n")' |
    nvim --clean --headless -l /dev/stdin nvim/.config/nvim/lazy-lock.json 2>/dev/null)"
  case "$lock_pins" in
    '' | *[!0-9]*) bad "lazy-lock.json does not parse — lazy drops it without a word and installs every plugin at the tip of its branch" ;;
    0) bad "lazy-lock.json parses but pins nothing — every plugin installs at the tip of its branch" ;;
    *) ok "lazy-lock.json parses the way lazy reads it, and pins $lock_pins plugins" ;;
  esac
else
  meh "nvim not installed, cannot decode lazy-lock.json"
fi

# 99 is loaded on its keys, not at startup. With its mappings set inside config
# lazy had no trigger for it, so it loaded at every start, pulled nvim-cmp in
# with it, and left a VimLeavePre hook writing ./tmp/99-state into whatever
# directory nvim was in when it quit. tests/test-performance.sh asserts the
# eager SET in a running nvim; this is the half CI and the pre-commit hook see
# without starting one. `lazy = false` overrides any trigger, so it fails too.
SPEC99="nvim/.config/nvim/lua/rich/plugins/99.lua"
if ! grep -qE '^[[:space:]]*keys[[:space:]]*=[[:space:]]*\{' "$SPEC99" 2>/dev/null; then
  bad "$SPEC99 declares no lazy keys, so 99 and nvim-cmp load at every startup"
elif grep -qE '^[[:space:]]*lazy[[:space:]]*=[[:space:]]*false' "$SPEC99"; then
  bad "$SPEC99 declares keys but also lazy = false, which loads 99 at every startup anyway"
else
  ok "99 waits for its keys rather than loading at every startup"
fi

# .luarc.json must leave the library to lazydev, and must not hide its absence.
#
# lua_ls lets .luarc.json override the settings its client sends, and lazydev
# works by sending them. This file set workspace.library to luv alone, which
# replaced lazydev's whole library: vim.api had no definition and no hover
# anywhere in this config. It also set diagnostics.globals = ["vim"], which does
# not touch the library -- with that key alone, definitions still resolve -- but
# silenced the undefined-global warning on vim, the one thing that would have
# said the library was missing. Two keys doing two different kinds of harm, so
# two assertions, each with its own reason. The file itself stays, as lua_ls's
# root marker.
#
# Parsed rather than grepped, because lua_ls reads a nested
# {"workspace": {"library": ...}} the same as the dotted key, with or without a
# "Lua." prefix; every leaf is printed as one dotted key, and each entry of a
# list as key=entry, so that only a globals list naming vim fails. A file that
# is missing, does not parse, or holds no keys at all fails, rather than reading
# as a file that sets nothing.
LUARC="nvim/.config/nvim/.luarc.json"
if command -v nvim >/dev/null 2>&1; then
  # A plain string, not a heredoc in $( ), for the bash 3.2 reason given above
  # the lua parse check: so no apostrophes anywhere in it.
  luarc_keys="$(printf '%s\n' 'local f = io.open(arg[1])
if not f then return end
local ok, t = pcall(vim.json.decode, f:read("*a"))
f:close()
if not ok or type(t) ~= "table" then return end
local function walk(prefix, v)
  if type(v) == "table" and next(v) ~= nil and not vim.islist(v) then
    for k, x in pairs(v) do walk(prefix .. k .. ".", x) end
  else
    local key = prefix:sub(1, -2):gsub("^Lua%.", "")
    io.stdout:write(key, "\n")
    if type(v) == "table" then
      for _, x in ipairs(v) do io.stdout:write(key, "=", tostring(x), "\n") end
    end
  end
end
walk("", t)' | nvim --clean --headless -l /dev/stdin "$LUARC" 2>/dev/null)"
  # grep -c prints 0 and exits 1 when nothing matches; the count is all that is
  # read, and an empty one reads as the failing side.
  luarc_library="$(printf '%s\n' "$luarc_keys" | grep -cx 'workspace\.library')"
  luarc_globals="$(printf '%s\n' "$luarc_keys" | grep -cx 'diagnostics\.globals=vim')"
  if [ -z "$luarc_keys" ]; then
    bad "could not read any setting out of $LUARC — missing, not JSON, or empty, so whether it overrides lazydev cannot be said"
  else
    if [ "${luarc_library:-1}" -eq 0 ]; then
      ok ".luarc.json leaves workspace.library to lazydev, so lua_ls knows what vim.* is"
    else
      bad "$LUARC sets workspace.library — lua_ls lets that file override what lazydev sends, so it replaces lazydev's library and vim.* gets no definitions or hover in this config"
    fi
    if [ "${luarc_globals:-1}" -eq 0 ]; then
      ok ".luarc.json does not declare vim a global, so a missing library still shows as vim being undefined"
    else
      bad "$LUARC lists vim in diagnostics.globals — definitions still resolve, but it silences the undefined-global warning on vim, which is how a missing lazydev library shows"
    fi
  fi
else
  meh "nvim not installed, cannot parse $LUARC"
fi

# Line wrap, and which way round it has to point.
#
# This is the one option in options.lua whose value has already been changed by
# a commit about something else. It went in as true; commit 0bdf224 — "Resolved
# LSP errors and hardened colorscheme.lua" — left it false, with a trailing
# space, in a diff nobody was reading for this. Nothing said a word: the file
# still parses, nvim still starts, every other check here stays green, and the
# only symptom is long lines running off the right of the screen, which reads as
# a preference rather than a regression.
#
# TWO halves, because setting an option is not the same as it being set. Lua's
# last write wins, so wrap = true at the top of options.lua and a wo.wrap =
# false in an autocmd further down would leave wrap off with this file still
# claiming otherwise. The second grep looks for anything that turns it off again
# ANYWHERE under nvim/.config/nvim -- a directory walk, not `git ls-files`, so
# it also sees untracked lua there and does not see wezterm's. Comment lines are
# dropped so that a lua comment quoting the pattern cannot trip it. What neither
# half can see is an
# installed plugin doing it at runtime — that needs a running nvim, and
# tests/test-nvim.sh is where that assertion lives.
wrap="$(nvim_opt wrap)"
nowrap="$(grep -rInE 'vim\.(opt|o|wo|go|opt_local)\.wrap[[:space:]]*=[[:space:]]*false|(set|setlocal)[[:space:]]+nowrap' \
  nvim/.config/nvim --include='*.lua' | grep -vE '^[^:]*:[0-9]+:[[:space:]]*--')"
if [ -z "$wrap" ]; then
  bad "could not read vim.opt.wrap out of $OPTIONS at all — the comparison would be vacuous"
elif [ "$wrap" != "true" ]; then
  bad "$OPTIONS sets wrap = $wrap, so long lines run off the right of the screen instead of wrapping"
elif [ -n "$nowrap" ]; then
  bad "options.lua sets wrap = true and the lua config turns it off again — the later write is the one that counts:"
  printf '%s\n' "$nowrap" | sed 's/^/      /'
else
  ok "line wrap is on in options.lua and nothing in the lua config turns it off again"
fi

# Hard wrap at 80, and the fact that setting it is not the same as getting it.
#
# 'wrap' folds at the window edge; 'textwidth' is what holds a line to 80. The
# value is static and belongs here, but the load-bearing half of that setting is
# NOT static and cannot be checked here at all: Neovim's own ftplugins strip 't'
# from formatoptions for lua and sh, and gitcommit sets textwidth=72, so a bare
# assignment in options.lua reads correct while doing nothing in the two
# languages this repo is mostly written in. options.lua answers that with a
# FileType autocmd that writes after them, and tests/test-nvim.sh proves the
# ordering by typing 140 columns into a lua buffer and counting what comes out.
#
# What this half does catch is the value being changed, and the value being
# changed BACK somewhere else in the lua: the second grep allows an assignment
# of 80 and reports any other number, which is what a stray `textwidth = 0` in
# a plugin config or an autocmd would be.
textwidth="$(nvim_opt textwidth)"
othertw="$(grep -rInE 'vim\.(opt|o|bo|wo|opt_local)\.textwidth[[:space:]]*=' \
  nvim/.config/nvim --include='*.lua' |
  grep -vE '^[^:]*:[0-9]+:[[:space:]]*--' |
  grep -vE '=[[:space:]]*80[[:space:]]*$')"
if [ -z "$textwidth" ]; then
  bad "could not read vim.opt.textwidth out of $OPTIONS at all — the comparison would be vacuous"
elif [ "$textwidth" != "80" ]; then
  bad "$OPTIONS sets textwidth = $textwidth, not 80, so prose stops wrapping where this repo writes it"
elif [ -n "$othertw" ]; then
  bad "options.lua sets textwidth = 80 and the lua config sets it to something else — the later write wins:"
  printf '%s\n' "$othertw" | sed 's/^/      /'
else
  ok "textwidth is 80 in options.lua and nothing in the lua config sets it to anything else"
fi

# One clipboard, and nothing later in the lua changing it back.
#
# Without unnamedplus a plain y lands in a register only this nvim can see, so
# the machine has one clipboard and nvim another -- the thing that was asked to
# stop. Same two halves as wrap and textwidth: the value in options.lua, and any
# later write anywhere under nvim/.config/nvim, because lua's last write wins.
# A write of "unnamedplus", double-quoted, is allowed, trailing comment or not;
# any other spelling of it is reported, which errs loud. What neither
# half can see is a plugin changing it at runtime, or a yank that does not
# actually reach pbcopy; tests/test-nvim.sh yanks and pastes in a running nvim
# against stand-in pbcopy and pbpaste for that.
clip="$(nvim_opt clipboard)"
otherclip="$(grep -rInE 'vim\.(opt|o|go|opt_global|opt_local)\.clipboard[[:space:]]*(=|:)|(set|setglobal|setlocal)[[:space:]]+clipboard' \
  nvim/.config/nvim --include='*.lua' |
  grep -vE '^[^:]*:[0-9]+:[[:space:]]*--' |
  grep -vE '=[[:space:]]*"unnamedplus"[[:space:]]*(--.*)?$')"
if [ -z "$clip" ]; then
  bad "could not read vim.opt.clipboard out of $OPTIONS at all — the comparison would be vacuous"
elif [ "$clip" != '"unnamedplus"' ]; then
  bad "$OPTIONS sets clipboard = $clip, not \"unnamedplus\", so a plain y stays in a register the rest of the machine cannot see"
elif [ -n "$otherclip" ]; then
  bad "options.lua sets clipboard = \"unnamedplus\" and the lua config changes it again — the later write wins:"
  printf '%s\n' "$otherclip" | sed 's/^/      /'
else
  ok "nvim uses the system clipboard (clipboard=unnamedplus) and nothing in the lua config changes it"
fi

# Every language server Mason installs is one lsp.lua starts, and the reverse.
#
# They are two lists in lsp.lua with nothing holding them together. A server
# added to vim.lsp.enable and not to ensure_installed works on this machine,
# where Mason already has it, and on a new one never attaches. A server added
# only to ensure_installed is downloaded on every machine and never runs:
# automatic_enable is off (asserted below), so nothing but the enable list
# starts one. Neither says so: the buffer just has no language server.
# rust_analyzer may be on the enable side alone, because it comes from rustup,
# not Mason.
#
# One vim.lsp.enable call, too: lua's last write wins, so a second one anywhere
# in the config -- vim.lsp.enable(name, false) turns a server off -- would make
# the list compared here not the whole story.
lsp_installed="$(lsp_list '/ensure_installed = {/,/}/')"
lsp_enabled="$(lsp_list '/vim\.lsp\.enable({/,/})/')"
lsp_calls="$(grep -rnE 'vim\.lsp\.enable\(' nvim/.config/nvim --include='*.lua' |
  grep -cvE '^[^:]*:[0-9]+:[[:space:]]*--')"
lsp_only_enabled="$(comm -13 <(printf '%s\n' "$lsp_installed") <(printf '%s\n' "$lsp_enabled") |
  grep -vx rust_analyzer | paste -sd, -)"
lsp_only_installed="$(comm -23 <(printf '%s\n' "$lsp_installed") <(printf '%s\n' "$lsp_enabled") |
  paste -sd, -)"
if [ -z "$lsp_installed" ] || [ -z "$lsp_enabled" ]; then
  bad "could not read ensure_installed or vim.lsp.enable out of $LSP — the comparison would be vacuous"
elif [ -n "$lsp_only_enabled" ]; then
  bad "$LSP starts $lsp_only_enabled but Mason never installs it, so on a new machine it never attaches"
elif [ -n "$lsp_only_installed" ]; then
  bad "Mason installs $lsp_only_installed but $LSP never starts it, so it is downloaded on every machine and never runs"
elif [ "${lsp_calls:-0}" -ne 1 ]; then
  bad "the nvim config calls vim.lsp.enable ${lsp_calls:-0} times, not once, so lsp.lua's list is not the whole story"
else
  ok "Mason installs every language server lsp.lua starts, and lsp.lua starts all $(printf '%s\n' "$lsp_installed" | grep -c .) it installs"
fi

# Nothing but that enable list starts a server: mason-lspconfig's
# automatic_enable is off, and nothing turns it back on.
#
# mason-lspconfig defaults it to on, and then runs vim.lsp.enable for every
# server Mason has installed, so the list compared above was not the whole
# story: a server installed from :Mason started with nothing here naming it.
# Its settings are merged across setup() calls, so the last value written is
# the one used, and a second assignment anywhere in the config -- another
# setup() call, a lazy opts table -- could be that one. So there must be
# exactly one, inside lsp.lua's setup() call, and it must be false: a table is
# mason-lspconfig's way of turning it on for some servers. tests/test-nvim.sh
# asks a running nvim which servers are enabled.
mlc_block="$(sed -n '/require("mason-lspconfig")\.setup({/,/^[[:space:]]*})/p' "$LSP" | grep -vE '^[[:space:]]*--')"
mlc_value="$(printf '%s\n' "$mlc_block" |
  sed -n 's/^[[:space:]]*automatic_enable[[:space:]]*=[[:space:]]*\([^,[:space:]]*\).*/\1/p')"
mlc_writes="$(grep -rnE 'automatic_enable[[:space:]]*=' nvim/.config/nvim --include='*.lua' |
  grep -cvE '^[^:]*:[0-9]+:[[:space:]]*--')"
if [ -z "$mlc_block" ]; then
  bad "could not find require(\"mason-lspconfig\").setup({ in $LSP — whether automatic_enable is off cannot be said"
elif [ -z "$mlc_value" ]; then
  bad "$LSP's mason-lspconfig setup() leaves automatic_enable out, so it defaults to on and every server Mason has installed starts, listed or not"
elif [ "$mlc_value" != false ]; then
  bad "$LSP sets automatic_enable = $mlc_value, not false, so servers Mason has installed start whether or not lsp.lua lists them"
elif [ "${mlc_writes:-0}" -ne 1 ]; then
  bad "the nvim config sets automatic_enable ${mlc_writes:-0} times, not once — mason-lspconfig keeps the last value written, so lsp.lua's false may not be it"
else
  ok "mason-lspconfig's automatic_enable is false, so only lsp.lua's enable list starts a language server"
fi

# A count on ]q [q ]d [d.
#
# Neovim's own versions of all four take one: 3]q moves three quickfix entries.
# This config replaces them -- to centre the line, and to open the diagnostic
# float -- and the replacements hard-coded one: a bare cnext under <Cmd>, and
# vim.diagnostic.jump({ count = 1 }). So 3]q moved one entry, and nothing said
# so, because a count is exactly the thing nobody types while testing a map.
#
# Every cnext, cprev and vim.diagnostic.jump in the lua config has to take the
# count, as v:count1 or vim.v.count1, on the same line. Comment lines are
# dropped, and so is a trailing comment, so that neither can supply the word.
# tests/test-nvim.sh presses 3]q and 3]d in a running nvim; this catches the
# literal coming back.
navs="$(grep -rnE 'cnext|cprev|vim\.diagnostic\.jump\(' nvim/.config/nvim --include='*.lua' |
  grep -vE '^[^:]*:[0-9]+:[[:space:]]*--' | sed 's/[[:space:]]--.*$//')"
navs_next="$(printf '%s\n' "$navs" | grep -c 'cnext')"
navs_prev="$(printf '%s\n' "$navs" | grep -c 'cprev')"
navs_jump="$(printf '%s\n' "$navs" | grep -c 'diagnostic\.jump')"
navs_all="$(printf '%s\n' "$navs" | grep -c .)"
uncounted="$(printf '%s\n' "$navs" | grep . | grep -vE 'v[:.]count1')"
if [ "${navs_next:-0}" -eq 0 ] || [ "${navs_prev:-0}" -eq 0 ] || [ "${navs_jump:-0}" -eq 0 ]; then
  bad "found no cnext, cprev or vim.diagnostic.jump in the lua config — ]q [q ]d [d have moved, and the count check would be vacuous"
elif [ -n "$uncounted" ]; then
  bad "quickfix or diagnostic jumps that ignore a count, so 3]q or 3]d moves one:"
  printf '%s\n' "$uncounted" | sed 's/^/      /'
else
  ok "]q [q ]d [d take a count: all $navs_all cnext, cprev and vim.diagnostic.jump calls use v:count1"
fi

section "tmux config"
# terminal-features is a list, `set -sa` appends to it, and prefix S sources
# the whole file again. With nothing resetting the list first, every reload
# added another copy of the line: nothing broke, and the list only grew. The
# reset has to come before the FIRST append, or it throws away the ones above.
#
# What tmux ends up declaring is what is appended after the LAST reset, because
# a reset or a plain `set` further down replaces everything before it -- the
# same last-write-wins shape as the checks above, so this reads the file the way
# tmux applies it rather than looking for a mention. sync, hyperlinks and
# overline are things WezTerm draws and tmux drops unless they are declared:
# whole-frame redraws, OSC 8 links, SGR 53.
tf_state="$(awk '
  /^[[:space:]]*set(-option)?[[:space:]]+-[A-Za-z]+[[:space:]]+terminal-features([[:space:]]|$)/ {
    line = $0
    sub(/[[:space:]]#.*/, "", line)
    if ($2 ~ /a/) {
      if (!first_append) first_append = NR
      feats = feats " " line
    } else {
      if (!first_reset) first_reset = NR
      feats = ($2 ~ /u/) ? "" : line
    }
  }
  END {
    gsub(/[,:"\047]/, " ", feats)
    print first_reset + 0, first_append + 0, feats
  }
' "$TMUXCONF")"
read -r tf_reset tf_append tf_feats <<<"$tf_state"
case "$tf_reset" in '' | *[!0-9]*) tf_reset=0 ;; esac
case "$tf_append" in '' | *[!0-9]*) tf_append=0 ;; esac
if [ "$tf_append" -eq 0 ]; then
  bad "found no 'set -sa terminal-features' line — nothing declares what the outer terminal can do, and this check has nothing to read"
elif [ "$tf_reset" -eq 0 ]; then
  bad "terminal-features is appended to with no 'set -su terminal-features' before it — every prefix S adds another copy of the list"
elif [ "$tf_reset" -gt "$tf_append" ]; then
  bad "the terminal-features reset (line $tf_reset) comes after the first append (line $tf_append), so it throws that append away"
else
  ok "terminal-features is reset before it is appended to, so a reload does not add another copy"
fi
# usstyle is read from that same list, and so is extkeys in the restore check
# below. Both used to be a grep for any set line naming them, which stayed
# green with a reset under that line and tmux holding neither. The grep was
# itself a fix: tmux.conf's comment explains what usstyle is, so a bare
# `grep usstyle` stayed green after the setting was removed. The awk above
# reads set lines only, and strips their trailing comments.
case " $tf_feats " in
  *" usstyle "*) ok "terminal-features declares usstyle (undercurl survives)" ;;
  *) bad "terminal-features does not end up declaring usstyle — nvim's diagnostic undercurls are stripped" ;;
esac
tf_missing=""
for f in sync hyperlinks overline; do
  case " $tf_feats " in
    *" $f "*) ;;
    *) tf_missing="$tf_missing $f" ;;
  esac
done
if [ -n "$tf_missing" ]; then
  bad "terminal-features does not end up declaring${tf_missing} — tmux strips those before they reach WezTerm"
else
  ok "terminal-features declares sync, hyperlinks and overline, so redraws arrive whole and links stay links"
fi

# Restore must not sit where a held Ctrl puts it, and the key it moved to has to
# be a key the terminal can actually send.
#
# The prefix is C-a. Holding Ctrl through the next keystroke turns `prefix r`
# (rename-window) into `prefix C-r`, which is resurrect's DEFAULT restore key —
# so leaving @resurrect-restore unset means an accidental full session restore
# while renaming a window. That is the defect this asserts against.
#
# The second half is the one that would rot silently. C-S-r and C-r are the same
# byte in a traditional terminal; they are only distinct when tmux asks for
# extended key reporting -- xterm's modifyOtherKeys, here (extended-keys) -- AND
# believes the terminal can do it (the extkeys terminal-feature). Drop either
# and the binding still READS correct while becoming unreachable — the config
# would claim a key that cannot be pressed. So any Shift-bearing restore key
# requires both.
#
# Both are read the way tmux applies them. extended-keys is the LAST line that
# sets it, so a later `set -s extended-keys off` counts; extkeys comes from the
# features appended after the last terminal-features reset, as above. Counting
# lines that mention either, which this did, stayed green with tmux holding
# neither.
restore_key="$(tmux_setting '@resurrect-restore')"
ext_keys="$(grep -E '^[[:space:]]*set(-option)?([[:space:]]+-[A-Za-z]+)*[[:space:]]+extended-keys([[:space:]]|$)' "$TMUXCONF" |
  tail -1 | sed 's/[[:space:]]#.*//' |
  awk '{ for (i = 1; i < NF; i++) if ($i == "extended-keys") { v = $(i + 1); gsub(/["\047]/, "", v); print v; exit } }')"
ext_on=0
case "$ext_keys" in on | always) ext_on=1 ;; esac
ext_feat=0
case " $tf_feats " in *" extkeys "*) ext_feat=1 ;; esac
needs_ext=no
case "$restore_key" in
  *-S-*) needs_ext=yes ;;
esac
if [ -z "$restore_key" ]; then
  bad "tmux.conf never sets @resurrect-restore, so restore keeps resurrect's C-r default — one held Ctrl away from 'prefix r' (rename-window)"
elif [ "$restore_key" = "C-r" ]; then
  bad "@resurrect-restore is C-r, which is exactly what a held Ctrl turns 'prefix r' into"
elif [ "$needs_ext" = yes ] && [ "$ext_on" -eq 0 ]; then
  bad "@resurrect-restore is '$restore_key', but extended-keys does not end up on (last value: '${ext_keys:-unset}') — without it that is the same byte as the plain-Ctrl key and the binding is unreachable"
elif [ "$needs_ext" = yes ] && [ "$ext_feat" -eq 0 ]; then
  bad "@resurrect-restore is '$restore_key', but terminal-features does not end up declaring extkeys — tmux will not ask the terminal for the sequence that makes it distinct"
else
  ok "restore is bound to '$restore_key', off the held-Ctrl path, with the extended-keys support that makes it a key the terminal can send"
fi

# One clipboard, from tmux's side.
#
# copy-command is what every argument-less copy-pipe runs -- y here, and tmux's
# own Enter and mouse-drag bindings, which this file never names. Unset, those
# copies stay in tmux's buffer unless the terminal happens to act on OSC 52. A
# command written after y's copy-pipe-and-cancel overrides it for that key, so y
# has to be bare. And tmux's default prefix+] pastes its OWN newest buffer, so
# text copied in a browser never comes out of it; the binding has to read
# pbpaste. tests/test-bindings.sh presses y and ] against stand-ins.
#
# The LAST of each is read, not the first: tmux applies a file top to bottom,
# so a later copy-command or rebinding is the one that counts -- the same
# last-write-wins shape the nvim checks above guard against. A copy-command
# written with double quotes reads back as the whole line and fails, rather than
# passing on a value nobody extracted.
copy_cmd="$(grep -E '^[[:space:]]*set .*copy-command ' "$TMUXCONF" | tail -1 |
  sed "s/.*copy-command '\([^']*\)'[[:space:]]*\(#.*\)*$/\1/")"
y_line="$(grep -E '^[[:space:]]*bind(-key)?[[:space:]]+-T[[:space:]]+copy-mode-vi[[:space:]]+y[[:space:]]' "$TMUXCONF" | tail -1)"
paste_line="$(grep -E '^[[:space:]]*bind(-key)?[[:space:]]+\][[:space:]]' "$TMUXCONF" | tail -1)"
y_bare=0
if printf '%s\n' "$y_line" |
  grep -E '^[[:space:]]*bind(-key)?[[:space:]]+-T[[:space:]]+copy-mode-vi[[:space:]]+y[[:space:]]+send-keys[[:space:]]+-X[[:space:]]+copy-pipe-and-cancel[[:space:]]*(#.*)?$' >/dev/null; then
  y_bare=1
fi
if [ -z "$copy_cmd" ]; then
  bad "tmux.conf never sets copy-command — Enter and a mouse drag copy into tmux's own buffer, not the system clipboard"
elif [ "$copy_cmd" != "pbcopy" ]; then
  bad "tmux.conf sets copy-command '$copy_cmd', not 'pbcopy' — a tmux copy does not reach the system clipboard"
elif [ "$y_bare" -eq 0 ]; then
  bad "copy-mode-vi y is not a bare copy-pipe-and-cancel — a command after it overrides copy-command for y"
elif [ -z "$paste_line" ]; then
  bad "nothing binds prefix ], so it pastes tmux's own newest buffer instead of the system clipboard"
else
  case "$paste_line" in
    *pbpaste*) ok "tmux copies to and pastes from the system clipboard (copy-command pbcopy, a bare y, prefix ] reads pbpaste)" ;;
    *) bad "prefix ] is bound but never reads pbpaste, so it pastes something other than the system clipboard" ;;
  esac
fi

# Continuum has no timer. It appends `#(continuum_save.sh)` to status-right and
# relies on tmux running that command every time it draws the status line. So if
# `set -g status-right` ever moves BELOW the line that runs tpm, it overwrites
# continuum's addition, every automatic save stops, and there is no error and no
# missing file to notice — the save directory just quietly stops growing.
#
# Line numbers, because ordering is the whole point.
sr_line="$(grep -n '^[[:space:]]*set .*status-right' tmux/.config/tmux/tmux.conf | head -1 | cut -d: -f1)"
tpm_line="$(grep -n "^[[:space:]]*run .*tpm" tmux/.config/tmux/tmux.conf | tail -1 | cut -d: -f1)"
if [ -z "$sr_line" ] || [ -z "$tpm_line" ]; then
  meh "could not locate both status-right and the tpm run line; skipping the ordering check"
elif [ "$sr_line" -lt "$tpm_line" ]; then
  ok "status-right is set before tpm runs, so continuum's auto-save survives"
else
  bad "status-right (line $sr_line) is set AFTER tpm (line $tpm_line) — it overwrites continuum's #() and auto-save silently stops"
fi

# tpm has to load in the background. In the foreground the first session is not
# created until every plugin's .tmux script has run, so a new WezTerm window
# shows nothing for that long and prefix S blocks for as long again — slow, and
# nothing ever says why.
#
# EVERY line that runs tpm is read, not just the last: tmux applies them all,
# top to bottom, so one in the foreground anywhere in the file is a wait however
# many backgrounded ones follow it. And finding none at all fails rather than
# passing, because then this asserted nothing.
tpm_runs="$(grep -cE '^[[:space:]]*run(-shell)?[[:space:]].*plugins/tpm/tpm' "$TMUXCONF")"
tpm_fg="$(grep -E '^[[:space:]]*run(-shell)?[[:space:]].*plugins/tpm/tpm' "$TMUXCONF" |
  grep -cvE '^[[:space:]]*run(-shell)?[[:space:]]+-[A-Za-z]*b[A-Za-z]*[[:space:]]')"
case "$tpm_runs" in '' | *[!0-9]*) tpm_runs=0 ;; esac
case "$tpm_fg" in '' | *[!0-9]*) tpm_fg=1 ;; esac
if [ "$tpm_runs" -eq 0 ]; then
  bad "found no line in tmux.conf that runs tpm — the plugins never load, and whether they would wait cannot be read"
elif [ "$tpm_fg" -gt 0 ]; then
  bad "tmux.conf runs tpm without -b — every new server and every prefix S waits for all the plugins to load"
else
  ok "tpm loads in the background (run -b), so a new session does not wait for the plugins"
fi

# Every key tmux.conf binds is either pressed by tests/test-bindings.sh or
# listed there as deliberately not driven, with a reason.
#
# That accounting lived in the suite and compared COUNTS: eleven driven plus ten
# undriven against twenty-one `bind` lines. Rename `bind w` to `bind W` and both
# numbers are still twenty-one, so a key could drop out of the accounting and
# come back as a different one without a word. Compare the sets — and do it
# here, because it is a fact about two files and needs no terminal to find out.
driven="$(sed -n 's/^driven="\(.*\)"$/\1/p' tests/test-bindings.sh)"
undriven="$(sed -n 's/^undriven="\(.*\)"$/\1/p' tests/test-bindings.sh)"
bound_keys="$(tmux_bound_keys | sort -u)"
if [ -z "$driven" ] || [ -z "$undriven" ] || [ -z "$bound_keys" ]; then
  bad "could not read the driven/undriven lists or tmux.conf's bindings — the comparison would be vacuous"
else
  accounted="$(printf '%s %s' "$driven" "$undriven" | tr ' ' '\n' | grep -v '^$' | sort -u)"
  unaccounted="$(comm -23 <(printf '%s\n' "$bound_keys") <(printf '%s\n' "$accounted") | tr '\n' ' ')"
  phantom="$(comm -13 <(printf '%s\n' "$bound_keys") <(printf '%s\n' "$accounted") | tr '\n' ' ')"
  if [ -z "$unaccounted" ] && [ -z "$phantom" ]; then
    ok "every key tmux.conf binds is pressed or explained in test-bindings.sh"
  else
    [ -n "$unaccounted" ] && bad "tmux.conf binds ${unaccounted}— test-bindings.sh neither presses nor explains them"
    [ -n "$phantom" ] && bad "test-bindings.sh accounts for ${phantom}— which tmux.conf does not bind"
  fi
fi

section "Constants kept in step"
# Two pairs of numbers were held together by a comment asking a person to
# remember. tmux-resurrect-saves says "Keep in step with
# @resurrect-guard-min-windows in tmux.conf"; tmux.conf says its retention
# window is "Kept in step with tmux-resurrect-saves' KEEP_DAILY_DAYS". Both
# pairs agreed. Nothing made them.
#
# WHAT DIVERGENCE COSTS, which is why these are asserted rather than trusted.
# Move the guard's floor without the script's and the guard vetoes at a
# threshold prune does not share: prune then keeps saves the guard will never
# let become `last`, and deletes ones it would have. Move one retention window
# and resurrect's own backup deletion fights prune's policy. Either way the
# first symptom is a save that is gone when you need it, which is the worst
# imaginable moment to discover a comment went stale.
#
# The guard's own defaults are in here too. They only take effect when tmux.conf
# does not set the option — which is exactly when a divergence would be silent,
# because nothing looks wrong until the line is deleted. Its header documents
# each default in prose as well, so every one of these numbers is written down
# three or four times.
agree() { # $1 = what the value is, $2... = "where=value"
  local what="$1"
  shift
  local n=$#
  local first="" first_where="" pair where value broken=0
  for pair in "$@"; do
    where="${pair%%=*}"
    value="${pair#*=}"
    case "$value" in
      '' | *[[:space:]]*)
        bad "could not read $what out of $where — the comparison would be vacuous"
        broken=1
        continue
        ;;
    esac
    if [ -z "$first_where" ]; then
      first="$value"
      first_where="$where"
    elif [ "$value" != "$first" ]; then
      bad "$what: $first_where says '$first' but $where says '$value' — nothing but a comment held those together"
      broken=1
    fi
  done
  [ "$broken" -eq 0 ] && ok "$what is '$first' in all $n places that write it down"
}

agree "the guard's minimum window count" \
  "tmux.conf=$(tmux_setting @resurrect-guard-min-windows)" \
  "the guard's own default=$(guard_default @resurrect-guard-min-windows)" \
  "the guard's header=$(guard_doc_default @resurrect-guard-min-windows)" \
  "tmux-resurrect-saves MIN_WINDOWS=$(sh_default "$SAVES" MIN_WINDOWS)"

agree "the retention window in days" \
  "tmux.conf @resurrect-delete-backup-after=$(tmux_setting @resurrect-delete-backup-after)" \
  "tmux-resurrect-saves KEEP_DAILY_DAYS=$(sh_default "$SAVES" KEEP_DAILY_DAYS)"

agree "the guard's collapse percentage" \
  "tmux.conf=$(tmux_setting @resurrect-guard-collapse-pct)" \
  "the guard's own default=$(guard_default @resurrect-guard-collapse-pct)" \
  "the guard's header=$(guard_doc_default @resurrect-guard-collapse-pct)"

agree "whether the guard is on by default" \
  "tmux.conf=$(tmux_setting @resurrect-guard)" \
  "the guard's own default=$(guard_default @resurrect-guard)" \
  "the guard's header=$(guard_doc_default @resurrect-guard)"

agree "whether the guard announces its vetoes" \
  "tmux.conf=$(tmux_setting @resurrect-guard-notify)" \
  "the guard's own default=$(guard_default @resurrect-guard-notify)" \
  "the guard's header=$(guard_doc_default @resurrect-guard-notify)"

# Same shape, inside one file: the header says how far guard.log is trimmed, and
# two lines of code do the trimming. A header describing its own file is no more
# self-maintaining than one describing a different file.
# shellcheck disable=SC2016  # $lines and $logfile are text in the guard, not here
agree "how many lines guard.log is trimmed to" \
  "the guard's header=$(sed -n 's/.*trimmed to \([0-9][0-9]*\) lines.*/\1/p' "$GUARD" | head -1)" \
  "its length test=$(sed -n 's/.*"\$lines" -gt \([0-9][0-9]*\).*/\1/p' "$GUARD" | head -1)" \
  "the tail that trims it=$(sed -n 's/.*tail -n \([0-9][0-9]*\) "\$logfile".*/\1/p' "$GUARD" | head -1)"

# The stow package set is written by hand in six places, and the first version
# of this check knew about four of them — which is the defect it exists to catch,
# committed inside the fix for it. So the copies are FOUND rather than listed: a
# line counts as one when it names four or more of the packages, which no prose
# here does, and every copy must name exactly the set `make stow` uses.
#
# Miss a copy when adding a package and the symptom is silent: check.sh's
# "every package is stowed" quietly stops covering it, so new files in that
# package never go live and nothing says so.
#
# tests/test-check.sh is skipped. Its job is to hold deliberately broken copies
# of things, and a mutation that shortens this list is test data, not drift.
pkg_set() { # $1 = whitespace-separated package names
  printf '%s' "$1" | tr ' ' '\n' | grep -v '^$' | grep -vE '^(git|gitconfig)$' | sort -u | paste -sd, -
}
pkg_ref="$(pkg_set "$(sed -n '/^stow:/,/^$/p' Makefile | grep -m1 'PKGS=' | sed 's/.*PKGS="\([^"]*\)".*/\1/')")"
if [ -z "$pkg_ref" ]; then
  bad "could not read the package list out of the Makefile — every copy would compare against nothing"
else
  pkg_words="$(printf '%s' "$pkg_ref" | tr ',' ' ')"
  # A copy is a RUN of package names with nothing between them. Counting names
  # anywhere on the line is not enough: checks/machine.sh's tool loop happens to
  # name four of the six, interleaved with rg, fd and stow, and was reported as
  # a package list that had lost two entries.
  # shellcheck disable=SC2016  # $0 and $... below are awk's, not the shell's
  pkg_hits="$(git ls-files | grep -v '^tests/test-check.sh$' | tr '\n' '\0' |
    xargs -0 awk -v names=" $pkg_words " '
      {
        line = $0
        gsub(/[^A-Za-z0-9_-]/, " ", line)
        n = split(line, tok, " ")
        run = ""; best = ""; runlen = 0; bestlen = 0
        for (i = 1; i <= n; i++) {
          if (tok[i] != "" && index(names, " " tok[i] " ") > 0) {
            run = run " " tok[i]
            runlen++
            if (runlen > bestlen) { best = run; bestlen = runlen }
          } else {
            run = ""
            runlen = 0
          }
        }
        if (bestlen >= 4) print FILENAME "\t" best
      }')"
  pkg_copies=0
  pkg_bad=0
  while IFS="$(printf '\t')" read -r f run; do
    [ -n "$f" ] || continue
    pkg_copies=$((pkg_copies + 1))
    if [ "$(pkg_set "$run")" != "$pkg_ref" ]; then
      bad "$f lists the stow packages as '$(pkg_set "$run")', and 'make stow' uses '$pkg_ref'"
      pkg_bad=$((pkg_bad + 1))
    fi
  done <<<"$pkg_hits"
  if [ "$pkg_copies" -lt 2 ]; then
    bad "found $pkg_copies place(s) listing the stow packages — there are several, so the scan has broken"
  elif [ "$pkg_bad" -eq 0 ]; then
    ok "all $pkg_copies copies of the stow package list agree ($pkg_ref)"
  fi
fi

# A comment that quotes a line of another file is a copy, and copies drift. The
# guard's header quotes the two tmux.conf lines that wire it up — the most
# useful thing in that header, and the easiest to leave behind when the wiring
# changes.
quoted_bad=0
quoted_seen=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  quoted_seen=$((quoted_seen + 1))
  grep -qxF "$line" "$TMUXCONF" || {
    bad "a comment quotes \"$line\" as tmux.conf's wiring, and tmux.conf has no such line"
    quoted_bad=$((quoted_bad + 1))
  }
done < <(git ls-files | grep -vxF "$TMUXCONF" |
  xargs grep -h -E '^#[[:space:]]+set(-option)? -g @' 2>/dev/null | sed 's/^#[[:space:]]*//')
if [ "$quoted_seen" -eq 0 ]; then
  meh "no comment quotes a tmux.conf line, so there was nothing to compare"
elif [ "$quoted_bad" -eq 0 ]; then
  ok "every tmux.conf line a comment quotes ($quoted_seen of them) is really in tmux.conf"
fi

# shfmt's flags are written twice: once in the Makefile's lint recipe, once in
# conform.lua for format-on-save. If they differ, saving a script in nvim and
# linting it disagree, and the file you just saved fails `make lint`.
#
# They did differ, without either copy changing: conform.lua passed its flags
# as prepend_args, and conform's own shfmt args append `-i <shiftwidth>` after
# them whenever no .editorconfig is found. shfmt takes the last -i, shiftwidth
# is 4, so every save re-indented to 4 while both files read `-i 2 -ci`. That
# is why prepend_args is rejected outright rather than compared: the strings in
# it are not the flags shfmt ends up with.
#
# The block ends at the first line that is only `},`, so a multi-line table
# nested ahead of `args` would end it early; that reads as empty and fails,
# rather than passing.
#
# Nor is conform.lua's block the only place shfmt can be configured. lazy
# deep-merges the opts of every spec for a plugin, so a second conform spec
# anywhere in the config that says ["shfmt"] = { append_args = { "-i", "4" } }
# lands inside this block at runtime: args stay ours, -i 4 goes after them, and
# a save re-indents to 4 while this block still reads -i 2. A plain assignment
# replaces the block instead, and either way which wins depends on load order,
# not on anything this can read. So every definition of shfmt in the lua config
# is counted -- a bare key, a bracketed one with either quote, an assignment to
# formatters.shfmt, or to a field of shfmt -- and more than one fails, as does
# a scan that cannot find conform.lua's own. Inside each, prepend_args and
# append_args fail too, wherever it is.
CONFORM="nvim/.config/nvim/lua/rich/plugins/conform.lua"
lint_shfmt="$(awk '
  /^lint:/ { inside = 1; next }
  inside && !/^\t/ { inside = 0 }
  inside {
    for (i = 1; i <= NF; i++) {
      if ($i != "shfmt") continue
      out = ""
      for (j = i + 1; j <= NF && $j !~ /^\$/; j++) {
        if ($j != "-d") out = out (out == "" ? "" : " ") $j
      }
      print out
    }
  }' Makefile | sort -u)"
# The awk follows each definition from where it matches to its closing brace,
# and reports any prepend_args or append_args on the way. Whole-line comments
# are skipped and trailing ones cut, since conform.lua's own comment names
# prepend_args.
shfmt_def="(^|[^A-Za-z_.\"'])shfmt[[:space:]]*=[[:space:]]*\\{"
shfmt_def="$shfmt_def|\\[[[:space:]]*[\"']shfmt[\"'][[:space:]]*\\][[:space:]]*=([^=]|\$)"
shfmt_def="$shfmt_def|formatters\\.shfmt[[:space:]]*=([^=]|\$)"
shfmt_def="$shfmt_def|(\\.shfmt|\\[[[:space:]]*[\"']shfmt[\"'][[:space:]]*\\])(\\.[A-Za-z_]+|\\[[^]]*\\])+[[:space:]]*=([^=]|\$)"
# shellcheck disable=SC2016  # $0 is awk's record, not the shell's
shfmt_scan="$(find nvim/.config/nvim -name '*.lua' | sort |
  SHFMT_DEF="$shfmt_def" xargs awk '
    FNR == 1 { depth = 0 }
    /^[[:space:]]*--/ { next }
    {
      line = $0
      sub(/[[:space:]]--.*$/, "", line)
      if (depth == 0) {
        if (!match(line, ENVIRON["SHFMT_DEF"])) next
        print "def " FILENAME ":" FNR ":" $0
        line = substr(line, RSTART)
      }
      if (line ~ /(prepend|append)_args/) print "extra " FILENAME ":" FNR ":" $0
      t = line
      depth += gsub(/\{/, "", t)
      t = line
      depth -= gsub(/\}/, "", t)
      if (depth < 0) depth = 0
    }')"
shfmt_defs="$(printf '%s\n' "$shfmt_scan" | sed -n 's/^def //p')"
shfmt_extra="$(printf '%s\n' "$shfmt_scan" | sed -n 's/^extra //p')"
shfmt_ndefs="$(printf '%s\n' "$shfmt_defs" | grep -c .)"
shfmt_block="$(sed -n '/^[[:space:]]*shfmt[[:space:]]*=[[:space:]]*{/,/^[[:space:]]*},/p' "$CONFORM")"
# shellcheck disable=SC2016  # $FILENAME is conform's placeholder, not the shell's
conform_shfmt="$(printf '%s\n' "$shfmt_block" |
  grep -E '^[[:space:]]*(prepend_|append_)?args[[:space:]]*=' |
  grep -oE '"[^"]*"' | tr -d '"' |
  grep -vxE -- '-filename|\$FILENAME' | paste -sd' ' -)"
if [ -n "$shfmt_extra" ]; then
  bad "shfmt is given prepend_args or append_args — conform splices those around args from elsewhere (its own end in -i <shiftwidth>), shfmt takes the last -i, so they are not the flags a save runs with:"
  printf '%s\n' "$shfmt_extra" | sed 's/^/      /'
elif [ "${shfmt_ndefs:-0}" -gt 1 ]; then
  bad "conform's shfmt formatter is configured in $shfmt_ndefs places — lazy merges a second spec into the first, an assignment replaces it, and load order decides:"
  printf '%s\n' "$shfmt_defs" | sed 's/^/      /'
elif [ "${shfmt_defs%%:*}" != "$CONFORM" ]; then
  bad "the scan for shfmt definitions did not find the one in $CONFORM — it has gone blind, and would count a second one as none"
elif [ -z "$lint_shfmt" ] || [ -z "$conform_shfmt" ]; then
  bad "could not read shfmt's flags out of the Makefile's lint recipe or $CONFORM's args — the comparison would be vacuous"
elif [ "$lint_shfmt" != "$conform_shfmt" ]; then
  bad "'make lint' runs shfmt $lint_shfmt but format-on-save runs shfmt $conform_shfmt — a script saved in nvim fails lint"
else
  ok "format-on-save and 'make lint' run shfmt with the same flags ($lint_shfmt), and conform adds none of its own"
fi

section "Shell"
if command -v zsh >/dev/null 2>&1; then
  if zsh -n zsh/.zshrc 2>/dev/null; then ok ".zshrc parses"; else bad ".zshrc has a syntax error"; fi
else
  meh "zsh not installed, cannot parse .zshrc"
fi

# The (#q...) glob qualifier silently does nothing without EXTENDED_GLOB, which
# made the completion cache unreachable and cost a full compinit every shell.
# Anchored to the setopt line for the same reason as usstyle above.
if grep -q '(#q' zsh/.zshrc; then
  if grep -qE '^[[:space:]]*setopt[^#]*extendedglob' zsh/.zshrc; then
    ok ".zshrc enables extendedglob where it uses (#q...) qualifiers"
  else
    bad ".zshrc uses (#q...) without extendedglob — those tests silently never match"
  fi
fi

# The .zshrc.local block is the last thing .zshrc runs, because whatever runs
# last sets the $? the first prompt shows. Anything appended after it -- an
# installer's `[ -s file ] && source file` line is the usual shape, and envman's
# went in here exactly that way -- leaves $? at 1 wherever its file is missing,
# so starship draws its red error character before a single command has run.
# Per-machine lines belong in ~/.zshrc.local itself. Comments and blank lines
# after the block are fine; code is not.
zshrc_tail="$(grep -vE '^[[:space:]]*(#|$)' zsh/.zshrc 2>/dev/null | tail -n 3 | paste -sd'|' -)"
# shellcheck disable=SC2016  # $HOME is text to match in .zshrc, not expanded here
if [ -z "$zshrc_tail" ]; then
  bad "could not read the end of zsh/.zshrc — whether the .zshrc.local block is last cannot be said"
elif [ "$zshrc_tail" != 'if [[ -f "$HOME/.zshrc.local" ]]; then|  source "$HOME/.zshrc.local"|fi' ]; then
  bad ".zshrc runs code after its .zshrc.local block, so the first prompt can open on a failed status — put per-machine lines in ~/.zshrc.local"
else
  ok ".zshrc ends with its .zshrc.local block, so the first prompt opens on a clean status"
fi

# .zshrc writes out what `brew shellenv` prints rather than running it. Running
# it cost a bash process on every shell, and it prints nothing at all when PATH
# already starts with brew's bin and sbin, so a shell handed such a PATH never
# got HOMEBREW_PREFIX and loaded neither plugin. tests/test-zshrc.sh proves the
# block sets what brew would; this catches the eval coming back. Comment lines
# are dropped, because the block's own comment names what it replaced.
zshrc_code="$(grep -vE '^[[:space:]]*#' zsh/.zshrc 2>/dev/null)"
if [ -z "$zshrc_code" ]; then
  bad "could not read any code out of zsh/.zshrc — the shellenv check would be vacuous"
elif grep -qE 'shellenv' <<<"$zshrc_code"; then
  bad ".zshrc runs brew shellenv — a bash process on every shell, and no HOMEBREW_PREFIX at all when PATH already starts with brew's bin"
else
  ok ".zshrc sets Homebrew's environment itself rather than running brew shellenv on every shell"
fi

# zle starts in vi mode when $EDITOR or $VISUAL mentions vi, and .zshrc exports
# EDITOR=nvim, so with no keymap chosen every shell started from a shell came up
# in vi insert mode while a fresh terminal did not. The choice has to come
# before compinit, which binds its ^X keys into whichever keymap is current,
# and the last one in the file is the one that holds.
keymap="$(awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*bindkey[[:space:]]+(-e|-v|-A[[:space:]])/ {
    sub(/#.*/, ""); gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, "")
    last = NR ":" $0
  }
  END { print last }
' zsh/.zshrc 2>/dev/null)"
keymap_at="${keymap%%:*}"
compinit_at="$(grep -m1 -nE '^[[:space:]]*compinit([[:space:]]|$)' zsh/.zshrc 2>/dev/null | cut -d: -f1)"
if [ -z "$keymap" ]; then
  bad ".zshrc chooses no keymap — a shell that inherits EDITOR=nvim starts in vi insert mode"
elif [ -z "$compinit_at" ]; then
  bad "could not find where .zshrc runs compinit — the keymap ordering check would be vacuous"
elif [ "${keymap#*:}" != "bindkey -e" ]; then
  bad ".zshrc's last keymap choice is '${keymap#*:}', not 'bindkey -e' (line $keymap_at)"
elif [ "$keymap_at" -ge "$compinit_at" ]; then
  bad "bindkey -e (line $keymap_at) comes after compinit (line $compinit_at) — compinit's ^X keys land in the keymap EDITOR picked"
else
  ok ".zshrc pins the emacs keymap before compinit, whatever EDITOR a shell inherits"
fi

# Without interactive_comments, a command pasted from the README with its
# trailing comment runs the comment as arguments. Read as zsh reads option
# names -- any case, underscores ignored, "no" negates -- and the last setopt
# or unsetopt that names it is the one that holds.
comments="$(awk '
  /^[[:space:]]*#/ { next }
  $1 == "setopt" || $1 == "unsetopt" {
    for (i = 2; i <= NF; i++) {
      if ($i ~ /^#/) break
      o = tolower($i); gsub(/_/, "", o)
      on = ($1 == "setopt")
      if (o ~ /^no/) { o = substr(o, 3); on = !on }
      if (o == "interactivecomments") state = (on ? "on" : "off") ":" NR
    }
  }
  END { print state }
' zsh/.zshrc 2>/dev/null)"
case "$comments" in
  on:*) ok ".zshrc sets interactive_comments, so a pasted command's trailing # comment stays a comment" ;;
  off:*) bad ".zshrc turns interactive_comments off again at line ${comments#*:} — a pasted # comment becomes arguments" ;;
  *) bad ".zshrc never sets interactive_comments — a pasted # comment becomes arguments" ;;
esac

# starship's init sets RPROMPT to a `starship prompt --right` run before every
# prompt, and draws nothing with it unless starship.toml has a right_format.
# .zshrc clears RPROMPT after the init when there is none, so the two files
# have to agree. Only a top-level right_format counts: under a [table] header
# the key belongs to that module. The last RPROMPT assignment is the one that
# holds.
#
# A line inside a """ or ''' string is text, neither key nor header. Every
# starship preset writes format as one, with lines that open with
# [text](style); taking those for a header stopped the reader above a
# right_format it never saw, and the check passed while RPROMPT='' hid a right
# prompt starship really drew. Comment lines are skipped before the quotes are
# counted, so a comment that mentions """ cannot open a string either.
STARSHIP_TOML="starship/.config/starship.toml"
right_format="$(awk '
  BEGIN { sq = sprintf("%c", 39) }
  !in_str && /^[[:space:]]*#/ { next }
  {
    was_in = in_str
    s = $0
    while (1) {
      if (in_str) {
        p = index(s, delim)
        if (!p) break
        in_str = 0
      } else {
        p = index(s, "\"\"\""); q = index(s, sq sq sq)
        if (q && (!p || q < p)) { p = q; delim = sq sq sq }
        else if (p) delim = "\"\"\""
        else break
        in_str = 1
      }
      s = substr(s, p + 3)
    }
    if (was_in) next
  }
  /^[[:space:]]*\[/ { exit }
  /^[[:space:]]*right_format[[:space:]]*=/ { print NR }
' "$STARSHIP_TOML" 2>/dev/null)"
starship_init_at="$(grep -m1 -nE '^[^#]*starship init zsh' zsh/.zshrc 2>/dev/null | cut -d: -f1)"
rprompt="$(awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*(export[[:space:]]+)?RPROMPT=/ {
    v = $0; sub(/^[[:space:]]*(export[[:space:]]+)?RPROMPT=/, "", v)
    sub(/[[:space:]]*(#.*)?$/, "", v)
    last = NR ":" v
  }
  END { print last }
' zsh/.zshrc 2>/dev/null)"
rprompt_at="${rprompt%%:*}"
rprompt_val="${rprompt#*:}"
if [ ! -s "$STARSHIP_TOML" ]; then
  bad "could not read $STARSHIP_TOML — the RPROMPT check would be vacuous"
elif [ -z "$starship_init_at" ]; then
  bad "could not find starship init in .zshrc — the RPROMPT check would be vacuous"
elif [ -n "$right_format" ]; then
  if [ -n "$rprompt" ] && [ "$rprompt_at" -gt "$starship_init_at" ]; then
    bad "starship.toml sets right_format (line $right_format) but .zshrc replaces RPROMPT after starship init (line $rprompt_at) — starship's right prompt never draws"
  else
    ok "starship.toml has a right_format, and .zshrc leaves starship's RPROMPT alone"
  fi
elif [ -z "$rprompt" ]; then
  bad "starship.toml has no right_format, and .zshrc never clears RPROMPT — every prompt forks a starship that draws nothing"
elif [ "$rprompt_at" -le "$starship_init_at" ]; then
  bad ".zshrc clears RPROMPT (line $rprompt_at) before starship init (line $starship_init_at), which sets it again"
else
  case "$rprompt_val" in
    "''" | '""' | "")
      ok ".zshrc clears RPROMPT after starship init, as starship.toml has no right_format"
      ;;
    *)
      bad ".zshrc's last RPROMPT assignment (line $rprompt_at) is $rprompt_val, not '' — starship.toml has no right_format"
      ;;
  esac
fi

section "Known shell traps"
# A pipeline ending in a quiet grep, under `set -o pipefail`: grep exits on the
# first match, the producer takes SIGPIPE, and the pipeline reports FAILURE even
# though the pattern matched. Four separate false results in this repo came from
# it, including a check reporting a present colour scheme as missing.
hazard=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if ! grep -qE '^[[:space:]]*set .*pipefail' "$f" 2>/dev/null &&
    ! grep -qE '^[[:space:]]*\.[[:space:]].*lib\.sh' "$f" 2>/dev/null; then
    continue
  fi
  # Comments stripped first: a doc comment describing the hazard is not the
  # hazard, and counting it would make this check cry wolf about itself.
  n="$(sed 's/#.*//' "$f" | grep -cE '\|[[:space:]]*grep[[:space:]]+-q')"
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  if [ "$n" -gt 0 ]; then
    bad "$f: $n pipeline(s) into a quiet grep under pipefail — SIGPIPE reports failure on a MATCH"
    hazard=$((hazard + n))
  fi
done < <(git ls-files '*.sh' 'tmux/.local/bin/*' 2>/dev/null)
[ "$hazard" -eq 0 ] && ok "no pipeline into a quiet grep under pipefail anywhere in the repo"

# Sourcing a script that sets -e imports it. tests/lib.sh deliberately does not;
# under -e a failing assertion aborts the suite instead of reporting FAIL, and
# the run goes quiet looking exactly like a normal finish.
if grep -qE '^[[:space:]]*set -[a-z]*e' tests/lib.sh 2>/dev/null; then
  bad "tests/lib.sh sets -e — a failing assertion would abort the suite instead of reporting"
else
  ok "tests/lib.sh does not set -e, so assertions report rather than abort"
fi

section "Prompt"
# The git_status symbols are the only space between that module and the next.
# Its format has no trailing separator, and every module that can follow it
# begins with a word ("via 🐍", "took 5s"), so a symbol with no trailing space
# runs straight into it. Three did: ahead was a bare "⇡", and for as long as a
# branch was ahead of its upstream the prompt read "⇡took 5s". Nothing failed
# and nothing looked broken, only cramped.
#
# Every key in the table bar the settings, not the three that were wrong: any
# symbol can be the last one drawn, and one added later is covered too. TOML
# rejects a key set twice, so there is no later write to miss. A symbol set to
# "" draws nothing and needs no gap; a single-quoted one, or any other
# spelling, is reported, which errs loud.
#
# And every symbol starship draws must be in the table, because one left out
# gets starship's default, which this cannot read. Reading only the keys
# written here passed while renamed's default, a bare "»", made a branch whose
# only change was a staged rename read "»took 5s". The list is the symbol keys
# `starship print-config git_status` names in 1.24, which needs starship, and
# CI has none; checks/machine.sh asks the installed starship instead, so a
# symbol a later release adds is caught there.
GS_SYMBOLS="conflicted ahead behind diverged up_to_date untracked stashed
  modified staged renamed deleted typechanged"
gs_syms="$(awk '/^\[git_status\][[:space:]]*(#.*)?$/ { p = 1; next } /^\[/ { p = 0 } p' \
  starship/.config/starship.toml |
  grep -E '^[[:space:]]*[a-z_]+[[:space:]]*=' |
  grep -vE '^[[:space:]]*(style|format|disabled|ignore_submodules|windows_starship|use_git_executable)[[:space:]]*=')"
gs_seen="$(printf '%s\n' "$gs_syms" | grep -c '=')"
gs_bad="$(printf '%s\n' "$gs_syms" | grep '=' | grep -vE '=[[:space:]]*"([^"]* )?"[[:space:]]*(#.*)?$')"
# Space-padded, so a case pattern matches whole keys: "staged" is not found
# inside a hypothetical "unstaged".
gs_keys=" $(printf '%s\n' "$gs_syms" | sed -nE 's/^[[:space:]]*([a-z_]+)[[:space:]]*=.*/\1/p' | tr '\n' ' ')"
gs_unset=""
for k in $GS_SYMBOLS; do
  case "$gs_keys" in
    *" $k "*) ;;
    *) gs_unset="$gs_unset $k" ;;
  esac
done
if [ "${gs_seen:-0}" -eq 0 ]; then
  bad "read no symbols out of starship.toml's [git_status] table — the check would be vacuous"
elif [ -n "$gs_bad" ] || [ -n "$gs_unset" ]; then
  if [ -n "$gs_unset" ]; then
    bad "git_status symbol(s) not set in starship.toml, so starship draws its default, which can lack the space (renamed's is \"»\"):$gs_unset"
  fi
  if [ -n "$gs_bad" ]; then
    bad "git_status symbol(s) with no trailing space, so they run into the next module (\"⇡took 5s\"):"
    printf '%s\n' "$gs_bad" | sed 's/^/      /'
  fi
else
  ok "every git_status symbol ends in a space ($gs_seen of them, none left to starship's default), so none runs into the next module"
fi

section "Formatters"
# home/.prettierrc is stowed to ~, so it is the prettier config for every repo
# under ~ that has none of its own, and format-on-save applies it. Its tabWidth
# is 4, which re-indented every YAML file on save, this repo's CI workflow
# included, so an override takes YAML back to 2. `make lint` proves that
# against the YAML here, but only where prettier is installed; this needs
# nothing but python3.
#
# The width is worked out the way prettier does it, not by finding the
# override: the top-level value, then every override whose files match, in
# order, so a later one that sets YAML back to 4 is the one that counts.
# Patterns are matched as shell globs against the bare name, which is how
# prettier matches a plain one like *.yml. Anything more than letters, digits,
# _ . - * and ? can match differently there: an override for .github/**/*.yml,
# one for *.{yml,yaml}, or an excludeFiles naming .github/workflows/ci.yml each
# had prettier re-indent ci.yml at 4 while this still read 2. So such a
# pattern, in files or excludeFiles, fails as one this cannot judge rather than
# being guessed at. A .prettierrc written as YAML rather than JSON does not
# parse here, and fails as unreadable.
prettier_width() { # $1 = file name; prints the tabWidth prettier would use
  python3 -c '
import fnmatch, json, re, sys
cfg = json.load(open(sys.argv[1]))
width = cfg.get("tabWidth", 2)
def globs(v):
    return [v] if isinstance(v, str) else list(v or [])
for o in cfg.get("overrides", []):
    for g in globs(o.get("files")) + globs(o.get("excludeFiles")):
        if not re.fullmatch(r"[\w.*?-]+", g):
            print("unjudgeable", g)
            sys.exit()
    hit = any(fnmatch.fnmatch(sys.argv[2], g) for g in globs(o.get("files")))
    out = any(fnmatch.fnmatch(sys.argv[2], g) for g in globs(o.get("excludeFiles")))
    if hit and not out:
        width = o.get("options", {}).get("tabWidth", width)
print(width)
' home/.prettierrc "$1" 2>/dev/null
}
if ! command -v python3 >/dev/null 2>&1; then
  meh "python3 not installed, cannot read home/.prettierrc"
else
  yml_w="$(prettier_width ci.yml)"
  yaml_w="$(prettier_width ci.yaml)"
  if [ -z "$yml_w" ] || [ -z "$yaml_w" ]; then
    bad "could not read a tabWidth for YAML out of home/.prettierrc — the check would be vacuous"
  elif [ "${yml_w%% *}" = unjudgeable ]; then
    bad "home/.prettierrc has an override pattern this check cannot judge (${yml_w#* }) — prettier may match it differently from a glob on the bare name, so a 2 here would prove nothing"
  elif [ "$yml_w" != 2 ] || [ "$yaml_w" != 2 ]; then
    bad "home/.prettierrc gives .yml files a tabWidth of $yml_w and .yaml files $yaml_w — anything but 2 and format-on-save re-indents them"
  else
    ok "prettier indents YAML by 2 under home/.prettierrc, whatever its top-level tabWidth"
  fi
fi

section "Git"
# The global ignore is judged by git itself, not by reading its patterns,
# because its defect was in how git reads one. A pattern with a slash in the
# middle is anchored to the repo root, so tmp/99-* caught the 99 plugin's
# scratch files only from an nvim started at the top of a repo. Started in a
# subdirectory they were one `git add -A` from a commit, prompt excerpts of the
# source and all. The nested path below is what proves the **/; the .env
# templates are what prove the negations still win.
#
# A fresh repo in a temp dir, so this repo's own .gitignore cannot answer for
# it. GIT_DIR and GIT_INDEX_FILE are unset first. The pre-commit hook exports
# GIT_INDEX_FILE, and from a linked worktree GIT_DIR too, both naming the real
# repository's files; with GIT_DIR set, `git init` would reinitialise that
# repository and check-ignore would read its excludes. A subshell, so the trap
# that removes the temp dir cannot replace one check.sh sets.
GLOBAL_IGNORE="git/.config/git/ignore"
ign_out="$(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CONFIG_PARAMETERS
  probe="$(mktemp -d "${TMPDIR:-/tmp}/check-ignore.XXXXXX")" || exit 1
  trap 'rm -rf "$probe"' EXIT
  git init -q "$probe" || exit 1
  ask() { # $1 = what the path should be, $2 = the path
    git -C "$probe" -c core.excludesFile="$REPO/$GLOBAL_IGNORE" check-ignore --no-index -q "$2"
    printf '%s %s %s\n' "$1" "$?" "$2"
  }
  for p in tmp/99-state sub/dir/tmp/99-prompt-1 .DS_Store .env .venv/bin/python \
    pkg/__pycache__/m.pyc node_modules/x/i.js; do
    ask ignored "$p"
  done
  for p in .env.example .env.sample .env.template .env.dist; do
    ask kept "$p"
  done
)"
ign_seen=0
ign_bad=0
while read -r want rc p; do
  [ -n "$p" ] || continue
  ign_seen=$((ign_seen + 1))
  case "$want:$rc" in
    ignored:0 | kept:1) continue ;;
    ignored:1) bad "the global ignore does not ignore $p, so a repo with no .gitignore of its own commits it" ;;
    kept:0) bad "the global ignore hides $p, the checked-in template its negations exist to keep" ;;
    *) bad "git check-ignore could not judge $p (exit $rc), so the global ignore went unchecked" ;;
  esac
  ign_bad=$((ign_bad + 1))
done <<<"$ign_out"
if [ "$ign_seen" -eq 0 ]; then
  bad "could not ask git about $GLOBAL_IGNORE at all — the check would be vacuous"
elif [ "$ign_bad" -eq 0 ]; then
  ok "the global ignore covers what it claims at any depth and keeps the .env templates ($ign_seen paths, judged by git)"
fi

section "Make targets"
# A target listed in .PHONY but with no recipe does not error — make prints
# "Nothing to be done" and exits 0. `make test` did exactly that after a careless
# edit deleted the target, reporting success while running nothing.
# Every .PHONY line, not just the first: make accepts any number of them, and
# reading one would leave everything on a second line silently unchecked.
phony="$(grep '^.PHONY:' Makefile | cut -d: -f2-)"
for target in $phony; do
  if grep -qE "^${target}:" Makefile; then
    ok "make $target has a recipe"
  else
    bad "make $target is declared .PHONY but has no recipe — it exits 0 doing nothing"
  fi
done

section "Fresh machine"
# checks/machine.sh warns when a formatter conform.lua names is missing from
# THIS machine. Nothing asked whether bootstrap.sh would install it on the NEXT
# one, so a formatter or linter added to the nvim config and not to bootstrap's
# brew list is a silent no-op for its filetypes on every fresh machine, while
# the machine it was added on, set up by hand, stays green.
#
# A tool is matched to a formula of the same name. Two come with a toolchain
# instead: gofmt with go, rustfmt with the rustup install install_rust runs.
# They are named here, with what provides them, so the exception is visible
# rather than a gap, and a tool whose formula is named differently needs a line
# here the same way. The brew list is brew_install_pkgs' `local pkgs=(` array,
# comments dropped, one package per word; the rustup install has to be a line
# of code, not a comment.
#
# The two tables are READ, by nvim, not grepped. A line-based read took the
# quoted names off each `ft = {` line, and stylua keeps an entry written over
# several lines as it is: `python = {`, `"black",`, `},`. The names on the inner
# line were skipped, the entry's own `},` ended the range, and every entry after
# it was dropped too, so a partial read reported "all 2" and passed with three
# formatters missing from bootstrap. conform.lua returns its spec, so the table
# is the spec's opts. lint.lua fills linters_by_ft inside its config function,
# so that function runs against a stand-in for require("lint") that only keeps
# what is assigned to it. nvim only, like the lock and parse checks: CI installs
# it before these run.
#
# Nothing read is never a pass. conform.lua is required to yield formatters,
# lint.lua to yield linters when it is there, and every filetype in either to
# yield at least one name: a function or an empty list in its place is reported
# rather than counted as nothing to install. lint.lua is not itself required:
# it is one plugin's config, and linting may stop going through it.
boot_pkgs="$(sed -n '/^brew_install_pkgs()/,/^}/p' bootstrap.sh |
  sed -n '/local pkgs=(/,/)/p' |
  sed -e 's/#.*//' -e 's/local pkgs=(//' -e 's/)//' |
  tr -s '[:blank:]' '\n' | grep -v '^$')"
boot_rustup="$(grep -vE '^[[:space:]]*#' bootstrap.sh | grep -cF 'sh.rustup.rs')"
conform_lua=nvim/.config/nvim/lua/rich/plugins/conform.lua
lint_lua=nvim/.config/nvim/lua/rich/plugins/lint.lua
if command -v nvim >/dev/null 2>&1; then
  lint_arg=""
  [ -f "$lint_lua" ] && lint_arg="$lint_lua"
  # One line per name, "formatter black" or "linter shellcheck", and "unread
  # formatter lua" for a filetype that yields none. A nested list is conform's
  # older way of naming alternatives, so its names count too; keys that are
  # not list positions, like stop_after_first, are options and are skipped.
  nvim_tools="$(printf '%s\n' 'local function names(v, out)
  for _, x in ipairs(v) do
    if type(x) == "string" then
      out[#out + 1] = x
    elseif type(x) == "table" then
      names(x, out)
    end
  end
  return out
end
local function emit(kind, by_ft)
  if type(by_ft) ~= "table" then return end
  for ft, v in pairs(by_ft) do
    local got = type(v) == "table" and names(v, {}) or {}
    if #got == 0 then io.stdout:write("unread ", kind, " ", tostring(ft), "\n") end
    for _, n in ipairs(got) do io.stdout:write(kind, " ", n, "\n") end
  end
end
local ok, spec = pcall(dofile, arg[1])
if ok and type(spec) == "table" and type(spec.opts) == "table" then
  emit("formatter", spec.opts.formatters_by_ft)
end
if arg[2] then
  local lint = { linters = {}, linters_by_ft = {}, try_lint = function() end }
  package.preload.lint = function() return lint end
  ok, spec = pcall(dofile, arg[2])
  if ok and type(spec) == "table" and type(spec.config) == "function" then
    pcall(spec.config, spec, type(spec.opts) == "table" and spec.opts or {})
  end
  emit("linter", lint.linters_by_ft)
end' | nvim --clean --headless -l /dev/stdin "$conform_lua" ${lint_arg:+"$lint_arg"} 2>/dev/null)"
  conform_tools="$(printf '%s\n' "$nvim_tools" | sed -n 's/^formatter //p')"
  lint_tools="$(printf '%s\n' "$nvim_tools" | sed -n 's/^linter //p')"
  fresh_bad=0
  if [ -z "$boot_pkgs" ] || [ -z "$conform_tools" ]; then
    bad "could not read bootstrap's brew list or conform's formatters — the comparison would be vacuous"
    fresh_bad=$((fresh_bad + 1))
  fi
  if [ -n "$lint_arg" ] && [ -z "$lint_tools" ]; then
    bad "read no linters out of lint.lua — whether bootstrap installs them would go unchecked"
    fresh_bad=$((fresh_bad + 1))
  fi
  while read -r kind ft; do
    [ -n "$ft" ] || continue
    bad "the $kind entry for $ft is not a list of names — whether bootstrap installs what it runs goes unchecked"
    fresh_bad=$((fresh_bad + 1))
  done <<<"$(printf '%s\n' "$nvim_tools" | sed -n 's/^unread //p')"
  tools_seen=0
  if [ -n "$boot_pkgs" ]; then
    for t in $(printf '%s\n%s\n' "$conform_tools" "$lint_tools" | grep -v '^$' | sort -u); do
      tools_seen=$((tools_seen + 1))
      case "$t" in
        gofmt) grep -qxF go <<<"$boot_pkgs" && continue ;;
        rustfmt) [ "${boot_rustup:-0}" -gt 0 ] && continue ;;
        *) grep -qxF "$t" <<<"$boot_pkgs" && continue ;;
      esac
      bad "the nvim config runs $t, and bootstrap.sh does not install it — on a fresh machine its filetypes are silently not formatted or linted"
      fresh_bad=$((fresh_bad + 1))
    done
  fi
  [ "$fresh_bad" -eq 0 ] && ok "bootstrap.sh installs all $tools_seen formatters and linters the nvim config runs"
else
  meh "nvim not installed, cannot read the formatters and linters the nvim config runs"
fi

section "Git hooks"
# A hook and a make target are two copies of one command, and everything that
# DESCRIBES a hook — the README, the Makefile's own help, bootstrap.sh, the
# message check.sh prints — names the target rather than the command. So when
# pre-push was changed to run the fast subset, four separate descriptions went
# on saying "test on push": true of the target they named, false of the hook.
#
# Assert the equivalence instead of the wording. Each hook must run exactly what
# its target runs, and every file that advertises the pairing must name that
# target, so the wording cannot survive the hook changing under it.
hook_runs() { # $1 = hook name — the repo-relative command it execs
  # shellcheck disable=SC2016  # the $( ) below is text to match, not to run
  sed -n 's|^exec "$(git rev-parse --show-toplevel)/\([^"]*\)"|\1|p' ".githooks/$1"
}
target_runs() { # $1 = make target — the command its recipe runs
  awk -v t="$1" '
    $0 ~ "^" t ":" { found = 1; next }
    found && /^\t/ {
      sub(/^\t@?\.\//, "")
      print
      exit
    }
  ' Makefile
}
hooks_bad=0
for pair in pre-commit:check pre-push:test-fast; do
  hook="${pair%%:*}"
  target="${pair##*:}"
  hc="$(hook_runs "$hook")"
  tc="$(target_runs "$target")"
  if [ -z "$hc" ] || [ -z "$tc" ]; then
    bad "could not read what .githooks/$hook or 'make $target' runs — the comparison would be vacuous"
    hooks_bad=$((hooks_bad + 1))
  elif [ "$hc" != "$tc" ]; then
    bad ".githooks/$hook runs '$hc' but 'make $target' runs '$tc' — everything that describes this hook names the target"
    hooks_bad=$((hooks_bad + 1))
  else
    ok ".githooks/$hook runs exactly what 'make $target' runs ($hc)"
  fi
  # One phrase — "check on commit", "test-fast on push" — repeated in three
  # files. Built from the pair above, so renaming the target breaks all three
  # here rather than in six months when someone reads one of them.
  phrase="$target on ${hook#pre-}"
  for f in README.md Makefile bootstrap.sh checks/machine.sh; do
    # checks/machine.sh may legitimately not be here: --repo-only has to keep
    # working without the machine half, which is what lets CI run this one
    # alone. Warn rather than skip quietly — a check that stops checking
    # without saying so is the thing this file exists to prevent.
    [ -f "$f" ] || {
      meh "$f is not here, so its description of the hooks went unchecked"
      continue
    }
    grep -qF "$phrase" "$f" || {
      bad "$f advertises the git hooks without saying '$phrase'"
      hooks_bad=$((hooks_bad + 1))
    }
  done
done
[ "$hooks_bad" -eq 0 ] && ok "every file that advertises the hooks names the target the hook really runs"

section "Slow suites"
# A suite opts out of the fast set with SUITE_SLOW=1, and every one of them says
# in its header who still runs it. That sentence was copy-pasted into seven
# files and went false in all seven on the day pre-push started passing --fast:
# it said the hook still ran everything, when the hook now skips precisely
# these. Nothing noticed, because a comment is not executed.
#
# So derive the sentence from the hook instead of trusting the copies. Comments
# are flattened before matching, because otherwise this would be dictating where
# the line wraps.
case "$(hook_runs pre-push)" in
  *--fast*) slow_phrase="and so does the pre-push hook" ;;
  *) slow_phrase="the pre-push hook runs these too" ;;
esac
slow_bad=0
slow_seen=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  slow_seen=$((slow_seen + 1))
  flat="$(sed -n 's/^#[[:space:]]\{0,1\}//p' "$f" | tr '\n' ' ' | tr -s ' ')"
  grep -qF "$slow_phrase" <<<"$flat" || {
    bad "$f declares SUITE_SLOW=1 but never says '$slow_phrase' — its header and the hook disagree"
    slow_bad=$((slow_bad + 1))
  }
done < <(grep -l '^SUITE_SLOW=1' tests/test-*.sh)
if [ "$slow_seen" -eq 0 ]; then
  bad "no suite declares SUITE_SLOW=1 — either --fast runs everything now, or the marker was renamed"
elif [ "$slow_bad" -eq 0 ]; then
  ok "all $slow_seen slow suites say who runs them, and it agrees with what pre-push does"
fi

section "README"
# The README is the only file here that describes this repo without executing
# any of it, so nothing notices when it stops being true. By the time this was
# written it had drifted twice: it quoted a pre-push timing that had been
# corrected in the hook the day before, and it never mentioned `make test-fast`,
# which exists. One document, five minutes, two defects.
#
# Everything below is mechanical. The README may name a target, a file, a
# binding or a figure only when the thing it names is really here.

# The body of one "## " section of the README, so a table can be read without
# matching rows from a different table.
readme_section() { # $1 = heading text, without the "## "
  awk -v h="$1" '
    $0 == "## " h { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' README.md
}
# The first cell of every table row in a section, as bare backticked tokens.
readme_keys() { # $1 = heading text
  # shellcheck disable=SC2016  # backticks here are markdown, not substitution
  readme_section "$1" | awk -F'|' '/^\|/ { print $2 }' | grep -oE '`[^`]+`' | tr -d '`'
}

readme_bad=0

# --- make targets, both directions ------------------------------------------
# Forwards: a target the README tells you to run must exist, or the setup
# instructions are wrong on a machine nobody has tried them on.
# shellcheck disable=SC2013  # splitting on words is the point
for t in $(grep -oE '\bmake [a-z][a-z0-9-]*' README.md | awk '{ print $2 }' | sort -u); do
  grep -qE "^$t:" Makefile || {
    bad "the README tells you to run 'make $t', which the Makefile does not define"
    readme_bad=$((readme_bad + 1))
  }
done
# Backwards, which is how `make test-fast` stayed invisible for as long as it
# did. `help` is the deliberate exception: `make help` prints the target list
# out of the Makefile itself, so naming it in the README would be a third copy
# of the same list.
README_UNDOCUMENTED="help"
# shellcheck disable=SC2013  # .PHONY is one line of space-separated targets
for t in $(grep '^.PHONY:' Makefile | cut -d: -f2-); do
  case " $README_UNDOCUMENTED " in *" $t "*) continue ;; esac
  grep -qE "(^|[^a-z0-9-])make $t([^a-z0-9-]|$)" README.md || {
    bad "the Makefile defines 'make $t' and the README never mentions it"
    readme_bad=$((readme_bad + 1))
  }
done

# --- files and paths ---------------------------------------------------------
# Shape, not guesswork: a backticked token counts as a path when it contains a
# slash or carries a filename extension. `q` and `main` are prose and cannot be
# told from filenames, so they are left alone. This catches the reference that
# has moved, which is the drift that actually happens. Paths under ~ are a fact
# about the machine, and checks/machine.sh asserts those.
paths_seen=0
tracked="$(git ls-files)"
# shellcheck disable=SC2016  # backticks here are markdown, not substitution
readme_tokens="$(grep -oE '`[^`]+`' README.md | tr -d '`' | sort -u)"
tracked_names="$(git ls-files | sed 's|.*/||')"
while IFS= read -r tok; do
  case "$tok" in
    '~'/*) continue ;;
    */* | *.[a-z]*) : ;;
    *) continue ;;
  esac
  tok="${tok%/}"
  tok="${tok#./}"
  paths_seen=$((paths_seen + 1))
  [ -e "$tok" ] && continue
  grep -qxF "$tok" <<<"$tracked" && continue
  grep -qxF "$tok" <<<"$tracked_names" && continue
  bad "the README references \`$tok\`, which is not in this repo"
  readme_bad=$((readme_bad + 1))
done <<<"$readme_tokens"
[ "$paths_seen" -eq 0 ] && {
  bad "found no path-shaped references in the README at all — the extraction has broken"
  readme_bad=$((readme_bad + 1))
}

# --- stow packages -----------------------------------------------------------
# The table at the top is the only index of what this repo installs.
for p in $(grep -oE '^\| \*\*[a-z]+\*\*' README.md | tr -d '|* '); do
  [ -d "$p" ] || {
    bad "the README's package table lists **$p**, which is not a directory here"
    readme_bad=$((readme_bad + 1))
  }
done
# shellcheck disable=SC2013  # PKGS is one line of space-separated packages
for p in $(grep -m1 'PKGS=' Makefile | sed 's/.*PKGS="\([^"]*\)".*/\1/'); do
  grep -qE "^\| \*\*$p\*\*" README.md || {
    bad "'make stow' installs the $p package and the README's table does not list it"
    readme_bad=$((readme_bad + 1))
  }
done

# --- what the prompt actually shows ------------------------------------------
# The table row for starship named three modules; the format string has eight.
# Nobody had lied — the row was written when the prompt had three, and adding
# python, nodejs, rust, golang and cmd_duration to the config did not touch it.
# Every module in the format string has to appear in the row, spelled the way
# starship spells it, so the row cannot fall behind the prompt again.
star_row="$(grep -m1 '^| \*\*starship\*\*' README.md)"
star_fmt="$(grep -m1 '^format = ' starship/.config/starship.toml)"
if [ -z "$star_row" ] || [ -z "$star_fmt" ]; then
  bad "could not read the starship row or the format string — the comparison would be vacuous"
  readme_bad=$((readme_bad + 1))
else
  for mod in $(printf '%s' "$star_fmt" | grep -oE '\$[a-z_]+' | tr -d '$'); do
    # Not prompt content: one ends the line, the other draws the ❯.
    case "$mod" in line_break | character) continue ;; esac
    case "$star_row" in
      *"${mod//_/ }"*) : ;;
      *)
        bad "starship's prompt includes \$$mod and the README's row does not mention it"
        readme_bad=$((readme_bad + 1))
        ;;
    esac
  done
fi

# --- the helper scripts the README documents ---------------------------------
# Both are introduced by a bold backticked heading, and the usage block under
# the second one is a promise about its command-line interface.
# shellcheck disable=SC2016  # backticks here are markdown, not substitution
for s in $(grep -oE '^\*\*`[a-z-]+`\*\*' README.md | tr -d '*`'); do
  [ -x "tmux/.local/bin/$s" ] || {
    bad "the README documents \`$s\`, which is not an executable in tmux/.local/bin"
    readme_bad=$((readme_bad + 1))
  }
done
# shellcheck disable=SC2013  # splitting on words is the point
for sub in $(grep -oE 'tmux-resurrect-saves [a-z]+' README.md | awk '{ print $2 }' | sort -u); do
  grep -qE "^[[:space:]]*$sub\)" tmux/.local/bin/tmux-resurrect-saves || {
    bad "the README shows 'tmux-resurrect-saves $sub', which the script does not accept"
    readme_bad=$((readme_bad + 1))
  }
done

# --- key bindings ------------------------------------------------------------
# tmux's grammar is `bind [-flags] [-T table] KEY command`, so the key is the
# first argument that is not a flag or a flag's argument. A subset test, not
# equality: tmux.conf also binds the prefix and the copy-mode keys, which the
# README deliberately does not tabulate.
bound="$(tmux_bound_keys)"
keys_seen=0
if [ -z "$bound" ]; then
  bad "could not read any bound key out of tmux.conf — the binding table check would be vacuous"
  readme_bad=$((readme_bad + 1))
else
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    # The README writes the key the way a person says it; tmux has its own name.
    [ "$k" = "Backspace" ] && k="BSpace"
    keys_seen=$((keys_seen + 1))
    grep -qxF "$k" <<<"$bound" || {
      bad "the README's tmux table documents '$k', which tmux.conf does not bind"
      readme_bad=$((readme_bad + 1))
    }
  done < <(readme_keys "Key tmux bindings")
  [ "$keys_seen" -eq 0 ] && {
    bad "read no keys out of the README's tmux table — the extraction has broken"
    readme_bad=$((readme_bad + 1))
  }
fi

# The leader mappings get the strong version, because tests/test-nvim.sh already
# pins the exact set against a real nvim: anything the README claims has to be
# in it. BOTH modes — the first run of this check reported `<leader>9v` as
# undocumented, and it was right that nothing asserted it: 9v is visual-only and
# the suite enumerated normal mode alone. The suite now pins both sets, so the
# union below is the whole truth rather than most of it.
#
# The four non-leader rows get a weaker check — nothing enumerates them, so all
# this can say is that the key still appears as a quoted string in the config.
# That catches a mapping renamed or deleted, and would not notice one surviving
# only in a comment. Said plainly rather than left looking as strong as the
# assertion above.
expected_leader="$(sed -n 's/^EXPECTED_LEADER_[NV]="\(.*\)"$/\1/p' tests/test-nvim.sh | paste -sd, -)"
if [ -z "$expected_leader" ]; then
  bad "could not read EXPECTED_LEADER_N/V out of tests/test-nvim.sh — the leader table check would be vacuous"
  readme_bad=$((readme_bad + 1))
else
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in
      '<leader>'*)
        case ",$expected_leader," in
          *",$k,"*) : ;;
          *)
            bad "the README documents $k, which is not in test-nvim.sh's asserted set of leader mappings"
            readme_bad=$((readme_bad + 1))
            ;;
        esac
        ;;
      *)
        grep -rqF "\"$k\"" nvim/.config/nvim --include='*.lua' || {
          bad "the README documents the Neovim binding '$k', which appears nowhere in the lua config"
          readme_bad=$((readme_bad + 1))
        }
        ;;
    esac
  done < <(readme_keys "Key Neovim bindings")
fi

# --- figures -----------------------------------------------------------------
# THE DECISION about quoting numbers, because a measured figure is true only at
# the instant it is measured, on the machine it was measured on. The README does
# not quote measured timings at all, and neither do the hook headers. Both did;
# one had been wrong since the day before it was noticed. Asserting such a
# number would mean asserting how fast somebody else's laptop is, which is why
# tests/test-performance.sh measures the pre-push suite where it runs and fails
# against a ceiling instead. That is where a timing belongs, and the prose
# points there.
#
# A CONFIGURED constant is different: a file owns it. So the permitted figures
# are READ OUT of those files rather than listed here — change the interval and
# the prose has to follow, in either direction, or this fails.
save_interval="$(tmux_setting @continuum-save-interval)"
keep_all="$(sh_default tmux/.local/bin/tmux-resurrect-saves KEEP_ALL_DAYS)"
keep_daily="$(sh_default tmux/.local/bin/tmux-resurrect-saves KEEP_DAILY_DAYS)"
# A count is a figure too, and drifts the same way: the pre-push header argued
# from "16 suites" and "eight of those" when there were 18 and 9. Both are
# countable, so both are permitted — and self-correcting.
suite_count="$(git ls-files 'tests/test-*.sh' | wc -l | tr -d ' ')"
slow_count="$(grep -l '^SUITE_SLOW=1' tests/test-*.sh | wc -l | tr -d ' ')"
if [ -z "$save_interval" ] || [ -z "$keep_all" ] || [ -z "$keep_daily" ] ||
  [ "${suite_count:-0}" -eq 0 ] || [ "${slow_count:-0}" -eq 0 ]; then
  bad "could not read the configured intervals or the suite counts — the figure check would permit everything"
  readme_bad=$((readme_bad + 1))
else
  allowed="$(printf '%s\n%s\n%s\n%s\n%s' \
    "$save_interval minutes" "$keep_all days" "$keep_daily days" \
    "$suite_count suites" "$slow_count suites")"
  figs_seen=0
  for doc in README.md .githooks/pre-commit .githooks/pre-push; do
    # Backticked spans are code, not prose — `<leader>9s` would otherwise read
    # as "9 s". Everything else that is not a letter or a digit becomes a
    # space, which also joins "every 15\nminutes" back into one figure.
    # shellcheck disable=SC2016  # backticks here are markdown, not substitution
    prose="$(sed 's/`[^`]*`//g' "$doc" | tr -c 'A-Za-z0-9' ' ')"
    while IFS= read -r fig; do
      [ -n "$fig" ] || continue
      figs_seen=$((figs_seen + 1))
      grep -qxF "$fig" <<<"$allowed" || {
        bad "$doc quotes '$fig', which nothing here can read back — a figure belongs where something measures or counts it"
        readme_bad=$((readme_bad + 1))
      }
    done < <(awk '{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+(ms|s)$/) { print $i; continue }
        if ($i ~ /^[0-9]+$/ && i < NF && $(i + 1) ~ /^(ms|s|secs?|seconds?|mins?|minutes?|hours?|days?|weeks?|suites?)$/) print $i " " $(i + 1)
      }
    }' <<<"$prose")
  done
  [ "$figs_seen" -eq 0 ] && {
    bad "found no figures at all in the README — the extraction has broken"
    readme_bad=$((readme_bad + 1))
  }
fi

[ "$readme_bad" -eq 0 ] && ok "the README describes nothing that is not here (targets, paths, packages, bindings, figures)"

section "What is tracked"
# Files a program here WRITES at runtime have no business in the history. A
# guard.log went in with a commit about check.sh: the resurrect guard writes its
# log, its hold state and its pane-archive stash beside whatever save it is
# handed, so running it by hand on a relative path drops them in the cwd and
# `git add -A` does the rest. The 99 plugin's tmp_dir is relative to the cwd
# too, and its prompt files hold excerpts of whatever was being edited.
# .gitignore keeps them out; this is what notices one that gets past it, by
# `git add -f` or by a rule that stops matching. By basename, at any depth.
tracked_n="$(git ls-files | grep -c .)"
runtime_tracked="$(git ls-files | awk -F/ '
  $NF == "guard.log" || $NF == ".guard-state" || $NF == ".guard-pane-contents.tar.gz" || $NF ~ /^99-/ { print }
')"
if [ "${tracked_n:-0}" -eq 0 ]; then
  bad "git ls-files listed nothing — the scan for tracked runtime files would be vacuous"
elif [ -n "$runtime_tracked" ]; then
  bad "runtime files are tracked — the guard or the 99 plugin wrote them, and nothing here reads them:"
  printf '%s\n' "$runtime_tracked" | sed 's/^/      /'
else
  ok "no runtime file the guard or the 99 plugin writes is tracked"
fi

section "Lint coverage"
# `make lint` derives its file set from the shebangs, so a script only reaches
# the linters by starting with one. A shell script without a shebang would be
# linted by nothing and nothing would say so — which is exactly how
# tmux/.local/bin escaped the hand-written list that target replaced, leaving
# all five of the scripts stowed onto PATH unchecked.
#
# Two rules, because the failure differs: a *.sh file needs a SHELL shebang or
# lint skips it, and any executable needs some shebang or it is run by whatever
# shell happens to call it.
shebang_bad=0
shebang_seen=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  shebang_seen=$((shebang_seen + 1))
  first="$(head -1 "$f")"
  case "$f" in
    *.sh)
      case "$first" in
        '#!'*sh) continue ;;
        *) bad "$f is a shell script with no shell shebang — 'make lint' derives its file set from those, so nothing lints it" ;;
      esac
      ;;
    *)
      case "$first" in
        '#!'*) continue ;;
        *) bad "$f is executable with no shebang — whatever shell invokes it decides how it runs" ;;
      esac
      ;;
  esac
  shebang_bad=$((shebang_bad + 1))
done < <(
  {
    git ls-files '*.sh'
    git ls-files -s | awk '$1 == "100755" { print $4 }'
  } | sort -u
)
if [ "$shebang_seen" -eq 0 ]; then
  bad "found no shell scripts or executables at all — the scan has broken"
elif [ "$shebang_bad" -eq 0 ]; then
  ok "all $shebang_seen shell scripts and executables declare an interpreter, so lint sees them"
fi

section "CI"
# A workflow that exists but no longer calls these targets is worse than none:
# the badge stays green while nothing runs. Assert the wiring, not just the file.
CI=".github/workflows/ci.yml"
if [ ! -f "$CI" ]; then
  bad "no CI workflow — the hooks are local and bypassable with --no-verify"
else
  ok "CI workflow present"
  for target in check-repo test lint; do
    if grep -qE "make $target( |$)" "$CI"; then
      ok "CI runs 'make $target'"
    else
      bad "CI does not run 'make $target' — it would pass without checking"
    fi
  done
  if grep -qE '^[[:space:]]*runs-on: macos' "$CI"; then
    ok "CI runs on macOS, which is the only platform bootstrap.sh supports"
  else
    bad "CI does not run on macOS, so it cannot exercise this repo honestly"
  fi
  # The plugins CI tests have to be the ones lazy-lock.json pins, which is what
  # a fresh machine gets. CI primed them with `Lazy! sync`, and sync runs
  # update: every plugin moved to the tip of its branch and the lock was
  # rewritten, so the suites went green on versions this repo never chose.
  # restore is update held to the lock. Comment lines are dropped so the
  # comment explaining this cannot satisfy it, and a sync or update ANYWHERE
  # fails, because a later step running one would undo the restore.
  lazy_cmds="$(grep -vE '^[[:space:]]*#' "$CI" | grep -oE 'Lazy!?[[:space:]]+[a-z]+')"
  lazy_unpinned="$(grep -E '[[:space:]](sync|update)$' <<<"$lazy_cmds" | sort -u | tr '\n' ' ')"
  if [ -n "$lazy_unpinned" ]; then
    bad "CI runs ${lazy_unpinned}— that moves every plugin past lazy-lock.json, so CI tests versions this repo never pinned"
  elif ! grep -qE '[[:space:]]restore$' <<<"$lazy_cmds"; then
    bad "CI never runs 'Lazy! restore', so nothing holds the plugins it tests to lazy-lock.json"
  else
    ok "CI primes the plugins with 'Lazy! restore', at the commits lazy-lock.json pins"
  fi
fi
