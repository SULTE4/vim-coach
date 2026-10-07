-- Replays candidate idioms and checks that they reproduce what the user did.
--
-- Text candidates run in a child `nvim --embed` process, so replaying `dd` or `ci"`
-- never touches the user's registers, `.` repeat, undo tree or search history.
-- All candidates for one span go in a single RPC request.
--
-- Motion candidates run in the real window (screen-relative motions like H, M, L and
-- <C-d> need it). Motions do not change text, and the view, jumplist and last f/t
-- search are restored afterwards.
local cost = require("vim_coach.cost")

local uv = vim.uv or vim.loop

local M = {}

M.busy = false

local chan = nil
local failed = false

-- Defined once in the child. Replays every candidate on `before` and reports which
-- ones produce exactly `after`. Stops when the time budget runs out.
local CHILD_CODE = [[
_G._vc_replay = function(opts, before, after, cands, cursor, budget_ns)
  local api = vim.api
  local deadline = vim.uv.hrtime() + budget_ns
  for k, v in pairs(opts) do
    pcall(function() vim.bo[k] = v end)
  end
  local results = {}
  for i, c in ipairs(cands) do
    if vim.uv.hrtime() > deadline then
      break
    end
    api.nvim_buf_set_lines(0, 0, -1, false, before)
    local cur = c.cursor or cursor
    local row = math.max(1, math.min(cur[1], #before))
    local len = #(before[row] or "")
    local col = math.max(0, math.min(cur[2], math.max(len - 1, 0)))
    api.nvim_win_set_cursor(0, { row, col })
    local ok = pcall(function()
      if c.keys then
        vim.cmd.normal({ c.keys, bang = true })
      else
        vim.cmd("silent " .. c.ex)
      end
    end)
    local same = false
    if ok then
      local now = api.nvim_buf_get_lines(0, 0, -1, false)
      if #now == #after then
        same = true
        for j = 1, #after do
          if now[j] ~= after[j] then
            same = false
            break
          end
        end
      end
    end
    results[i] = same
  end
  return results
end
vim.o.undolevels = -1
vim.o.swapfile = false
vim.o.shada = ""
vim.o.more = false
]]

-- Buffer options copied from the user's buffer so indent and word rules match.
local COPY_OPTS = {
  "shiftwidth", "tabstop", "softtabstop", "expandtab", "autoindent", "smartindent",
  "commentstring", "iskeyword", "matchpairs", "textwidth",
}

local function ensure_child()
  if chan or failed then
    return chan
  end
  local ok, id = pcall(vim.fn.jobstart, { vim.v.progpath, "--embed", "--headless", "--clean", "-n" }, {
    rpc = true,
    on_exit = function()
      chan = nil
    end,
  })
  if not ok or not id or id <= 0 then
    failed = true
    return nil
  end
  local ok2 = pcall(vim.rpcrequest, id, "nvim_exec_lua", CHILD_CODE, {})
  if not ok2 then
    pcall(vim.fn.jobstop, id)
    failed = true
    return nil
  end
  chan = id
  return chan
end

--- Start the child process ahead of time so the first verify does not pay startup.
function M.warm()
  ensure_child()
end

function M.stop()
  if chan then
    pcall(vim.fn.jobstop, chan)
    chan = nil
  end
end

--- Returns a function that is true while time is left.
---@param ms number?
---@return fun():boolean
function M.budget(ms)
  local deadline = uv.hrtime() + (ms or cost.verify_budget_ms) * 1e6
  return function()
    return uv.hrtime() < deadline
  end
end

local function span_cursor(span)
  local row = span.cursor_before[1] - span.first_row + 1
  return { row, span.cursor_before[2] }
end

--- Replay several candidates on span.before and compare with span.after.
--- One RPC call. Candidates past the time budget or cost.max_candidates are false.
---@param span VimCoach.Span
---@param cands VimCoach.Candidate[]
---@param budget_ms number?
---@return boolean[]
function M.texts(span, cands, budget_ms)
  local out = {}
  for i = 1, #cands do
    out[i] = false
  end
  if #cands == 0 then
    return out
  end
  local id = ensure_child()
  if not id then
    return out
  end
  local opts = {}
  if span.buf and vim.api.nvim_buf_is_valid(span.buf) then
    for _, name in ipairs(COPY_OPTS) do
      opts[name] = vim.bo[span.buf][name]
    end
  end
  opts.textwidth = 0
  local send = {}
  for i = 1, math.min(#cands, cost.max_candidates) do
    local c = cands[i]
    send[i] = { keys = c.keys, ex = c.ex, cursor = c.cursor }
  end
  local budget_ns = (budget_ms or cost.verify_budget_ms) * 1e6
  local ok, res = pcall(vim.rpcrequest, id, "nvim_exec_lua",
    "return _vc_replay(...)", { opts, span.before, span.after, send, span_cursor(span), budget_ns })
  if ok and type(res) == "table" then
    for i, v in pairs(res) do
      out[i] = v == true
    end
  end
  return out
end

--- Single-candidate convenience wrapper around M.texts.
---@param span VimCoach.Span
---@param cand VimCoach.Candidate
---@return boolean
function M.text(span, cand)
  return M.texts(span, { cand })[1]
end

--- Replay a motion in the real window and check that it lands on `to`.
--- The buffer must not have changed between `from` and `to` (caller checks changedtick).
---@param win integer
---@param from table  winsaveview() dict captured at run start (lnum, col, curswant, topline...)
---@param cand VimCoach.Candidate  must have `keys`
---@param to {[1]:integer,[2]:integer}  (1-based row, 0-based col)
---@return boolean
function M.cursor(win, from, cand, to)
  if not cand.keys or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local result = false
  M.busy = true
  local ei = vim.o.eventignore
  vim.o.eventignore = "all"
  pcall(vim.api.nvim_win_call, win, function()
    local view = vim.fn.winsaveview()
    local cs = vim.fn.getcharsearch()
    vim.fn.winrestview(from)
    local ok = pcall(vim.cmd, "keepjumps normal! " .. cand.keys)
    if ok then
      local pos = vim.api.nvim_win_get_cursor(0)
      result = pos[1] == to[1] and pos[2] == to[2]
    end
    vim.fn.winrestview(view)
    vim.fn.setcharsearch(cs)
  end)
  vim.o.eventignore = ei
  M.busy = false
  return result
end

return M
