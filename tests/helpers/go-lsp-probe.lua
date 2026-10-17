-- What lsp.lua claims for Go, asked of a running gopls.
--
-- Each question in a folder this probe builds under tempname():
--   mod/      a module (go.mod): gopls roots there, completes strings.ToUpper
--             and reports an unused variable, the compiler's own error
--   loose/    .go files and no go.mod: gopls roots at the folder, so a file
--             created beside main.go after it was opened is seen
--   home/     a .go directly in $HOME still gets no root at all
--
-- Run as `nvim --headless -c 'luafile go-lsp-probe.lua'`. It cds into its own
-- folder, deletes it on the way out and quits nvim itself. Every line it prints
-- is KEY=value, for tests/test-nvim.sh to assert on; a value that could not be
-- established is printed as false or SKIP, never left out.

local function emit(k, v)
    io.stdout:write(("%s=%s\n"):format(k, tostring(v)))
end

local function finish()
    emit("GO_PROBE_DONE", true)
    -- Stop the servers before quitting: their file watchers otherwise report the
    -- folder vanishing when VimLeave deletes it.
    vim.lsp.stop_client(vim.lsp.get_clients())
    vim.wait(3000, function()
        return #vim.lsp.get_clients() == 0
    end, 50)
    vim.cmd("qa!")
end

-- A hang must still end in output the suite can read, not a killed process.
-- os.exit because this fires inside the event loop, where :qa is not allowed.
local watchdog = vim.uv.new_timer()
watchdog:start(150000, 0, function()
    io.stdout:write("GO_TIMED_OUT=true\n")
    os.exit(1)
end)

local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")
-- cd in, and delete on VimLeave rather than before quitting: a plugin that
-- writes into the cwd on its way out (99 saves ./tmp/99-state) then writes in
-- here, and it is gone after it has.
vim.cmd.cd(vim.fn.fnameescape(base))
vim.api.nvim_create_autocmd("VimLeave", {
    callback = function()
        vim.fn.delete(base, "rf")
    end,
})

-- By path rather than on PATH: mason puts its bin dir on PATH when it loads,
-- and nothing has loaded it yet. gopls also needs the go command itself.
if vim.fn.executable(vim.fn.stdpath("data") .. "/mason/bin/gopls") == 0 then
    emit("GO", "SKIP")
    return finish()
end
if vim.fn.executable("go") == 0 then
    emit("GO", "SKIP_NO_GO")
    return finish()
end

-- The loose and home questions are about folders with NO marker above them.
-- Written out rather than read from lspconfig, which has not loaded yet; a
-- marker it adds later would fail the root assertion, not pass it.
local above = vim.fs.root(base, { "go.work", "go.mod", ".git" })
emit("GO_NO_MARKER_ABOVE", above == nil)
if above then
    return finish()
end

local function client_of(buf)
    local c = vim.lsp.get_clients({ bufnr = buf, name = "gopls" })[1]
    return c and c.initialized and c or nil
end

