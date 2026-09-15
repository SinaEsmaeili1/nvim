local status, ts = pcall(require, "nvim-treesitter.configs")
if not status then
    return -- Exit quietly if plugin isn't ready
end

ts.setup {
  ensure_installed = { "python", "cpp", "lua", "html", "css" },
  highlight = { enable = true },
}