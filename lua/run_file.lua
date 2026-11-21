-- <space>r for Java, Python and C++: run the current file in a 15 line terminal below.
-- <space>r again stops the run (also from inside the terminal); the next run replaces the old output.
local M = {}

local run_buf = -1

local function shell(s)
  return vim.fn.shellescape(s)
end

-- The shell command that runs `path` for filetype `ft`, or nil and a message.
function M.command(ft, path)
  local name = vim.fn.fnamemodify(path, ":t")
  if ft == "java" then
    if vim.fn.executable("java") == 0 then
      return nil, "No java found on the system!"
    end
    return "java " .. shell(name)
  elseif ft == "python" then
    if vim.fn.executable("python3") == 0 then
      return nil, "No python3 found on the system!"
    end
    return "python3 -u " .. shell(name)
  elseif ft == "cpp" then
    local compiler = vim.fn.executable("clang++") == 1 and "clang++"
      or vim.fn.executable("g++") == 1 and "g++"
      or nil
    if not compiler then
      return nil, "No C++ compiler found on the system!"
    end
    local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "cpp-run")
    vim.fn.mkdir(dir, "p")
    local out = vim.fs.joinpath(dir, vim.fn.fnamemodify(path, ":t:r"))
    return ("%s -std=c++17 -Wall -Wextra -g %s -o %s && %s"):format(
      compiler,
      shell(vim.fn.fnamemodify(path, ":p")),
      shell(out),
      shell(out)
    )
  end
  return nil, "No run command for filetype '" .. ft .. "'"
end

-- The job id of the run if it is still going, else nil
local function running_job()
  if not vim.api.nvim_buf_is_valid(run_buf) then
    return nil
  end
  local ok, job = pcall(vim.api.nvim_buf_get_var, run_buf, "terminal_job_id")
  if ok and job and job > 0 and vim.fn.jobwait({ job }, 0)[1] == -1 then
    return job
  end
  return nil
end

-- Stop the run; its output stays on screen
function M.stop()
  local job = running_job()
  if job then
    vim.fn.jobstop(job)
  end
end

function M.run()
  local ft = vim.bo.filetype
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("Save the file first", vim.log.levels.ERROR)
    return
  end
  local cmd, err = M.command(ft, path)
  if not cmd then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  vim.cmd("update")
  local dir = vim.fn.fnamemodify(path, ":p:h")
  -- the output of the previous (finished) run makes room for the new one
  if vim.api.nvim_buf_is_valid(run_buf) then
    vim.cmd("bwipeout! " .. run_buf)
  end
  vim.o.splitbelow = true
  vim.cmd("new")
  vim.cmd("resize 15")
  vim.cmd("lcd " .. vim.fn.fnameescape(dir))
  vim.cmd("term " .. cmd)
  run_buf = vim.api.nvim_get_current_buf()
  -- <space>r stops the run from inside its terminal too, while typing or not
  vim.keymap.set({ "n", "t" }, "<space>r", function()
    M.stop()
  end, { buffer = true, silent = true })
  vim.cmd("startinsert")
end

-- <space>r runs the current file; while a run is going, <space>r stops it instead
function M.toggle()
  if running_job() then
    M.stop()
  else
    M.run()
  end
end

-- Called from the java, python and cpp ftplugins
function M.setup_buffer()
  vim.keymap.set(
    "n",
    "<space>r",
    M.toggle,
    { buffer = true, silent = true, desc = "run file / stop run" }
  )
end

return M
