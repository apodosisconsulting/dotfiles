-- Autocompletion engine.
-- Sources: LSP results first, then words from the current buffer, then file paths.
-- Uses native Neovim snippets for expansion.
return {
    "hrsh7th/nvim-cmp",
    event = "InsertEnter",
    dependencies = {
        "hrsh7th/cmp-buffer",
        "hrsh7th/cmp-path",
    },
    config = function()
        local cmp = require("cmp")
        cmp.setup({
            snippet = {
                expand = function(args)
                    vim.snippet.expand(args.body)
                end,
            },
            sources = {
                { name = "nvim_lsp" },
                { name = "buffer" },
                { name = "path" },
            },
            mapping = cmp.mapping.preset.insert({
                ["<C-p>"] = cmp.mapping.select_prev_item(),
                ["<C-n>"] = cmp.mapping.select_next_item(),
                ["<C-y>"] = cmp.mapping.confirm({ select = true }),
                -- Enter accepts only an item you have moved to, or one a
                -- language server preselects; otherwise it is a newline.
                --
                -- cmp opens its menu with nothing selected (its completeopt
                -- is noselect), and select = true makes confirm take the
                -- first entry when nothing is. So with true, typing `alpha`
                -- and Enter in a buffer holding `alphabet` wrote `alphabet`
                -- and no line break: the menu was open, so the keypress went
                -- to cmp and never reached the buffer. With false, confirm
                -- finds no selection and falls back to the key itself.
                -- <C-y> above still accepts the first item. checks/repo.sh
                -- reads this line, and tests/test-nvim.sh presses Enter
                -- with the menu open.
                ["<CR>"] = cmp.mapping.confirm({ select = false }),
                ["<C-Space>"] = cmp.mapping.complete(),
                ["<C-b>"] = cmp.mapping.scroll_docs(-4),
                ["<C-f>"] = cmp.mapping.scroll_docs(4),
            }),
        })
    end,
}
