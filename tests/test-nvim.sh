#!/usr/bin/env bash
# Neovim at runtime.
#
# The repository checks prove every lua file PARSES. They do not prove nvim
# works. A plugin can load and do nothing, a formatter can be configured for a
# filetype whose binary is missing, and an LSP server can be listed and never
# attach — none of which a syntax check can see.
#
# XDG_STATE_HOME is redirected so shada, undo history and lsp.log land in a
# scratch dir rather than the real one. XDG_DATA_HOME is NOT redirected: the
# plugins are already installed there, and pointing it elsewhere would make lazy
# clone every one of them over the network on every run. It is honoured when
# the caller sets it, the way nvim honours it, which is how this suite runs a
# second Neovim against a plugin set and parsers of its own; NVIM_DATA below is
# where nvim will look, for the skips that ask whether Mason installed a server.
#
# XDG_CACHE_HOME is redirected too. vim.loader, which lazy turns on, compiles
# each lua file it loads into the cache's luac dir, under a name made from the
# file's full path, and nothing ever prunes that dir. Every file this suite
# loads from its scratch dir, which is deleted on exit, left an orphan in the
# real cache on every run: the negative control's copy of the config alone
# left 21 a run.
#
# Invocation matters. `nvim -l script.lua` does NOT put the config's runtime
# path in scope — require("lazy...") fails outright and an LSP probe times out
# reporting nothing attached, which looks exactly like "LSP cannot be driven
# headlessly". It can. `nvim --headless FILE -c 'lua ...'` is the form that
# loads the config properly.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Declared slow: tens of seconds, because it drives a real terminal, editor or
# language server, or repeats an expensive command many times. `tests/run.sh
# --fast` skips these, and so does the pre-push hook; CI runs the complete set,
# so what the hook skips is caught on the way in rather than on the way out.
# Read by run.sh with grep, not by this shell.
# shellcheck disable=SC2034
SUITE_SLOW=1

command -v nvim >/dev/null 2>&1 || skip_suite "nvim is not installed"

# Where nvim will look, not where the stow tree is: stdpath("config") follows
# XDG_CONFIG_HOME, which is how this suite is pointed at a worktree's config
# instead of the stowed one. The negative control below copies this directory,
# and with $HOME/.config/nvim written here it broke a copy of the main
# checkout's config while every other check tested the worktree's.
NVIM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
[ -f "$NVIM_CONFIG/init.lua" ] || skip_suite "no nvim config at $NVIM_CONFIG"
NVIM_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"

STATE="$TEST_TMP/state"
CACHE="$TEST_TMP/cache"
SANDBOX="$TEST_TMP/sandbox"
mkdir -p "$STATE" "$CACHE" "$SANDBOX"

# The system clipboard is shimmed for every nvim this suite starts.
#
# options.lua sets clipboard=unnamedplus, so in any nvim started here a yank, a
# delete or a change runs pbcopy and a p runs pbpaste -- looked up by name on
# PATH at the moment of the call. Without this, a probe that so much as `dd`s a
# line would overwrite whatever the person running the suite last copied, with
# no way to get it back. --headless does not prevent it: a yank inside a -c
# command is deferred, not skipped, and reaches pbcopy when the command ends.
#
# PATH rather than g:clipboard: it also catches anything that shells out to
# pbcopy itself, and a g:clipboard passed with --cmd would be silently replaced
# by any config that ever sets its own. The clipboard section below checks that
# nvim really resolved these before it lets any probe write.
CLIP_BIN="$TEST_TMP/clip-bin"
CLIP_FILE="$TEST_TMP/clipboard"
mkdir -p "$CLIP_BIN"
printf '#!/bin/sh\ncat >"%s"\n' "$CLIP_FILE" >"$CLIP_BIN/pbcopy"
printf '#!/bin/sh\ncat "%s" 2>/dev/null\n' "$CLIP_FILE" >"$CLIP_BIN/pbpaste"
chmod +x "$CLIP_BIN/pbcopy" "$CLIP_BIN/pbpaste"

# Run nvim headless on a file, with whatever -c commands follow.
nv() { # $1 = file, $2... = -c commands
  local file="$1"
  shift
  local args=()
  local c
  for c in "$@"; do args+=(-c "$c"); done
  # ${args[@]+...}, not a bare "${args[@]}": under set -u, bash 3.2 -- the
  # macOS /bin/bash that runs this suite -- calls an EMPTY array unbound and
  # abandons the command. The one caller with no -c commands is the startup
  # check below, so nvim never started there, the substitution came back empty,
  # and "no errors on startup" passed on that emptiness for as long as it
  # existed. The negative control under it is what keeps this from coming back.
  PATH="$CLIP_BIN:$PATH" XDG_STATE_HOME="$STATE" XDG_CACHE_HOME="$CACHE" \
    nvim --headless "$file" ${args[@]+"${args[@]}"} -c 'qa!' 2>&1
}

echo "== it starts, and starts clean =="
printf 'local x = 1\n' >"$SANDBOX/start.lua"
# The negative control copies NVIM_CONFIG, so before it: that is the config
# nvim loads.
out="$(nv "$SANDBOX/start.lua" 'lua print("CONFIG=[" .. vim.fn.stdpath("config") .. "]")')"
assert "the config the control copies is the one nvim loads ($NVIM_CONFIG)" \
  contains "$out" "CONFIG=[$NVIM_CONFIG]"
# Then the negative control, ahead of the check it guards. "No errors" is an
# assertion about EMPTY output, and empty is also what a probe that never ran
# produces -- which is exactly how this check passed while nv() was failing
# before it reached nvim. So the same call, with no -c commands, against a copy
# of the config that throws at the end of init.lua, has to come back with that
# error in it. If it does not, the clean result below proves nothing.
#
# What it shows is that nv() reaches nvim with no -c commands and that an
# error thrown by init.lua reaches the captured output. Not that every startup
# error does: init.lua has returned before any plugin that waits for
# BufReadPre, BufReadPost or VeryLazy has run its config, so the throw comes
# before them, and an error from one of those is outside what this proves.
#
# XDG_DATA_HOME is left alone, so the copy finds the installed plugins and lazy
# clones nothing. cp's complaints are dropped: a live config can hold a
# dangling link an old stow left behind, which nvim never opens and the control
# does not need.
BROKEN="$TEST_TMP/broken-config"
mkdir -p "$BROKEN"
cp -RL "$NVIM_CONFIG" "$BROKEN/nvim" 2>/dev/null
printf '\nerror("negative control")\n' >>"$BROKEN/nvim/init.lua"
out="$(XDG_CONFIG_HOME="$BROKEN" nv "$SANDBOX/start.lua")"
assert "a config that throws at startup is reported, so the next check can fail" \
  contains "$out" "negative control"
out="$(nv "$SANDBOX/start.lua")"
assert "no errors on startup" [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]

out="$(nv "$SANDBOX/start.lua" \
  'lua local s = require("lazy").stats(); print("LOADED=" .. s.loaded .. " OF=" .. s.count)')"
assert "lazy is present and reports its plugins" contains "$out" "LOADED="
plugin_count="$(printf '%s' "$out" | sed -n 's/.*OF=\([0-9]*\).*/\1/p')"
assert "it knows about the whole plugin set, not a fragment" [ "${plugin_count:-0}" -ge 20 ]

echo
echo "== the plugins that must be loaded at startup, are =="
# A colorscheme has to load before the UI draws; lazy-loading it means an
# unstyled flash or no theme at all.
out="$(nv "$SANDBOX/start.lua" \
  'lua local p = require("lazy.core.config").plugins; local n = 0; for _, x in pairs(p) do if x._.loaded then n = n + 1 end end; print("EAGER=" .. n)')"
eager="$(printf '%s' "$out" | sed -n 's/.*EAGER=\([0-9]*\).*/\1/p')"
assert "some plugins load eagerly, as the colorscheme must" [ "${eager:-0}" -ge 1 ]
# :-0 rather than a remembered plugin count: if the count could not be read the
# assertion above has already failed, and comparing against a number written
# here would let this one pass on a guess.
assert "but most are deferred — an eager everything would be a config bug" \
  [ "${eager:-99}" -lt "${plugin_count:-0}" ]

echo
echo "== line wrap is on, and stays on, in a file window =="
# checks/repo.sh reads the wrap line out of options.lua on every commit. This
# asserts the thing that grep structurally cannot: what a running nvim actually
# does once the whole config and every installed plugin has had its turn.
#
# 'wrap' is window-local (:help 'wrap') and Neovim's default for it is ON, so
# wrap being off is never an omission — something turned it off. The config
# loads in an order where every later step can undo an earlier one: options.lua,
# then lazy, then keymaps.lua, then each plugin's config, then the ftplugins for
# whatever file you opened. An ftplugin, a FileType autocmd, or one `setlocal
# nowrap` in a plugin takes wrap off the file in front of you while options.lua
# still reads "true", and a plugin update does that with no diff in this repo at
# all — which is the case lazy-lock.json being tracked exists to make visible.
#
# Only a FILE window is asserted, deliberately. Telescope's prompt, trouble,
# which-key, undotree, fugitive's diff panes, gitsigns blame and mason's UI all
# set nowrap on their own windows on purpose, and so does nvim for :terminal
# buffers. Asserting wrap in EVERY window would fail for entirely correct
# reasons.
#
# Two probes, because they go wrong for different reasons: the window nvim
# starts in, which is the config's doing and nothing else's; and a second file
# of a DIFFERENT filetype opened in the SAME window after things have settled,
# by which point that filetype's ftplugins and the plugins lazy loads on
# FileType/BufReadPost have run.
#
# The second probe MEASURES rather than reading the option back, because screen
# lines are the thing actually being complained about: with wrap on, a line
# three windows wide is drawn on several screen lines; with it off, on exactly
# one. nvim_win_text_height counts screen lines and is wrap-aware, and its
# "fill" is subtracted so a virtual line above the text — a diagnostic, a diff
# filler — cannot make an unwrapped line look wrapped. The line is built from
# the window's own width rather than written at a fixed length, so the probe
# does not quietly assert how wide a headless nvim happens to be.
#
# What this does NOT cover, said out loud rather than implied by the wait: lazy
# arms User VeryLazy from a UIEnter autocmd, and --headless attaches no UI, so a
# plugin deferred to VeryLazy never loads here.
printf 'A markdown paragraph, the kind of prose that line wrap exists for.\n' >"$SANDBOX/wrap.md"
out="$(nv "$SANDBOX/start.lua" \
  'lua print("WRAP_AT_START=" .. tostring(vim.wo.wrap))' \
  'lua vim.wait(2500)' \
  "lua vim.cmd.edit(vim.fn.fnameescape('$SANDBOX/wrap.md'))" \
  'lua vim.wait(1000, function() return vim.bo.filetype ~= "" end, 50)' \
  'lua print("WRAP_NEXT_FILE=" .. tostring(vim.wo.wrap) .. " FT_NEXT_FILE=" .. vim.bo.filetype)' \
  'lua local cols = vim.api.nvim_win_get_width(0); local line = string.rep("x", cols * 3); vim.api.nvim_buf_set_lines(0, 0, -1, false, { line }); local h = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 0 }); print("WRAP_SCREEN_LINES=" .. (h.all - h.fill) .. " WRAP_LINE_COLS=" .. #line .. " WRAP_WIN_COLS=" .. cols)')"

