-- In-memory session state. Nothing here is persisted, so it may hold example text.
local cost = require("vim_coach.cost")

local uv = vim.uv or vim.loop

local M = {}

local log = {} -- recent findings, newest last
local seen = {} -- idiom -> findings this session
local examples = {} -- idiom -> {before, after} of the latest finding
local claims = {} -- idiom -> vim.uv.now() of the latest key-detector claim

---@param finding VimCoach.Finding
function M.push(finding)
  local id = finding.event.idiom
  seen[id] = (seen[id] or 0) + 1
  if finding.example then
    examples[id] = finding.example
  end
  log[#log + 1] = finding
  if #log > cost.session_log_max then
    table.remove(log, 1)
  end
end

---@return VimCoach.Finding[]
function M.log()
  return log
end

---@return {before:string[], after:string[]}?
function M.example(idiom)
  return examples[idiom]
end

---@return integer
function M.seen(idiom)
  return seen[idiom] or 0
end

--- The key detector reported this idiom; the edit detector should not count it again.
function M.claim(idiom)
  claims[idiom] = uv.now()
end

---@param ms number  vim.uv.now() value
---@return table<string, boolean>
function M.claimed_since(ms)
  local out = {}
  for id, t in pairs(claims) do
    if t >= ms then
      out[id] = true
    end
  end
  return out
end

function M.reset()
  log, seen, examples, claims = {}, {}, {}, {}
end

return M
