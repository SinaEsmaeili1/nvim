-- Web search through the owner's own SearXNG on 127.0.0.1:8888: no search
-- API, no key (owner, 2026-11-21). A codecompanion web_search adapter, in
-- the same shape as its built-in DuckDuckGo one. Every search still waits
-- for the owner's approval (web_search's require_approval_before).
local fmt = string.format

local MAX_RESULTS = 8

return {
  name = "searxng",
  formatted_name = "SearXNG",
  roles = { llm = "assistant", user = "user" },
  opts = { method = "GET" },
  url = "http://127.0.0.1:8888/search?q=${query}&format=json",
  env = {},
  headers = { ["Accept"] = "application/json" },
  schema = { model = { default = "searxng" } },
  handlers = {},
  methods = {
    tools = {
      web_search = {
        setup = function(self, opts, data)
          self.env = vim.tbl_deep_extend("force", self.env or {}, {
            query = vim.uri_encode(data.query),
          })
        end,

        callback = function(self, data)
          if data.status >= 300 then
            return {
              status = "error",
              content = fmt(
                "SearXNG answered %s. Is it running? Check with: systemctl --user status searxng",
                data.status
              ),
            }
          end
          local ok, decoded = pcall(vim.json.decode, data.body)
          if not ok or type(decoded) ~= "table" then
            return {
              status = "error",
              content = "SearXNG's answer wasn't JSON (is the json format enabled in its settings?)",
            }
          end
          local out = {}
          for _, r in ipairs(decoded.results or {}) do
            if #out >= MAX_RESULTS then
              break
            end
            table.insert(
              out,
              { title = r.title or "", url = r.url or "", content = r.content or "" }
            )
          end
          if #out == 0 then
            return { status = "error", content = "No results found" }
          end
          return { status = "success", content = out }
        end,
      },
    },
  },
}