assert "wrap is on in the window nvim starts in" contains "$out" "WRAP_AT_START=true"
# Without this the measurement below could be reporting on a buffer whose
# filetype was never detected, which is not the claim being made.
assert "the second file is the filetype this assertion thinks it is" contains "$out" "FT_NEXT_FILE=markdown"
assert "wrap is still on after opening the next file in the same window" contains "$out" "WRAP_NEXT_FILE=true"

screen_lines="$(printf '%s' "$out" | sed -n 's/.*WRAP_SCREEN_LINES=\([0-9]*\).*/\1/p')"
line_cols="$(printf '%s' "$out" | sed -n 's/.*WRAP_LINE_COLS=\([0-9]*\).*/\1/p')"
win_cols="$(printf '%s' "$out" | sed -n 's/.*WRAP_WIN_COLS=\([0-9]*\).*/\1/p')"
printf '    %s screen lines for a %s-column line in a %s-column window\n' \
  "${screen_lines:-0}" "${line_cols:-0}" "${win_cols:-0}"
# :-0 defaults to the FAILING side: a count that could not be read must not
# pass.
assert "a line wider than the window is drawn on more than one screen line" \
  [ "${screen_lines:-0}" -ge 2 ]
# The tokens vanish as a set when the lua errors — an nvim older than 0.10,
# where nvim_win_text_height arrived, would do it — and three FAILs with no
# reason are hard to read at 2am. Not an assertion; the ones above have already
# failed.
if ! contains "$out" "WRAP_SCREEN_LINES="; then
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
fi

echo
echo "== 80 columns is held against the ftplugins that would undo it =="
# 'wrap' folds at the window edge; 'textwidth' is what keeps a line to 80. The
# interesting failure is not the option being unset, it is the option being set
# and then quietly overruled.
#
# Neovim's own ftplugins strip 't' from formatoptions — the flag that breaks a
# line as you type — for lua, sh, yaml, json and vim, and gitcommit sets a
# textwidth of its own (72). Those first two are the languages this
# repo is mostly written in, so a plain `vim.opt.textwidth = 80` in options.lua
# reads correct while doing nothing where it matters most. options.lua answers
# that with a FileType autocmd that writes after the ftplugins run; this proves
# the autocmd is still winning, which is a claim about ORDERING that no grep can
# make.
#
# gitcommit is asserted deliberately. Its ftplugin sets 72, the git convention,
# and this config overrides it to 80 — a decision, not an accident. If that is
# ever reconsidered, this is the assertion that says so out loud instead of
# letting commit-message width change quietly.
#
# The last probe TYPES rather than reading the option back, because the option
# is not the behaviour: 't' present with a textwidth of 0, or a formatexpr that
# swallows the break, would both read fine and wrap nothing.
cat >"$SANDBOX/tw_probe.lua" <<'LUA'
local dir = vim.env.TW_DIR
local out = {}
local fixtures = {
  { "fix.lua", "lua" },
  { "fix.sh", "sh" },
  { "fix.md", "markdown" },
  { "COMMIT_EDITMSG", "gitcommit" },
}
for _, spec in ipairs(fixtures) do
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. spec[1]))
  vim.wait(500, function() return vim.bo.filetype ~= "" end, 25)
  out[#out + 1] = string.format("TW_%s=%d T_%s=%s", spec[2], vim.bo.textwidth, spec[2],
    tostring(vim.bo.formatoptions:find("t") ~= nil))
end
-- Type 140 columns of ordinary words into a lua buffer — the filetype whose
-- ftplugin removes 't' — and report what the buffer actually ended up holding.
local typed = dir .. "/typed.lua"
vim.fn.writefile({}, typed)
vim.cmd.edit(vim.fn.fnameescape(typed))
vim.wait(500, function() return vim.bo.filetype ~= "" end, 25)
local text = string.rep("word ", 28)
vim.api.nvim_feedkeys(vim.keycode("i") .. text .. vim.keycode("<Esc>"), "x", false)
local widest = 0
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for _, l in ipairs(lines) do
  if #l > widest then
    widest = #l
  end
