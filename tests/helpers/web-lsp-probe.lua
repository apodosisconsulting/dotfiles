-- What lsp.lua claims for JavaScript, CSS and HTML, asked of the servers.
--
-- One folder this probe builds under tempname(), holding a file of each kind.
-- For each, the server lsp.lua names attaches AND does one thing only a running
-- server can, so a client that attached and then did nothing fails:
--   main.js     ts_ls finds greet's definition in the util.js beside it
--   style.css   cssls flags `colr` as an unknown property
--   index.html  html offers div as an element to open
--   list.html   emmet_language_server offers ul>li.item*3 expanded: a ul
--               holding three li of class item
--
-- Run as `nvim --headless -c 'luafile web-lsp-probe.lua'`. It cds into its own
-- folder, deletes it on the way out and quits nvim itself. Every line it prints
-- is KEY=value, for tests/test-nvim.sh to assert on. A server Mason has not
-- installed prints SKIP for its keys; a value that could not be established is
-- printed as false, never left out.

local function emit(k, v)
    io.stdout:write(("%s=%s\n"):format(k, tostring(v)))
end

local function finish()
    emit("WEB_PROBE_DONE", true)
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
    io.stdout:write("WEB_TIMED_OUT=true\n")
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

local dir = base .. "/loose"
vim.fn.mkdir(dir, "p")
vim.fn.writefile(
    { "export function greet(name) {", "  return `hi ${name}`;", "}" },
    dir .. "/util.js"
)
vim.fn.writefile({ 'import { greet } from "./util.js";', 'greet("x");' }, dir .. "/main.js")
vim.fn.writefile({ "body { colr: red; }" }, dir .. "/style.css")
vim.fn.writefile({ "<!doctype html>", "<html><body>", "<" }, dir .. "/index.html")
vim.fn.writefile({ "<!doctype html>", "<html><body>", "ul>li.item*3" }, dir .. "/list.html")

-- By path rather than on PATH: mason puts its bin dir on PATH when it loads,
-- and nothing has loaded it yet.
local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"
local function installed(bin)
    return vim.fn.executable(mason_bin .. bin) == 1
end

local function open(path, server)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    local function client()
        local c = vim.lsp.get_clients({ bufnr = buf, name = server })[1]
        return c and c.initialized and c or nil
    end
    vim.wait(30000, function()
        return client() ~= nil
    end, 50)
    return buf, client()
end

local function request(client, buf, method, line, character)
    local r = client:request_sync(method, {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = line, character = character },
    }, 10000, buf)
    return r and r.result
end

-- Asked again until the answer is the one wanted: a server that has attached
-- may still be loading the project, and answers nothing until it has. Polled by
-- hand rather than inside a vim.wait predicate: request_sync blocks, and calling
-- it from a predicate hung pyright-probe.lua until it was killed.
local function answers(client, buf, method, line, character, wanted)
    local deadline = vim.uv.hrtime() + 15e9
    repeat
        if wanted(request(client, buf, method, line, character)) then
            return true
        end
        vim.wait(250)
    until vim.uv.hrtime() > deadline
    return false
end

local function completes(client, buf, line, character, want)
    return answers(client, buf, "textDocument/completion", line, character, function(result)
        for _, it in ipairs(result and (result.items or result) or {}) do
            if it.label == want then
                return true
            end
        end
        return false
    end)
end

local function flags(buf, pattern)
    return vim.wait(20000, function()
        for _, d in ipairs(vim.diagnostic.get(buf)) do
            if d.message:find(pattern) then
                return true
            end
        end
        return false
    end, 100)
end

-- JavaScript.
if not installed("typescript-language-server") then
    emit("WEB_JS", "SKIP")
else
    local buf, client = open(dir .. "/main.js", "ts_ls")
    emit("WEB_JS_ATTACHED", client ~= nil)
    emit(
        "WEB_JS_DEFINITION",
        client ~= nil
            and answers(client, buf, "textDocument/definition", 1, 1, function(result)
                local def = result and (result[1] or result)
                local target = def and (def.uri or def.targetUri)
                return target ~= nil and vim.fs.basename(vim.uri_to_fname(target)) == "util.js"
            end)
    )
end

-- CSS.
if not installed("vscode-css-language-server") then
    emit("WEB_CSS", "SKIP")
else
    local buf, client = open(dir .. "/style.css", "cssls")
    emit("WEB_CSS_ATTACHED", client ~= nil)
    emit("WEB_CSS_FLAGS_UNKNOWN_PROPERTY", client ~= nil and flags(buf, "Unknown property: 'colr'"))
end

-- HTML.
if not installed("vscode-html-language-server") then
    emit("WEB_HTML", "SKIP")
else
    local buf, client = open(dir .. "/index.html", "html")
    emit("WEB_HTML_ATTACHED", client ~= nil)
    emit("WEB_HTML_COMPLETES_ELEMENT", client ~= nil and completes(client, buf, 2, 1, "div"))
end

-- Emmet. The abbreviation offered back as itself would prove nothing, so the
-- item has to carry the expansion: the text it puts in place of the
-- abbreviation holds a ul and three li of class item.
if not installed("emmet-language-server") then
    emit("WEB_EMMET", "SKIP")
else
    local buf, client = open(dir .. "/list.html", "emmet_language_server")
    emit("WEB_EMMET_ATTACHED", client ~= nil)
    emit(
        "WEB_EMMET_EXPANDS",
        client ~= nil
            and answers(client, buf, "textDocument/completion", 2, #"ul>li.item*3", function(result)
                for _, it in ipairs(result and (result.items or result) or {}) do
                    local text = it.textEdit and it.textEdit.newText or it.insertText or ""
                    local _, items = text:gsub('<li class="item">', "")
                    if text:find("<ul>", 1, true) and items == 3 then
                        return true
                    end
                end
                return false
            end)
    )
end

finish()
