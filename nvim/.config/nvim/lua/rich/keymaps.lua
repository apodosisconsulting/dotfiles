-- Global keymaps (not tied to any plugin).
-- Plugin-specific keymaps live in their respective plugin files.
-- All mappings use desc so they show up in which-key.

-- Basics
vim.keymap.set("n", "<leader>w", "<cmd>w<cr>", { silent = true, desc = "Write file" })
vim.keymap.set("n", "<leader>q", "<cmd>bd<cr>", { silent = true, desc = "Close buffer" })
vim.keymap.set("n", "<leader>Q", "<cmd>qa<cr>", { silent = true, desc = "Quit Neovim" })
vim.keymap.set("n", "<leader>e", "<cmd>Ex<cr>", { silent = true, desc = "Open netrw" })

-- Move selected lines up/down and re-indent
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { silent = true, desc = "Move selection down" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { silent = true, desc = "Move selection up" })

-- Join lines without moving cursor (mark position, join, restore)
vim.keymap.set("n", "J", "mzJ`z", { silent = true, desc = "Join lines, keep cursor" })

-- Half-page jumps stay centred so you don't lose your place
vim.keymap.set("n", "<C-d>", "<C-d>zz", { silent = true, desc = "Half-page down + center" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { silent = true, desc = "Half-page up + center" })

-- Search results stay centred and unfold any folds
vim.keymap.set("n", "n", "nzzzv", { silent = true, desc = "Next search + center" })
vim.keymap.set("n", "N", "Nzzzv", { silent = true, desc = "Prev search + center" })

-- Clear search highlights (hlsearch is on; Esc dismisses them)
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<cr>", { silent = true, desc = "Clear search highlights" })

-- Clipboard: there is one, the system's. options.lua sets clipboard=unnamedplus,
-- so a plain y and p already go through pbcopy and pbpaste: what you yank here
-- is what Cmd-V pastes anywhere else, and p pastes what you copied anywhere else.
--
-- So does every delete, which is the cost -- dd, x and ciw replace the clipboard
-- too, and so does a plain visual p, with the text it pasted over. These two go
-- round it:
--   <leader>d  deletes into the void register, so the clipboard is untouched
--   <leader>p  pastes over a selection and keeps the clipboard, so the same
--              text can be pasted again
--
-- <leader>p is the built-in visual P under a leader name. It used to be "_dP,
-- which pastes one place too early when the selection ends a line or the
-- buffer: "_d leaves the cursor on the character before the gap and P puts in
-- front of it, so `foo bar` with bar replaced came out `fooX ` instead of
-- `foo X`. Visual P keeps the default register -- under unnamedplus, the
-- clipboard -- and chooses where to put the way visual p does.
--
-- <leader>y and <leader>Y predate unnamedplus, when they were the only way to
-- the clipboard. They now copy to the same clipboard y and yy do -- yy, not Y:
-- the map is non-recursive, so "+Y is Vim's linewise Y, not Neovim's
-- Y-to-end-of-line. (Naming "+ also skips the "0 yank register a plain y
-- fills.) Kept so the habit still does what it always did. Deleting them is not
-- neutral: an unmapped <leader>Y runs as <Space> then Y -- move right, yank to
-- the end of the line -- and puts part of the line on the clipboard silently.
vim.keymap.set("x", "<leader>p", "P", { silent = true, desc = "Paste without register loss" })
vim.keymap.set({ "n", "v" }, "<leader>y", [["+y]], { silent = true, desc = "Yank to clipboard" })
vim.keymap.set("n", "<leader>Y", [["+Y]], { silent = true, desc = "Yank line to clipboard" })
vim.keymap.set({ "n", "v" }, "<leader>d", [["_d]], { silent = true, desc = "Delete to void register" })

-- Quickfix list navigation
vim.keymap.set("n", "]q", "<cmd>cnext<cr>zz", { silent = true, desc = "Next quickfix item" })
vim.keymap.set("n", "[q", "<cmd>cprev<cr>zz", { silent = true, desc = "Prev quickfix item" })

-- Disable Q (ex mode is never useful, easy to hit accidentally)
vim.keymap.set("n", "Q", "<nop>")

-- Quick search-replace for the word under cursor across the whole file
vim.keymap.set("n", "<leader>s", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]],
    { desc = "Replace word under cursor" })

-- Make current file executable without leaving the editor
vim.keymap.set("n", "<leader>x", "<cmd>!chmod +x %<CR>", { silent = true, desc = "chmod +x current file" })
