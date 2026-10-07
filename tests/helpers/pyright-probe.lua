-- What lsp.lua's pyright config claims, asked of a running pyright.
--
-- Three questions, each in a folder this probe builds under tempname():
--   1. In a folder with no root marker, does a module created AFTER the file
--      that imports it was opened get resolved, and complete?
--   2. Does a .py sitting directly in $HOME still get no root at all?
--   3. Does a package installed only in the folder's .venv resolve without the
--      venv being activated?
--
-- Run as `nvim --headless -c 'luafile pyright-probe.lua'`. It cds into its own
-- folder, deletes it on the way out and quits nvim itself. Every line it prints
-- is KEY=value, for tests/test-nvim.sh to assert on; a value that could not be
-- established is printed as false or SKIP, never left out.

local function emit(k, v)
    io.stdout:write(("%s=%s\n"):format(k, tostring(v)))
end

local function finish()
    emit("PYRIGHT_PROBE_DONE", true)
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
    io.stdout:write("PYRIGHT_TIMED_OUT=true\n")
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

-- Every question is about a folder with NO marker anywhere above it. If the temp
-- dir sits under one, the probe would be testing the marker path instead.
--
-- The list is written out rather than read from vim.lsp.config.pyright: nothing
-- has opened a file yet, so lazy has not loaded nvim-lspconfig, and the pyright
-- config does not exist to read. A marker lspconfig adds later that is not here
-- would make the root assertion below fail, not pass, so the copy cannot drift
-- into a false green.
local above = vim.fs.root(base, {
    "pyrightconfig.json",
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "requirements.txt",
    "Pipfile",
    ".git",
})
emit("PYRIGHT_NO_MARKER_ABOVE", above == nil)
if above then
    return finish()
end

-- publishDiagnostics, counted per file: "no missing-import diagnostic" means
-- nothing until pyright has reported on the file at least once.
local published = {}
local orig = vim.lsp.handlers["textDocument/publishDiagnostics"]
vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, res, ctx, cfg)
    if res and res.uri then
        published[res.uri] = (published[res.uri] or 0) + 1
    end
    return orig(err, res, ctx, cfg)
end

local function client_of(buf)
    local c = vim.lsp.get_clients({ bufnr = buf, name = "pyright" })[1]
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

local function missing_import(buf)
    for _, d in ipairs(vim.diagnostic.get(buf)) do
        if d.code == "reportMissingImports" then
            return true
        end
    end
    return false
end

-- Polled by hand rather than inside a vim.wait predicate: request_sync blocks,
-- and calling it from a predicate hung this probe until it was killed.
local function completes(client, buf, line, word, want)
    local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
    local col = text:find(word .. ".", 1, true) + #word
    local found, deadline = false, vim.uv.hrtime() + 5e9
    repeat
        local r = client:request_sync("textDocument/completion", {
            textDocument = { uri = vim.uri_from_bufnr(buf) },
            position = { line = line, character = col },
        }, 5000, buf)
        for _, it in ipairs(r and r.result and (r.result.items or r.result) or {}) do
            if it.label == want then
                found = true
            end
        end
        if not found then
            vim.wait(250)
        end
    until found or vim.uv.hrtime() > deadline
    return found
end

-- 1. A sibling module that appears after the import naming it.
--
-- main.py is written first, the way the import usually gets typed before the
-- module it names exists.
local loose = base .. "/loose"
vim.fn.mkdir(loose, "p")
vim.fn.writefile({ "import stats", "", "print(stats.get_word_count('a b'))" }, loose .. "/main.py")
local buf, client = open(loose .. "/main.py")
emit("PYRIGHT_ATTACHED", client ~= nil)
if not client then
    return finish()
end
-- Compared by realpath: nvim resolves symlinks in buffer names on macOS, and the
-- default $TMPDIR sits under one (/var -> /private/var).
emit(
    "PYRIGHT_ROOT_IS_FILE_DIR",
    client.root_dir ~= nil and vim.uv.fs_realpath(client.root_dir) == vim.uv.fs_realpath(loose)
)

