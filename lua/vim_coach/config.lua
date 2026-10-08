-- User-facing options. Tunable numbers live in cost.lua, not here.
local M = {}

M.defaults = {
  enabled = true,
  hint = "popup", -- "popup" | "virt" (end-of-line virtual text) | "notify" | false
  popup = { position = "cursor", dismiss_key = "<M-d>" }, -- position: "cursor" | "top_right"; dismiss_key false = off
  detectors = {
    keys = true, -- key-pattern detector (vim.on_key)
    edits = true, -- edit-shape detector (nvim_buf_attach)
  },
  exclude_ft = {
    "help", "qf", "netrw", "neo-tree", "NvimTree", "TelescopePrompt",
    "lazy", "mason", "gitcommit", "vim_coach",
  },
  count_jk = "relativenumber", -- suggest 7j/5k only with 'relativenumber' on | "always"
  ignore = {}, -- idiom ids never shown or recommended, e.g. { "count-jk" } (see :VimCoach dismiss)
  data_path = nil, -- nil = stdpath("data") .. "/vim_coach.json"
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if not M.options.data_path then
    M.options.data_path = vim.fn.stdpath("data") .. "/vim_coach.json"
  end
  M._exclude = {}
  for _, ft in ipairs(M.options.exclude_ft) do
    M._exclude[ft] = true
  end
  return M.options
end

--- True when a buffer should be ignored by both detectors.
---@param buf integer
function M.excluded(buf)
  if vim.bo[buf].buftype ~= "" then
    return true
  end
  return (M._exclude or {})[vim.bo[buf].filetype] == true
end

return M
