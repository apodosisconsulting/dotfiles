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
        { "gd", vim.lsp.buf.definition, desc = "Go to definition" },
        { "gD", vim.lsp.buf.type_definition, desc = "Go to type definition" },
        { "gi", vim.lsp.buf.implementation, desc = "Go to implementation" },
        { "gr", vim.lsp.buf.references, desc = "References" },
        -- No "K" here on purpose. Neovim 0.11 already maps K to hover, but
        -- buffer-locally and only `if maparg('K', 'n') == ''` — so declaring K
        -- in this table created a GLOBAL mapping that both defeated that guard
        -- and shadowed keywordprg (:Man) in every buffer without an LSP client.
        -- Dropping it restores :Man outside LSP buffers and lets 0.11 install
        -- (and clean up) its own hover map on attach and detach.
        { "<C-k>", vim.lsp.buf.signature_help, desc = "Signature help", mode = "i" },
        { "<leader>lq", vim.diagnostic.setqflist, desc = "Diagnostics to quickfix" },
    },

    config = function()
        local capabilities = require("cmp_nvim_lsp").default_capabilities()

        -- Mason auto-installs these servers on first run. They are the names
        -- vim.lsp.enable starts at the bottom of this function, bar
        -- rust_analyzer, which comes from rustup. checks/repo.sh holds the two
        -- lists together: a server enabled but never installed just never
        -- attaches on a new machine, and one installed but never enabled runs
        -- only while mason-lspconfig's automatic_enable happens to be on.
        require("mason-lspconfig").setup({
            ensure_installed = {
                "gopls",
                "lua_ls",
                "pyright",
                "ts_ls",
                "eslint",
                "html",
                "cssls",
                "phpactor",
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
        -- where none of lspconfig's markers for it are found: the file's own
        -- folder. pyright and phpactor each need it, for reasons given at each.
        local function marker_or_own_folder(server)
            return function(bufnr, on_dir)
                -- Read off the merged config rather than copied here, so the
                -- list stays lspconfig's across a :Lazy update.
                local root = vim.fs.root(bufnr, vim.lsp.config[server].root_markers)
                if root then
                    on_dir(root)
                    return
                end

                -- Never ~ or /: both servers index everything under their root.
                -- An unnamed buffer, or a folder that does not exist yet, has no
                -- realpath and no root either. on_dir(nil) hands the choice back
                -- to vim.lsp.start, which looks for the markers itself and finds
                -- none: pyright then runs without a root, as it did before, and
                -- phpactor, which lspconfig marks workspace_required, does not
                -- start. Not calling on_dir at all would leave the buffer with
                -- neither. realpath on both sides, because nvim resolves symlinks
                -- in buffer names on macOS and $HOME need be neither resolved nor
                -- slash-free.
                local name = vim.api.nvim_buf_get_name(bufnr)
                local dir = name ~= "" and vim.fs.dirname(name) or nil
                local real = dir and vim.uv.fs_realpath(dir)
                if not real or real == "/" or real == vim.uv.fs_realpath(vim.fs.normalize("~")) then
                    on_dir(nil)
                    return
                end
                on_dir(dir)
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

        -- rust-analyzer: use the rustup-managed binary (not mason's),
        -- enable all cargo features, run clippy on save
        vim.lsp.config.rust_analyzer = {
            cmd = { "rust-analyzer" },
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
        -- covers scss and less.
        vim.lsp.config.ts_ls = { capabilities = capabilities }
        vim.lsp.config.eslint = { capabilities = capabilities }
        vim.lsp.config.cssls = { capabilities = capabilities }
        vim.lsp.config.html = { capabilities = capabilities }

        -- phpactor, for PHP. lspconfig marks it workspace_required, with .git,
        -- composer.json and .phpactor.json/.yml as the markers, so in a folder
        -- of loose .php files -- which is how PHP usually starts -- phpactor
        -- never started at all: no completion, no diagnostics, and nothing to
        -- say why. Rooted at the file's own folder instead, `$g->` completes
        -- greet() from the Greeter.php beside it, and an undefined variable is
        -- flagged. A .php directly in ~ still gets no phpactor, deliberately.
        -- tests/test-nvim.sh checks both. phpactor is a PHP program, run by the
        -- php first on PATH, which bootstrap.sh installs.
        vim.lsp.config.phpactor = {
            capabilities = capabilities,
            root_dir = marker_or_own_folder("phpactor"),
        }

        vim.lsp.config.jsonls = { capabilities = capabilities }
        vim.lsp.config.clangd = { capabilities = capabilities }
        vim.lsp.config.gopls = { capabilities = capabilities }

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
            "phpactor",
            "jsonls",
            "clangd",
            "gopls",
            "yamlls",
            "dockerls",
            "bashls",
        })
    end,
}
