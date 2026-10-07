-- Minimal init for headless plenary tests: this plugin + plenary, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = vim.env.PLENARY_DIR or (vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(plenary)
vim.opt.swapfile = false
vim.opt.shada = ""
vim.cmd("runtime plugin/plenary.vim")
