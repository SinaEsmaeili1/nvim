-- file_search, run only while Neovim's current folder is inside the project.
return require("bonsai.tools.folder_guard")(
  "codecompanion.interactions.chat.tools.builtin.file_search"
)
