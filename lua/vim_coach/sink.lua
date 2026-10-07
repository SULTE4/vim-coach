-- Single entry point for detectors. Validates a finding, dedupes it against the
-- other detector, persists the event and offers a hint.
local catalog = require("vim_coach.catalog")
local session = require("vim_coach.session")

local M = {}

---@param finding VimCoach.Finding
---@return boolean recorded
function M.report(finding)
  local ev = finding and finding.event
  if not ev or not catalog[ev.idiom] then
    return false
  end
  if (ev.naive or 0) - (ev.ideal or 0) < 1 then
    return false
  end
  -- Count each edit once: if the key detector already reported this idiom during
  -- the span, the edit detector's event is a duplicate.
  if ev.src == "edit" and finding.since and session.claimed_since(finding.since)[ev.idiom] then
    return false
  end
  if ev.src == "keys" then
    session.claim(ev.idiom)
  end

  local store = require("vim_coach.store")
  ev.edit_id = ev.edit_id or store.new_id()
  ev.ts = ev.ts or os.time()
  ev.alts = ev.alts or {}
  ev.ft = ev.ft or ""
  ev.scale = ev.scale or 1
  ev.measured = ev.measured == true
  store.add(ev)
  session.push(finding)
  require("vim_coach.hints").offer(finding)
  return true
end

--- A detector saw the user type an idiom. May mark it learned.
---@param idiom string
function M.used(idiom)
  if not catalog[idiom] then
    return
  end
  if require("vim_coach.store").record_use(idiom, os.time()) then
    vim.schedule(function()
      vim.notify(("vim-coach: you now use %s regularly, marked as learned"):format(catalog[idiom].example),
        vim.log.levels.INFO)
    end)
  end
end

return M
