-- Edit-shape detector. Watches text changes (nvim_buf_attach on_bytes) and asks: what is
-- the shortest Vim command that would have produced this change? A suggestion is only
-- reported when replaying it on the "before" text gives exactly the "after" text.
--
-- Performance rules:
--   * on_bytes is O(1): it widens a dirty row range and never reads buffer text.
--   * Analysis runs only when a span ends, from vim.schedule, never inside on_bytes.
--   * A shadow copy of the lines is refreshed only over the changed rows.
local cost = require("vim_coach.cost")
local config = require("vim_coach.config")
local diff = require("vim_coach.diff")
local candidates = require("vim_coach.candidates")
local verify = require("vim_coach.verify")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local S = {} -- buf -> state
local gen = 0 -- bumped on every setup(); stale on_bytes callbacks detach themselves
local stopped = true
local in_insert = false
local active_buf = nil -- buffer with an open span
local keys_mod = nil
local timer = nil
local timer_buf = nil
local augroup = nil

-- Cursor and key snapshot taken on CursorMoved in normal mode while no span is open.
-- Keys typed before it (motions) are not charged to the edit.
local snap = { buf = nil, cursor = nil, total = 0, counters = nil }

-- Recent edit-shape signatures (memory only, never persisted).
local RING_MAX = 16
local ring = {}

-- Shadow handling ------------------------------------------------------------

local function take_shadow(st, buf)
  st.shadow = api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Replace shadow[s..e] (1-based, inclusive) with `new`.
local function splice(shadow, s, e, new)
  local n_old, n_new = e - s + 1, #new
  local len = #shadow
  local d = n_new - n_old
  if d > 0 then
    for i = len, e + 1, -1 do
      shadow[i + d] = shadow[i]
    end
  elseif d < 0 then
    for i = e + 1, len do
      shadow[i + d] = shadow[i]
    end
    for i = len + d + 1, len do
      shadow[i] = nil
    end
  end
  for i = 1, n_new do
    shadow[s + i - 1] = new[i]
  end
end

local function refresh_snap()
  snap.buf = api.nvim_get_current_buf()
  snap.cursor = api.nvim_win_get_cursor(0)
  if keys_mod then
    snap.total = keys_mod.total()
    snap.counters = keys_mod.counters()
  end
end

-- Span end -------------------------------------------------------------------

local function stop_timer()
  if timer then
    timer:stop()
  end
  timer_buf = nil
end

local function kdelta(now, base)
  if not now or not base then
    return nil
  end
  local d = {}
  for k, v in pairs(now) do
    d[k] = v - (base[k] or 0)
  end
  return d
end

