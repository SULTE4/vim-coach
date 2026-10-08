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
local pbuf, pwin ---@type integer?, integer?
local ptimer ---@type uv.uv_timer_t?
local group

--- Clock in seconds. Tests may replace it.
M._clock = function()
  return uv.hrtime() / 1e9
end

function M.setup()
  vim.api.nvim_set_hl(0, "VimCoachHint", { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, "VimCoachPopup", { link = "NormalFloat", default = true })
  vim.api.nvim_set_hl(0, "VimCoachPopupBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "VimCoachPopupKey", { link = "DiagnosticHint", default = true })
  group = vim.api.nvim_create_augroup("vim_coach_hints", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", { group = group, callback = function()
    M.close_popup()
  end })
end

--- Close the popup window, if any.
function M.close_popup()
  if ptimer then
    ptimer:stop()
  end
  if pwin and vim.api.nvim_win_is_valid(pwin) then
    pcall(vim.api.nvim_win_close, pwin, true)
  end
  pwin = nil
end

--- Test hook: forget cooldown timestamps.
function M._reset()
  last_any = nil
  M.clear()
end

--- Remove the virtual text hint, if any.
function M.clear()
  M.close_popup()
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

local function ordinal(n)
  if n == 1 then return "1st" elseif n == 2 then return "2nd" elseif n == 3 then return "3rd" end
  return n .. "th"
end

---@return string[] lines
---@return integer key_col  byte range of the label on line 2: key_col .. key_col+#label
local function popup_lines(finding, count)
  local e = finding.event
  local label = finding.label or e.idiom
  local lines = {}
  if finding.was then
    lines[1] = ("%s - %s time this session"):format(finding.was, ordinal(count))
  else
    local meta = require("vim_coach.catalog")[e.idiom]
    lines[1] = ("%s - %s time this session"):format(meta and meta.desc or e.idiom, ordinal(count))
  end
  lines[2] = ("Try: %s   (saves %d keys)"):format(label, e.naive - e.ideal)
  local alts = finding.alt_labels
  if not alts then
    alts = {}
    local cat = require("vim_coach.catalog")
    for _, a in ipairs(e.alts or {}) do
      if cat[a] then
        alts[#alts + 1] = cat[a].example
      end
    end
  end
  if #alts > 0 then
    lines[3] = "also: " .. table.concat(alts, "  ")
  end
  return lines, 5
end

local function show_popup(finding, count)
  M.close_popup()
  local lines, key_col = popup_lines(finding, count)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  if not pbuf or not vim.api.nvim_buf_is_valid(pbuf) then
    pbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[pbuf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(pbuf, ns, 1, key_col, {
    end_col = key_col + #(finding.label or finding.event.idiom), hl_group = "VimCoachPopupKey",
  })
  local opts = {
    focusable = false, style = "minimal", border = "rounded", title = " vim-coach ",
    noautocmd = true, zindex = 60, width = width, height = #lines,
  }
  if (config.options.popup or {}).position == "top_right" then
    opts.relative, opts.row, opts.col = "editor", 1, math.max(0, vim.o.columns - width - 2)
  else
    -- Need lines + 2 border rows below the cursor line; otherwise flip above.
    local below = vim.api.nvim_win_get_height(0) - vim.fn.winline()
    opts.relative = "cursor"
    opts.col = 0
    opts.row = below >= #lines + 2 and 1 or -(#lines + 2)
  end
  pwin = vim.api.nvim_open_win(pbuf, false, opts)
  vim.wo[pwin].winhighlight = "NormalFloat:VimCoachPopup,FloatBorder:VimCoachPopupBorder"
  ptimer = ptimer or uv.new_timer()
  ptimer:stop()
  ptimer:start(cost.popup_ttl_ms, 0, vim.schedule_wrap(M.close_popup))
end

--- True when count is hint_after * hint_escalation^k for some k >= 0.
local function on_schedule(count)
  local n = cost.hint_after
  while n < count do
    n = n * cost.hint_escalation
  end
  return n == count
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
  local count = session.seen(id)
  if not (on_schedule(count) or (count == 1 and (e.naive - e.ideal) >= cost.hint_big_saving)) then
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

  if mode == "popup" then
    show_popup(finding, count)
  elseif mode == "notify" then
    vim.notify(message(finding), vim.log.levels.INFO, { title = "vim-coach" })
  else
    show_virt(message(finding))
  end
  last_any = now
  return true
end

return M
