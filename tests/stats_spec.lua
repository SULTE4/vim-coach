local now = os.time()

package.loaded["vim_coach.score"] = {
  by_idiom = function(events)
    local by = {}
    for _, e in ipairs(events) do
      by[e.idiom] = by[e.idiom] or {}
      table.insert(by[e.idiom], e)
    end
    return by
  end,
  rank = function() return { { id = "count-jk", value = 4.5 }, { id = "ci-quote", value = 2.0 } } end,
  next_to_learn = function() return "counts-demo", nil end,
  weekly = function(_, _, id)
    if id == "count-jk" or id == "ci-quote" then
      return { this = { count = 3, saved = 15 }, last = { count = 2, saved = 10 } }
    end
    return { this = { count = 0, saved = 0 }, last = { count = 0, saved = 0 } }
  end,
}

local stats = require("vim_coach.stats")

local function ev(idiom, naive, ideal)
  return { idiom = idiom, naive = naive, ideal = ideal, ts = now }
end

describe("stats.render", function()
  local events = { ev("count-jk", 7, 2), ev("count-jk", 6, 2), ev("ci-quote", 10, 3) }
  local rollup = { ["count-jk"] = { ["2026-W01"] = { count = 4, saved = 20 } } }

  it("renders header, categories, trend and footer", function()
    package.loaded["vim_coach.score"].next_to_learn = function() return "ci-quote", "operators" end
    local lines, map = stats.render(events, rollup, { learned = { ["dot-repeat"] = 1 }, dismissed = { macro = true } }, now)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find('Next to learn: ci" (ci-quote)', 1, true))
    assert.truthy(text:find("it unlocks operators", 1, true))
    assert.truthy(text:find("keystrokes per week", 1, true))
    assert.truthy(text:find("MOTIONS", 1, true))
    assert.truthy(text:find("TEXT-OBJECTS", 1, true))
    assert.is_nil(text:find("CONCEPTS", 1, true))
    assert.is_nil(text:find("EX\n", 1, true))
    assert.truthy(text:find("x6 ", 1, true)) -- 2 events + 4 rolled up
    assert.truthy(text:find("+50%", 1, true))
    assert.truthy(text:find("LEARNED", 1, true))
    assert.truthy(text:find("DISMISSED", 1, true))
    assert.truthy(text:find("estimates from observed keys and modeled edits, not exact measurements", 1, true))
    local ids = {}
    for _, id in pairs(map) do
      ids[id] = true
    end
    assert.is_true(ids["count-jk"] and ids["dot-repeat"] and ids["macro"])
  end)

  it("handles empty data", function()
    local lines = stats.render({}, {}, { learned = {}, dismissed = {} }, now)
    assert.truthy(#lines >= 2)
  end)
end)
