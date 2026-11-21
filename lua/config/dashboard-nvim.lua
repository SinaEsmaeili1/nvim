local api = vim.api
local keymap = vim.keymap
local dashboard = require("dashboard")

local conf = {}

conf.center = {
  -- Bonsai's panel, the one Ctrl+A opens; Bonsai is started if it isn't running.
  {
    icon = "󰔱  ",
    desc = "Ask Bonsai                              ",
    action = function()
      require("bonsai.ui").start()
    end,
    key = "b",
  },
  {
    icon = "󰈞  ",
    desc = "Find File/Folder                        ",
    action = function()
      require("folders").find_files_and_folders()
    end,
    key = "<Leader> f f",
  },
  {
    icon = "󰈢  ",
    desc = "Recently opened files                   ",
    action = "FzfLua oldfiles",
    key = "<Leader> f r",
  },
  {
    icon = "󰉋  ",
    desc = "Recently opened folders                 ",
    action = function()
      require("folders").recent_folders()
    end,
    key = "<Leader> f d",
  },
  {
    icon = "󰈬  ",
    desc = "Project grep                            ",
    action = "FzfLua live_grep",
    key = "<Leader> f g",
  },
  {
    icon = "  ",
    desc = "Open Nvim config                        ",
    action = "tabnew $MYVIMRC | tcd %:p:h",
    key = "<Leader> e v",
  },
  {
    icon = "  ",
    desc = "New file                                ",
    action = "enew",
    key = "e",
  },
  {
    icon = "󰗼  ",
    desc = "Quit Nvim                               ",
    -- desc = "Quit Nvim                               ",
    action = "qa",
    key = "q",
  },
}

-- One of my ASCII arts (lua/dashboard_art.lua), picked at random each start among
-- those that fit above the menu. The menu takes 2 rows per entry and 3 for the
-- startup time, and the command line, the status line and a spare row aren't free.
conf.header = require("dashboard_art").pick(
  vim.o.columns,
  vim.o.lines - vim.o.cmdheight - 2,
  #conf.center * 2 + 3
)

dashboard.setup {
  theme = "doom",
  shortcut_type = "number",
  config = conf,
}

api.nvim_create_autocmd("FileType", {
  pattern = "dashboard",
  group = api.nvim_create_augroup("dashboard_enter", { clear = true }),
  callback = function(args)
    keymap.set("n", "q", ":qa<CR>", { buffer = true, silent = true })
    keymap.set("n", "e", ":enew<CR>", { buffer = true, silent = true })
    -- No indent guide here: mini.indentscope would draw a line down the menu.
    vim.b[args.buf].miniindentscope_disable = true
  end,
})
