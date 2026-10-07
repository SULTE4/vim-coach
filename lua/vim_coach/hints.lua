-- Occasional, rate-limited hints. offer() is cheap: a few table lookups.
local config = require("vim_coach.config")
local cost = require("vim_coach.cost")
local session = require("vim_coach.session")

local uv = vim.uv or vim.loop

local M = {}

local ns = vim.api.nvim_create_namespace("vim_coach_hint")
local timer ---@type uv.uv_timer_t?
local shown = { buf = nil, id = nil }
local last_any = nil ---@type number?
local last_idiom = {} ---@type table<string, number>

--- Clock in seconds. Tests may replace it.
M._clock = function()
  return uv.hrtime() / 1e9
end

function M.setup()
  vim.api.nvim_set_hl(0, "VimCoachHint", { link = "DiagnosticHint", default = true })
end

--- Test hook: forget cooldown timestamps.
function M._reset()
  last_any, last_idiom = nil, {}
  M.clear()
end

--- Remove the virtual text hint, if any.
function M.clear()
  if timer then
    timer:stop()
  end
  if shown.buf and vim.api.nvim_buf_is_valid(shown.buf) then
    pcall(vim.api.nvim_buf_del_extmark, shown.buf, ns, shown.id)
  end
  shown.buf, shown.id = nil, nil
end

local function message(finding)
  local e = finding.event
  local saved = e.naive - e.ideal
  local detail = finding.was and (finding.was .. ", ") or ""
  return ("vim-coach: %s could do this (%ssaves %d keys)"):format(finding.label or e.idiom, detail, saved)
end

local function show_virt(msg)
  M.clear()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  shown.buf = buf
  shown.id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { msg, "VimCoachHint" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
  timer = timer or uv.new_timer()
  timer:stop()
  timer:start(cost.hint_ttl_ms, 0, vim.schedule_wrap(M.clear))
end

---@param finding VimCoach.Finding
---@return boolean shown
function M.offer(finding)
  local mode = config.options.hint
  if not mode then
    return false
  end
  local e = finding and finding.event
  if not e then
    return false
  end
  local id = e.idiom
  local meta = require("vim_coach.catalog")[id]
  if meta and meta.stats_only then
    return false
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    return false
  end
  if session.seen(id) < cost.hint_after and (e.naive - e.ideal) < cost.hint_big_saving then
    return false
  end
  local st = require("vim_coach.store").state()
  if st.learned[id] or st.dismissed[id] then
    return false
  end
  local now = M._clock()
  if last_any and now - last_any < cost.hint_cooldown_s then
    return false
  end
  if last_idiom[id] and now - last_idiom[id] < cost.hint_idiom_cooldown_s then
    return false
  end

  local msg = message(finding)
  if mode == "notify" then
    vim.notify(msg, vim.log.levels.INFO, { title = "vim-coach" })
  else
    show_virt(msg)
  end
  last_any, last_idiom[id] = now, now
  return true
end

return M
