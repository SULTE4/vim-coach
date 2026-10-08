-- Key-pattern detector. The on_key hook is O(1): it bumps integer counters, feeds a
-- tiny tokenizer and writes finished normal-mode commands into a preallocated ring.
-- All analysis (verify, adoption matching, sink calls) runs deferred.
--
-- Privacy: insert, replace and cmdline keys only touch counters. They are never
-- stored. Normal-mode command tokens live in memory only.
local catalog = require("vim_coach.catalog")
local config = require("vim_coach.config")
local cost = require("vim_coach.cost")
local motions = require("vim_coach.motions")
local verify = require("vim_coach.verify")

local uv = vim.uv or vim.loop
local api = vim.api
local byte = string.byte
local hrtime = uv.hrtime

local M = {}

-- Counters (see VimCoach.KeyCounters) ----------------------------------------
local c_total, c_printable, c_bs, c_cw, c_cu, c_x, c_dd, c_arrows, c_esc = 0, 0, 0, 0, 0, 0, 0, 0, 0

-- Static tables ----------------------------------------------------------------
local ARROW_KEYS = {
  ["\128ku"] = "<Up>", ["\128kd"] = "<Down>", ["\128kl"] = "<Left>", ["\128kr"] = "<Right>",
}
local BS_KEY = "\128kb"

-- Byte classes for the normal-mode tokenizer.
local OP, ARG, PREFIX, REG, RCHAR = 1, 2, 3, 4, 5
local CLS = {}
for ch in ("dcy<>=!"):gmatch(".") do
  CLS[byte(ch)] = OP
end
for ch in ("fFtT'`m@q"):gmatch(".") do
  CLS[byte(ch)] = ARG
end
for ch in ("gz[]Z"):gmatch(".") do
  CLS[byte(ch)] = PREFIX
end
CLS[23] = PREFIX -- <C-w>
CLS[byte('"')] = REG
CLS[byte("r")] = RCHAR
-- Second keys after g that make an operator (gu gU g~ gq gw g? gc g@).
local GOP = {}
for ch in ("uU~qw?c@"):gmatch(".") do
  GOP[byte(ch)] = true
end

-- Movement bursts: token -> axis (1 vertical, 2 horizontal), direction and count slot.
local AXIS = { j = 1, k = 1, ["<Up>"] = 1, ["<Down>"] = 1, h = 2, l = 2, ["<Left>"] = 2, ["<Right>"] = 2 }
local DIR = { j = 1, ["<Down>"] = 1, k = -1, ["<Up>"] = -1, l = 1, ["<Right>"] = 1, h = -1, ["<Left>"] = -1 }
local SLOT = { j = 1, ["<Down>"] = 1, k = 2, ["<Up>"] = 2, l = 3, ["<Right>"] = 3, h = 4, ["<Left>"] = 4 }
local PLAIN = { "j", "k", "l", "h" }
local ARROWN = { "<Down>", "<Up>", "<Right>", "<Left>" }

-- Tokenizer states.
local S_START, S_OP, S_ARG, S_PREFIX, S_REG = 0, 1, 2, 3, 4

-- Strict sequence substitutions: token -> { [prev token or true] = def }.
local SEQ_DEFS = {
  ["a"] = { ["$"] = { "append-eol", "A", "$ a" } },
  ["i"] = {
    ["^"] = { "insert-bol", "I", "^ i" },
    ["x"] = { "substitute-char", "s", "x i" },
  },
  ["d$"] = { [true] = { "delete-eol", "D", "d$" } },
  ["c$"] = { [true] = { "change-eol", "C", "c$" } },
  ["y$"] = { [true] = { "yank-eol", "Y", "y$" } },
}

-- State ------------------------------------------------------------------------
local active = false
local ns = api.nvim_create_namespace("vim_coach_keys")
local group = nil
local timer = nil
local timer_active = false

local mode = "n" -- first char of the cached mode; "no" counts as "n"
local recording = false

