-- 99: ThePrimeagen's AI-powered coding assistant.
-- Uses Claude Code as the backend. Three core operations:
--   Search: AI finds relevant locations, populates quickfix list.
--   Visual: select text, prompt AI, replace with result.
--   Vibe:   open-ended agentic exploration.
return {
    "ThePrimeagen/99",
    -- Loaded on its keys. With the mappings set inside config, lazy had no
    -- trigger for 99 and loaded it at every start; its setup require()s
    -- nvim-cmp, so cmp and its two sources came too. Once loaded, 99 also
    -- registers a VimLeavePre hook that writes ./tmp/99-state into whatever
    -- directory nvim was started in, if that has a tmp/ (this repo does), and
    -- a status loop that re-arms every second for the life of the editor.
    -- lazy's stubs load 99 and replay the press, so the first <leader>9v still
    -- arrives in visual mode with the selection intact. One thing does move:
    -- 99 takes its project root from the cwd when it loads, which is now the
    -- first press rather than startup.
    keys = {
        -- Visual mode only, on purpose: 99 uses whatever the LAST visual
        -- selection was, so a normal-mode binding could quietly act on an old
        -- one.
        {
            "<leader>9v",
            function()
                require("99").visual()
            end,
            mode = "v",
            desc = "99: Visual",
        },
        -- For a request you no longer want: cancels everything in flight.
        {
            "<leader>9x",
            function()
                require("99").stop_all_requests()
            end,
            desc = "99: Stop all",
        },
        {
            "<leader>9s",
            function()
                require("99").search()
            end,
            desc = "99: Search",
        },
    },
    config = function()
        local _99 = require("99")

        -- For logging that is to a file if you wish to trace through requests
        -- for reporting bugs, i would not rely on this, but instead the provided
        -- logging mechanisms within 99.  This is for more debugging purposes
        local cwd = vim.uv.cwd()
        local basename = vim.fs.basename(cwd)
        _99.setup({
            provider = _99.Providers.ClaudeCodeProvider,
            logger = {
                level = _99.DEBUG,
                path = "/tmp/" .. basename .. ".99.debug",
                print_on_error = true,
            },
            -- When setting this to something that is not inside the CWD tools
            -- such as claude code or opencode will have permission issues
            -- and generation will fail refer to tool documentation to resolve
            -- https://opencode.ai/docs/permissions/#external-directories
            -- https://code.claude.com/docs/en/permissions#read-and-edit
            tmp_dir = "./tmp",

            --- Completions: #rules and @files in the prompt buffer
            completion = {
                -- I am going to disable these until i understand the
                -- problem better.  Inside of cursor rules there is also
                -- application rules, which means i need to apply these
                -- differently
                -- cursor_rules = "<custom path to cursor rules>"

                --- A list of folders where you have your own SKILL.md
                --- Expected format:
                --- /path/to/dir/<skill_name>/SKILL.md
                ---
                --- Example:
                --- Input Path:
                --- "scratch/custom_rules/"
                ---
                --- Output Rules:
                --- {path = "scratch/custom_rules/vim/SKILL.md", name = "vim"},
                --- ... the other rules in that dir ...
                ---
                -- custom_rules = {
                --     "scratch/custom_rules/",
                -- },

                --- Configure @file completion (all fields optional, sensible defaults)
                files = {
                    -- enabled = true,
                    -- max_file_size = 102400,     -- bytes, skip files larger than this
                    -- max_files = 5000,            -- cap on total discovered files
                    -- exclude = { ".env", ".env.*", "node_modules", ".git", ... },
                },

                --- What autocomplete you use: "cmp" or "blink"
                source = "cmp",
            },

            --- WARNING: if you change cwd then this is likely broken
            --- ill likely fix this in a later change
            ---
            --- md_files is a list of files to look for and auto add based on the location
            --- of the originating request.  That means if you are at /foo/bar/baz.lua
            --- the system will automagically look for:
            --- /foo/bar/AGENT.md
            --- /foo/AGENT.md
            --- assuming that /foo is project root (based on cwd)
            md_files = {
                "AGENT.md",
            },
        })
    end,
}
