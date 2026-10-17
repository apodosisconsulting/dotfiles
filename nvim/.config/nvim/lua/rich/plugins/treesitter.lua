-- Treesitter: syntax-aware highlighting, indentation, and code navigation.
-- Parsers are auto-installed on first encountering a filetype.
-- Textobjects add motions like vaf (select a function), ]m (next method),
-- and <leader>a to swap function arguments.
-- Context shows the current function/class at the top of the window when scrolling.
return {
    {
        "nvim-treesitter/nvim-treesitter",
        branch = "master",
        build = ":TSUpdate",
        event = { "BufReadPost", "BufNewFile" },
        dependencies = {
            { "nvim-treesitter/nvim-treesitter-textobjects", branch = "master" },
        },
        config = function()
            -- Say so when setup cannot run. Returning quietly looked like
            -- nothing was wrong: Neovim's own ftplugins start treesitter
            -- highlighting for lua, help and query, and everything else falls
            -- back to regex syntax, so the colours stayed while af, ]m,
            -- <leader>a and treesitter indent were all gone. The pinned master
            -- branch is frozen and supports Neovim 0.10 and 0.11 only, so a
            -- newer Neovim is where this shows first.
            local ok, configs = pcall(require, "nvim-treesitter.configs")
            if not ok then
                -- First line only: for a missing module the rest is Lua's
                -- whole search path, one line per place it looked, which at
                -- startup buries the line that says what is wrong.
                local reason = tostring(configs):match("^[^\n]*")
                -- Scheduled, not raised in place. This runs inside the
                -- BufReadPost that loads the plugin, and an ERROR notify there
                -- becomes an exception in whatever opened the file: an edit
                -- run from Lua failed although the file opened, and under a
                -- pcall -- which is how Telescope opens a file -- the message
                -- was swallowed and nothing was shown at all. Deferred, it is
                -- printed either way, even by a headless start that quits
                -- straight away.
                vim.schedule(function()
                    vim.notify("nvim-treesitter did not load: " .. reason, vim.log.levels.ERROR)
                end)
                return
            end

            -- nvim-treesitter annotates setup()'s argument as TSConfig, the
            -- type of its own internal config, in which every field is
            -- required; lua_ls flagged this call for leaving out modules,
            -- sync_install and ignore_install. setup() defaults the last two,
            -- and modules is not a setting at all: it is the table setup()
            -- merges this one into, so a modules key here would become a
            -- module of that name. Hence a suppression, not the fields.
            ---@diagnostic disable-next-line: missing-fields
            configs.setup({
                ensure_installed = {
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
                },
                highlight = { enable = true },
                indent = { enable = true },
                auto_install = true,

                textobjects = {
                    select = {
                        enable = true,
                        lookahead = true,
                        keymaps = {
                            ["af"] = { query = "@function.outer", desc = "Select outer function" },
                            ["if"] = { query = "@function.inner", desc = "Select inner function" },
                            ["ac"] = { query = "@class.outer", desc = "Select outer class" },
                            ["ic"] = { query = "@class.inner", desc = "Select inner class" },
                            ["aa"] = { query = "@parameter.outer", desc = "Select outer argument" },
                            ["ia"] = { query = "@parameter.inner", desc = "Select inner argument" },
                        },
                    },
                    move = {
                        enable = true,
                        set_jumps = true,
                        goto_next_start = {
                            ["]m"] = { query = "@function.outer", desc = "Next function start" },
                            ["]]"] = { query = "@class.outer", desc = "Next class start" },
                        },
                        goto_next_end = {
                            ["]M"] = { query = "@function.outer", desc = "Next function end" },
                            ["]["] = { query = "@class.outer", desc = "Next class end" },
                        },
                        goto_previous_start = {
                            ["[m"] = { query = "@function.outer", desc = "Prev function start" },
                            ["[["] = { query = "@class.outer", desc = "Prev class start" },
                        },
                        goto_previous_end = {
                            ["[M"] = { query = "@function.outer", desc = "Prev function end" },
                            ["[]"] = { query = "@class.outer", desc = "Prev class end" },
                        },
                    },
                    swap = {
                        enable = true,
                        swap_next = {
                            ["<leader>a"] = {
                                query = "@parameter.inner",
                                desc = "Swap with next argument",
                            },
                        },
                        swap_previous = {
                            ["<leader>A"] = {
                                query = "@parameter.inner",
                                desc = "Swap with prev argument",
                            },
                        },
                    },
                },
            })
        end,
    },
    {
        "nvim-treesitter/nvim-treesitter-context",
        event = { "BufReadPost", "BufNewFile" },
        opts = {},
    },
}
