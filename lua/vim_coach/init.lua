-- Vim Coach: finds edits and movements a Vim idiom could have done faster,
-- and ranks what to learn next.
local config = require("vim_coach.config")

local M = {}

local enabled = false
local did_setup = false

function M.setup(opts)
  config.setup(opts)
  require("vim_coach.store").setup(config.options.data_path)
  require("vim_coach.hints").setup()
  if not did_setup then
    did_setup = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("vim_coach_core", { clear = true }),
      callback = function()
        M.disable()
        require("vim_coach.store").stop()
      end,
    })
  end
  if config.options.enabled then
    M.enable()
  end
end

--- Commands call this so :VimCoach works even if setup() was never called.
function M._ensure()
  if not did_setup then
    M.setup({})
  end
end

function M.enable()
  if enabled then
    return
  end
  enabled = true
  if config.options.detectors.keys then
    require("vim_coach.keys").setup()
  end
  if config.options.detectors.edits then
    require("vim_coach.edits").setup()
    -- Start the verify child after startup so it never delays opening Neovim.
    vim.defer_fn(function()
      if enabled then
        require("vim_coach.verify").warm()
      end
    end, 2000)
  end
end

function M.disable()
  if not enabled then
    return
  end
  enabled = false
  require("vim_coach.keys").stop()
  require("vim_coach.edits").stop()
  require("vim_coach.verify").stop()
  require("vim_coach.hints").clear()
end

function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
  vim.notify("vim-coach " .. (enabled and "enabled" or "disabled"))
end

function M.is_enabled()
  return enabled
end

function M.stats()
  require("vim_coach.stats").open()
end

function M.scan()
  require("vim_coach.scan").run(vim.api.nvim_get_current_buf())
end

function M.dismiss(id)
  require("vim_coach.store").dismiss(id)
end

function M.undismiss(id)
  require("vim_coach.store").undismiss(id)
end

function M.learned(id)
  require("vim_coach.store").mark_learned(id, os.time())
end

function M.reset()
  require("vim_coach.store").reset()
  require("vim_coach.session").reset()
end

--- Echo this session's findings (newest last).
function M.log()
  local lines = {}
  for _, f in ipairs(require("vim_coach.session").log()) do
    local e = f.event
    lines[#lines + 1] = ("%s  %-16s %-10s saved %d%s"):format(
      os.date("%H:%M:%S", e.ts), e.idiom, f.label, e.naive - e.ideal, f.was and ("  (" .. f.was .. ")") or "")
  end
  if #lines == 0 then
    lines = { "vim-coach: no findings this session yet" }
  end
  vim.notify(table.concat(lines, "\n"))
end

return M
