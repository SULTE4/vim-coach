local config = require("vim_coach.config")
local session = require("vim_coach.session")

local state = { learned = {}, dismissed = {} }
package.loaded["vim_coach.store"] = { state = function() return state end }

local hints = require("vim_coach.hints")
local cost = require("vim_coach.cost")

local function finding(idiom, naive, ideal)
  return {
    event = { idiom = idiom, naive = naive or 7, ideal = ideal or 2 },
    label = "7j",
    was = "j x7",
  }
end

local function push(f)
  session.push(f)
  return f
end

local function virt_marks()
  return vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("vim_coach_hint"), 0, -1, { details = true })
end

describe("hints.offer", function()
  local now
  before_each(function()
    config.setup({ hint = "virt" })
    session.reset()
    state.learned, state.dismissed = {}, {}
    now = 1000
    hints._clock = function() return now end
    hints.setup()
    hints._reset()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b" })
  end)
  after_each(function()
    hints.clear()
  end)

  it("stays quiet below the repeat threshold", function()
    for _ = 1, cost.hint_after - 1 do
      assert.is_false(hints.offer(push(finding("count-jk"))))
    end
    assert.same(0, #virt_marks())
  end)

  it("hints at the threshold with suggestive text", function()
    local f
    for _ = 1, cost.hint_after do
      f = push(finding("count-jk"))
    end
    assert.is_true(hints.offer(f))
    local marks = virt_marks()
    assert.same(1, #marks)
    local text = marks[1][4].virt_text[1][1]
    assert.truthy(text:find("7j could do this", 1, true))
    assert.truthy(text:find("saves 5 keys", 1, true))
    assert.truthy(text:find("j x7", 1, true))
  end)

  it("hints immediately for a big saving", function()
    assert.is_true(hints.offer(push(finding("macro", 30, 5))))
  end)

  it("respects global and per-idiom cooldowns", function()
    assert.is_true(hints.offer(push(finding("macro", 30, 5))))
    now = now + cost.hint_cooldown_s - 1
    assert.is_false(hints.offer(push(finding("global-cmd", 40, 5))))
    now = now + 2
    assert.is_true(hints.offer(push(finding("global-cmd", 40, 5))))
    assert.is_false(hints.offer(push(finding("macro", 30, 5))))
    now = now + cost.hint_idiom_cooldown_s
    assert.is_true(hints.offer(push(finding("macro", 30, 5))))
  end)

  it("suppresses learned and dismissed idioms", function()
    state.learned["macro"] = 1
    state.dismissed["global-cmd"] = true
    assert.is_false(hints.offer(push(finding("macro", 30, 5))))
    assert.is_false(hints.offer(push(finding("global-cmd", 40, 5))))
  end)

  it("never shows in insert mode", function()
    vim.cmd("startinsert")
    vim.api.nvim_feedkeys("", "x", false)
    local f = push(finding("macro", 30, 5))
    local mode = vim.api.nvim_get_mode().mode
    local res = hints.offer(f)
    vim.cmd("stopinsert")
    if mode:sub(1, 1) == "i" then
      assert.is_false(res)
    end
    -- headless: also stub the mode to be sure
    local orig = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "i", blocking = false } end
    local res2 = hints.offer(f)
    vim.api.nvim_get_mode = orig
    assert.is_false(res2)
  end)

  it("honors hint = false and notify mode", function()
    config.setup({ hint = false })
    assert.is_false(hints.offer(push(finding("macro", 30, 5))))
    config.setup({ hint = "notify" })
    local got
    local orig = vim.notify
    vim.notify = function(msg, level, opts) got = { msg, level, opts } end
    local ok = hints.offer(push(finding("macro", 30, 5)))
    vim.notify = orig
    assert.is_true(ok)
    assert.same(vim.log.levels.INFO, got[2])
    assert.same("vim-coach", got[3].title)
  end)

  it("clear removes the virtual text", function()
    hints.offer(push(finding("macro", 30, 5)))
    hints.clear()
    assert.same(0, #virt_marks())
  end)

  it("never hints a stats-only habit", function()
    local f
    for _ = 1, cost.hint_after + 1 do
      f = push({ event = { idiom = "fidget", naive = 40, ideal = 0 }, label = "jk" })
    end
    assert.is_false(hints.offer(f))
  end)
end)