local function open(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.wait(30000, function()
        return client_of(buf) ~= nil
    end, 50)
    return buf, client_of(buf)
end

-- Compared by realpath: nvim resolves symlinks in buffer names on macOS, and the
-- default $TMPDIR sits under one (/var -> /private/var).
local function same_dir(a, b)
    return a ~= nil and b ~= nil and vim.uv.fs_realpath(a) == vim.uv.fs_realpath(b)
end

local function has_diag(buf, text)
    for _, d in ipairs(vim.diagnostic.get(buf)) do
        if d.message:find(text, 1, true) then
            return true
        end
    end
    return false
end

-- Polled by hand rather than inside a vim.wait predicate: request_sync blocks,
-- and calling it from a predicate hung pyright-probe.lua until it was killed.
local function completes(client, buf, line, character, want)
    local deadline = vim.uv.hrtime() + 15e9
    repeat
        local r = client:request_sync("textDocument/completion", {
            textDocument = { uri = vim.uri_from_bufnr(buf) },
            position = { line = line, character = character },
        }, 10000, buf)
        for _, it in ipairs(r and r.result and (r.result.items or r.result) or {}) do
            if it.label == want then
                return true
            end
        end
        vim.wait(250)
    until vim.uv.hrtime() > deadline
    return false
end

-- 1. A module.
local mod = base .. "/mod"
vim.fn.mkdir(mod, "p")
vim.fn.writefile({ "module example.com/probe", "", "go 1.21" }, mod .. "/go.mod")
vim.fn.writefile({
    "package main",
    "",
    'import "strings"',
    "",
    "func main() {",
    '\tx := strings.ToUpper("a")',
    "}",
}, mod .. "/main.go")
local buf, client = open(mod .. "/main.go")
emit("GO_MOD_ATTACHED", client ~= nil)
if client then
    emit("GO_MOD_ROOT_IS_MODULE", same_dir(client.root_dir, mod))
    -- Just after "strings.", where every member of the package is a candidate.
    emit("GO_MOD_COMPLETES_STDLIB", completes(client, buf, 5, #"\tx := strings.", "ToUpper"))
    emit(
        "GO_MOD_DIAGNOSES",
        vim.wait(20000, function()
            return has_diag(buf, "declared and not used: x")
        end, 100)
    )
end

-- 2. A folder of loose files. util.go is there before main.go is opened;
-- later.go is written after, the way the next file of an exercise is.
local loose = base .. "/loose"
vim.fn.mkdir(loose, "p")
vim.fn.writefile({ "package main", "", "func helper() int { return 1 }" }, loose .. "/util.go")
vim.fn.writefile({
    "package main",
    "",
    'import "fmt"',
    "",
    "func main() {",
    "\tfmt.Println(helper(), later())",
    "}",
}, loose .. "/main.go")
local lbuf, lclient = open(loose .. "/main.go")
emit("GO_LOOSE_ATTACHED", lclient ~= nil)
if lclient then
    emit("GO_LOOSE_ROOT_IS_FILE_DIR", same_dir(lclient.root_dir, loose))
    -- Precondition: gopls has type-checked main.go and found later() missing.
    -- Without it, "later resolves" below could just mean gopls never looked.
    local flagged = vim.wait(20000, function()
        return has_diag(lbuf, "undefined: later")
    end, 100)
    emit("GO_LOOSE_FLAGS_MISSING_BEFORE", flagged)
    emit("GO_LOOSE_SEES_EXISTING_SIBLING", flagged and not has_diag(lbuf, "undefined: helper"))
    vim.fn.writefile({ "package main", "", "func later() int { return 2 }" }, loose .. "/later.go")
    -- Touch main.go the way typing would, so gopls re-checks it either way.
    vim.api.nvim_buf_set_lines(lbuf, -1, -1, false, { "" })
    local t0 = vim.uv.hrtime()
    local resolved = flagged
        and vim.wait(15000, function()
            return not has_diag(lbuf, "undefined: later")
        end, 100)
    emit("GO_LOOSE_RESOLVES_AFTER_CREATE", resolved)
    emit("GO_LOOSE_RESOLVE_MS", math.floor((vim.uv.hrtime() - t0) / 1e6))
end

-- 3. A .go directly in $HOME must keep no root, or gopls would load the whole
-- home directory. HOME points at a scratch folder only while :edit runs, which
-- is when root_dir reads it.
local fakehome = base .. "/home"
vim.fn.mkdir(fakehome, "p")
vim.fn.writefile({ "package main", "", "func main() {}" }, fakehome .. "/loose.go")
local real_home = vim.env.HOME
vim.env.HOME = fakehome
local ok_edit = pcall(vim.cmd.edit, vim.fn.fnameescape(fakehome .. "/loose.go"))
vim.env.HOME = real_home
local hbuf = vim.api.nvim_get_current_buf()
vim.wait(30000, function()
    return client_of(hbuf) ~= nil
end, 50)
local hclient = client_of(hbuf)
emit("GO_HOME_ATTACHED", ok_edit and hclient ~= nil)
emit("GO_HOME_STAYS_ROOTLESS", ok_edit and hclient ~= nil and hclient.root_dir == nil)

finish()
