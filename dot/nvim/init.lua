-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- プラグインの設定
require("lazy").setup({ require("plugins") })

-- Vim settings
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.cmdheight = 2
vim.opt.updatetime = 300
vim.opt.signcolumn = "number"
vim.opt.mouse = ""
vim.opt.number = true
vim.opt.cursorline = true
vim.opt.showmatch = true
vim.opt.virtualedit = "onemore"
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.smarttab = true

-- Key mappings
vim.keymap.set("n", "j", "gj")
vim.keymap.set("n", "k", "gk")

-- カラースキームの設定
vim.api.nvim_command('colorscheme nightfox')
