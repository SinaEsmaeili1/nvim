-- Hello World starters for new .py, .cpp, .java, .html and .js files.
local M = {}

local function lines(s) return vim.split(s, "\n", { plain = true }) end

local html = [[
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hello, World!</title>
</head>
<body>
    <h1>Hello, World!</h1>
</body>
</html>]]

local python = [[
def main():
    print("Hello, World!")


if __name__ == "__main__":
    main()]]

local cpp = [[
#include <iostream>

int main() {
    std::cout << "Hello, World!" << std::endl;
    return 0;
}]]

local function java(path)
  local class = vim.fn.fnamemodify(path, ":t:r"):gsub("[^%w_$]", "_")
  if class:match("^%d") then class = "_" .. class end
  local out = {}
  local abs = vim.fn.fnamemodify(path, ":p:h") .. "/"
  local pkg = abs:match("/src/main/java/(.*)/$") or abs:match("/src/test/java/(.*)/$")
  if pkg then
    vim.list_extend(out, { "package " .. pkg:gsub("/", ".") .. ";", "" })
  end
  vim.list_extend(out, {
    "public class " .. class .. " {",
    "    public static void main(String[] args) {",
    '        System.out.println("Hello, World!");',
    "    }",
    "}",
  })
  return out
end

-- The template lines for a file path, or nil when that file gets none
function M.lines(path)
  local name = vim.fn.fnamemodify(path, ":t")
  if name == "__init__.py" then return nil end
  local ext = name:match("%.([^.]+)$")
  if ext == "py" then return lines(python) end
  if ext == "cpp" then return lines(cpp) end
  if ext == "java" then return java(path) end
  if ext == "html" then return lines(html) end
  if ext == "js" then return { 'console.log("Hello, World!");' } end
  return nil
end

-- A new buffer (file does not exist yet): fill it, leave it unmodified, cursor on the print line
function M.fill_buffer(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or vim.uv.fs_stat(path) then return end
  local text = M.lines(path)
  if not text then return end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modified = false
  for i, l in ipairs(text) do
    if l:find("Hello, World!", 1, true) and not l:find("<title>", 1, true) then
      -- Only in a window that shows the new buffer (`nvim -o a.py b.py` makes several at once).
      if vim.api.nvim_win_get_buf(0) == buf then vim.api.nvim_win_set_cursor(0, { i, #l:match("^%s*") }) end
      break
    end
  end
end

-- A file just created empty by the file tree: write the template into it (files with content stay)
function M.fill_file(path)
  local st = path and vim.uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size ~= 0 then return end
  local text = M.lines(path)
  if text then vim.fn.writefile(text, path) end
end

vim.api.nvim_create_autocmd("BufNewFile", {
  group = vim.api.nvim_create_augroup("hello_world_templates", { clear = true }),
  pattern = { "*.py", "*.cpp", "*.java", "*.html", "*.js" },
  callback = function(args) M.fill_buffer(args.buf) end,
  desc = "Hello World starter for a new file",
})

return M
