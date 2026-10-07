if vim.g.loaded_vim_coach then
  return
end
vim.g.loaded_vim_coach = 1

local subcommands = { "stats", "scan", "log", "toggle", "reset", "dismiss", "undismiss", "learned" }
local with_id = { dismiss = true, undismiss = true, learned = true }

local function ids()
  local out = {}
  for id, e in pairs(require("vim_coach.catalog")) do
    if not e.concept then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function complete(arglead, cmdline)
  local parts = vim.split(vim.trim(cmdline), "%s+")
  local trailing = cmdline:match("%s$") ~= nil
  local n = trailing and #parts + 1 or #parts
  local pool
  if n <= 2 then
    pool = subcommands
  elseif with_id[parts[2]] then
    pool = ids()
  else
    return {}
  end
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, pool)
end

vim.api.nvim_create_user_command("VimCoach", function(o)
  local vc = require("vim_coach")
  vc._ensure()
  local sub = o.fargs[1] or "stats"
  local id = o.fargs[2]
  if sub == "stats" then
    vc.stats()
  elseif sub == "scan" then
    vc.scan()
  elseif sub == "log" then
    vc.log()
  elseif sub == "toggle" then
    vc.toggle()
  elseif sub == "reset" then
    if vim.fn.confirm("vim-coach: erase all stats?", "&Yes\n&No", 2) == 1 then
      vc.reset()
      vim.notify("vim-coach: stats erased")
    end
  elseif with_id[sub] then
    local cat = require("vim_coach.catalog")
    if not id or not cat[id] or cat[id].concept then
      vim.notify("vim-coach: unknown idiom id: " .. tostring(id), vim.log.levels.ERROR)
      return
    end
    vc[sub](id)
  else
    vim.notify("vim-coach: unknown subcommand: " .. sub, vim.log.levels.ERROR)
  end
end, { nargs = "*", complete = complete, desc = "Vim Coach" })
