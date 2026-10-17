-- Treesitter: syntax-aware highlighting, indentation, and code navigation.
-- Parsers are installed on first encountering a filetype that has one.
-- Textobjects add motions like vaf (select a function), ]m (next method),
-- and <leader>a to swap function arguments.
-- Context shows the current function/class at the top of the window when scrolling.
--
-- These are the main branches of nvim-treesitter and its textobjects. Their
-- master branches, which this used to pin, are frozen and stop at Neovim 0.11.
-- main is a rewrite that does less by itself: it installs parsers and ships
-- queries, and turns nothing on. So everything master's configs.setup() did is
-- asked for here, buffer by buffer: highlighting with vim.treesitter.start, the
-- indentexpr, and every textobject map. main needs Neovim 0.12, and it builds
-- each parser with the tree-sitter CLI, which bootstrap.sh installs as
-- tree-sitter-cli. The plain tree-sitter formula is now only the library.

-- Installed on every machine. Any other language nvim-treesitter has a parser
-- for is installed the first time a file of it is opened, as auto_install did.
local parsers = {
    "lua",
    "vim",
    "vimdoc",
    "bash",
    "markdown",
    "markdown_inline",
    "html",
    "css",
    "json",
    "yaml",
    "toml",
    "query",
    "javascript",
    "typescript",
    "python",
    "rust",
    "c",
    "go",
    "gomod",
    "gosum",
    "gowork",
    "gotmpl",
}