local function describe(shape, kd)
  local min = cost.min_run_edit
  if kd and kd.bs >= min.bs then
    return ("%d x <BS>"):format(kd.bs)
  elseif kd and kd.x >= min.x then
    return ("%d x x"):format(kd.x)
  elseif kd and kd.dd >= min.dd then
    return ("%d x dd"):format(kd.dd)
  end
  local k = shape.kind
  if k == "intra" then
    local it = shape.items[1]
    if it.old == "" then
      return "text inserted"
    elseif it.new == "" then
      return ("%d chars deleted"):format(vim.fn.strchars(it.old))
    end
    return ("%d chars replaced"):format(vim.fn.strchars(it.old))
  elseif k == "per_line" then
    return ("%d lines edited"):format(#shape.items)
  elseif k == "del_lines" then
    return ("%d lines deleted"):format(shape.n)
  elseif k == "move" then
    return ("%d lines moved"):format(shape.n)
  elseif k == "dup" then
    return ("%d lines duplicated"):format(shape.n)
  elseif k == "join" then
    return ("%d lines joined"):format(shape.n)
  end
  return "edited"
end

-- Count of identical recent shapes including this one.
local function ring_push(sig)
  if not sig then
    return 0
  end
  local n = 1
  for _, s in ipairs(ring) do
    if s == sig then
      n = n + 1
    end
  end
  ring[#ring + 1] = sig
  if #ring > RING_MAX then
    table.remove(ring, 1)
  end
  return n
end

-- Characters inserted by the edit (what the user typed).
local function typed_chars(shape)
  local n = 0
  for _, it in ipairs(shape.items or {}) do
    n = n + vim.fn.strchars(it.new)
  end
  return n
end

local function analyze(buf, before, after, first_row, cursor, since, kd)
  local shape = diff.classify(before, after)
  if shape.kind == "none" then
    return
  end
  local span = {
    buf = buf,
    ft = vim.bo[buf].filetype,
    before = before,
    after = after,
    first_row = first_row,
    cursor_before = cursor,
    keys = kd,
    measured = kd ~= nil,
    since = since,
  }
  local repeats = ring_push(diff.signature(shape))
  local cands = candidates.generate(span, shape)
  if #cands == 0 then
    return
  end
  local ok = verify.texts(span, cands)
  local best
  local seen, alts, labels = {}, {}, {}
  for i, c in ipairs(cands) do
    if ok[i] then
      if not best then
        best = c
        seen[c.idiom] = true
      elseif not seen[c.idiom] then
        seen[c.idiom] = true
        alts[#alts + 1] = c.idiom
        labels[c.idiom] = c.label
      end
    end
  end
  if not best then
    return
  end

  local idiom, label, ideal = best.idiom, best.label, best.cost
  -- The same shape again and again: a plain `.` repeats the change.
  local is_dot = repeats >= cost.repeat_min and best.keys ~= nil
  if is_dot then
    alts[#alts + 1] = idiom
    labels[idiom] = label
    idiom, label, ideal = "dot-repeat", ".", 1
  end

  local modeled = candidates.model_naive(shape)
  if is_dot then
    -- `.` does not retype the text, so the typed text and <Esc> count for naive.
    modeled = modeled + typed_chars(shape) + 1
  end
  local naive, measured = modeled, false
  if kd then
    local m = kd.total
    if not is_dot then
      m = m - kd.printable - kd.esc
    end
    if m >= 1 and m <= 10 * modeled + 30 then
      naive, measured = m, true
    end
  end
  if naive - ideal < 1 then
    return
  end

  local alt_list, alt_labels = {}, {}
  for _, a in ipairs(alts) do
    if a ~= idiom then
      alt_list[#alt_list + 1] = a
      alt_labels[#alt_labels + 1] = labels[a]
    end
  end
  require("vim_coach.sink").report({
    event = {
      idiom = idiom,
      alts = alt_list,
      ft = span.ft,
      scale = shape.scale,
      naive = naive,
      ideal = ideal,
      src = "edit",
      measured = measured,
    },
    label = label,
    alt_labels = alt_labels,
    was = describe(shape, kd),
    example = { before = before, after = after },
    since = since,
  })
end

local function changenr(buf)
  if api.nvim_get_current_buf() == buf then
    return vim.fn.changenr()
  end
  return api.nvim_buf_call(buf, vim.fn.changenr)
end

local function finalize(buf, from_timer)
  local st = S[buf]
  if not st or not st.active then
    return
  end
  -- A normal-mode span that entered insert mode (ci") stays open until InsertLeave.
  if from_timer and in_insert and api.nvim_get_current_buf() == buf then
    return
  end
  if timer_buf == buf then
    stop_timer()
  end
  local lo, hi, delta = st.lo, st.hi, st.delta
  local since, cursor, tainted = st.since, st.cursor, st.tainted
  local kc, kt = st.kcounters, st.ktotal
  st.active, st.lo, st.hi, st.delta, st.tainted = false, nil, nil, 0, false
  if active_buf == buf then
    active_buf = nil
  end
  if not api.nvim_buf_is_valid(buf) then
    S[buf] = nil
    return
  end

  local nlines = api.nvim_buf_line_count(buf)
  if not st.shadow or #st.shadow + delta ~= nlines then
    take_shadow(st, buf)
    return
  end
  if nlines > cost.max_lines or config.excluded(buf) then
    st.off = true
    return
  end

  hi = math.min(hi, nlines - 1)
  lo = math.min(lo, hi)
  local ctx = cost.diff_context
  local clo = math.max(0, lo - ctx)
  local chi = math.min(nlines - 1, hi + ctx)
  local bhi = chi - delta
  if bhi < clo - 1 or bhi >= #st.shadow then
    take_shadow(st, buf)
    return
  end
  local after = api.nvim_buf_get_lines(buf, clo, chi + 1, false)
  local before = {}
  for i = clo + 1, bhi + 1 do
    before[#before + 1] = st.shadow[i]
  end
  splice(st.shadow, clo + 1, bhi + 1, after)

  -- New edits raise the undo sequence past anything seen; undo and redo do not.
  local seq = changenr(buf)
  local fresh = seq > st.seq
  if fresh then
    st.seq = seq
  end

  local counters = keys_mod and keys_mod.counters() or nil
  refresh_snap()

  if tainted or not fresh or (hi - lo + 1) > cost.max_span_lines then
    return
  end
  if vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= "" then
    return
  end
  local kd = nil
  if counters and kc and (counters.total - (kt or 0)) > 0 then
    kd = kdelta(counters, kc)
  end
  analyze(buf, before, after, clo + 1, cursor, since, kd)
end

local function schedule_finalize(buf)
  local st = S[buf]
  if not st or st.pending then
    return
  end
  st.pending = true
  vim.schedule(function()
    st.pending = false
    finalize(buf, false)
  end)
end

local function arm_timer(buf)
  if not timer then
    timer = uv.new_timer()
  end
  timer_buf = buf
  timer:start(cost.edit_debounce_ms, 0, function()
    local b = timer_buf
    if not b then
      return
    end
    vim.schedule(function()
      finalize(b, true)
    end)
  end)
end

-- on_bytes -------------------------------------------------------------------

local function start_span(buf, st)
  if active_buf and active_buf ~= buf then
    schedule_finalize(active_buf)
  end
  active_buf = buf
  st.active = true
  st.since = uv.now()
  st.tainted = vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= ""
  if snap.buf == buf and snap.cursor then
    st.cursor = snap.cursor
  elseif api.nvim_get_current_buf() == buf then
    st.cursor = api.nvim_win_get_cursor(0)
  else
    st.cursor = { 1, 0 }
  end
  st.ktotal = snap.total
  st.kcounters = snap.counters
end

local function make_on_bytes(buf, st, my_gen)
  return function(_, _, _, srow, _, _, orow, _, _, nrow)
    if stopped or gen ~= my_gen or st.off then
      return true
    end
    if verify.busy then
      return
    end
    local d = nrow - orow
    if not st.active then
      start_span(buf, st)
      st.lo, st.hi, st.delta = srow, srow + nrow, d
    else
      local e_old = srow + orow
      local lo, hi = st.lo, st.hi
      if lo > e_old then
        lo = lo + d
      end
      if hi > e_old then
        hi = hi + d
      else
        hi = srow + nrow
      end
      if srow < lo then
        lo = srow
      end
      if srow + nrow > hi then
        hi = srow + nrow
      end
      st.lo, st.hi, st.delta = lo, hi, st.delta + d
    end
    if not in_insert then
      arm_timer(buf)
    end
  end
end

--- Attach to a buffer (idempotent). Skips excluded and oversized buffers.
---@param buf integer?
---@return boolean attached
function M.attach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if stopped then
    return false
  end
  if S[buf] then
    return true
  end
  if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
    return false
  end
  if config.excluded(buf) or api.nvim_buf_line_count(buf) > cost.max_lines then
    return false
  end
  local st = { active = false, delta = 0, tainted = false, off = false, pending = false }
  take_shadow(st, buf)
  st.seq = api.nvim_buf_call(buf, function()
    return vim.fn.undotree().seq_last
  end)
  S[buf] = st
  local ok = api.nvim_buf_attach(buf, false, {
    on_bytes = make_on_bytes(buf, st, gen),
    on_reload = function()
      if S[buf] == st then
        st.active = false
        vim.schedule(function()
          if S[buf] == st and api.nvim_buf_is_valid(buf) then
            take_shadow(st, buf)
            -- The undo history was reset by the reload.
            st.seq = api.nvim_buf_call(buf, function()
              return vim.fn.undotree().seq_last
            end)
          end
        end)
      end
    end,
    on_detach = function()
      if S[buf] == st then
        S[buf] = nil
      end
      if active_buf == buf then
        active_buf = nil
      end
    end,
  })
  if not ok then
    S[buf] = nil
    return false
  end
  if api.nvim_get_current_buf() == buf and not snap.buf then
    refresh_snap()
  end
  return true
end

--- Finish the open span of a buffer now (what InsertLeave or the debounce timer do).
---@param buf integer?
function M.flush(buf)
  finalize((buf == nil or buf == 0) and api.nvim_get_current_buf() or buf, false)
end

--- Shadow copy of a buffer (for tests).
---@param buf integer
---@return string[]?
function M._shadow(buf)
  return S[buf] and S[buf].shadow or nil
end

function M.stop()
  stopped = true
  in_insert = false
  active_buf = nil
  if augroup then
    pcall(api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
  timer_buf = nil
  S = {}
  ring = {}
  snap = { buf = nil, cursor = nil, total = 0, counters = nil }
  keys_mod = nil
end

function M.setup()
  M.stop()
  stopped = false
  gen = gen + 1
  if (config.options.detectors or {}).keys ~= false then
    local ok, k = pcall(require, "vim_coach.keys")
    if ok and type(k) == "table" and k.counters and k.total then
      keys_mod = k
    end
  end
  augroup = api.nvim_create_augroup("vim_coach_edits", { clear = true })
  local function au(events, cb)
    api.nvim_create_autocmd(events, { group = augroup, callback = cb })
  end
  au({ "BufReadPost", "BufNewFile", "BufEnter" }, function(a)
    local b = a.buf
    vim.schedule(function()
      M.attach(b)
    end)
  end)
  au("FileType", function(a)
    local st = S[a.buf]
    if st and config.excluded(a.buf) then
      st.off = true
    elseif not st then
      M.attach(a.buf)
    end
  end)
  au("InsertEnter", function()
    in_insert = true
    stop_timer()
  end)
  au("InsertLeave", function(a)
    in_insert = false
    schedule_finalize(a.buf)
  end)
  au("CursorMoved", function()
    if active_buf or in_insert then
      return
    end
    local b = api.nvim_get_current_buf()
    if S[b] and api.nvim_get_mode().mode == "n" then
      refresh_snap()
    end
  end)
  M.attach(api.nvim_get_current_buf())
  refresh_snap()
end

return M
