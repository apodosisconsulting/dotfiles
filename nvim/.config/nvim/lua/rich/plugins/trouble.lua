-- Trouble: project-wide diagnostics list (errors, warnings, etc.).
-- Better than the default quickfix list. Toggle with <leader>tt,
-- navigate with [t / ]t.
return {
    "folke/trouble.nvim",
    cmd = "Trouble",
    keys = {
        { "<leader>tt", "<cmd>Trouble diagnostics toggle<cr>", desc = "Trouble: Toggle" },
        {
            "[t",
            function()
                -- trouble annotates prev and next as view actions, fun(view,
                -- ctx), so lua_ls asked for a view and every field of one.
                -- What require("trouble") hands out is api.lua's wrapper,
                -- which takes opts alone: trouble's own ApiFn. The cast says
                -- so, here and in ]t.
                local prev_item = require("trouble").prev --[[@as trouble.ApiFn]]
                prev_item({ skip_groups = true, jump = true })
            end,
            desc = "Trouble: Prev item",
        },
        {
            "]t",
            function()
                local next_item = require("trouble").next --[[@as trouble.ApiFn]]
                next_item({ skip_groups = true, jump = true })
            end,
            desc = "Trouble: Next item",
        },
    },
}
