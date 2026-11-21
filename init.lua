-- My Neovim configuration, which I use every day on Arch + Hyprland in kitty with fish,
-- with Bonsai as a local coding agent. README.md describes what's in it.
--
-- Author: Sina Esmaeili
-- GitHub: https://github.com/SinaEsmaeili1
vim.loader.enable()

-- 1. BOOTSTRAP Lazy.nvim (Add this so plugins actually install)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system {
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  }
end
vim.opt.rtp:prepend(lazypath)

local utils = require("utils")
local expected_version = "0.12.0"
utils.is_compatible_version(expected_version)

local config_dir = vim.fn.stdpath("config")

-- some global settings
require("globals")
vim.cmd("source " .. vim.fs.joinpath(config_dir, "viml_conf/options.vim"))

-- 2. LOAD PLUGINS FIRST
-- This ensures the dashboard and treesitter are registered before mappings try to use them
require("plugin_specs")

-- 3. YOUR IDEA: Load Treesitter here safely
-- If it's not installed yet, pcall prevents the "Dashboard" from crashing
-- pcall(function()
--   require("nvim-treesitter.configs").setup({
--     ensure_installed = { "python", "cpp", "lua", "html", "css", "javascript" },
--     auto_install = true,
--     highlight = { enable = true },
--   })
-- end)

-- 4. Load the rest of the UI
require("custom-autocmd")
require("templates")
require("mappings")
require("diagnostic-conf")
require("folders").setup() -- remember opened folders for "Recently opened folders"
require("live_server").setup() -- :Live / :live, a live server for the current folder

local color_scheme = require("colorschemes")
color_scheme.rand_colorscheme()