local ring, rsize = {}, cost.ring_size
local rhalf = math.floor(cost.ring_size / 2)
local head, proc = 0, 0 -- tokens written / tokens already matched for adoption
local prev = nil -- previous completed token

-- Tokenizer
local st, buf, hascnt, opkey, pfx, redact = S_START, "", false, nil, nil, false

-- Run
local run_tok, run_n, run_min, last_t = nil, 0, 0, 0
local run_win, run_buf, run_view, run_tick, run_since

-- Burst: consecutive count-less moves on one axis (integers only on the hot path)
local burst_ax, burst_n, burst_rev, burst_dir, burst_min, burst_arrow = nil, 0, 0, 0, 0, false
local bcount = { 0, 0, 0, 0 }

local NAMES = {} -- raw special key -> keytrans name (filled lazily, rare keys only)
local adopt_list = nil -- { {id, {patterns}} }
local adopt_cache = {}
local adopt_cache_n = 0

local function name_of(key)
  local n = NAMES[key]
  if not n then
    n = vim.fn.keytrans(key)
    NAMES[key] = n
  end
  return n
end

-- Deferred analysis --------------------------------------------------------------

local function sink()
  return require("vim_coach.sink")
end

local function ok_buffer(buf_)
  return api.nvim_buf_is_valid(buf_) and not config.excluded(buf_)
end

