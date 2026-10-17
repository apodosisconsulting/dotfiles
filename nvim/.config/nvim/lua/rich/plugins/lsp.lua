-- LSP: language intelligence (completions, diagnostics, go-to-definition, etc.).
-- Uses Neovim 0.11+ native vim.lsp.config API.
-- Mason auto-installs language servers; cmp-nvim-lsp advertises completion
-- capabilities so servers send richer results.
return {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
        -- mason-org, not williamboman: both repos moved there and the old paths
        -- are now 301 redirects. Git follows them, so this is future-proofing
        -- rather than a fix — run :Lazy sync once after this change so lazy
        -- rewrites the two origins.
        { "mason-org/mason.nvim", config = true },
        { "mason-org/mason-lspconfig.nvim" },
        { "hrsh7th/cmp-nvim-lsp" },
    },

    keys = {
        { "<leader>ld", vim.diagnostic.open_float, desc = "Line diagnostics" },
        -- vim.v.count1, not 1, so 3]d skips to the third diagnostic, as
        -- Neovim's own ]d does. These replace those to open the float on
        -- arrival, and a hard-coded count = 1 had made every count move one.
        -- checks/repo.sh asserts both keep it.
        {
            "[d",
            function()
                vim.diagnostic.jump({ count = -vim.v.count1, float = true })
            end,
            desc = "Prev diagnostic",
        },
        {
            "]d",
            function()
                vim.diagnostic.jump({ count = vim.v.count1, float = true })
            end,
            desc = "Next diagnostic",
        },

        { "<leader>rn", vim.lsp.buf.rename, desc = "Rename symbol" },
        { "<leader>ca", vim.lsp.buf.code_action, desc = "Code action", mode = { "n", "v" } },
        -- No gd, gD, gi or gr here either: config() sets them per buffer, when
        -- a server attaches, and says why.
        --
        -- No "K" here on purpose. Neovim 0.11 already maps K to hover, but
        -- buffer-locally and only `if maparg('K', 'n') == ''` — so declaring K
        -- in this table created a GLOBAL mapping that both defeated that guard
        -- and shadowed keywordprg (:Man) in every buffer without an LSP client.
        -- Dropping it restores :Man outside LSP buffers and lets 0.11 install
        -- (and clean up) its own hover map on attach and detach.
        { "<C-k>", vim.lsp.buf.signature_help, desc = "Signature help", mode = "i" },
        { "<leader>lq", vim.diagnostic.setqflist, desc = "Diagnostics to quickfix" },
        -- Inlay hints start off, and this turns them on and off in every buffer
        -- at once. Global rather than per buffer, so the key is there before
        -- any server attaches; config() tells gopls which kinds to send.
        {
            "<leader>lh",
            function()
                vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
            end,
            desc = "Toggle inlay hints",
        },
    },

    config = function()
        local capabilities = require("cmp_nvim_lsp").default_capabilities()

        -- gd, gD, gi and gr belong to the buffer a server attaches to, for the
        -- reason K is left to Neovim in `keys` above. As global `keys` they
        -- replaced Vim's own gd (go to the local declaration) and gi (insert
        -- where insert last stopped) in every buffer with no server, where all
        -- they did was say the method was not supported.
        --
        -- nowait on gr, because Neovim 0.11 maps gra, gri, grn, grr and grt
        -- globally: gr was a prefix of all five, so every press waited out
        -- timeoutlen to see whether another key followed. In a server's buffer
        -- it now hides those five, and each has a key of its own here:
        -- <leader>ca, gi, <leader>rn, gr itself and gD. No mapping starts with
        -- gd, gD or gi, so they need no nowait; tests/test-nvim.sh asserts
        -- both.
        vim.api.nvim_create_autocmd("LspAttach", {
            group = vim.api.nvim_create_augroup("rich-lsp-keys", { clear = true }),
            callback = function(ev)
                local function map(lhs, rhs, opts)
                    opts.buffer = ev.buf
                    vim.keymap.set("n", lhs, rhs, opts)
                end
                map("gd", vim.lsp.buf.definition, { desc = "Go to definition" })
                map("gD", vim.lsp.buf.type_definition, { desc = "Go to type definition" })
                map("gi", vim.lsp.buf.implementation, { desc = "Go to implementation" })
                map("gr", vim.lsp.buf.references, { desc = "References", nowait = true })
            end,
        })

        -- Mason auto-installs these servers on first run. They are the names
        -- vim.lsp.enable starts at the bottom of this function, bar
        -- rust_analyzer, which comes from rustup. checks/repo.sh holds the two
        -- lists together: a server enabled but never installed just never
        -- attaches on a new machine, and one installed but never enabled is
        -- downloaded on every machine and never runs.
        --
        -- It never runs because automatic_enable is off, which makes that
        -- enable list the one thing that starts a server. mason-lspconfig
        -- defaults it to on, and then calls vim.lsp.enable for every server
        -- Mason has installed: one added from :Mason, or left behind by an old
        -- ensure_installed, started in every buffer of its filetypes with
        -- nothing here naming it. A copy of this config with cssls taken out
        -- of the enable list still enabled cssls, because Mason had css-lsp;
        -- with this off, it did not. Off also skips the config overrides
        -- mason-lspconfig ships for some servers, none of them one used here.
        require("mason-lspconfig").setup({
            automatic_enable = false,
            ensure_installed = {
                "gopls",
                "lua_ls",
                "pyright",
                "ts_ls",
                "eslint",
                "html",
                "cssls",
                "emmet_language_server",
                "jsonls",
                "clangd",
                "yamlls",
                "dockerls",
                "bashls",
            },
        })

        -- lua_ls: lazydev.nvim handles workspace library and vim globals,
        -- so we only need root markers and checkThirdParty here
        vim.lsp.config.lua_ls = {
            capabilities = capabilities,
            root_markers = {
                ".luarc.json",
                ".luarc.jsonc",
                ".luacheckrc",
                ".stylua.toml",
                "stylua.toml",
                ".git",
            },
            settings = {
                Lua = {
                    workspace = { checkThirdParty = false },
                },
            },
        }

        -- A root_dir for a server that needs one in a folder of loose files,
        -- where lspconfig's own rule for it finds none: the file's own folder.
        -- pyright and gopls need it, for the reasons given at each.
        local function marker_or_own_folder(server)
            -- lspconfig's rule is read off its config rather than copied here,
            -- so it stays lspconfig's across a :Lazy update: a root_dir
            -- function where it has one (gopls's looks for go.work, then
            -- go.mod, then .git), its root_markers where not (pyright's). Read
            -- now, before the config this goes into replaces the function.
            local rule = vim.lsp.config[server].root_dir
            local markers = vim.lsp.config[server].root_markers

            local function own_folder(bufnr, on_dir)
                -- Never ~ or /: the server indexes everything under its root.
                -- An unnamed buffer, or a folder that does not exist yet, has no
                -- realpath and no root either. on_dir(nil) hands the choice back
                -- to vim.lsp.start, which looks for the markers itself, if the
                -- server has any, finds none, and runs the server without a
                -- root, as before. Not calling on_dir at all would leave the
                -- buffer with no server. realpath on both sides, because nvim
                -- resolves symlinks in buffer names on macOS and $HOME need be
                -- neither resolved nor slash-free.
                local name = vim.api.nvim_buf_get_name(bufnr)
                local dir = name ~= "" and vim.fs.dirname(name) or nil
                local real = dir and vim.uv.fs_realpath(dir)
                if not real or real == "/" or real == vim.uv.fs_realpath(vim.fs.normalize("~")) then
                    on_dir(nil)
                    return
                end
                on_dir(dir)
            end

            return function(bufnr, on_dir)
                if type(rule) == "function" then
                    rule(bufnr, function(root)
                        if root then
                            on_dir(root)
                        else
                            own_folder(bufnr, on_dir)
                        end
                    end)
                    return
                end
                local root = markers and vim.fs.root(bufnr, markers)
                if root then
                    on_dir(root)
                    return
                end
                own_folder(bufnr, on_dir)
            end
        end

        -- pyright needs two things lspconfig does not give it: a root in a folder
        -- with no project marker, and the project's venv when none is activated.
        -- tests/test-nvim.sh exercises both against a running pyright.
        vim.lsp.config.pyright = {
            capabilities = capabilities,

            -- lspconfig roots pyright at the nearest pyrightconfig.json,
            -- pyproject.toml, setup.py, setup.cfg, requirements.txt, Pipfile or
            -- .git. A folder of loose scripts has none, so pyright ran with no
            -- root and no workspace folder -- and Neovim runs none of a server's
            -- file watchers for a client without one. pyright still resolved
            -- `import stats` from main.py's own folder, which is why this looked
            -- intermittent, but it was never told about a stats.py created after
            -- it started, or changed outside this nvim: the import stayed "could
            -- not be resolved", and `stats.` completed nothing new, until nvim
            -- restarted.
            root_dir = marker_or_own_folder("pyright"),

            -- pyright has no venv discovery of its own. With no pythonPath it
            -- runs the first python3 on PATH, which outside an activated venv is
            -- Homebrew's, so every third-party import was "could not be
            -- resolved" and completed nothing. So when no venv is active, use
            -- <root>/.venv or <root>/venv if there is one. An activated venv
            -- still wins, as does a pythonPath set anywhere else. This runs once
            -- per client, after root_dir has settled, on that client's own copy
            -- of the config, so one project's interpreter never reaches another.
            before_init = function(_, config)
                -- A table, from lspconfig's pyright settings. Neovim types
                -- every settings value as any JSON value, strings included,
                -- so lua_ls refused the pythonPath assignment below until
                -- told; lspconfig's own pyright.lua makes the same cast.
                local python = config.settings and config.settings.python --[[@as table?]]
                if vim.env.VIRTUAL_ENV or not config.root_dir then
                    return
                end
                if not python or python.pythonPath then
                    return
                end
                for _, venv in ipairs({ ".venv", "venv" }) do
                    local interpreter = vim.fs.joinpath(config.root_dir, venv, "bin", "python")
                    if vim.fn.executable(interpreter) == 1 then
                        python.pythonPath = interpreter
                        return
                    end
                end
            end,
        }

        -- rust-analyzer: rustup's, with all cargo features, running clippy on
        -- save.
        --
        -- rustup's by path, not by name. Mason puts its own bin dir first on
        -- nvim's PATH, so a bare "rust-analyzer" ran Mason's build whenever
        -- Mason had one, which it did although nothing here installs it:
        -- 0.3.3081-standalone, where rustup's is 1.92.0, the toolchain's own.
        -- rustup's is a proxy, so it runs the analyser of whichever toolchain
        -- the project picks. bootstrap.sh installs it; where it is missing,
        -- nvim starts no rust-analyzer rather than Mason's.
        vim.lsp.config.rust_analyzer = {
            cmd = {
                vim.fs.joinpath(
                    vim.env.CARGO_HOME or vim.fs.normalize("~/.cargo"),
                    "bin",
                    "rust-analyzer"
                ),
            },
            filetypes = { "rust" },
            root_markers = { "Cargo.toml", "rust-project.json", ".git" },
            capabilities = capabilities,
            settings = {
                ["rust-analyzer"] = {
                    cargo = { allFeatures = true },
                    -- checkOnSave is a plain boolean now; the command moved to
                    -- its own `check` table. Passing the old map form makes
                    -- rust-analyzer reject the whole key as an invalid config
                    -- value, so clippy silently never runs on save.
                    checkOnSave = true,
                    check = { command = "clippy" },
                },
            },
        }

        -- JavaScript, CSS and HTML need nothing beyond lspconfig's defaults.
        -- ts_ls falls back to the cwd for a root, and that is enough: tsserver
        -- resolves and watches a file's imports itself, so in a folder of loose
        -- .js a sibling module created after the file was opened still
        -- completes (measured). eslint starts only for a file under an eslint
        -- config, and lints with the eslint that project installed. cssls also
        -- covers scss and less. emmet_language_server offers the expansion of
        -- an Emmet abbreviation as a completion, so ul>li.item*3 typed in HTML
        -- becomes the list from the menu, and m10 in CSS becomes margin: 10px;
        -- it runs beside html and cssls, in their filetypes and JSX's.
        vim.lsp.config.ts_ls = { capabilities = capabilities }
        vim.lsp.config.eslint = { capabilities = capabilities }
        vim.lsp.config.cssls = { capabilities = capabilities }
        vim.lsp.config.html = { capabilities = capabilities }
        vim.lsp.config.emmet_language_server = { capabilities = capabilities }

        vim.lsp.config.jsonls = { capabilities = capabilities }
        vim.lsp.config.clangd = { capabilities = capabilities }

        -- gopls. tests/test-nvim.sh exercises it against a running gopls,
        -- through tests/helpers/go-lsp-probe.lua.
        vim.lsp.config.gopls = {
            capabilities = capabilities,

            -- lspconfig roots gopls at the nearest go.work, go.mod or .git, and
            -- a folder of loose .go files, which is how a first program or an
            -- exercise starts, has none of them. gopls still ran, with no root
            -- and so no workspace folder, which meant no file watching, as
            -- with pyright above: a file that already sat beside the open one
            -- resolved, but a call into a later.go written beside it after it
            -- was opened stayed "undefined: later" for the 15s it was watched.
            -- With the file's own folder as the root, it resolved.
            root_dir = marker_or_own_folder("gopls"),

            -- Merged into lspconfig's, which turns on semanticTokens. Every
            -- name here is one `gopls api-json` lists, and tests/test-nvim.sh
            -- checks them against it.
            settings = {
                gopls = {
                    -- All of staticcheck's analyzers. Left unset, gopls runs a
                    -- subset its maintainers picked for speed, which in a
                    -- package written to trip them missed SA5000 (assigning to
                    -- a nil map), S1002 (if b == true) and ST1005 (an error
                    -- string with a capital and a full stop).
                    staticcheck = true,
                    -- But true also brought in the style checks staticcheck
                    -- itself leaves off: its documented default is "all" less
                    -- SA9003, ST1000, ST1003, ST1016 and ST1020 to ST1023.
                    -- ST1000 alone flagged every package that had no package
                    -- comment. Off again, so this is staticcheck as it runs on
                    -- its own. gopls's own off-by-default analyzers, shadow
                    -- among them, stay off.
                    analyses = {
                        SA9003 = false,
                        ST1000 = false,
                        ST1003 = false,
                        ST1016 = false,
                        ST1020 = false,
                        ST1021 = false,
                        ST1022 = false,
                        ST1023 = false,
                    },
                    -- Every kind of inlay hint gopls has. None is drawn until
                    -- <leader>lh turns hints on, which is why all of them can
                    -- be: parameter names at a call, the type a := or a range
                    -- infers, a composite literal's field names and type, a
                    -- constant's value, a generic call's type arguments, and
                    -- an error being dropped.
                    hints = {
                        assignVariableTypes = true,
                        compositeLiteralFields = true,
                        compositeLiteralTypes = true,
                        constantValues = true,
                        functionTypeParameters = true,
                        ignoredError = true,
                        parameterNames = true,
                        rangeVariableTypes = true,
                    },
                    -- The extensions filetypes.lua makes gotmpl, read from
                    -- there so the two lists cannot drift apart.
                    templateExtensions = require("rich.filetypes").go_template_extensions,
                },
            },
        }

        -- yamlls: schema validation for docker-compose, k8s, CI configs, etc.
        vim.lsp.config.yamlls = {
            capabilities = capabilities,
            settings = {
                yaml = {
                    schemaStore = { enable = true },
                },
            },
        }

        vim.lsp.config.dockerls = { capabilities = capabilities }
        vim.lsp.config.bashls = { capabilities = capabilities }

        vim.lsp.enable({
            "lua_ls",
            "pyright",
            "rust_analyzer",
            "ts_ls",
            "eslint",
            "html",
            "cssls",
            "emmet_language_server",
            "jsonls",
            "clangd",
            "gopls",
            "yamlls",
            "dockerls",
            "bashls",
        })
    end,
}
