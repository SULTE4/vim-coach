local score = require("vim_coach.score")
local catalog = require("vim_coach.catalog")
local cost = require("vim_coach.cost")

local NOW = 1760000000
local DAY = 86400

local function ev(idiom, naive, ideal, ts, id)
  return { edit_id = id or "x", ts = ts or NOW, idiom = idiom, alts = {}, ft = "lua", scale = 1,
    naive = naive, ideal = ideal, src = "edit", measured = false }
end

local function empty_state()
  return { learned = {}, dismissed = {} }
end

local function doc_events()
  local evs = {}
  for i = 1, 10 do
    evs[#evs + 1] = ev("ci-quote", 14, 3, NOW, "q" .. i)
  end
  for i = 1, 2 do
    evs[#evs + 1] = ev("visual-block", 60, 6, NOW, "v" .. i)
  end
  return evs
end

describe("score", function()
  it("matches the doc 6.1 worked example", function()
    local ranked = score.rank(score.by_idiom(doc_events()), catalog, empty_state(), NOW)
    assert.equals("ci-quote", ranked[1].id)
    assert.equals("visual-block", ranked[2].id)
    assert.is_true(math.abs(ranked[1].value - 55) < 0.01)
    assert.is_true(math.abs(ranked[2].value - 36) < 0.01)
    assert.is_true(math.abs(ranked[1].opportunity - 110) < 0.01)
  end)

  it("halves at the half-life", function()
    local fresh = score.opportunity({ ev("ci-quote", 14, 3, NOW) }, NOW)
    local old = score.opportunity({ ev("ci-quote", 14, 3, NOW - cost.HALF_LIFE_DAYS * DAY) }, NOW)
    assert.is_true(math.abs(old - fresh / 2) < 1e-6)
  end)

  it("ignores events saving less than MIN_SAVED", function()
    local small = ev("ci-quote", 3 + cost.MIN_SAVED - 1, 3)
    assert.equals(0, score.opportunity({ small }, NOW))
    local ok = ev("ci-quote", 3 + cost.MIN_SAVED, 3)
    assert.equals(cost.MIN_SAVED, score.opportunity({ ok }, NOW))
    assert.equals(0, #score.rank(score.by_idiom({ small }), catalog, empty_state(), NOW))
  end)

  it("skips learned, dismissed and concept entries", function()
    local by = score.by_idiom(doc_events())
    by["operators"] = { ev("operators", 20, 1) }
    local r = score.rank(by, catalog, { learned = { ["ci-quote"] = 1 }, dismissed = {} }, NOW)
    assert.equals("visual-block", r[1].id)
    assert.equals(1, #r)
    r = score.rank(by, catalog, { learned = {}, dismissed = { ["visual-block"] = true, ["ci-quote"] = true } }, NOW)
    assert.equals(0, #r)
  end)

  it("by_idiom credits only the primary idiom", function()
    local e = ev("ci-quote", 14, 3)
    e.alts = { "visual-block" }
    local by = score.by_idiom({ e })
    assert.equals(1, #by["ci-quote"])
    assert.is_nil(by["visual-block"])
  end)

  it("redirects to an unlearned detectable prerequisite", function()
    local ranked = { { id = "dt-char", value = 5, opportunity = 15 } }
    local id, because = score.next_to_learn(ranked, catalog, empty_state())
    assert.equals("find-char", id)
    assert.equals("dt-char", because)
    id, because = score.next_to_learn(ranked, catalog, { learned = { ["find-char"] = 1 }, dismissed = {} })
    assert.equals("dt-char", id)
    assert.is_nil(because)
    id = score.next_to_learn(ranked, catalog, { learned = {}, dismissed = { ["find-char"] = true } })
    assert.equals("dt-char", id)
  end)

  it("never redirects to concept prerequisites", function()
    local ranked = { { id = "ci-quote", value = 5, opportunity = 10 } }
    local id, because = score.next_to_learn(ranked, catalog, empty_state())
    assert.equals("ci-quote", id)
    assert.is_nil(because)
    assert.is_nil(score.next_to_learn({}, catalog, empty_state()))
  end)

  it("weekly combines raw events and rollup buckets", function()
    local this_k = os.date("%G-W%V", NOW)
    local last_k = os.date("%G-W%V", NOW - 7 * DAY)
    local evs = { ev("ci-quote", 14, 3, NOW, "a"), ev("ci-quote", 10, 2, NOW - 7 * DAY, "b"),
      ev("visual-block", 60, 6, NOW, "c"), ev("ci-quote", 14, 3, NOW - 30 * DAY, "d") }
    local rollup = { ["ci-quote"] = { [this_k] = { count = 2, saved = 20 }, [last_k] = { count = 1, saved = 5 },
      ["2000-W01"] = { count = 9, saved = 99 } } }
    local w = score.weekly(evs, rollup, "ci-quote", NOW)
    assert.same({ count = 3, saved = 31 }, w.this)
    assert.same({ count = 2, saved = 13 }, w.last)
  end)

  it("never recommends a stats-only habit", function()
    local evs = doc_events()
    for i = 1, 50 do
      evs[#evs + 1] = ev("fidget", 20, 0, NOW, "f" .. i)
    end
    local ranked = score.rank(score.by_idiom(evs), catalog, empty_state(), NOW)
    assert.equals("fidget", ranked[1].id)
    assert.equals("ci-quote", (score.next_to_learn(ranked, catalog, empty_state())))
  end)
end)
