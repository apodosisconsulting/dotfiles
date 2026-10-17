# dotfiles

Personal development environment managed with [GNU Stow](https://www.gnu.org/software/stow/). Rosé Pine Moon theme across Neovim, tmux, WezTerm, and Starship.

## What's included

| Package      | What it does                                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------------------- |
| **nvim**     | Neovim config — LSP (see Languages), Treesitter, Telescope, Harpoon, Git, completions, ThePrimeagen's 99 AI plugin  |
| **tmux**     | Window-focused workflow with vim-style navigation, session persistence via resurrect/continuum                      |
| **wezterm**  | Terminal emulator — auto-attaches to tmux, Rosé Pine Moon theme, JetBrainsMono Nerd Font                            |
| **zsh**      | Shell config — nvm's default node from the start, cached completions, fzf, autosuggestions, syntax highlighting     |
| **starship** | Minimal prompt — directory, git branch, git status, and python, nodejs, rust, golang, cmd duration where they apply |
| **git**      | Global git config and ignores                                                                                       |
| **home**     | Global formatter configs (.prettierrc, .stylua.toml, .clang-format)                                                 |

## Setup

On a new Mac, `./bootstrap.sh` does all of it: Homebrew and the tools, Go's
goimports, the Rust toolchain, the stow, the tmux plugins and the git hooks. On
a Mac that already has the tools:

```sh
make stow   # link the configs into ~
make hooks  # check on commit, test-fast on push
```

The first start of each tool installs the rest of what it needs:

- **Neovim** installs its plugins at the commits `lazy-lock.json` pins, then
  Mason installs the language servers and nvim-treesitter builds its parsers
  with the tree-sitter CLI. The first start takes a while; later ones do not.
- **tmux**: `./bootstrap.sh` clones the plugins. After `make stow` alone, press
  prefix `I` once.
- **99** needs `claude` on PATH.

Settings for one machine only go in ~/.zshrc.local, which .zshrc runs last and
git never sees. A ~/.gitconfig wins over the repo's git config key by key, and
`make check` names any key it overrides.

## Key tmux bindings

Prefix is `Ctrl-a`.

| Binding     | Action                                             |
| ----------- | -------------------------------------------------- |
| `h` / `l`   | Previous / next window                             |
| `j` / `k`   | Next / previous session                            |
| `c`         | New window                                         |
| `q`         | Kill window (with confirmation)                    |
| `Q`         | Kill session (smart — won't close WezTerm)         |
| `r` / `R`   | Rename window / session                            |
| `s`         | Save session (resurrect)                           |
| `M-s`       | Save session, bypassing the degenerate-state guard |
| `S`         | Source tmux.conf                                   |
| `f`         | Sessionizer popup                                  |
| `w`         | Session/window tree overview                       |
| `Backspace` | Clear screen and scrollback                        |
| `]`         | Paste the system clipboard                         |
| `H` / `L`   | Move window left / right                           |
| `C`         | New session                                        |

Without the prefix, Ctrl-h/j/k/l move between tmux panes and Neovim splits
alike, so Ctrl-l no longer clears the shell; prefix `Backspace` does.

## Session persistence

tmux-resurrect saves the session layout; tmux-continuum auto-saves every 15
minutes while a client is attached, and auto-restores on tmux start. Saves live
in `~/.local/share/tmux/resurrect/`, and a `last` symlink points at the one that
auto-restore will use. Prefix `M-r` (Option-r) restores it by hand; WezTerm
keeps Ctrl-Shift-R for itself, which is why that is not the key.

Reload tmux.conf (prefix `S`) after `make test` has finished, not during it.
continuum only turns auto-save back on at a reload when it counts no other tmux
server, and the test suites run their own, so a reload mid-run leaves auto-save
off until the next one.

Two helper scripts in `tmux/.local/bin/` harden that setup:

**`tmux-resurrect-guard`** — stops a throwaway session state from becoming
`last`. Continuum saves on a timer, so if the timer fires while tmux is holding
something trivial (the bare one-window `main` session WezTerm creates on
startup, for instance) that trivial state would otherwise be written out and
`last` repointed at it — and the next auto-restore would faithfully bring back
one window instead of your real workspace.

It runs as resurrect's `post-save-layout` hook, which fires after the candidate
save is written but before `last` moves. It counts `window` records in the
candidate and vetoes the save if the state looks throwaway. Tuning options live
next to the plugin settings in `tmux.conf`; the mechanism is explained in the
script's header.

**`tmux-resurrect-saves`** — manages the save directory:

```sh
tmux-resurrect-saves list                # every save with session/window/pane counts
tmux-resurrect-saves prune               # dry run of the retention policy
tmux-resurrect-saves prune --apply       # actually delete
tmux-resurrect-saves promote <timestamp> # point `last` at a specific save
```

Retention keeps everything from the last 7 days, then one save per day back to
90 days, and drops degenerate saves at any age. Whatever `last` points at is
never deleted.

## Languages

Each gets a language server, which gives completion, diagnostics, `gd` and the
rest, and a formatter that runs on save.

| Language               | Language server                                 | Formatted on save by                    |
| ---------------------- | ----------------------------------------------- | --------------------------------------- |
| Go                     | gopls, with staticcheck; also .gohtml, .gotmpl  | goimports, which adds and drops imports |
| JavaScript, TypeScript | ts_ls, and eslint where a project configures it | prettier                                |
| HTML, CSS, SCSS, Less  | html and cssls, with Emmet abbreviations        | prettier                                |
| Python                 | pyright, which uses the project's .venv         | black                                   |
| Lua                    | lua_ls                                          | stylua                                  |
| Rust                   | rustup's rust-analyzer, with clippy on save     | rustfmt                                 |
| C, C++                 | clangd                                          | clang-format                            |
| Shell                  | bashls, which runs shellcheck as you type       | shfmt                                   |
| JSON, YAML, Dockerfile | jsonls, yamlls, dockerls                        | prettier, for JSON and YAML             |

A folder of loose files with no go.mod, pyproject.toml or the like still gets a
working server: Go and Python files are rooted at their own folder.

## Key Neovim bindings

Leader is `Space`. Press it and pause: which-key lists every mapping.

| Binding                         | Action                             |
| ------------------------------- | ---------------------------------- |
| `<leader>ff`                    | Find files                         |
| `<leader>fg`                    | Live grep                          |
| `<leader>fb`                    | Open buffers                       |
| `<leader>ha` / `<leader>hh`     | Add file to Harpoon / Harpoon menu |
| `<leader>h1`-`<leader>h4`       | Jump to Harpoon file 1-4           |
| `<C-h>` `<C-j>` `<C-k>` `<C-l>` | Move between splits and tmux panes |
| `<leader>gs`                    | Git status (Fugitive)              |
| `gd`                            | Go to definition                   |
| `gr`                            | References                         |
| `gi`                            | Go to implementation               |
| `<leader>ca`                    | Code action                        |
| `<leader>rn`                    | Rename symbol                      |
| `<leader>cf`                    | Format (it also runs on save)      |
| `<leader>lh`                    | Toggle inlay hints                 |
| `]d` / `[d`                     | Next / prev diagnostic             |
| `<leader>tt`                    | Diagnostics list (Trouble)         |
| `<leader>lq`                    | Send diagnostics to quickfix       |
| `]q` / `[q`                     | Next / prev quickfix item          |
| `<leader>u`                     | Undo tree                          |
| `<leader>9s`                    | 99 AI search                       |
| `<leader>9v`                    | 99 AI visual replace               |

`gd`, `gr` and `gi` exist only in a buffer with a language server; elsewhere
they are Vim's own.

## One clipboard

Neovim and tmux both use the system clipboard, the one Cmd-C and Cmd-V use. In
Neovim a plain `y` copies to it and `p` pastes from it. So does a delete, which
is the cost: `<leader>d` deletes without touching it, and `<leader>p` pastes
over a selection without replacing it. In tmux, copy mode's `y`, Enter and a
mouse drag all copy to it, and prefix `]` pastes from it rather than from tmux's
own buffer. The shell's own cut and paste keys (Ctrl-U, Ctrl-W, Ctrl-Y) still
use zsh's separate kill ring, deliberately: clearing a line would otherwise
overwrite the clipboard.

## Updating

| What               | How                                                  |
| ------------------ | ---------------------------------------------------- |
| Neovim plugins     | `:Lazy sync`, try it, then commit `lazy-lock.json`   |
| Language servers   | `:Mason`, then `U`                                   |
| Treesitter parsers | `:TSUpdate`                                          |
| tmux plugins       | prefix `U`, then `all`                               |
| Homebrew tools     | `brew upgrade`                                       |
| Go tools           | `go install` goimports again, as `bootstrap.sh` does |
| Rust               | `rustup update`, which brings rust-analyzer with it  |

`lazy-lock.json` is what makes a fresh machine get the plugin versions this one
has, so a plugin update is not finished until it is committed. `:Lazy restore`
puts every plugin back to what it pins.

## When something is wrong

Run `make check` first: it names the assumptions that no longer hold.

| Symptom                            | Look at                                                  |
| ---------------------------------- | -------------------------------------------------------- |
| No completion, diagnostics or `gd` | `:LspInfo`, then `:LspRestart`                           |
| Format-on-save does nothing        | `:ConformInfo`, which lists the formatters it found      |
| A plugin errors at startup         | `:Lazy`, then `:checkhealth lazy`                        |
| tmux came back with one window     | `tmux-resurrect-saves list`, then `promote` the good one |
| A new config file has no effect    | `make stow`: a file added to a package is not linked yet |

## Make targets

```
make stow       # Apply symlinks (with dry-run)
make unstow     # Remove symlinks
make check      # Assert this setup's assumptions still hold
make check-repo # Repository checks only (no machine assumptions; what CI runs)
make doctor     # Debug info (PATH, symlinks, etc.)
make bootstrap  # Full setup from scratch
make test       # Run the test suites in tests/
make test-fast  # Skip the suites that drive a terminal (what pre-push runs)
make lint       # shellcheck, shfmt, stylua and prettier over the repo (what CI lints)
make hooks      # Install the git hooks (check on commit, test-fast on push)
make tidy       # Report accumulated cruft (deletes nothing)
make tidy-apply # Act on what tidy reported
```

`check` is assertions, not an inventory. Every line corresponds to something
that was once wrong here for weeks without producing a symptom — a colour scheme
name that silently fell back, a linter that silently never ran, a completion
cache that was never used. It exits non-zero on failure.

The rule it exists to enforce: **if it can be wrong without saying so, it isn't
finished.**

`check` is split in two, and the split matters:

|                     |                                                                                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `checks/repo.sh`    | Is the _repository_ internally consistent? Holds on any machine with git and the usual text tools, so CI runs it.                        |
| `checks/machine.sh` | Is _this machine_ set up the way the repo assumes? Needs WezTerm, fonts, a stow tree and a git identity — none of which a CI runner has. |

A check that cannot pass in CI ends up disabled, and a disabled check is worse
than no check because it still looks like coverage.

`make hooks` wires `check` to pre-commit and `test-fast` to pre-push, so none of
this depends on remembering to run it. pre-push runs the fast subset rather than
`test` on purpose: the suites that drive a real terminal, editor or language
server dominate the full run, and a hook slow enough to get bypassed is worse
than no hook because it still looks like coverage.

How fast it has to stay is deliberately not a number written here. A timing in
prose is true only on the machine and the day it was measured, and nothing
re-measures it — this file quoted a pre-push timing that had been corrected in
the hook itself the day before, and stayed wrong because reading it is nobody's
job. `tests/test-performance.sh` times the run where it actually runs and fails
against a ceiling instead. `checks/repo.sh` enforces the rule: the only figures
allowed here are ones it can read back out of the config that owns them.

GitHub Actions runs `make lint`, `make check-repo` and `make test` on every
push, so
`--no-verify`, a clone that never ran `make hooks`, and the suites pre-push
skips are all covered. `bootstrap.sh` installs the hooks on a fresh machine, and
`check` fails if they are missing. Bypass a single run with
`git commit --no-verify` / `git push --no-verify`.

`tidy` reports and `tidy-apply` deletes: old tmux-resurrect saves, stale `99-*`
scratch files, the nvim LSP log, and branches already merged into `main`.
Uncommitted work is only ever reported, never touched.

## Changing this repo

Every change carries a comment beside it saying why: the mechanism, not just
the intent. Then it gets proof that it holds. A static fact gets an assertion
in `checks/repo.sh` (or `checks/machine.sh`, if it is about this machine), and
behaviour gets a test in `tests/`. Either way, a mutation in
`tests/test-check.sh` breaks the thing on purpose and requires that exact
assertion to go red, so a check that cannot fail does not count as one.

Run one suite on its own:

```sh
bash tests/test-nvim.sh
```

A suite that sets `SUITE_SLOW=1` drives a real terminal, editor or language
server. `make test-fast` and the pre-push hook skip those; `make test` and CI
run them all.
