-- Bonsai's sandbox (owner, 2026-11-21: "sanboxed based on the current
-- directory and no esclation can be used").
-- Bonsai works only inside the folder Neovim was opened in (the root):
--   * file tools refuse any path that resolves outside it (symlinks followed);
--   * commands run in bubblewrap: the system read-only, the root the only
--     writable place, the rest of $HOME hidden, no network, and no way to
--     gain privileges (bwrap sets no_new_privs, so sudo and setuid fail).
-- Opened in $HOME or /, the root would be too wide, so the tools are off.
local M = {}

local root_override

-- The folder Neovim was opened in (saved at startup by the plugin spec).
function M.root()
  local start = root_override or vim.g.bonsai_root or vim.uv.cwd()
  return vim.uv.fs_realpath(start) or start
end

-- For tests: use another root.
function M.set_root(path)
  root_override = path
end

function M.usable()
  local root = M.root()
  local home = vim.uv.fs_realpath(vim.uv.os_homedir()) or vim.uv.os_homedir()
  return root ~= "/" and root ~= home
end

-- The real path, resolved one part at a time, so a symlink is followed
-- before any ".." after it (text-only clean-up would let "link/../x" escape).
local function resolve(path)
  local cur = "/"
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      cur = vim.fs.dirname(cur) or "/"
    elseif part ~= "." then
      local next_path = (cur == "/" and "" or cur) .. "/" .. part
      cur = vim.uv.fs_realpath(next_path) or next_path
    end
  end
  return cur
end

function M.inside(path)
  local root = M.root()
  if path:sub(1, 1) == "~" then
    path = vim.uv.os_homedir() .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    path = root .. "/" .. path
  end
  local real = resolve(path)
  return real == root or real:sub(1, #root + 1) == root .. "/"
end

-- Why tools that work in Neovim's current folder must not run now, or nil.
-- The plugin's tools search that folder and open relative paths from it, so it
-- has to be inside the project too (contract: NEOVIM-AGENT.md, Addendum 3, B2).
function M.folder_refusal()
  local cwd = vim.fn.getcwd()
  if not M.usable() then
    return M.refusal(cwd)
  end
  if not M.inside(cwd) then
    return ("Refused: Neovim's current folder (%s) is outside the project folder (%s). Go back with :cd %s"):format(
      cwd,
      M.root(),
      M.root()
    )
  end
end

function M.refusal(path)
  if not M.usable() then
    return ("Refused: Neovim was opened in %s, which is too wide for Bonsai. Open Neovim in a project folder."):format(
      M.root()
    )
  end
  return ("Refused: `%s` is outside the project folder (%s). Bonsai can only work inside it."):format(
    path,
    M.root()
  )
end

-- The command line, run by /bin/sh inside bubblewrap.
function M.wrap(cmd)
  local root = M.root()
  return {
    "bwrap",
    "--unshare-all", -- its own user, pid, ipc, uts and cgroup namespaces, and no network
    "--die-with-parent",
    "--new-session",
    "--ro-bind",
    "/usr",
    "/usr",
    "--symlink",
    "usr/bin",
    "/bin",
    "--symlink",
    "usr/bin",
    "/sbin",
    "--symlink",
    "usr/lib",
    "/lib",
    "--symlink",
    "usr/lib",
    "/lib64",
    "--ro-bind",
    "/etc",
    "/etc",
    "--proc",
    "/proc",
    "--dev",
    "/dev",
    "--tmpfs",
    "/tmp",
    "--tmpfs",
    "/run",
    "--bind",
    root,
    root, -- after /tmp, so a root under /tmp still works
    "--chdir",
    root,
    "--clearenv",
    "--setenv",
    "PATH",
    "/usr/local/bin:/usr/bin",
    "--setenv",
    "HOME",
    root,
    "--setenv",
    "TMPDIR",
    "/tmp",
    "--setenv",
    "LANG",
    vim.env.LANG or "C.UTF-8",
    "--setenv",
    "TERM",
    "dumb",
    "--",
    "/bin/sh",
    "-c",
    cmd,
  }
end

return M
