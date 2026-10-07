-- Trouble: project-wide diagnostics list (errors, warnings, etc.).
-- Better than the default quickfix list. Toggle with <leader>tt,
-- navigate with [t / ]t.
return {
    "folke/trouble.nvim",
    cmd = "Trouble",
    -- opts, even empty, is what makes lazy call setup(): lazy runs it only when
    -- a spec has config or opts, and trouble creates :Trouble inside setup().
    -- It has no plugin/ directory to do that on load, so without this
    -- <leader>tt loaded trouble and then printed "E492: Not an editor command:
    -- Trouble diagnostics toggle", on that press and every one after it.
    opts = {},
    keys = {
        { "<leader>tt", "<cmd>Trouble diagnostics toggle<cr>", desc = "Trouble: Toggle" },
        {
            "[t",
            function()
                local trouble = require("trouble")
                trouble.prev({ skip_groups = true, jump = true })
            end,
            desc = "Trouble: Prev item",
        },
        {
            "]t",
            function()
                local trouble = require("trouble")
                trouble.next({ skip_groups = true, jump = true })
            end,
            desc = "Trouble: Next item",
        },
    },
}
