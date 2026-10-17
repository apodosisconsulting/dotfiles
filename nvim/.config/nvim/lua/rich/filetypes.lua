-- Filetypes Neovim does not know, or knows by another name.
--
-- Required from lua/rich/init.lua ahead of everything else, so it is in place
-- before the first buffer is read whatever loads when. In a plugin's config it
-- would hold only if that plugin happened to load before the first file's
-- filetype was detected.
local M = {}

-- Go templates. Neovim gives .gohtml and .gotmpl no filetype at all, so they
-- had no highlighting and no language server. As gotmpl, gopls attaches: nvim
-- names the filetype as the document's language, and gopls takes a gotmpl
-- document as a template, reports its parse errors and sends semantic tokens
-- for its actions. lsp.lua gives gopls this same list as templateExtensions,
-- which is how gopls tells a template by its name alone, for a file nvim has
-- not opened.
--
-- .tmpl stays Neovim's "template", on purpose. That filetype's syntax file is
-- HTML's, so a .tmpl is highlighted as HTML; as gotmpl the HTML in it would
-- lose its colours, because nvim-treesitter's gotmpl queries highlight only the
-- {{ }} actions and inject HTML into nothing but an `html "..."` call's string.
-- gopls claims no extension by default either: its templateExtensions starts
-- empty. A project whose .tmpl files are Go templates can add "tmpl" here.
M.go_template_extensions = { "gohtml", "gotmpl" }

local extension = {}
for _, ext in ipairs(M.go_template_extensions) do
    extension[ext] = "gotmpl"
end
vim.filetype.add({ extension = extension })

return M
