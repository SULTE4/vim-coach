-- Scoring (design doc section 6). All numbers come from cost.lua.
local cost = require("vim_coach.cost")

local M = {}

local function decay(age_days)
  if age_days < 0 then
    age_days = 0
  end
  return 0.5 ^ (age_days / cost.HALF_LIFE_DAYS)
end

--- Weighted keystrokes saved for one idiom.
---@param events VimCoach.Event[]
---@param now integer unix seconds
---@return number
function M.opportunity(events, now)
  local total = 0
  for _, e in ipairs(events) do
    local saved = e.naive - e.ideal
    if saved >= cost.MIN_SAVED then
      total = total + saved * decay((now - e.ts) / 86400)
    end
  end
  return total
end

--- Group events by their credited idiom (alts are never counted).
---@param events VimCoach.Event[]
---@return table<string, VimCoach.Event[]>
function M.by_idiom(events)
  local out = {}
  for _, e in ipairs(events) do
    local list = out[e.idiom]
    if not list then
      list = {}
      out[e.idiom] = list
    end
    list[#list + 1] = e
  end
  return out
end

---@class VimCoach.Ranked
---@field id string
---@field opportunity number
---@field value number

--- Rank idioms by learning value = opportunity / difficulty.
---@param events_by_idiom table<string, VimCoach.Event[]>
---@param catalog table
---@param state VimCoach.State
---@param now integer
---@return VimCoach.Ranked[]
function M.rank(events_by_idiom, catalog, state, now)
  local ranked = {}
  for id, events in pairs(events_by_idiom) do
    local meta = catalog[id]
    if meta and not meta.concept and not state.learned[id] and not state.dismissed[id] then
      local opp = M.opportunity(events, now)
      if opp > 0 then
        ranked[#ranked + 1] = { id = id, opportunity = opp, value = opp / meta.difficulty }
      end
    end
  end
  table.sort(ranked, function(a, b)
    if a.value ~= b.value then
      return a.value > b.value
    end
    return a.id < b.id
  end)
  return ranked
end

--- Top recommendation, redirected to an unlearned detectable prerequisite if any.
--- Concept prerequisites are never redirect targets.
---@param ranked VimCoach.Ranked[]
---@param catalog table
---@param state VimCoach.State
---@return string? id
---@return string? because_of
function M.next_to_learn(ranked, catalog, state)
  -- Stats-only habits (e.g. fidget) have nothing to learn, so they are never recommended.
  local top
  for _, r in ipairs(ranked) do
    if not (catalog[r.id] and catalog[r.id].stats_only) then
      top = r
      break
    end
  end
  if not top then
    return nil
  end
  local meta = catalog[top.id]
  for _, req in ipairs(meta and meta.requires or {}) do
    local r = catalog[req]
    if r and not r.concept and not state.learned[req] and not state.dismissed[req] then
      return req, top.id
    end
  end
  return top.id
end

local function week_key(ts)
  return os.date("%G-W%V", ts)
end

--- Count and keystrokes saved for the ISO week containing `now` and the one before.
---@param events VimCoach.Event[]
---@param rollup table
---@param idiom string
---@param now integer
---@return {this: {count:integer, saved:integer}, last: {count:integer, saved:integer}}
function M.weekly(events, rollup, idiom, now)
  local this_k, last_k = week_key(now), week_key(now - 7 * 86400)
  local out = { this = { count = 0, saved = 0 }, last = { count = 0, saved = 0 } }
  local function add(key, count, saved)
    local slot = key == this_k and out.this or (key == last_k and out.last or nil)
    if slot then
      slot.count = slot.count + count
      slot.saved = slot.saved + saved
    end
  end
  for _, e in ipairs(events) do
    if e.idiom == idiom then
      add(week_key(e.ts), 1, e.naive - e.ideal)
    end
  end
  for key, b in pairs((rollup and rollup[idiom]) or {}) do
    add(key, b.count or 0, b.saved or 0)
  end
  return out
end

return M
