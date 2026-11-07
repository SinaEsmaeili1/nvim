-- nvim-treesitter main branch: install parsers, then start highlighting per buffer
local status, ts = pcall(require, "nvim-treesitter")
if not status then
  return -- Exit quietly if plugin isn't ready
end

ts.install { "python", "cpp", "lua", "html", "css", "java" }

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("treesitter_highlight", { clear = true }),
  callback = function(args)
    -- falls back to the regular Vim syntax when no parser is available
    pcall(vim.treesitter.start, args.buf)
  end,
  desc = "Enable treesitter highlighting",
})