-- Master set its textobject maps per buffer, and only where the language has a
-- textobjects query, so ]] and [[ stayed Vim's own section motions in a text
-- file. These are set the same way. Modes are master's too: select in visual
-- and operator-pending, move in those and normal, swap in normal.
local select_maps = {
    { "af", "@function.outer", "Select outer function" },
    { "if", "@function.inner", "Select inner function" },
    { "ac", "@class.outer", "Select outer class" },
    { "ic", "@class.inner", "Select inner class" },
    { "aa", "@parameter.outer", "Select outer argument" },
    { "ia", "@parameter.inner", "Select inner argument" },
}
local move_maps = {
    { "]m", "goto_next_start", "@function.outer", "Next function start" },
    { "]]", "goto_next_start", "@class.outer", "Next class start" },
    { "]M", "goto_next_end", "@function.outer", "Next function end" },
    { "][", "goto_next_end", "@class.outer", "Next class end" },
    { "[m", "goto_previous_start", "@function.outer", "Prev function start" },
    { "[[", "goto_previous_start", "@class.outer", "Prev class start" },
    { "[M", "goto_previous_end", "@function.outer", "Prev function end" },
    { "[]", "goto_previous_end", "@class.outer", "Prev class end" },
}
local swap_maps = {
    { "<leader>a", "swap_next", "Swap with next argument" },
    { "<leader>A", "swap_previous", "Swap with prev argument" },
}

-- Scheduled, not raised in place. config runs inside the BufReadPost that loads
-- the plugin, and an ERROR notify there becomes an exception in whatever opened
-- the file: an edit run from Lua failed although the file opened, and under a
-- pcall -- which is how Telescope opens a file -- the message was swallowed and
-- nothing was shown at all. Deferred, it is printed either way, even by a
-- headless start that quits straight away.
local function loud(msg)
    vim.schedule(function()
        vim.notify(msg, vim.log.levels.ERROR)
    end)
end

-- First line only: for a missing module the rest is Lua's whole search path,
-- one line per place it looked, which at startup buries the line that says what
-- is wrong.
local function first_line(err)
    return (tostring(err):match("^[^\n]*"))
end

local function has_query(lang, name)
    return #vim.treesitter.query.get_files(lang, name) > 0
end

-- Everything master's highlight, indent and textobjects modules did for a
-- buffer. False when there is no parser for it yet, so the caller can install
-- one; safe to run on a buffer twice.
local function attach(buf)
    if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].filetype == "" then
        return true
    end
    local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
    if not lang or not vim.treesitter.language.add(lang) then
        return false
    end

    -- Neovim's own ftplugins already start it for lua, markdown, help and
    -- query; for the rest nothing does but this, so a Go or Python file would
    -- otherwise get regex syntax and look about right. vim.treesitter.start
    -- turns regex syntax off, so it is not called where there is no highlights
    -- query to replace it with.
    if not vim.treesitter.highlighter.active[buf] and has_query(lang, "highlights") then
        local ok, err = pcall(vim.treesitter.start, buf, lang)
        if not ok then
            loud("treesitter highlighting did not start for " .. lang .. ": " .. first_line(err))
        end
    end

    -- master set it only where the language has an indents query, which
    -- leaves the filetype's own indentexpr everywhere else.
    if has_query(lang, "indents") then
        vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end

    if has_query(lang, "textobjects") then
        local select = require("nvim-treesitter-textobjects.select")
        local move = require("nvim-treesitter-textobjects.move")
        local swap = require("nvim-treesitter-textobjects.swap")
        for _, m in ipairs(select_maps) do
            vim.keymap.set({ "x", "o" }, m[1], function()
                select.select_textobject(m[2], "textobjects")
            end, { buffer = buf, desc = m[3] })
        end
        for _, m in ipairs(move_maps) do
            vim.keymap.set({ "n", "x", "o" }, m[1], function()
                move[m[2]](m[3], "textobjects")
            end, { buffer = buf, desc = m[4] })
        end
        for _, m in ipairs(swap_maps) do
            vim.keymap.set("n", m[1], function()
                swap[m[2]]("@parameter.inner")
            end, { buffer = buf, desc = m[3] })
        end
    end
    return true
end

local function attach_all()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        attach(buf)
    end
end

return {
    {
        "nvim-treesitter/nvim-treesitter",
        branch = "main",
        -- Every parser the configured list names, and then :TSUpdate's job:
        -- main's README requires each installed parser to be rebuilt at the
        -- revision a new plugin commit pins. Waited for, because lazy runs this
        -- on install and on restore, and `nvim --headless "+Lazy! restore" +qa`
        -- -- what CI and a fresh machine run -- would otherwise quit with the
        -- builds still going. An error here is how lazy shows a failed build.
        build = function()
            if vim.fn.executable("tree-sitter") == 0 then
                error(
                    "no tree-sitter CLI on PATH to build parsers with: brew install tree-sitter-cli"
                )
            end
            local ts = require("nvim-treesitter")
            if not ts.install(parsers, { summary = true }):wait(300000) then
                error("some treesitter parsers did not build; :TSLog says why")
            end
            if not ts.update(nil, { summary = true }):wait(300000) then
                error("some treesitter parsers did not update; :TSLog says why")
            end
        end,
        -- main's README says it does not support lazy-loading. What its
        -- plugin/ files register -- filetype-to-parser names such as sh to
        -- bash, and the predicates its indents queries use -- is in place
        -- before anything here uses it, because attach() runs from config,
        -- after they have loaded. Neovim's own ftplugins start treesitter for
        -- lua and markdown sooner, and a markdown file opened first still had
        -- its sh fence parsed as bash. So it still waits for a file, which
        -- keeps it out of the eager set tests/test-performance.sh holds to
        -- lazy.nvim and rose-pine.
        event = { "BufReadPost", "BufNewFile" },
        dependencies = {
            { "nvim-treesitter/nvim-treesitter-textobjects", branch = "main" },
        },
        config = function()
            -- Say so when setup cannot run. Returning quietly looked like
            -- nothing was wrong: Neovim's own ftplugins start treesitter
            -- highlighting for lua, markdown, help and query, and everything
            -- else falls back to regex syntax, so the colours stayed while af,
            -- ]m, <leader>a and treesitter indent were all gone.
            if vim.fn.has("nvim-0.12") == 0 then
                loud(
                    "nvim-treesitter's main branch needs Neovim 0.12, and this is "
                        .. tostring(vim.version())
                        .. ": brew upgrade neovim"
                )
                return
            end
            local ok, ts = pcall(require, "nvim-treesitter")
            local ok_to, textobjects = pcall(require, "nvim-treesitter-textobjects")
            if not ok or not ok_to then
                loud("nvim-treesitter did not load: " .. first_line(ok and textobjects or ts))
                return
            end
            -- master has a module of this name too, with no install in it, so
            -- a checkout that never left master gets this far.
            if type(ts.install) ~= "function" then
                loud("nvim-treesitter is not on its main branch: :Lazy restore nvim-treesitter")
                return
            end

            -- Explicit, though it is the default: setup() puts the directory
            -- at the front of the runtimepath only when it is given. lazy
            -- rebuilds the runtimepath out of the directories that exist each
            -- time it loads a plugin, so on a fresh machine, where site does
            -- not exist yet, it is gone before this runs, and a parser
            -- installed where nothing looks is no parser. In front, it also
            -- wins over any parser master left in its own plugin directory.
            ts.setup({ install_dir = vim.fn.stdpath("data") .. "/site" })
            textobjects.setup({
                select = { lookahead = true },
                move = { set_jumps = true },
            })

            vim.api.nvim_create_autocmd("FileType", {
                group = vim.api.nvim_create_augroup("rich-treesitter", { clear = true }),
                callback = function(ev)
                    if attach(ev.buf) then
                        return
                    end
                    -- The auto_install that master had. Only for a language
                    -- nvim-treesitter has a parser for: get_lang falls back to
                    -- the filetype itself, so a Telescope prompt asks too.
                    -- Tier 4 is "unsupported", which install() skips.
                    local lang = vim.treesitter.language.get_lang(vim.bo[ev.buf].filetype)
                    local info = lang and require("nvim-treesitter.parsers")[lang]
                    if not info or not info.install_info or info.tier == 4 then
                        return
                    end
                    ts.install(lang):await(vim.schedule_wrap(attach_all))
                end,
            })

            -- No-op when they are all there, which is every start but the
            -- first. build installs them on a fresh machine before this runs;
            -- this covers a build that never ran.
            local installed = ts.get_installed("parsers")
            local missing = vim.tbl_filter(function(p)
                return not vim.list_contains(installed, p)
            end, parsers)
            if #missing > 0 then
                ts.install(missing):await(vim.schedule_wrap(attach_all))
            end

            -- The buffer whose BufReadPost loaded this has had its FileType
            -- already, before the autocmd above existed, and lazy replays the
            -- BufRead events for a plugin it loads but not FileType.
            attach_all()
        end,
    },
    {
        "nvim-treesitter/nvim-treesitter-context",
        event = { "BufReadPost", "BufNewFile" },
        opts = {},
    },
}
