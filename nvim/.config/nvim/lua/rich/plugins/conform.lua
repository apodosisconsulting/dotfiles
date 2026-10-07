-- Auto-formatting on save. Falls back to LSP formatting if no dedicated
-- formatter is configured for the filetype. Manual format: <leader>cf.
-- Formatter defaults (indent width, etc.) come from global config files
-- in ~/  (.prettierrc, .stylua.toml, .clang-format); project-level
-- configs override these automatically.
--
-- .prettierrc's tabWidth is 4, with an override taking YAML back to 2. JSON
-- has no comments, so the reason lives here: YAML in these repos is written
-- at 2, and at 4 every save re-indented the file -- 53 of the 69 lines in
-- .github/workflows/ci.yml. `make lint` runs prettier over the tracked YAML
-- with that file, and checks/repo.sh asserts the override.
return {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    keys = {
        {
            "<leader>cf",
            function()
                require("conform").format({ async = true, lsp_format = "fallback" })
            end,
            mode = "",
            desc = "Format buffer",
        },
    },
    opts = {
        formatters_by_ft = {
            lua = { "stylua" },
            python = { "black" },
            javascript = { "prettier" },
            typescript = { "prettier" },
            javascriptreact = { "prettier" },
            typescriptreact = { "prettier" },
            css = { "prettier" },
            html = { "prettier" },
            json = { "prettier" },
            yaml = { "prettier" },
            markdown = { "prettier" },
            sh = { "shfmt" },
            bash = { "shfmt" },
            go = { "gofmt" },
            rust = { "rustfmt" },
            c = { "clang-format" },
            cpp = { "clang-format" },
        },
        formatters = {
            shfmt = {
                -- Match the repo's shell scripts (2-space) instead of shfmt's
                -- default tabs, so format-on-save doesn't reflow them.
                prepend_args = { "-i", "2", "-ci" },
            },
        },
        format_on_save = {
            timeout_ms = 2000,
            lsp_format = "fallback",
        },
    },
}
