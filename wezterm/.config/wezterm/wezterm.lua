-- WezTerm terminal emulator configuration.
-- Launches directly into a tmux session (creates or reattaches to "main").
-- Rosé Pine Moon theme to match nvim and tmux.
local wezterm = require("wezterm")
return {
    font_size = 18.0,
    font = wezterm.font_with_fallback({
        "JetBrainsMono Nerd Font",
        "JetBrains Mono",
        "Menlo",
    }),

    -- Exact name of the bundled scheme: lowercase, hyphenated, no accent.
    -- "Rosé Pine Moon" matches nothing and WezTerm falls back to the default
    -- without warning, which is why this looked wrong next to nvim and tmux.
    color_scheme = "rose-pine-moon",
    enable_tab_bar = false, -- tmux handles windowing
    window_padding = {
        left = 4,
        right = 4,
        top = 4,
        bottom = 4,
    },

    -- No effect in this setup. The kitty keyboard protocol is switched on by
    -- the program reading the keys, and every pane is tmux (default_prog
    -- below), which never asks for it and does not pass a request from nvim
    -- or anything else inside it through. tmux uses xterm's modifyOtherKeys
    -- instead; see the extended-keys comment in tmux.conf.
    enable_kitty_keyboard = true,
    -- Little of this is ever filled. tmux switches WezTerm to the alternate
    -- screen when it attaches, which keeps no scrollback, so the scrollback
    -- that exists is tmux's own history-limit in tmux.conf.
    scrollback_lines = 10000,
    adjust_window_size_when_changing_font_size = false,

    -- Opt+Left/Right send ESC b / ESC f, which zsh's emacs keymap binds to
    -- backward-word / forward-word, and Opt+Backspace sends Ctrl-W,
    -- backward-kill-word. tmux passes all three to the pane unchanged.
    keys = {
        { key = "LeftArrow", mods = "OPT", action = wezterm.action.SendString("\x1bb") },
        { key = "RightArrow", mods = "OPT", action = wezterm.action.SendString("\x1bf") },
        { key = "Backspace", mods = "OPT", action = wezterm.action.SendString("\x17") },
    },

    -- Auto-attach to tmux "main" session (or create it)
    default_prog = {
        "/opt/homebrew/bin/tmux",
        "new",
        "-A",
        "-s",
        "main",
    },
}
