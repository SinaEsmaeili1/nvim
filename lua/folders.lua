-- Folder helpers: which folder Neo-tree should show, a "recently opened folders" history,
-- and the dashboard pickers "Find File/Folder" and "Recently opened folders".
local M = {}

local root_markers = { ".git", "pom.xml", "build.gradle", "build.gradle.kts" }
local history_file = vim.fs.joinpath(vim.fn.stdpath("state"), "recent_folders.txt")
local max_entries = 200

--- Folder to show for a path: a folder is itself; a file maps to its project root
--- (git/Maven/Gradle), or to the folder it is in when it is not part of a project.
function M.folder_for(path)
  if vim.fn.isdirectory(path) == 1 then
    return M.normalize(path)
  end
  return vim.fs.root(path, root_markers) or vim.fs.dirname(M.normalize(path))
end

function M.normalize(path)
  local p = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if #p > 1 then
    p = (p:gsub("/+$", ""))
  end
  return p
end

local function read_history()
  local ok, lines = pcall(vim.fn.readfile, history_file)
  return ok and lines or {}
end

-- Folders that are never worth listing: home and / themselves, Nvim's runtime and plugins
local function ignored(dir)
  if dir == "/" or dir == M.normalize(vim.env.HOME) then
    return true
  end
  for _, prefix in ipairs { vim.env.VIMRUNTIME, vim.fn.stdpath("data") } do
    if prefix and vim.startswith(dir, M.normalize(prefix)) then
      return true
    end
  end
  return false
end

--- Put a folder at the top of the recent-folders history.
function M.remember(dir)
  if not dir or dir == "" or vim.fn.isdirectory(dir) == 0 then
    return
  end
  dir = M.normalize(dir)
  if ignored(dir) then
    return
  end

  local list = { dir }
  for _, d in ipairs(read_history()) do
    if d ~= dir and #list < max_entries then
      table.insert(list, d)
    end
  end
  vim.fn.mkdir(vim.fs.dirname(history_file), "p")
  pcall(vim.fn.writefile, list, history_file)
end

--- Open a folder: make it the working directory and show it in Neo-tree.
function M.open_folder(dir)
  dir = M.normalize(dir)
  if vim.bo.filetype == "dashboard" then
    vim.cmd.enew()
  end
  vim.cmd.cd(vim.fn.fnameescape(dir))
  require("neo-tree.command").execute { action = "focus", dir = dir }
end

--- Fuzzy-find files and folders below the working directory.
--- A file opens for editing; a folder opens in Neo-tree (see `open_folder`).
function M.find_files_and_folders()
  require("fzf-lua").files {
    prompt = "Files/Folders> ",
    fd_opts = "--color=never --type f --type l --type d --exclude .git",
    actions = {
      ["enter"] = function(selected, opts)
        local entry = require("fzf-lua.path").entry_to_file(selected[1] or "", opts)
        local path = entry.path or ""
        if opts.cwd and not vim.startswith(path, "/") then
          path = vim.fs.joinpath(opts.cwd, path)
        end

        if #selected == 1 and vim.fn.isdirectory(path) == 1 then
          M.open_folder(path)
        else
          require("fzf-lua.actions").file_edit_or_qf(selected, opts)
        end
      end,
    },
  }
end

--- Pick a folder from the recent-folders history and open it.
function M.recent_folders()
  local items = {}
  for _, dir in ipairs(read_history()) do
    if vim.fn.isdirectory(dir) == 1 then
      table.insert(items, vim.fn.fnamemodify(dir, ":~"))
    end
  end

  if #items == 0 then
    vim.notify("No recently opened folders yet", vim.log.levels.INFO)
    return
  end

  require("fzf-lua").fzf_exec(items, {
    prompt = "Recent folders> ",
    actions = {
      ["enter"] = function(selected)
        if selected[1] then
          M.open_folder(vim.fs.normalize(selected[1]))
        end
      end,
    },
  })
end

--- Record folders as they are opened:
---  * folders given on the command line (`nvim some_dir`), or the folder Nvim starts in
---    when it is started without arguments (`cd some_dir && nvim`)
---  * every change of the working directory (`:cd`, Neo-tree, the pickers above)
---  * the project folder of every file that is opened
function M.setup()
  for _, arg in ipairs(vim.fn.argv()) do
    if vim.fn.isdirectory(arg) == 1 then
      M.remember(arg)
    end
  end
  if vim.fn.argc() == 0 then
    M.remember(vim.fn.getcwd())
  end

  local group = vim.api.nvim_create_augroup("recent_folders", { clear = true })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    pattern = { "global", "tabpage" },
    callback = function()
      M.remember(vim.v.event.cwd)
    end,
    desc = "remember the new working directory",
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(args)
      local file = args.file
      -- buftype is set after reading for some buffers (e.g., help), so check it later
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) and vim.bo[args.buf].buftype == "" and file ~= "" then
          M.remember(M.folder_for(file))
        end
      end)
    end,
    desc = "remember the project folder of opened files",
  })
end

return M
