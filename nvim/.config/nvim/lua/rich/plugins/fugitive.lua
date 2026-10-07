-- Fugitive: full git UI inside Neovim.
-- Lazy-loaded on <leader>gs or any :Git command.
return {
    "tpope/vim-fugitive",
    -- Only names fugitive still defines. lazy makes a stub for each, so the
    -- :Gblame and :Glog that fugitive dropped were still offered on :G<Tab>,
    -- and then failed: "Command `Gblame` not found after loading
    -- `vim-fugitive`". Blame and log are :Git blame and :Gclog now.
    cmd = { "Git", "G", "Gdiffsplit", "Gvdiffsplit", "Gread", "Gwrite", "Gedit", "Gclog" },
    keys = {
        { "<leader>gs", "<cmd>Git<cr>", desc = "Fugitive: Git Status" },
    },
}