-- Precondition: pyright has looked at main.py and flagged the missing module.
-- Without it, a pass below could just mean pyright never looked.
vim.wait(20000, function()
    return missing_import(buf)
end, 50)
emit("PYRIGHT_FLAGS_MISSING_BEFORE", missing_import(buf))

-- Create the sibling on disk, as another pane or tool would, then touch main.py
-- the way typing would, so pyright re-checks it either way.
vim.fn.writefile(
    { "def get_word_count(text: str) -> int:", "    return len(text.split())" },
    loose .. "/stats.py"
)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
emit(
    "PYRIGHT_RESOLVES_AFTER_CREATE",
    vim.wait(15000, function()
        return not missing_import(buf)
    end, 100)
)
emit("PYRIGHT_COMPLETES_NEW_SIBLING", completes(client, buf, 2, "stats", "get_word_count"))

-- 2. A .py directly in $HOME must keep no root, or pyright would index the whole
-- home directory. HOME points at a scratch folder only while :edit runs, which
-- is when root_dir reads it.
local fakehome = base .. "/home"
vim.fn.mkdir(fakehome, "p")
vim.fn.writefile({ "x = 1" }, fakehome .. "/loose.py")
local real_home = vim.env.HOME
vim.env.HOME = fakehome
local ok_edit = pcall(vim.cmd.edit, vim.fn.fnameescape(fakehome .. "/loose.py"))
vim.env.HOME = real_home
local hbuf = vim.api.nvim_get_current_buf()
vim.wait(30000, function()
    return client_of(hbuf) ~= nil
end, 50)
local hclient = client_of(hbuf)
emit("PYRIGHT_HOME_ATTACHED", ok_edit and hclient ~= nil)
emit("PYRIGHT_HOME_STAYS_SINGLE_FILE", ok_edit and hclient ~= nil and hclient.root_dir == nil)

-- 3. A package that only the folder's .venv has, with no venv activated.
--
-- A real venv, because pyright runs the interpreter to learn its search paths.
-- --without-pip keeps it to a fraction of a second, and the package is written
-- straight into its site-packages.
local python3 = vim.fn.exepath("python3")
if python3 == "" then
    emit("PYRIGHT_VENV", "SKIP")
    return finish()
end
local proj = base .. "/venvproj"
vim.fn.system({ python3, "-m", "venv", "--without-pip", proj .. "/.venv" })
local purelib = vim.trim(vim.fn.system({
    proj .. "/.venv/bin/python",
    "-c",
    "import sysconfig; print(sysconfig.get_paths()['purelib'])",
}))
if vim.v.shell_error ~= 0 or purelib == "" then
    emit("PYRIGHT_VENV", "SKIP")
    return finish()
end
vim.fn.mkdir(purelib .. "/probe_venv_only", "p")
vim.fn.writefile(
    { "def hello() -> int:", "    return 1" },
    purelib .. "/probe_venv_only/__init__.py"
)
vim.fn.writefile({ "import probe_venv_only", "", "probe_venv_only.hello()" }, proj .. "/main.py")
-- As if nvim had been started from a shell that never activated it.
vim.env.VIRTUAL_ENV = nil
local vbuf, vclient = open(proj .. "/main.py")
emit("PYRIGHT_VENV", vclient ~= nil)
if not vclient then
    return finish()
end
local python = vclient.settings and vclient.settings.python or {}
emit(
    "PYRIGHT_VENV_INTERPRETER",
    python.pythonPath ~= nil
        and vim.uv.fs_realpath(vim.fs.dirname(python.pythonPath))
            == vim.uv.fs_realpath(proj .. "/.venv/bin")
)
-- Completion first: it only offers hello once the import has really resolved,
-- so by the time it does, the diagnostics read below are from that analysis and
-- not from whatever pyright published before it had looked.
emit("PYRIGHT_VENV_COMPLETES", completes(vclient, vbuf, 2, "probe_venv_only", "hello"))
local vuri = vim.uri_from_bufnr(vbuf)
vim.wait(20000, function()
    return (published[vuri] or 0) > 0
end, 50)
emit("PYRIGHT_VENV_RESOLVES", (published[vuri] or 0) > 0 and not missing_import(vbuf))

finish()