-- Candidates that need no replay (used when an edit already followed the run).
local PURE_IDIOMS = { ["find-char"] = true, ["word-motion"] = true, ["line-ends"] = true }
local function pure_candidates(job, base, vert, from, to, cn)
  local good = {}
  if vert then
    local rows = to[1] - from[1]
    if math.abs(rows) ~= cn or (rows > 0) ~= (base == "j") then
      return good
    end
    local win = job.win
    local folded = false
    pcall(api.nvim_win_call, win, function()
      for r = math.min(from[1], to[1]), math.max(from[1], to[1]) do
        if vim.fn.foldclosed(r) ~= -1 then
          folded = true
          return
        end
      end
    end)
    if not folded then
      good[1] = motions.candidates(base, cn, from, to, {})[1]
    end
    return good
  end
  local line = job.line
  job.line = nil
  if not line or from[1] ~= to[1] then
    return good
  end
  for _, c in ipairs(motions.candidates(base, cn, from, to, { line = line })) do
    if PURE_IDIOMS[c.idiom] then
      local ok = true
      if c.idiom == "word-motion" and motions.RUN[base] == 3 then
        -- {N}w for a w/b/e run: confirm by simulation
        ok = motions.word_count(line, from[2], to[2], base, job.n) == job.n
      end
      if ok then
        good[#good + 1] = c
      end
    end
  end
  return good
end

--- Verify and report one finished run. Runs deferred, never from on_key.
local function analyze(job)
  if vim.fn.reg_executing() ~= "" then
    return
  end
  local win, bufnr = job.win, job.buf
  if job.endwin ~= win or job.endbuf ~= bufnr or not api.nvim_win_is_valid(win) then
    return
  end
  if not ok_buffer(bufnr) or job.tick ~= job.endtick or api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  local from = { job.view.lnum, job.view.col }
  local to = job.to
  local base, cn, was = nil, job.n, nil
  if job.burst then
    local vertical = job.ax == 1
    local net = vertical and math.abs(to[1] - from[1]) or math.abs(to[2] - from[2])
    if job.n >= cost.fidget_min_keys and job.rev >= cost.fidget_min_reversals and net <= cost.fidget_max_net then
      job.line = nil
      sink().report({
        event = {
          idiom = "fidget", alts = {}, ft = vim.bo[bufnr].filetype, scale = job.n, naive = job.n,
          ideal = 0, src = "keys", measured = true,
        },
        label = vertical and "jk" or "hl",
        was = ("%s x%d, net %d"):format(vertical and "j/k" or "h/l", job.n, net),
        since = job.since,
      })
      return
    end
    if net == 0 or job.n < job.min then
      return
    end
    if vertical then
      base, cn = to[1] > from[1] and "j" or "k", net
    else
      base = to[2] > from[2] and "l" or "h"
    end
    local names = job.arrow and ARROWN or PLAIN
    local parts = {}
    for i = 1, 4 do
      if job.c[i] > 0 then
        parts[#parts + 1] = names[i] .. " x" .. job.c[i]
      end
    end
    was = table.concat(parts, ", ")
  else
    if from[1] == to[1] and from[2] == to[2] then
      return
    end
    base = motions.base(job.tok)
    was = job.tok .. " x" .. job.n
  end
  if from[1] == to[1] and from[2] == to[2] then
    return
  end
  job.was = was
  local vert = base == "j" or base == "k"
  local good = {}
  if api.nvim_buf_get_changedtick(bufnr) == job.endtick then
    -- Text unchanged since the run ended: replay candidates in the real window.
    job.line = nil
    local ctx = {
      line = api.nvim_buf_get_lines(bufnr, to[1] - 1, to[1], false)[1],
      nlines = api.nvim_buf_line_count(bufnr),
    }
    local cands = motions.candidates(base, cn, from, to, ctx)
    local within = verify.budget()
    for i = 1, math.min(#cands, cost.max_candidates) do
      if not within() then
        break
      end
      if verify.cursor(win, job.view, cands[i], to) then
        good[#good + 1] = cands[i]
      end
    end
  else
    -- An edit followed the run, so replay is unsafe. Accept only candidates that are
    -- computable from data captured at run end.
    good = pure_candidates(job, base, vert, from, to, cn)
  end
  if #good == 0 then
    return
  end
  local best = good[1]
  for i = 2, #good do
    if good[i].cost < best.cost then
      best = good[i]
    end
  end
  local alts, alt_labels, seen = {}, {}, { [best.idiom] = true }
  for _, c in ipairs(good) do
    if not seen[c.idiom] then
      seen[c.idiom] = true
      alts[#alts + 1] = c.idiom
      alt_labels[#alt_labels + 1] = c.label
    end
  end
  sink().report({
    event = {
      idiom = best.idiom,
      alts = alts,
      ft = vim.bo[bufnr].filetype,
      scale = job.n,
      naive = job.n,
      ideal = best.cost,
      src = "keys",
      measured = true,
    },
    label = best.label,
    alt_labels = alt_labels,
    was = was,
    since = job.since,
  })
end

local function report_strict(def)
  vim.schedule(function()
    if not active or vim.fn.reg_executing() ~= "" then
      return
    end
    local b = api.nvim_get_current_buf()
    if not ok_buffer(b) then
      return
    end
    sink().report({
      event = {
        idiom = def[1],
        alts = {},
        ft = vim.bo[b].filetype,
        scale = 1,
        naive = 2,
        ideal = 1,
        src = "keys",
        measured = true,
      },
      label = def[2],
      was = def[3],
      since = uv.now(),
    })
  end)
end

local function build_adopt()
  adopt_list = {}
  adopt_cache, adopt_cache_n = {}, 0
  for id, entry in pairs(catalog) do
    if entry.adopt and not entry.concept then
      adopt_list[#adopt_list + 1] = { id, entry.adopt }
    end
  end
end

local function adopt_ids(tok)
  local ids = adopt_cache[tok]
  if ids then
    return ids
  end
  ids = {}
  for _, e in ipairs(adopt_list) do
    for _, pat in ipairs(e[2]) do
      if tok:find(pat) then
        ids[#ids + 1] = e[1]
        break
      end
    end
  end
  if adopt_cache_n > 512 then
    adopt_cache, adopt_cache_n = {}, 0
  end
  adopt_cache[tok] = ids
  adopt_cache_n = adopt_cache_n + 1
  return ids
end

--- Match tokens written since the last flush against catalog adopt patterns.
local function flush_adopt()
  if head - proc > rsize then
    proc = head - rsize
  end
  local s
  while proc ~= head do
    local tok = ring[proc % rsize + 1]
    proc = proc + 1
    if tok then
      for _, id in ipairs(adopt_ids(tok)) do
        s = s or sink()
        s.used(id)
      end
    end
  end
end

-- Hot path -------------------------------------------------------------------------

-- Snapshot the end of the current run and hand it to a deferred analysis.
local function end_run()
  if run_n >= run_min then
    local job = {
      tok = run_tok, n = run_n, win = run_win, buf = run_buf, view = run_view,
      tick = run_tick, since = run_since,
      to = api.nvim_win_get_cursor(0),
      endwin = api.nvim_get_current_win(),
      endbuf = api.nvim_get_current_buf(),
      endtick = api.nvim_buf_get_changedtick(0),
    }
    local b = motions.base(run_tok)
    if b ~= "j" and b ~= "k" then
      job.line = api.nvim_buf_get_lines(0, job.to[1] - 1, job.to[1], false)[1]
    end
    vim.schedule(function()
      if active then
        analyze(job)
      end
    end)
  end
  run_tok = nil
  run_view = nil
end

-- Snapshot the end of the current movement burst; nothing is queued for short ones.
local function end_burst()
  if burst_n >= burst_min or (burst_n >= cost.fidget_min_keys and burst_rev >= cost.fidget_min_reversals) then
    local job = {
      burst = true, ax = burst_ax, n = burst_n, rev = burst_rev, min = burst_min, arrow = burst_arrow,
      c = { bcount[1], bcount[2], bcount[3], bcount[4] },
      win = run_win, buf = run_buf, view = run_view, tick = run_tick, since = run_since,
      to = api.nvim_win_get_cursor(0),
      endwin = api.nvim_get_current_win(),
      endbuf = api.nvim_get_current_buf(),
      endtick = api.nvim_buf_get_changedtick(0),
    }
    if burst_ax == 2 then
      job.line = api.nvim_buf_get_lines(0, job.to[1] - 1, job.to[1], false)[1]
    end
    vim.schedule(function()
      if active then
        analyze(job)
      end
    end)
  end
  burst_ax = nil
  run_view = nil
end

local function on_timer()
  vim.schedule(M._on_idle)
end

local function arm(ms)
  timer_active = true
  timer:start(ms, 0, on_timer)
end

function M._on_idle()
  timer_active = false
  if not active then
    return
  end
  local idle_ms = cost.run_idle_ms
  local left = idle_ms
  if run_tok or burst_ax then
    local idle = (hrtime() - last_t) / 1e6
    if idle >= idle_ms then
      if burst_ax then
        end_burst()
      else
        end_run()
      end
    else
      left = idle_ms - idle
    end
  end
  flush_adopt()
  if run_tok or burst_ax then
    arm(math.max(1, math.ceil(left)))
  end
end

local function on_token(tok)
  if tok == "x" then
    c_x = c_x + 1
  elseif tok == "dd" then
    c_dd = c_dd + 1
  end
  if recording then
    return
  end
  ring[head % rsize + 1] = tok
  head = head + 1

  local seq = SEQ_DEFS[tok]
  if seq then
    local def = seq[prev or false] or seq[true]
    if def then
      report_strict(def)
    end
  end
  prev = tok

  local ax = AXIS[tok]
  if ax then
    if burst_ax == ax then
      burst_n = burst_n + 1
      local d = DIR[tok]
      if d ~= burst_dir then
        burst_rev = burst_rev + 1
        burst_dir = d
      end
      local sl = SLOT[tok]
      bcount[sl] = bcount[sl] + 1
      last_t = hrtime()
    else
      if burst_ax then
        end_burst()
      end
      if run_tok then
        end_run()
      end
      local arrow = ax and motions.RUN[tok] == 4
      burst_ax, burst_n, burst_rev, burst_dir, burst_arrow = ax, 1, 0, DIR[tok], arrow
      burst_min = cost.min_run[arrow and "arrows" or (ax == 1 and "vertical" or "horizontal")]
      bcount[1], bcount[2], bcount[3], bcount[4] = 0, 0, 0, 0
      bcount[SLOT[tok]] = 1
      last_t = hrtime()
      run_win = api.nvim_get_current_win()
      run_buf = api.nvim_get_current_buf()
      run_view = vim.fn.winsaveview()
      run_tick = api.nvim_buf_get_changedtick(0)
      run_since = uv.now()
    end
  else
    if burst_ax then
      end_burst()
    end
    if tok == run_tok then
      run_n = run_n + 1
      last_t = hrtime()
    else
      if run_tok then
        end_run()
      end
      local kind = motions.RUN[tok]
      if kind then
        run_tok, run_n, run_min, last_t = tok, 1, cost.min_run[motions.KINDS[kind]], hrtime()
        run_win = api.nvim_get_current_win()
        run_buf = api.nvim_get_current_buf()
        run_view = vim.fn.winsaveview()
        run_tick = api.nvim_buf_get_changedtick(0)
        run_since = uv.now()
      end
    end
  end
  if not timer_active then
    arm(cost.run_idle_ms)
  end
  if head - proc >= rhalf then
    vim.schedule(flush_adopt)
  end
end

local function finish(b, key)
  local name = key
  if b < 32 or b == 127 or b == 128 then
    name = name_of(key)
  end
  if redact then
    name = "_"
  end
  local tok = buf == "" and name or (buf .. name)
  st, buf, hascnt, opkey, redact = S_START, "", false, nil, false
  on_token(tok)
end

local function tokenize(key, b)
  if b == 27 or b == 3 then -- <Esc> / <C-c> cancel a pending command
    st, buf, hascnt, opkey, redact = S_START, "", false, nil, false
    return
  end
  local s = st
  if s == S_ARG then
    return finish(b, key)
  elseif s == S_REG then
    buf = buf .. key
    st = S_START
    return
  elseif s == S_PREFIX then
    if pfx == 103 and GOP[b] then -- g + operator letter
      buf, st, opkey = buf .. key, S_OP, key
      return
    end
    return finish(b, key)
  end
  -- S_START or S_OP: counts first
  if (b >= 49 and b <= 57) or (b == 48 and hascnt) then
    buf, hascnt = buf .. key, true
    return
  end
  local c = CLS[b]
  if s == S_OP then
    if key == opkey then
      return finish(b, key)
    elseif b == 105 or b == 97 then -- i / a text object
      buf, st = buf .. key, S_ARG
      return
    elseif c == ARG or c == PREFIX then
      buf, st = buf .. key, S_ARG
      return
    end
    return finish(b, key)
  end
  -- S_START
  if not c then
    return finish(b, key)
  elseif c == OP then
    buf, st, opkey = buf .. key, S_OP, key
  elseif c == ARG then
    if b == 113 and recording then -- q stops a recording
      return finish(b, key)
    end
    buf, st = buf .. key, S_ARG
  elseif c == PREFIX then
    buf, st, pfx = buf .. key, S_PREFIX, b
  elseif c == REG then
    buf, st = buf .. key, S_REG
  else -- RCHAR: the replacement character is not kept
    buf, st, redact = buf .. key, S_ARG, true
  end
end

-- Classify one typed key: counters first, then the tokenizer (normal mode only).
local function handle(key, b)
  c_total = c_total + 1
  if b == 128 then
    if ARROW_KEYS[key] then
      c_arrows = c_arrows + 1
    end
  elseif b == 27 then
    c_esc = c_esc + 1
  end
  local m = mode
  if m == "n" then
    if b == 128 then
      local a = ARROW_KEYS[key]
      if a then
        return tokenize(a, 129) -- the name is already a token; 129 marks it as non-special
      end
    end
    return tokenize(key, b)
  elseif m == "i" or m == "R" then
    if b == 128 then
      if key == BS_KEY then
        c_bs = c_bs + 1
      end
    elseif b == 8 or b == 127 then
      c_bs = c_bs + 1
    elseif b == 23 then
      c_cw = c_cw + 1
    elseif b == 21 then
      c_cu = c_cu + 1
    elseif b >= 32 then
      c_printable = c_printable + 1
    end
  end
end

-- A mapping fired: `typed` holds the keys the user really pressed (e.g. "gcc" or the
-- <C-w> behind nvim's default insert mapping), `key` is only the first mapped result.
local function handle_typed(typed)
  local i, n = 1, #typed
  while i <= n do
    local b = byte(typed, i)
    local len = 1
    if b == 128 then
      len = 3
    elseif b >= 240 then
      len = 4
    elseif b >= 224 then
      len = 3
    elseif b >= 194 then
      len = 2
    end
    handle(typed:sub(i, i + len - 1), b)
    i = i + len
  end
end

--- vim.on_key callback. Exposed for the perf spec.
---@param key string
---@param typed string
function M._on_key(key, typed)
  if typed == "" or verify.busy then
    return
  end
  if typed ~= key then
    return handle_typed(typed)
  end
  return handle(key, byte(key, 1))
end

local function reset_tokenizer()
  st, buf, hascnt, opkey, redact = S_START, "", false, nil, false
end

-- Public API -------------------------------------------------------------------------

function M.setup()
  if active then
    return
  end
  active = true
  rsize = cost.ring_size
  rhalf = math.floor(rsize / 2)
  for i = 1, rsize do
    ring[i] = false
  end
  head, proc, prev, run_tok, burst_ax = 0, 0, nil, nil, nil
  reset_tokenizer()
  build_adopt()
  mode = api.nvim_get_mode().mode:sub(1, 1)
  recording = vim.fn.reg_recording() ~= ""
  timer = uv.new_timer()
  timer_active = false
  group = api.nvim_create_augroup("vim_coach_keys", { clear = true })
  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      local new = vim.v.event.new_mode:sub(1, 1)
      if new ~= mode then
        mode = new
        reset_tokenizer()
      end
    end,
  })
  api.nvim_create_autocmd("RecordingEnter", {
    group = group,
    callback = function()
      recording = true
      reset_tokenizer()
    end,
  })
  api.nvim_create_autocmd("RecordingLeave", {
    group = group,
    callback = function()
      recording = false
      reset_tokenizer()
      prev = nil
    end,
  })
  vim.on_key(M._on_key, ns)
end

function M.stop()
  if not active then
    return
  end
  active = false
  vim.on_key(nil, ns)
  if group then
    pcall(api.nvim_del_augroup_by_id, group)
    group = nil
  end
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
  timer_active = false
  run_tok, run_view, burst_ax = nil, nil, nil
  reset_tokenizer()
end

--- Copy of the cumulative typed-key counters.
---@return VimCoach.KeyCounters
function M.counters()
  return {
    total = c_total, printable = c_printable, bs = c_bs, cw = c_cw, cu = c_cu,
    x = c_x, dd = c_dd, arrows = c_arrows, esc = c_esc,
  }
end

---@return integer
function M.total()
  return c_total
end

-- Test helpers ------------------------------------------------------------------------

--- Command tokens currently held in the ring, oldest first.
function M._ring()
  local out = {}
  local first = math.max(0, head - rsize)
  for i = first, head - 1 do
    out[#out + 1] = ring[i % rsize + 1]
  end
  return out
end

function M._reset()
  c_total, c_printable, c_bs, c_cw, c_cu, c_x, c_dd, c_arrows, c_esc = 0, 0, 0, 0, 0, 0, 0, 0, 0
  for i = 1, rsize do
    ring[i] = false
  end
  head, proc, prev, run_tok, burst_ax = 0, 0, nil, nil, nil
  reset_tokenizer()
end

---@param m string  cached mode char
function M._set_mode(m)
  mode = m
end

return M
