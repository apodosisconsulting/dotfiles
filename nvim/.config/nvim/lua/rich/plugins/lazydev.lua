-- Lazydev: proper Neovim Lua API completions when editing your config.
-- Automatically configures lua_ls to understand vim.*, lazy.nvim specs,
-- and plugin APIs without manual workspace.library paths.
--
-- So .luarc.json must not set workspace.library. lua_ls lets that file
-- override the settings a client sends, lazydev's library included, and it
-- did: vim.api had no definition and no hover anywhere in this config. Its
-- diagnostics.globals = { "vim" } hid that, by silencing the one warning that
-- would have shown it. The file stays only as lua_ls's root marker (lsp.lua's
-- root_markers): it is what makes this directory the workspace, rather than
-- whatever holds the next marker further up. checks/repo.sh fails if it sets
-- either key again.
return {
    "folke/lazydev.nvim",
    ft = "lua",
    opts = {
        library = {
            { path = "${3rd}/luv/library", words = { "vim%.uv" } },
        },
    },
}