end
out[#out + 1] = string.format("TYPED_COLS=%d TYPED_LINES=%d TYPED_WIDEST=%d", #text, #lines, widest)
print(table.concat(out, " "))
LUA
printf 'local x = 1\n' >"$SANDBOX/fix.lua"
printf '#!/bin/sh\necho hi\n' >"$SANDBOX/fix.sh"
printf '# Title\n\nprose\n' >"$SANDBOX/fix.md"
printf 'subject\n\nbody\n' >"$SANDBOX/COMMIT_EDITMSG"
out="$(TW_DIR="$SANDBOX" nv "$SANDBOX/start.lua" \
  'lua vim.wait(1500)' \
  "luafile $SANDBOX/tw_probe.lua")"

assert "textwidth is 80 in lua, whose ftplugin sets none and strips auto-wrap" \
  contains "$out" "TW_lua=80"
assert "auto-wrap survives the lua ftplugin that removes it" contains "$out" "T_lua=true"
assert "textwidth is 80 in sh, the other language this repo is written in" \
  contains "$out" "TW_sh=80"
assert "auto-wrap survives the sh ftplugin that removes it" contains "$out" "T_sh=true"
assert "markdown, where the prose lives, is 80" contains "$out" "TW_markdown=80"
assert "gitcommit is overridden from its ftplugin's 72 to this config's 80" \
  contains "$out" "TW_gitcommit=80"

typed_cols="$(printf '%s' "$out" | sed -n 's/.*TYPED_COLS=\([0-9]*\).*/\1/p')"
typed_lines="$(printf '%s' "$out" | sed -n 's/.*TYPED_LINES=\([0-9]*\).*/\1/p')"
typed_widest="$(printf '%s' "$out" | sed -n 's/.*TYPED_WIDEST=\([0-9]*\).*/\1/p')"
printf '    typing %s columns into a lua buffer produced %s line(s), widest %s\n' \
  "${typed_cols:-0}" "${typed_lines:-0}" "${typed_widest:-0}"
# Both defaults point at the FAILING side: a figure that could not be read must
# not pass.
assert "typing past 80 in a lua buffer actually breaks the line" \
  [ "${typed_lines:-0}" -ge 2 ]
assert "and no line it left behind is wider than 80" [ "${typed_widest:-999}" -le 80 ]
if ! contains "$out" "TYPED_LINES="; then
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
fi

# ...and only in files. The autocmd fires on every FileType, and a prompt
# buffer has one: Telescope's is TelescopePrompt. With textwidth 80 and 't' a
# query typed past column 80 was broken onto a new line as it was typed, and
# Telescope searched only for the text after the break. So type one, into a
# real find_files, and count the prompt's lines. The assertions above are the
# other half: excluding the prompt must not exclude a file.
cat >"$SANDBOX/prompt_probe.lua" <<'LUA'
local ok, builtin = pcall(require, "telescope.builtin")
if not ok then
  print("PROMPT_TELESCOPE=missing")
  return
end
builtin.find_files({ cwd = vim.env.TW_DIR })
vim.wait(3000, function() return vim.bo.filetype == "TelescopePrompt" end, 50)
local buf = vim.api.nvim_get_current_buf()
local query = string.rep("abcdefghi ", 9) .. "z"
vim.api.nvim_feedkeys(query, "xt", false)
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print(string.format("PROMPT_FT=%s PROMPT_BT=%s PROMPT_QUERY_COLS=%d PROMPT_LINES=%d PROMPT_WHOLE=%s PROMPT_TW=%d",
  vim.bo[buf].filetype, vim.bo[buf].buftype, #query, #lines,
  tostring(lines[1] ~= nil and lines[1]:sub(-#query) == query), vim.bo[buf].textwidth))
LUA
out="$(TW_DIR="$SANDBOX" nv "$SANDBOX/start.lua" 'lua vim.wait(1000)' "luafile $SANDBOX/prompt_probe.lua")"
if contains "$out" "PROMPT_TELESCOPE=missing"; then
  printf '  \033[33mSKIP\033[0m  telescope is not installed, so there is no prompt to type into\n'
else
  prompt_cols="$(printf '%s' "$out" | sed -n 's/.*PROMPT_QUERY_COLS=\([0-9]*\).*/\1/p')"
  prompt_lines="$(printf '%s' "$out" | sed -n 's/.*PROMPT_LINES=\([0-9]*\).*/\1/p')"
  prompt_tw="$(printf '%s' "$out" | sed -n 's/.*PROMPT_TW=\([0-9]*\).*/\1/p')"
  printf "    typing %s columns into Telescope's prompt left %s line(s)\n" \
    "${prompt_cols:-0}" "${prompt_lines:-0}"
  # Without these the count below could be of some other buffer.
  assert "the probe typed into Telescope's prompt buffer (guards a vacuous pass)" \
    contains "$out" "PROMPT_FT=TelescopePrompt PROMPT_BT=prompt"
  assert "...a query longer than 80 columns" [ "${prompt_cols:-0}" -gt 80 ]
  assert "a long Telescope query stays on one line" [ "${prompt_lines:-0}" -eq 1 ]
  assert "...and that line holds the whole query" contains "$out" "PROMPT_WHOLE=true"
  # 80 is the failing side: a textwidth that could not be read must not pass.
  assert "the prompt does not get the files' textwidth of 80" [ "${prompt_tw:-80}" -ne 80 ]
  if ! contains "$out" "PROMPT_LINES="; then
    printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  fi
fi

echo
echo "== an LSP client actually attaches to a real file =="
# vim.wait with a predicate polls rather than sleeping a guess, so this either
# attaches inside the budget or reports honestly that it did not.
if [ -x "$NVIM_DATA/mason/bin/lua-language-server" ]; then
  out="$(nv "$SANDBOX/start.lua" \
    'lua vim.wait(20000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end, 250)' \
    'lua local c = vim.lsp.get_clients({ bufnr = 0 }); print("FT=" .. vim.bo.filetype .. " CLIENTS=" .. #c .. " NAME=" .. (c[1] and c[1].name or "none"))')"
  assert "the filetype is detected" contains "$out" "FT=lua"
  assert "a language server attached" contains "$out" "NAME=lua_ls"

  # Attaching is not knowing anything. In this config's own files lua_ls had no
  # definition and no hover for vim.api, because .luarc.json set a library that
  # replaced the one lazydev sends -- and attached all the same. checks/repo.sh
  # reads .luarc.json; this asks lua_ls itself, in a file of the config nvim is
  # running, where the vim.api function the file calls is defined.
  #
  # The definition is polled: lua_ls answers "none" until it has loaded its
  # library, so one early answer says nothing either way. The file is opened
  # from a .txt, so the only lua_ls running is the one rooted at the config.
  #
  # Knowing vim.* is also what lets lua_ls hold this config's calls to the
  # plugins' own annotations. While .luarc.json replaced the library it checked
  # nothing and said nothing; once lazydev's library got through, it found 9
  # warnings in 99.lua, lsp.lua, treesitter.lua and trouble.lua, and options.lua
  # sets virtual_text, so each one sat inline in the file. So the same nvim also
  # asks what lua_ls reports in every lua file of the config, and requires
  # nothing.
  #
  # lua_ls pushes diagnostics and cannot be asked for them (it answers
  # textDocument/diagnostic with "method not found"), and it publishes nothing
  # at all for a file with nothing wrong, so silence is all a clean file says.
  # Silence is also what a lua_ls that never looked would say. So a canary goes
  # in with the config's files: a vim.api call with its arguments missing, in a
  # scratch buffer named inside the config, so it is diagnosed as one of them.
  # Every one is opened before lua_ls starts loading its workspace, so one load
  # covers every plugin they require and one pass diagnoses them all. A file
  # opened after the load was measured putting the others off by 3.6s. Only
  # once lua_ls has flagged the canary, has no progress report open, and has
  # published nothing for 3s, is the count read.
  cat >"$SANDBOX/luadef_probe.lua" <<'LUA'
local busy, said = {}, vim.uv.now()
vim.api.nvim_create_autocmd("LspProgress", {
  callback = function(ev)
    busy[ev.data.params.token] = ev.data.params.value.kind ~= "end" or nil
  end,
})
local publish = vim.lsp.handlers["textDocument/publishDiagnostics"]
vim.lsp.handlers["textDocument/publishDiagnostics"] = function(...)
  said = vim.uv.now()
  return publish(...)
end
local config = vim.fn.stdpath("config")
vim.cmd.edit(vim.fn.fnameescape(config .. "/lua/rich/options.lua"))
local files = vim.list_extend({ config .. "/init.lua" }, vim.fn.globpath(config, "lua/**/*.lua", false, true))
for _, f in ipairs(files) do
  local b = vim.fn.bufadd(f)
  vim.fn.bufload(b)
  vim.bo[b].filetype = "lua"
end
vim.wait(20000, function()
  return #vim.lsp.get_clients({ bufnr = 0, name = "lua_ls" }) > 0
end, 50)
local client = vim.lsp.get_clients({ bufnr = 0, name = "lua_ls" })[1]
-- A scratch buffer is buftype=nofile, which no :w can write, so its name puts
-- it in lua_ls's workspace and nothing on disk. It is attached by hand,
-- because nvim attaches no server to a nofile buffer, and without FileType,
-- which nothing else needs to see.
local canary = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(canary, config .. "/luadiag_canary.lua")
vim.api.nvim_buf_set_lines(canary, 0, -1, false, { "vim.api.nvim_buf_get_lines()" })
vim.api.nvim_buf_call(canary, function()
  vim.cmd("noautocmd setlocal filetype=lua")
end)
if client then
  vim.lsp.buf_attach_client(canary, client.id)
end
local row, col
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  local s = l:find("vim.api.nvim_", 1, true)
  if s and not l:match("^%s*%-%-") then
    -- 0-based, and a few characters into the function name after "vim.api."
    row, col = i - 1, s + 9
    break
  end
end
local def = "none"
if client and row then
  local params = { textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = row, character = col } }
  vim.wait(30000, function()
    local res = client:request_sync("textDocument/definition", params, 5000, 0)
    local r = res and res.result
    if r and r[1] then
      def = vim.uri_to_fname(r[1].uri or r[1].targetUri)
      return true
    end
    return false
  end, 500)
end
print(string.format("LUADEF_ATTACHED=%s LUADEF_CALL=%s LUADEF=%s", tostring(client ~= nil), tostring(row ~= nil), def))
if def == "none" then
  return
end
local flagged = false
vim.wait(60000, function()
  for _, d in ipairs(vim.diagnostic.get(canary)) do
    flagged = flagged or d.code == "missing-parameter"
  end
  return flagged and next(busy) == nil and vim.uv.now() - said >= 3000
end, 250)
local reported = {}
for _, d in ipairs(vim.diagnostic.get()) do
  if d.bufnr ~= canary and d.source and d.source:find("Lua") then
    local name = vim.api.nvim_buf_get_name(d.bufnr):sub(#config + 2)
    table.insert(reported, string.format("%s:%d [%s] %s", name, d.lnum + 1, tostring(d.code), (d.message:gsub("\n", " "))))
  end
end
table.sort(reported)
for _, l in ipairs(reported) do
  print("LUADIAG " .. l)
end
print(string.format("LUADIAG_CANARY=%s LUADIAG_FILES=%d LUADIAG_TOTAL=%d", tostring(flagged), #files, #reported))
LUA
  : >"$SANDBOX/luadef.txt"
  out="$(nv "$SANDBOX/luadef.txt" "luafile $SANDBOX/luadef_probe.lua")"
  luadef="$(printf '%s' "$out" | sed -n 's/.*LUADEF=\([^ ]*\).*/\1/p' | head -1)"
  printf '    vim.api in options.lua is defined at %s\n' "${luadef:-nothing nvim printed}"
  assert "lua_ls attaches to a file of this config" contains "$out" "LUADEF_ATTACHED=true"
  assert "the probe found a vim.api call to ask about (guards a vacuous pass)" \
    contains "$out" "LUADEF_CALL=true"
  assert "lua_ls finds that call's definition in Neovim's own runtime" \
    contains "${luadef:-none}" "/lua/vim/_meta/"
  luadiag_files="$(printf '%s' "$out" | sed -n 's/.*LUADIAG_FILES=\([0-9]*\).*/\1/p' | head -1)"
  luadiag_total="$(printf '%s' "$out" | sed -n 's/.*LUADIAG_TOTAL=\([0-9]*\).*/\1/p' | head -1)"
  printf "    lua_ls reports %s problem(s) across %s of the config's lua files\n" \
    "${luadiag_total:-an unread number of}" "${luadiag_files:-0}"
  printf '%s\n' "$out" | sed -n 's/^LUADIAG \(.*\)/      \1/p'
  assert "lua_ls flags the canary's call, so it was checking calls (guards a vacuous pass)" \
    contains "$out" "LUADIAG_CANARY=true"
  assert "...with the whole config open, not a fragment of it" [ "${luadiag_files:-0}" -ge 20 ]
  assert "lua_ls reports nothing in any of the config's own lua files" [ "${luadiag_total:-1}" -eq 0 ]
else
  printf '  \033[33mSKIP\033[0m  lua-language-server is not installed via mason\n'
fi

echo
echo "== pyright resolves what a folder of loose scripts imports =="
# lsp.lua gives pyright two things lspconfig does not: the file's own folder as
# its root where no project marker is found, and the folder's .venv when no venv
# is activated. tests/helpers/pyright-probe.lua builds a folder for each claim
# and prints KEY=value lines; see it for how each one is made non-vacuous.
#
# The sibling question is asked about a module created AFTER the file importing
# it is open. One that already exists is not the test: pyright resolves that
# even with no root -- measured -- so it would pass with the fix removed. What
# fails without a root is everything that changes on disk afterwards, because
# Neovim runs none of a server's file watchers for a client with no workspace
# folder.
#
# Not nv(): the probe opens its own files and quits nvim itself. TMPDIR puts its
# folders under this suite's scratch dir, and the cd it does keeps anything a
# plugin writes into the cwd on exit in there too.
if [ -x "$NVIM_DATA/mason/bin/pyright-langserver" ]; then
  out="$(TMPDIR="$TEST_TMP" PATH="$CLIP_BIN:$PATH" XDG_STATE_HOME="$STATE" XDG_CACHE_HOME="$CACHE" \
    nvim --headless -c "luafile $REPO_ROOT/tests/helpers/pyright-probe.lua" 2>&1)"
  # Only an explicit =false is a skip. A probe that died before printing it is
  # not "a marker sits above"; it falls through, fails its assertions, and the
  # check after them says what nvim printed.
  if contains "$out" "PYRIGHT_NO_MARKER_ABOVE=false"; then
    printf '  \033[33mSKIP\033[0m  a pyright root marker sits above %s, so the no-marker case cannot be set up\n' "$TEST_TMP"
  else
    assert "pyright attaches to a file in a folder with no root marker" contains "$out" "PYRIGHT_ATTACHED=true"
    assert "the file's own folder becomes pyright's root" contains "$out" "PYRIGHT_ROOT_IS_FILE_DIR=true"
    assert "it flags the import while the module does not exist yet (guards a vacuous pass)" \
      contains "$out" "PYRIGHT_FLAGS_MISSING_BEFORE=true"
    assert "the import resolves once the module appears on disk" contains "$out" "PYRIGHT_RESOLVES_AFTER_CREATE=true"
    assert "and module. then completes the function it defines" contains "$out" "PYRIGHT_COMPLETES_NEW_SIBLING=true"
    assert "a .py directly in HOME still gets pyright" contains "$out" "PYRIGHT_HOME_ATTACHED=true"
    assert "...but no root, so pyright does not index the whole home directory" \
      contains "$out" "PYRIGHT_HOME_STAYS_SINGLE_FILE=true"
    if contains "$out" "PYRIGHT_VENV=SKIP"; then
      printf '  \033[33mSKIP\033[0m  no python3 to build a venv with\n'
    else
      assert "pyright attaches in a folder with a .venv" contains "$out" "PYRIGHT_VENV=true"
      assert "with no venv activated, it is pointed at the folder's .venv" \
        contains "$out" "PYRIGHT_VENV_INTERPRETER=true"
      assert "a package only that .venv has completes" contains "$out" "PYRIGHT_VENV_COMPLETES=true"
      assert "...and is not reported missing" contains "$out" "PYRIGHT_VENV_RESOLVES=true"
    fi
  fi
  # The tokens vanish as a set when the probe dies; say what nvim said instead.
  if ! contains "$out" "PYRIGHT_PROBE_DONE=true"; then
    no "the pyright probe did not run to the end"
    printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
else
  printf '  \033[33mSKIP\033[0m  pyright is not installed via mason\n'
fi

echo
echo "== JavaScript, CSS and HTML each get a working language server =="
# A file of each kind, and for each the server lsp.lua names, asked to do one
# thing only a working server can. tests/helpers/web-lsp-probe.lua builds them
# and prints KEY=value lines.
#
# Not nv(), for the reasons given at the pyright probe above.
out="$(TMPDIR="$TEST_TMP" PATH="$CLIP_BIN:$PATH" XDG_STATE_HOME="$STATE" XDG_CACHE_HOME="$CACHE" \
  nvim --headless -c "luafile $REPO_ROOT/tests/helpers/web-lsp-probe.lua" 2>&1)"
web_server() { # $1 = probe key, $2 = server; true when the probe could run it
  if contains "$out" "$1=SKIP"; then
    printf '  \033[33mSKIP\033[0m  %s is not installed via mason\n' "$2"
    return 1
  fi
}
if web_server WEB_JS ts_ls; then
  assert "ts_ls attaches to a .js file" contains "$out" "WEB_JS_ATTACHED=true"
  assert "...and finds the definition in the module it imports" contains "$out" "WEB_JS_DEFINITION=true"
fi
if web_server WEB_CSS cssls; then
  assert "cssls attaches to a .css file" contains "$out" "WEB_CSS_ATTACHED=true"
  assert "...and flags a misspelt property" contains "$out" "WEB_CSS_FLAGS_UNKNOWN_PROPERTY=true"
fi
if web_server WEB_HTML html; then
  assert "html attaches to a .html file" contains "$out" "WEB_HTML_ATTACHED=true"
  assert "...and completes an element name" contains "$out" "WEB_HTML_COMPLETES_ELEMENT=true"
fi
# The tokens vanish as a set when the probe dies; say what nvim said instead.
if ! contains "$out" "WEB_PROBE_DONE=true"; then
  no "the web language server probe did not run to the end"
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
fi

echo
echo "== each shellcheck finding in a shell script is reported once =="
# bash-language-server runs shellcheck itself whenever one is on PATH, on open
# and as you type. nvim-lint ran it a second time on every save, so after a
# :write each finding sat in the buffer twice: 8 diagnostics for 4 findings in
# the fixture below, measured, against 4 before the write. lint.lua is gone;
# this is what keeps a second runner from coming back, whatever it is.
#
# The fixture has two findings on each of two lines, and is already in the
# form shfmt writes, so format-on-save leaves the lines where they are. The
# probe waits for bashls to report, writes the file, then waits until nothing
# has changed the diagnostics for 2s, and counts (line, code) pairs. The code is
# compared as a number: bashls reports SC2086 and nvim-lint reported 2086, so
# comparing them as written would have found no duplicate at all. The write is
# counted and at least one finding is required, so a probe that never wrote, or
# a bashls that ran no shellcheck, cannot pass by finding nothing to repeat.
if [ ! -x "$NVIM_DATA/mason/bin/bash-language-server" ]; then
  printf '  \033[33mSKIP\033[0m  bash-language-server is not installed via mason\n'
elif ! command -v shellcheck >/dev/null 2>&1; then
  printf '  \033[33mSKIP\033[0m  shellcheck is not on PATH, so bashls has no findings to report\n'
else
  cat >"$SANDBOX/shdup_probe.lua" <<'LUA'
local said, wrote = vim.uv.now(), 0
vim.api.nvim_create_autocmd("DiagnosticChanged", {
  callback = function()
    said = vim.uv.now()
  end,
})
vim.api.nvim_create_autocmd("BufWritePost", {
  callback = function()
    wrote = wrote + 1
  end,
})
local function code(d)
  return tostring(d.code or ""):match("^S?C?(%d+)$")
end
vim.wait(20000, function()
  return #vim.lsp.get_clients({ bufnr = 0, name = "bashls" }) > 0
end, 50)
local attached = #vim.lsp.get_clients({ bufnr = 0, name = "bashls" }) > 0
vim.wait(20000, function()
  for _, d in ipairs(vim.diagnostic.get(0)) do
    if code(d) then
      return true
    end
  end
  return false
end, 50)
vim.cmd("write")
local at = vim.uv.now()
vim.wait(15000, function()
  return vim.uv.now() - at >= 1500 and vim.uv.now() - said >= 2000
end, 50)
local seen, found, twice = {}, 0, {}
for _, d in ipairs(vim.diagnostic.get(0)) do
  local c = code(d)
  if c then
    local key = (d.lnum + 1) .. ":SC" .. c
    if seen[key] then
      twice[#twice + 1] = key
    else
      seen[key] = true
      found = found + 1
    end
  end
end
print(string.format("SHDUP_ATTACHED=%s SHDUP_WROTE=%d SHDUP_FINDINGS=%d SHDUP_TWICE=%d SHDUP_REPEATED=%s",
  tostring(attached), wrote, found, #twice, table.concat(twice, ",")))
LUA
  # shellcheck disable=SC2016  # $foo and $bar are the fixture's findings
  printf '#!/bin/bash\necho $foo\necho $bar\n' >"$SANDBOX/shdup.sh"
  out="$(nv "$SANDBOX/shdup.sh" "luafile $SANDBOX/shdup_probe.lua")"
  shdup_found="$(printf '%s' "$out" | sed -n 's/.*SHDUP_FINDINGS=\([0-9]*\).*/\1/p' | head -1)"
  shdup_twice="$(printf '%s' "$out" | sed -n 's/.*SHDUP_TWICE=\([0-9]*\).*/\1/p' | head -1)"
  printf '    %s finding(s) after :write, %s of them reported more than once %s\n' \
    "${shdup_found:-an unread number of}" "${shdup_twice:-an unread number}" \
    "$(printf '%s' "$out" | sed -n 's/.*SHDUP_REPEATED=\([^ ]*\).*/\1/p' | head -1)"
  assert "bashls attaches to a shell script" contains "$out" "SHDUP_ATTACHED=true"
  assert "the probe wrote the file, which is when a second runner fires (guards a vacuous pass)" \
    contains "$out" "SHDUP_WROTE=1"
  assert "shellcheck's findings reached the buffer (guards a vacuous pass)" [ "${shdup_found:-0}" -ge 1 ]
  assert "no shellcheck finding is reported twice on the same line" [ "${shdup_twice:-1}" -eq 0 ]
  if ! contains "$out" "SHDUP_FINDINGS="; then
    printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  fi
fi

echo
echo "== format-on-save actually reformats =="
# conform is configured per filetype. A formatter named for a filetype whose
# binary is missing makes format-on-save a silent no-op for that filetype, which
# is indistinguishable from "my file was already tidy".
# "the file changed" is NOT enough: conform is configured with
# lsp_format = "fallback", so when the named formatter is missing lua_ls
# reformats instead and the file changes anyway. Verified by mutation — pointing
# lua at a nonexistent formatter left this assertion green. Ask conform which
# formatter it would actually use for the buffer, and require that it is the
# configured one AND that it is available.
#
# Nor is "changed" enough where the flags matter. sh passed it for as long as
# conform was appending its own -i after the configured flags: the file did
# change -- to 4-space indentation, which `make lint` then rejected. Given the
# exact text the formatter should produce, the check compares against that.
format_check() { # $1 = extension, $2 = ugly content, $3 = expected formatter, $4 = exact result (optional)
  local ext="$1" ugly="$2" want="$3" want_text="${4:-}"
  local f="$SANDBOX/fmt.$ext"
  # A formatter that is not installed is an environment fact, not a defect in
  # the config — skip and say which, the way every other suite here does. Only a
  # formatter that IS present but which conform will not offer is a failure.
  # This guard was lost when the assertion was rewritten to ask conform, and CI
  # duly reported two missing binaries as config failures.
  if ! command -v "$want" >/dev/null 2>&1 &&
    [ ! -x "$NVIM_DATA/mason/bin/$want" ]; then
    printf '  \033[33mSKIP\033[0m  %s: %s is not installed on this machine\n' "$ext" "$want"
    return 0
  fi
  printf '%s' "$ugly" >"$f"
  local out
  out="$(nv "$f" \
    'lua vim.wait(2000)' \
    'lua local ok, c = pcall(require, "conform"); if not ok then print("CONFORM=missing") else local fs = c.list_formatters(0); local names = {}; for _, x in ipairs(fs) do names[#names + 1] = x.name .. (x.available and ":available" or ":MISSING") end; print("FORMATTERS=" .. table.concat(names, ",")) end' \
    'lua vim.cmd("write")' \
    'lua vim.wait(4000)')"
  if ! contains "$out" "$want:available"; then
    # No attempt to echo conform's list back: nvim interleaves print output with
    # the file-write message on one line, and every extraction of it I tried
    # reported the path instead. The assertion is what matters, and "conform has
    # no available stylua for a .lua buffer" is actionable on its own.
    no "$ext: conform offers no available '$want' for this buffer"
  fi
  if [ -n "$want_text" ]; then
    # $( ) strips trailing newlines from both sides alike.
    if [ "$(cat "$f")" = "$(printf '%s' "$want_text")" ]; then
      ok "$ext is formatted on save by $want, into exactly the text expected of it"
    else
      no "$ext: saving did not produce the text $want should make of it (expected, then got):"
      printf '%s' "$want_text" | sed 's/^/      want| /'
      sed 's/^/      got | /' "$f"
    fi
  elif [ "$(cat "$f")" != "$ugly" ]; then
    ok "$ext is formatted on save by $want, which conform reports as available"
  else
    no "$ext: $want is available but the file was not reformatted on save"
  fi
}

format_check lua 'local   x=1
' stylua
# What `make lint` passes, -i 2 -ci: two spaces, and case arms indented under
# their `case`. The 8-space body tells -i 2 from conform's -i <shiftwidth>,
# which made it 4; the case arm tells -ci from its absence.
format_check sh 'if true; then
        echo hi
fi
case x in
a) echo a ;;
esac
' shfmt 'if true; then
  echo hi
fi
case x in
  a) echo a ;;
esac
'
format_check json '{"a":1,   "b":2}
' prettier
format_check scss '.a{.b{color:red}}
' prettier

echo
echo "== treesitter is set up, not just highlighting =="
# treesitter.lua returns early, and says why, when Neovim is older than 0.12 or
# nvim-treesitter cannot be required, and until it said so that failure made no
# sound. Highlighting a lua buffer is the WRONG thing to check, and was
# measured to be: with setup skipped, a lua buffer still has an active
# highlighter, because Neovim's own lua ftplugin starts one. What only setup
# provides is the textobject maps and the indentexpr, so those are what is
# asserted, every map by mode and desc, and three of them by pressing them.
#
# Lua is the fixture because Neovim ships its parser, so the maps do not depend
# on a parser download. The indentexpr does: nvim-treesitter's main branch has
# it set only where there is an indents query, and it installs that query with
# the parser, which takes the tree-sitter CLI. So with no CLI and no query that
# one is a skip; with the CLI it is asserted, because the parsers should then
# be there.
#
# Then a C file, for highlighting. On main nothing starts it except this config
# -- Neovim's own ftplugins do for lua, markdown, help and query only -- and
# without it a C file gets regex syntax and looks about right. Neovim ships the
# C parser and its highlights query too. And a text file, where no map may be
# set: ]] has to stay Vim's own section motion where there is no parser.
#
# Proven by hand: misspelling the nvim-treesitter module in a copy of the
# config fails every assertion here about what treesitter sets up -- the maps,
# the three keys, the indent and the C highlighting -- and nvim then prints the
# error treesitter.lua reports.
cat >"$SANDBOX/ts_probe.lua" <<'LUA'
local dir = vim.env.TS_DIR
local out = {}
local function maps(lhs)
  local modes, desc = "", nil
  for _, mode in ipairs({ "n", "x", "o" }) do
    local m = vim.fn.maparg(vim.keycode(lhs), mode, false, true)
    if not vim.tbl_isempty(m) and m.buffer == 1 then
      modes = modes .. mode
      desc = desc or m.desc
    end
  end
  return lhs .. "/" .. modes .. "=" .. (desc or "none"):gsub(" ", "_")
end
vim.cmd.edit(vim.fn.fnameescape(dir .. "/ts.lua"))
vim.wait(2000, function()
  return not maps("af"):find("=none$")
end, 50)
out[#out + 1] = "TS_FT=" .. vim.bo.filetype
out[#out + 1] = "TS_INDENT=" .. vim.bo.indentexpr
out[#out + 1] = "TS_LUA_INDENTS=" .. #vim.treesitter.query.get_files("lua", "indents")
local all = {}
for _, lhs in ipairs({ "af", "if", "ac", "ic", "aa", "ia", "]m", "]]", "]M", "][", "[m", "[[", "[M", "[]",
  "<leader>a", "<leader>A" }) do
  all[#all + 1] = maps(lhs)
end
out[#out + 1] = "TS_MAPS=" .. table.concat(all, ",")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("]m", "x", false)
out[#out + 1] = "TS_MOVE=" .. vim.api.nvim_win_get_cursor(0)[1]
local two = vim.api.nvim_buf_get_lines(0, 4, 5, false)[1] or ""
vim.api.nvim_win_set_cursor(0, { 5, (two:find("(a", 1, true) or 1) })
vim.api.nvim_feedkeys(vim.keycode("<leader>a"), "x", false)
out[#out + 1] = "TS_SWAP=[" .. (vim.api.nvim_buf_get_lines(0, 4, 5, false)[1] or "") .. "]"
vim.api.nvim_win_set_cursor(0, { 6, 4 })
vim.api.nvim_feedkeys('"_dif', "x", false)
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|")
out[#out + 1] = "TS_DIF_GONE=" .. tostring(not text:find("a + b", 1, true))
out[#out + 1] = "TS_DIF_KEPT=" .. tostring(text:find("return 1", 1, true) ~= nil and text:find("function two", 1, true) ~= nil)
vim.cmd.edit(vim.fn.fnameescape(dir .. "/ts.c"))
vim.wait(1000, function()
  return vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil
end, 50)
out[#out + 1] = "TS_C_FT=" .. vim.bo.filetype
out[#out + 1] = "TS_C_HL=" .. tostring(vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil)
vim.cmd.edit(vim.fn.fnameescape(dir .. "/ts.txt"))
out[#out + 1] = "TS_TXT_FT=" .. vim.bo.filetype .. " TS_TXT_MAPS=" .. maps("]]")
print(table.concat(out, " "))
LUA
printf 'local function one()\n    return 1\nend\n\nlocal function two(a, b)\n    return a + b\nend\n' >"$SANDBOX/ts.lua"
printf 'int f(int a)\n{\n    return a;\n}\n' >"$SANDBOX/ts.c"
printf 'plain text\n' >"$SANDBOX/ts.txt"
out="$(TS_DIR="$SANDBOX" nv "$SANDBOX/start.lua" 'lua vim.wait(1000)' "luafile $SANDBOX/ts_probe.lua")"
EXPECTED_TS_MAPS="af/xo=Select_outer_function,if/xo=Select_inner_function,ac/xo=Select_outer_class,ic/xo=Select_inner_class,aa/xo=Select_outer_argument,ia/xo=Select_inner_argument,]m/nxo=Next_function_start,]]/nxo=Next_class_start,]M/nxo=Next_function_end,][/nxo=Next_class_end,[m/nxo=Prev_function_start,[[/nxo=Prev_class_start,[M/nxo=Prev_function_end,[]/nxo=Prev_class_end,<leader>a/n=Swap_with_next_argument,<leader>A/n=Swap_with_prev_argument"
assert "the fixture is a lua buffer, which the ones below assume" contains "$out" "TS_FT=lua"
assert "every textobject map is set on the buffer, in master's modes, with its desc" \
  contains "$out" "TS_MAPS=$EXPECTED_TS_MAPS "
assert "]m from the first function lands on the second" contains "$out" "TS_MOVE=5"
assert "<leader>a swaps the argument under the cursor with the next" \
  contains "$out" "TS_SWAP=[local function two(b, a)]"
assert "dif deletes the body of the function the cursor is in" contains "$out" "TS_DIF_GONE=true"
assert "...and nothing outside it (guards a dif that deleted everything)" contains "$out" "TS_DIF_KEPT=true"
if contains "$out" "TS_LUA_INDENTS=0" && ! command -v tree-sitter >/dev/null 2>&1; then
  printf "  \033[33mSKIP\033[0m  indent: no tree-sitter CLI, so nvim-treesitter's lua queries were never installed\n"
else
  assert "indent comes from treesitter, not the filetype's own indentexpr" \
    contains "$out" "TS_INDENT=v:lua.require'nvim-treesitter'.indentexpr()"
fi
assert "the second fixture is a C buffer" contains "$out" "TS_C_FT=c"
assert "a C file is highlighted by treesitter, which only this config starts" \
  contains "$out" "TS_C_HL=true"
assert "a text file gets none of the maps, so ]] is still Vim's own" \
  contains "$out" "TS_TXT_FT=text TS_TXT_MAPS=]]/=none"
# Not an assertion; the ones above have already failed. When setup did not run,
# what nvim printed carries treesitter.lua's reason, which is the next thing
# anyone will want.
if ! contains "$out" "TS_MAPS=$EXPECTED_TS_MAPS " || ! contains "$out" "TS_C_HL=true"; then
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
fi

echo
echo "== nvim-treesitter's build installs the list, and clears what master left =="
# lazy runs this build on install and on restore, in the real data dir, which
# nothing here may build into. So the build function is taken out of
# treesitter.lua and called by hand, on a stand-in plugin directory, with a
# stand-in nvim-treesitter that records what it is asked for and finishes at
# once, and a stand-in tree-sitter on PATH for it to find.
#
# The parser list is asserted whole, the way the leader mappings are: when this
# fails it is usually not a bug but a parser added or removed, and this is the
# line that records it.
#
# Proven by hand on copies of treesitter.lua: deleting the two deletes fails
# both of their checks, and deleting the CLI check fails the last two.
#
# NO_TS_BIN holds nvim alone, so a PATH of it and the system's directories has
# no tree-sitter on it from Homebrew.
NO_TS_BIN="$TEST_TMP/no-ts-bin"
mkdir -p "$NO_TS_BIN"
ln -s "$(command -v nvim)" "$NO_TS_BIN/nvim"
EXPECTED_TS_PARSERS="lua,vim,vimdoc,bash,markdown,markdown_inline,html,css,json,yaml,toml,query,javascript,typescript,python,rust,c,go,gomod,gosum,gowork,gotmpl"
TS_FAKE_BIN="$TEST_TMP/ts-fake-bin"
mkdir -p "$TS_FAKE_BIN"
printf '#!/bin/sh\nexit 0\n' >"$TS_FAKE_BIN/tree-sitter"
chmod +x "$TS_FAKE_BIN/tree-sitter"
cat >"$SANDBOX/ts_build_probe.lua" <<'LUA'
local calls = {}
package.preload["nvim-treesitter"] = function()
  local function task()
    return { wait = function() return true end }
  end
  return {
    install = function(langs)
      calls[#calls + 1] = "install:" .. table.concat(langs, ",")
      return task()
    end,
    update = function()
      calls[#calls + 1] = "update"
      return task()
    end,
  }
end
local dir = arg[2]
for _, d in ipairs({ "parser", "parser-info", "lua" }) do
  vim.fn.mkdir(dir .. "/" .. d, "p")
end
vim.fn.writefile({ "" }, dir .. "/parser/scss.so")
vim.fn.writefile({ "" }, dir .. "/parser-info/scss.revision")
vim.fn.writefile({ "" }, dir .. "/lua/keep.lua")
local spec = dofile(arg[1])
local ok, err = pcall(spec[1].build, { dir = dir })
io.stdout:write(string.format("BUILD_OK=%s BUILD_ERR=[%s] BUILD_CALLS=%s PARSER_LEFT=%s INFO_LEFT=%s KEEP_LEFT=%s\n",
  tostring(ok), tostring(err or ""):gsub("%s", "_"), table.concat(calls, ";"),
  tostring(vim.uv.fs_stat(dir .. "/parser") ~= nil), tostring(vim.uv.fs_stat(dir .. "/parser-info") ~= nil),
  tostring(vim.uv.fs_stat(dir .. "/lua/keep.lua") ~= nil)))
LUA
out="$(PATH="$TS_FAKE_BIN:$NO_TS_BIN:/usr/bin:/bin" XDG_STATE_HOME="$STATE" XDG_CACHE_HOME="$CACHE" \
  nvim --clean --headless -l "$SANDBOX/ts_build_probe.lua" \
  "$NVIM_CONFIG/lua/rich/plugins/treesitter.lua" "$TEST_TMP/ts-plugin" 2>&1)"
assert "the build succeeds against an nvim-treesitter that does what it is asked" contains "$out" "BUILD_OK=true"
assert "it installs exactly the parser list, then updates what is installed" \
  contains "$out" "BUILD_CALLS=install:$EXPECTED_TS_PARSERS;update "
assert "it removes the parsers master built into the plugin directory" contains "$out" "PARSER_LEFT=false"
assert "...and their revision files" contains "$out" "INFO_LEFT=false"
assert "...and nothing else there (guards a build that deleted the plugin)" contains "$out" "KEEP_LEFT=true"
if ! contains "$out" "BUILD_OK=true"; then
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
fi
# The same build with no tree-sitter on PATH: a failed build is how lazy shows
# it, and it must not get as far as asking for a parser.
out="$(PATH="$NO_TS_BIN:/usr/bin:/bin" XDG_STATE_HOME="$STATE" XDG_CACHE_HOME="$CACHE" \
  nvim --clean --headless -l "$SANDBOX/ts_build_probe.lua" \
  "$NVIM_CONFIG/lua/rich/plugins/treesitter.lua" "$TEST_TMP/ts-plugin-nocli" 2>&1)"
# Spaces are underscores in BUILD_ERR, so the error is the only place this
# can come from.
assert "with no tree-sitter CLI the build fails, saying what to install" \
  contains "$out" "brew_install_tree-sitter-cli"
refute "...before it asks for a parser it cannot build" contains "$out" "BUILD_CALLS=install"

echo
echo "== a missing tree-sitter CLI is said once, not left to fail per parser =="
# main builds every parser with the tree-sitter CLI. Without it each install
# downloads the parser's source and then fails, one error per language, and
# auto-install does that again for every new filetype. treesitter.lua checks
# for the CLI first and says what to install instead. So: a language nvim-
# treesitter has a parser for and this machine does not, asked for in an nvim
# whose PATH holds nvim, the system's tools and nothing from Homebrew. Two of
# them, one after the other, because the second must not say it again.
#
# The probe reports the languages it picked and whether nvim found any
# tree-sitter at all, so a pass cannot come from there being nothing to
# install or from a CLI that was there after all. Nothing is downloaded: with no
# CLI, treesitter.lua does not start an install. Proven by hand on copies of
# the config: deleting the loud() call from have_cli() fails the first check,
# never setting warned_cli fails the second, and making have_cli() answer yes
# regardless fails the first and the last.
cat >"$SANDBOX/ts_cli_probe.lua" <<'LUA'
local parsers = require("nvim-treesitter.parsers")
local installed = require("nvim-treesitter").get_installed()
local langs = vim.tbl_keys(parsers)
table.sort(langs)
local picks = {}
for _, lang in ipairs(langs) do
  local p = parsers[lang]
  if #picks < 2 and p.install_info and p.tier ~= 4 and not vim.list_contains(installed, lang)
    and vim.treesitter.language.get_lang(lang) == lang and not vim.treesitter.language.add(lang) then
    picks[#picks + 1] = lang
  end
end
print("TS_CLI=[" .. vim.fn.exepath("tree-sitter") .. "] TS_PICKED=" .. (#picks == 2 and table.concat(picks, ",") or "none"))
for _, lang in ipairs(#picks == 2 and picks or {}) do
  vim.cmd.enew()
  vim.bo.filetype = lang
  vim.wait(500)
end
LUA
out="$(PATH="$CLIP_BIN:$NO_TS_BIN:/usr/bin:/bin" XDG_STATE_HOME="$STATE" XDG_CACHE_HOME="$CACHE" \
  nvim --headless "$SANDBOX/start.lua" -c 'lua vim.wait(1000)' -c "luafile $SANDBOX/ts_cli_probe.lua" -c 'qa!' 2>&1)"
if ! contains "$out" "TS_CLI=[]"; then
  printf '  \033[33mSKIP\033[0m  a tree-sitter CLI is on the system PATH, so its absence cannot be set up\n'
elif contains "$out" "TS_PICKED=none"; then
  no "found no language that nvim-treesitter knows and this machine has not installed (guards a vacuous pass)"
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
else
  printf '    %s\n' "$(printf '%s' "$out" | grep -o 'TS_PICKED=[^ ]*' | head -1)"
  said="$(printf '%s\n' "$out" | grep -c 'no tree-sitter on PATH (brew install tree-sitter-cli)')"
  assert "with no tree-sitter CLI, treesitter.lua says which to install" [ "${said:-0}" -ge 1 ]
  assert "...once, not once per language" [ "${said:-0}" -le 1 ]
  refute "...and does not start an install that can only fail" contains "$out" "Downloading"
fi

echo
echo "== the leader mappings resolve to what the config claims =="
# A lazy `keys` entry that never registers leaves a key that silently does
# nothing — the plugin is configured, the binding is not there.
out="$(nv "$SANDBOX/start.lua" \
  'lua vim.wait(2000)' \
  'lua for _, k in ipairs({ "<leader>ff", "<leader>cf", "<leader>ha" }) do local m = vim.fn.maparg(vim.keycode(k), "n", false, true); print(k .. "=" .. ((m and m.desc) or (m and next(m) and "mapped") or "MISSING")) end')"
assert "<leader>ff is mapped (telescope)" contains "$out" "<leader>ff=Find files"
assert "<leader>cf is mapped (conform)" contains "$out" "<leader>cf=Format buffer"
assert "<leader>ha is mapped (harpoon, via lazy keys)" contains "$out" "<leader>ha=Harpoon"

echo
echo "== the whole set of leader mappings, by name =="
# The three assertions above name three keys. This names all of them, for the
# same reason test-performance.sh asserts the eager plugin SET rather than a
# startup time: a lazy `keys` entry that stops registering leaves a key that
# silently does nothing, and checking three of thirty-four would not notice.
#
# Deliberately the exact set, not a minimum. A binding appearing is as worth
# knowing as one vanishing — a plugin update that quietly claims <leader>x is
# how you lose a mapping you use without ever being told.
#
# When this fails it is usually not a bug: you added or removed a mapping and
# this is the line that records it. Update the list and the diff says which key
# changed, which is the point.
EXPECTED_LEADER_N="<leader>9s,<leader>9x,<leader>Q,<leader>Y,<leader>ca,<leader>cf,<leader>d,<leader>e,<leader>fb,<leader>fd,<leader>ff,<leader>fg,<leader>fh,<leader>fo,<leader>fr,<leader>fs,<leader>gs,<leader>h1,<leader>h2,<leader>h3,<leader>h4,<leader>ha,<leader>hh,<leader>hr,<leader>ld,<leader>lq,<leader>q,<leader>rn,<leader>s,<leader>tt,<leader>u,<leader>w,<leader>x,<leader>y"

# Visual mode as well as normal, because they are declared separately and go
# missing separately: <leader>9v is visual-only, so the normal-mode list above
# would never notice it disappearing — which is exactly what let the README
# advertise it with nothing anywhere asserting it existed.
EXPECTED_LEADER_V="<leader>9v,<leader>ca,<leader>cf,<leader>d,<leader>p,<leader>y"

# The leader is a space, so a leader mapping is one whose lhs starts with one;
# nvim reports the raw lhs, not the <leader> form.
leader_set() { # $1 = mode, as nvim_get_keymap takes it
  nv "$SANDBOX/start.lua" \
    'lua vim.wait(2500)' \
    "$(printf 'lua local out = {} for _, m in ipairs(vim.api.nvim_get_keymap("%s")) do if m.lhs:sub(1, 1) == " " then out[#out + 1] = "<leader>" .. m.lhs:sub(2) end end table.sort(out) print("LEADER:" .. table.concat(out, ","))' "$1")"
}

for mode in n v; do
  case "$mode" in
    n) want="$EXPECTED_LEADER_N" name="normal" ;;
    v) want="$EXPECTED_LEADER_V" name="visual" ;;
  esac
  actual_leader="$(printf '%s' "$(leader_set "$mode")" | tr -d '\r' | grep -o 'LEADER:[^[:space:]]*' | head -1 | sed 's/^LEADER://')"

  if [ -z "$actual_leader" ]; then
    no "could not read the $name-mode keymap list out of nvim at all"
    continue
  fi
  printf '    %s %s-mode leader mappings\n' "$(printf '%s' "$actual_leader" | tr ',' '\n' | grep -c .)" "$name"
  if [ "$actual_leader" = "$want" ]; then
    ok "the $name-mode leader mappings are exactly the expected set"
  else
    no "the $name-mode leader mappings have changed"
    # Name the difference. A diff of two long comma-separated strings is not
    # something anyone should have to read by eye at 2am.
    printf '%s' "$want" | tr ',' '\n' | sort >"$TEST_TMP/want"
    printf '%s' "$actual_leader" | tr ',' '\n' | sort >"$TEST_TMP/got"
    comm -23 "$TEST_TMP/want" "$TEST_TMP/got" | sed 's/^/      MISSING now:  /'
    comm -13 "$TEST_TMP/want" "$TEST_TMP/got" | sed 's/^/      NEW since:    /'
  fi
done

echo
echo "== every command a lazy stub names exists once its plugin loads =="
# A lazy `cmd` entry is a stub: lazy defines the name, and the first use
# deletes the stub, loads the plugin and runs the command again, expecting the
# plugin to have defined the real one by then. If it has not, the name still
# completes on the command line and fails only when it is used. Both ways that
# happened here: trouble was never set up, so :Trouble never existed and
# <leader>tt was E492; and fugitive's list named :Gblame and :Glog, which
# fugitive no longer defines.
#
# Read from lazy rather than listed here, so a plugin that gains a cmd entry is
# covered without anyone remembering this section exists. Proven by hand both
# ways: deleting trouble's `opts = {}` fails the :Trouble line, and putting
# "Gblame" back in fugitive's list fails that one.
cat >"$SANDBOX/cmd_probe.lua" <<'LUA'
local Plugin = require("lazy.core.plugin")
local found = {}
for name, plugin in pairs(require("lazy.core.config").plugins) do
  local cmds = Plugin.values(plugin, "cmd", true)
  if #cmds > 0 then
    require("lazy").load({ plugins = { name } })
    for _, c in ipairs(cmds) do
      found[#found + 1] = string.format("%s:%s:%d", name, c, vim.fn.exists(":" .. c))
    end
  end
end
table.sort(found)
print("LAZYCMDS=" .. table.concat(found, ","))
LUA
out="$(nv "$SANDBOX/start.lua" "luafile $SANDBOX/cmd_probe.lua")"
lazy_cmds="$(printf '%s' "$out" | tr -d '\r' | grep -o 'LAZYCMDS=[^[:space:]]*' | head -1 | sed 's/^LAZYCMDS=//')"
# The vacuity guard: an empty list would pass every assertion in the loop by
# running none of them.
if [ -z "$lazy_cmds" ]; then
  no "could not read a single lazy cmd stub out of nvim — this section would assert nothing"
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
else
  printf '    %s command(s) named by lazy cmd stubs\n' "$(printf '%s' "$lazy_cmds" | tr ',' '\n' | grep -c .)"
  for entry in $(printf '%s' "$lazy_cmds" | tr ',' ' '); do
    cmd_plugin="${entry%%:*}"
    cmd_rest="${entry#*:}"
    cmd_exists="${cmd_rest##*:}"
    # exists() is 2 for a user command that matches in full. :-0 is the
    # failing side: a figure that could not be read must not pass.
    assert ":${cmd_rest%%:*} exists once $cmd_plugin has loaded" [ "${cmd_exists:-0}" = 2 ]
  done
fi

echo
echo "== a count reaches ]q [q ]d [d =="
# Neovim's own versions of these four take a count; this config replaces them,
# and the replacements used to throw it away: 3]q moved one entry, and so did
# 3]d. Seven quickfix entries and seven diagnostics, one per line, and each
# jump of three from an end has to land on the fourth. The maps are checked to
# be this config's first, because Neovim's defaults honour a count too -- with
# the overrides gone, every count assertion would pass on the defaults.
#
# A plain ]q is asserted as well: v:count1 is 1 with no count typed, and a
# v:count there would have been 0 -- which cnext rejects.
cat >"$SANDBOX/count_probe.lua" <<'LUA'
local buf = vim.api.nvim_get_current_buf()
local out = {}
local function desc(lhs)
  local m = vim.fn.maparg(lhs, "n", false, true)
  return (m and m.desc or "none"):gsub(" ", "_")
end
out[#out + 1] = "MAP_NQ=" .. desc("]q") .. " MAP_ND=" .. desc("]d")
local items = {}
for i = 1, 7 do
  items[#items + 1] = { bufnr = buf, lnum = i, col = 1, text = "entry " .. i }
end
vim.fn.setqflist(items)
vim.cmd("cfirst")
vim.api.nvim_feedkeys("3]q", "x", false)
out[#out + 1] = "QF_NEXT=" .. vim.fn.getqflist({ idx = 0 }).idx
out[#out + 1] = "QF_NEXT_LINE=" .. vim.api.nvim_win_get_cursor(0)[1]
vim.api.nvim_feedkeys("]q", "x", false)
out[#out + 1] = "QF_PLAIN=" .. vim.fn.getqflist({ idx = 0 }).idx
vim.cmd("clast")
vim.api.nvim_feedkeys("3[q", "x", false)
out[#out + 1] = "QF_PREV=" .. vim.fn.getqflist({ idx = 0 }).idx
local ns = vim.api.nvim_create_namespace("count_probe")
local diags = {}
for i = 0, 6 do
  diags[#diags + 1] = { lnum = i, col = 0, message = "d" .. i, severity = vim.diagnostic.severity.WARN }
end
vim.diagnostic.set(ns, buf, diags)
out[#out + 1] = "DIAGS=" .. #vim.diagnostic.get(buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("3]d", "x", false)
out[#out + 1] = "D_NEXT=" .. vim.api.nvim_win_get_cursor(0)[1]
vim.api.nvim_win_set_cursor(0, { 7, 0 })
vim.api.nvim_feedkeys("3[d", "x", false)
out[#out + 1] = "D_PREV=" .. vim.api.nvim_win_get_cursor(0)[1]
print(table.concat(out, " "))
LUA
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' >"$SANDBOX/count.txt"
out="$(nv "$SANDBOX/count.txt" 'lua vim.wait(1500)' "luafile $SANDBOX/count_probe.lua")"
# Each figure defaults to 0, which no assertion below accepts.
count_fig() { printf '%s' "$out" | sed -n "s/.*$1=\([0-9]*\).*/\1/p" | head -1; }
qf_next="$(count_fig QF_NEXT)"
qf_next_line="$(count_fig QF_NEXT_LINE)"
qf_plain="$(count_fig QF_PLAIN)"
qf_prev="$(count_fig QF_PREV)"
diag_n="$(count_fig DIAGS)"
d_next="$(count_fig D_NEXT)"
d_prev="$(count_fig D_PREV)"
printf '    3]q -> entry %s, then ]q -> %s; 3[q from 7 -> %s; 3]d -> line %s; 3[d from 7 -> line %s\n' \
  "${qf_next:-0}" "${qf_plain:-0}" "${qf_prev:-0}" "${d_next:-0}" "${d_prev:-0}"
assert "]q and ]d are this config's maps, not Neovim's defaults (guards a vacuous pass)" \
  contains "$out" "MAP_NQ=Next_quickfix_item MAP_ND=Next_diagnostic"
assert "the seven diagnostics to jump between are there" [ "${diag_n:-0}" -eq 7 ]
assert "3]q from the first entry lands on the fourth" [ "${qf_next:-0}" -eq 4 ]
# Entry N is on line N. The two defaults differ so that neither figure being
# missing can make them equal.
assert "...on that entry's line, so zz did not take the count as well" \
  [ "${qf_next_line:-0}" -eq "${qf_next:--1}" ]
plain_step=0
[ "${qf_next:-0}" -ge 1 ] && plain_step=$((${qf_plain:-0} - qf_next))
assert "a plain ]q after it still moves one entry" [ "$plain_step" -eq 1 ]
assert "3[q from the last entry lands on the fourth" [ "${qf_prev:-0}" -eq 4 ]
assert "3]d from line 1 lands on the fourth diagnostic" [ "${d_next:-0}" -eq 4 ]
assert "3[d from line 7 lands on the fourth diagnostic" [ "${d_prev:-0}" -eq 4 ]

echo
echo "== Enter in the completion menu is a newline unless an item was chosen =="
# cmp.lua maps <CR> to confirm({ select = false }) and checks/repo.sh reads that
# line; this presses it. A buffer holding "alphabet", "alpha" typed on the line
# below, and cmp's menu open offering alphabet with nothing selected: Enter has
# to leave "alpha" and start a new line, where select = true wrote "alphabet"
# and no line break. Then the same with <C-y>, which has to accept "alphabet".
# That is the control: it shows the menu really offered the word and a confirm
# through this config's maps really inserts it, so the newline is Enter's
# choice and not cmp missing or broken.
#
# Typed the way a person types, which is what the timers are for. cmp completes
# on TextChangedI only when the cursor has moved one column since the last one,
# so "alph" fed at once and then "a" on its own opens the menu, and five letters
# fed at once read as a paste and open nothing. nvim_feedkeys with "x!" stays in
# Insert mode once the typeahead runs out, and the timers run while it waits:
# they type the last letter, wait for the menu, press the key, wait for the
# buffer to change, then type "next" and leave Insert mode. The key and "next"
# are fed apart because fed together, here, nvim never left Insert mode. A
# watchdog exits nvim after 20s, so a probe that sticks fails instead of
# hanging the suite. A .txt, so no language server can preselect an item.
cat >"$SANDBOX/cmp_probe.lua" <<'LUA'
local key = vim.keycode(vim.env.CMP_KEY)
local t0 = vim.uv.now()
local menu, offered, selected = false, false, "unread"
local function lines()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|")
end
local function report(tag)
  io.stdout:write(string.format("CMP_%s CMP_MENU=%s CMP_OFFERED=%s CMP_SELECTED=%s CMP_LINES=%s\n", tag,
    tostring(menu), tostring(offered), selected, lines()))
  io.stdout:flush()
end
local spec = require("lazy.core.config").plugins["nvim-cmp"]
if not (spec and vim.uv.fs_stat(spec.dir)) then
  io.stdout:write("CMP_PLUGIN=missing\n")
  return
end
vim.defer_fn(function()
  report("WATCHDOG")
  os.exit(1)
end, 20000)
local function type_next()
  if lines() == "alphabet soup|alpha" and vim.uv.now() - t0 < 10000 then
    return vim.defer_fn(type_next, 20)
  end
  vim.defer_fn(function()
    vim.api.nvim_feedkeys(vim.keycode("next<Esc>"), "nt", false)
  end, 100)
end
local function press()
  local cmp = package.loaded.cmp
  if cmp and cmp.visible() then
    menu = true
    for _, e in ipairs(cmp.get_entries()) do
      offered = offered or e:get_word() == "alphabet"
    end
    local e = cmp.get_selected_entry()
    selected = e and e:get_word() or "none"
    vim.api.nvim_feedkeys(key, "mt", false)
    vim.defer_fn(type_next, 20)
  elseif vim.uv.now() - t0 > 8000 then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nt", false)
  else
    vim.defer_fn(press, 20)
  end
end
local function last_letter()
  if lines() ~= "alphabet soup|alph" and vim.uv.now() - t0 < 8000 then
    return vim.defer_fn(last_letter, 20)
  end
  vim.api.nvim_feedkeys("a", "mt", false)
  vim.defer_fn(press, 20)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alphabet soup", "" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.defer_fn(last_letter, 20)
vim.api.nvim_feedkeys("Aalph", "tx!", false)
report("DONE")
LUA
: >"$SANDBOX/cmp.txt"
cmp_press() { # $1 = the key, as vim.keycode takes it; prints what the buffer ended up holding
  local got
  got="$(CMP_KEY="$1" nv "$SANDBOX/cmp.txt" 'lua vim.wait(500)' "luafile $SANDBOX/cmp_probe.lua")"
  printf '%s\n' "$got"
  # Not an assertion; the ones after it fail on their own. When the probe did
  # not finish, what nvim printed is the next thing anyone will want.
  if ! contains "$got" "CMP_DONE" && ! contains "$got" "CMP_PLUGIN=missing"; then
    printf '      nvim said: %s\n' "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-200)" >&2
  fi
}
out="$(cmp_press '<CR>')"
if contains "$out" "CMP_PLUGIN=missing"; then
  printf '  \033[33mSKIP\033[0m  nvim-cmp is not installed, so there is no menu to press Enter in\n'
else
  printf '    Enter: %s\n' "$(printf '%s' "$out" | grep -o 'CMP_LINES=.*' | head -1)"
  # Without these the lines below could be from a menu that never opened.
  assert "cmp's menu was open, offering alphabet, when Enter was pressed (guards a vacuous pass)" \
    contains "$out" "CMP_MENU=true CMP_OFFERED=true"
  assert "...with nothing selected in it" contains "$out" "CMP_SELECTED=none"
  assert "Enter with nothing selected keeps the typed word and starts a new line" \
    contains "$out" "CMP_DONE CMP_MENU=true CMP_OFFERED=true CMP_SELECTED=none CMP_LINES=alphabet soup|alpha|next"
  out="$(cmp_press '<C-y>')"
  printf '    <C-y>: %s\n' "$(printf '%s' "$out" | grep -o 'CMP_LINES=.*' | head -1)"
  assert "<C-y> with nothing selected still accepts the first item, so the newline above was Enter's choice" \
    contains "$out" "CMP_DONE CMP_MENU=true CMP_OFFERED=true CMP_SELECTED=none CMP_LINES=alphabet soup|alphabetnext"
fi

echo
echo "== one clipboard: yank, paste and delete all go through the system's =="
# What options.lua and keymaps.lua claim, checked by doing it: yy has to land
# on pbcopy, p has to read pbpaste, and the two void-register maps have to
# leave the clipboard alone. Plain dd is asserted to WRITE it, because that is
# the documented cost, and without it the <leader>d assertion could pass on a
# config where nothing reached the clipboard at all.
#
# The shims are checked FIRST. If nvim resolved pbcopy anywhere else, every
# probe below would be writing to a real clipboard, so a failure there skips
# them rather than carrying on.
#
# The leader maps are fed as keys, not run with :normal. Ex strips the space
# between a command and its argument, so `execute "normal \<Space>dd"` runs a
# plain dd -- and the <leader>d assertion failed on a correct config until that
# was found. vim.keycode expands <leader> from mapleader, so each probe says
# what it means.
printf 'alpha\nbeta\n' >"$SANDBOX/clip.txt"
out="$(nv "$SANDBOX/clip.txt" \
  'lua print("PBCOPY=" .. vim.fn.exepath("pbcopy") .. " PBPASTE=" .. vim.fn.exepath("pbpaste") .. " CB=" .. vim.o.clipboard)')"
if contains "$out" "PBCOPY=$CLIP_BIN/pbcopy PBPASTE=$CLIP_BIN/pbpaste"; then
  ok "nvim resolves pbcopy and pbpaste to this suite's shims, not the real clipboard"
  # Read straight after startup, which is what a vim.schedule'd set would fail.
  assert "clipboard=unnamedplus is already set when a -c command runs" contains "$out" "CB=unnamedplus"

  rm -f "$CLIP_FILE"
  nv "$SANDBOX/clip.txt" 'normal! jyy' >/dev/null
  assert "yy puts the line on the system clipboard" [ "$(cat "$CLIP_FILE" 2>/dev/null)" = "beta" ]

  # From mid-line, so Neovim's own Y (to end of line) would copy "lpha".
  rm -f "$CLIP_FILE"
  nv "$SANDBOX/clip.txt" 'lua vim.api.nvim_feedkeys(vim.keycode("l<leader>Y"), "mx", false)' >/dev/null
  assert "<leader>Y still copies the whole line, as it did before unnamedplus" \
    [ "$(cat "$CLIP_FILE" 2>/dev/null)" = "alpha" ]

  printf 'from another app\n' >"$CLIP_FILE"
  out="$(nv "$SANDBOX/clip.txt" 'normal! p' 'lua print("LINE2=" .. vim.fn.getline(2))')"
  assert "p pastes what was copied outside nvim" contains "$out" "LINE2=from another app"

  printf 'keep me\n' >"$CLIP_FILE"
  nv "$SANDBOX/clip.txt" 'normal! dd' >/dev/null
  assert "dd replaces the clipboard too: the cost options.lua documents" \
    [ "$(cat "$CLIP_FILE")" = "alpha" ]

  printf 'keep me\n' >"$CLIP_FILE"
  out="$(nv "$SANDBOX/clip.txt" \
    'lua vim.api.nvim_feedkeys(vim.keycode("<leader>dd"), "mx", false)' \
    'lua print("LINES=" .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))')"
  # The deletion is asserted as well: a <leader>d that deleted nothing would
  # leave the clipboard alone too.
  assert "<leader>d deletes the line" contains "$out" "LINES=beta"
  assert "...without replacing the clipboard" [ "$(cat "$CLIP_FILE")" = "keep me" ]

  printf 'keep me' >"$CLIP_FILE"
  out="$(nv "$SANDBOX/clip.txt" \
    'lua vim.api.nvim_feedkeys(vim.keycode("jviw<leader>p"), "mx", false)' \
    'lua print("LINE2=" .. vim.fn.getline(2))')"
  assert "<leader>p pastes the clipboard over a selection" contains "$out" "LINE2=keep me"
  assert "...and the clipboard still holds the pasted text, not the text it replaced" \
    [ "$(cat "$CLIP_FILE")" = "keep me" ]

  # The case the old "_dP got wrong: a selection that ends the line. "_d left the
  # cursor on the space before the gap and P put in front of it, so this came
  # out "fooX ". A whole-line selection, as above, cannot show it.
  printf 'foo bar\n' >"$SANDBOX/clip_eol.txt"
  printf 'X' >"$CLIP_FILE"
  # shellcheck disable=SC2016  # $ is vim's end-of-line motion, not the shell's
  out="$(nv "$SANDBOX/clip_eol.txt" \
    'lua vim.api.nvim_feedkeys(vim.keycode("$viw<leader>p"), "mx", false)' \
    'lua print("EOL=[" .. vim.fn.getline(1) .. "]")')"
  assert "<leader>p over the last word of a line puts it where the word was" contains "$out" "EOL=[foo X]"
else
  no "nvim did not resolve pbcopy/pbpaste to the shims; skipped every probe that would write a clipboard"
  printf '      nvim said: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
fi

echo
echo "== quitting writes nothing into nvim's cwd =="
# 99 keeps its request history in ./tmp/99-state and writes it from a
# VimLeavePre hook its setup registers. The path is resolved when the hook
# runs, so it lands in nvim's cwd at quit, wherever nvim was started. While 99
# loaded at every start, every nvim that quit in a directory with a tmp/ wrote
# one there: this repo has one, so a run of this suite from the repo root did.
# 99 now loads on its keys, so a plain start and quit must leave tmp/ empty.
# Neither nvim below changes directory, so each one quits in CWD99.
#
# Two guards against a vacuous pass. The probe reports whether 99 loaded, so a
# run in which nvim never started cannot pass by writing nothing; and the same
# start and quit with 99 loaded by hand must write the file, so a 99 that has
# moved its state somewhere else cannot pass either.
CWD99="$TEST_TMP/cwd99"
mkdir -p "$CWD99/tmp"
out="$(cd "$CWD99" && nv "$SANDBOX/start.lua" \
  'lua print("LOADED_99=" .. tostring(require("lazy.core.config").plugins["99"]._.loaded ~= nil))')"
assert "a plain start does not load 99" contains "$out" "LOADED_99=false"
refute "...and quitting leaves no tmp/99-state in nvim's cwd" [ -e "$CWD99/tmp/99-state" ]
(cd "$CWD99" && nv "$SANDBOX/start.lua" 'lua require("lazy").load({ plugins = { "99" } })' >/dev/null)
assert "with 99 loaded, quitting does write it, so the check above can fail" \
  [ -e "$CWD99/tmp/99-state" ]

echo
echo "== nothing leaked into the real config or repo =="
assert "the scratch state dir was used" [ -d "$STATE" ]
refute "no stray files were left in the sandbox's parent" [ -e "$TEST_TMP/shada" ]
# vim.loader names a compiled file after the path it came from, so this run's
# leftovers are the names holding this run's scratch dir. The scratch cache
# having some is what gives the real one having none a meaning: a loader that
# cached nothing at all would pass that on its own.
run_tag="$(basename "$TEST_TMP")"
real_luac="${XDG_CACHE_HOME:-$HOME/.cache}/nvim/luac"
ours="$(find "$CACHE/nvim/luac" -maxdepth 1 -name "*$run_tag*" 2>/dev/null | wc -l | tr -d ' ')"
leaked="$(find "$real_luac" -maxdepth 1 -name "*$run_tag*" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${ours:-0}" -eq 0 ] && [ "${leaked:-1}" -eq 0 ]; then
  printf '  \033[33mSKIP\033[0m  vim.loader cached nothing this run loaded, so nothing could have leaked\n'
else
  assert "the lua this run loaded was compiled into the scratch cache" [ "${ours:-0}" -ge 1 ]
  assert "and none of it into the real one, where nothing prunes it" [ "${leaked:-1}" -eq 0 ]
fi

finish
