local config = require("vim_coach.config")
local session = require("vim_coach.session")

local state = { learned = {}, dismissed = {} }
package.loaded["vim_coach.store"] = { state = function() return state end }

local hints = require("vim_coach.hints")

local function finding(idiom, naive, ideal, extra)
  return vim.tbl_extend("force", {
    event = { idiom = idiom, naive = naive or 7, ideal = ideal or 2, alts = {} },
    label = "7j",
    was = "j x7",
  }, extra or {})
end

-- Mimics sink: push to the session, then offer.
local function report(f)
  session.push(f)
  return hints.offer(f)
end

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      out[#out + 1] = w
    end
  end
  return out
end

local function popup_text(w)
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
end

describe("hints.offer", function()
  local now
  before_each(function()
    config.setup({ hint = "popup" })
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

  it("follows the escalation schedule 3, 6, 12", function()
    local shown = {}
    for i = 1, 12 do
      now = now + 100 -- clear of the global gap
      if report(finding("count-jk")) then
        shown[#shown + 1] = i
      end
    end
    assert.same({ 3, 6, 12 }, shown)
  end)

  it("hints on first sighting for a big saving only", function()
    assert.is_true(report(finding("macro", 30, 5)))
    now = now + 100
    assert.is_false(report(finding("macro", 30, 5))) -- 2nd sighting, off schedule
    assert.is_false(report(finding("global-cmd", 7, 2)))
  end)

  it("enforces the global gap", function()
    assert.is_true(report(finding("macro", 30, 5)))
    now = now + 5
    assert.is_false(report(finding("global-cmd", 40, 5)))
    now = now + 6
    assert.is_true(report(finding("dup-lines", 40, 5)))
  end)

  it("suppresses stats_only, learned and dismissed idioms", function()
    state.learned["macro"] = 1
    state.dismissed["global-cmd"] = true
    assert.is_false(report(finding("macro", 30, 5)))
    assert.is_false(report(finding("global-cmd", 40, 5)))
    assert.is_false(report(finding("fidget", 40, 5)))
  end)

  it("never shows in insert mode", function()
    local orig = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "i", blocking = false } end
    local res = report(finding("macro", 30, 5))
    vim.api.nvim_get_mode = orig
    assert.is_false(res)
  end)

  it("honors hint = false", function()
    config.setup({ hint = false })
    assert.is_false(report(finding("macro", 30, 5)))
    assert.same(0, #floats())
  end)

  it("uses notify with the same gating", function()
    config.setup({ hint = "notify" })
    local got
    local orig = vim.notify
    vim.notify = function(msg, level, opts) got = { msg, level, opts } end
    local ok = report(finding("macro", 30, 5))
    vim.notify = orig
    assert.is_true(ok)
    assert.same(vim.log.levels.INFO, got[2])
    assert.same("vim-coach", got[3].title)
    assert.truthy(got[1]:find("7j could do this", 1, true))
  end)

  it("uses virtual text with the same gating", function()
    config.setup({ hint = "virt" })
    assert.is_true(report(finding("macro", 30, 5)))
    local ns = vim.api.nvim_create_namespace("vim_coach_hint")
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
    assert.same(1, #marks)
    assert.truthy(marks[1][4].virt_text[1][1]:find("saves 25 keys", 1, true))
    assert.same(0, #floats())
  end)
end)

describe("hints popup", function()
  local now
  before_each(function()
    config.setup({ hint = "popup" })
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

  it("opens an unfocusable float with the expected content", function()
    local f = finding("count-jk", 7, 2, { alt_labels = { "}", "G" } })
    for _ = 1, 3 do
      session.push(f)
    end
    assert.is_true(hints.offer(f))
    local ws = floats()
    assert.same(1, #ws)
    local cfg = vim.api.nvim_win_get_config(ws[1])
    assert.is_false(cfg.focusable)
    -- relative = "cursor" is reported by Neovim as a window-relative position
    assert.same("win", cfg.relative)
    assert.same(1, cfg.row)
    local text = popup_text(ws[1])
    assert.truthy(text:find("j x7 - 3rd time this session", 1, true))
    assert.truthy(text:find("Try: 7j   (saves 5 keys)", 1, true))
    assert.truthy(text:find("also: }  G", 1, true))
  end)

  it("falls back to catalog examples for alts and desc without was", function()
    local f = finding("count-jk", 7, 2, { was = false })
    f.was = nil
    f.event.alts = { "paragraph-jump" }
    session.push(f)
    session.push(f)
    session.push(f)
    assert.is_true(hints.offer(f))
    local text = popup_text(floats()[1])
    assert.truthy(text:find("Count before j/k", 1, true))
    assert.truthy(text:find("also: }", 1, true))
  end)

  it("places the popup at the top right when configured", function()
    config.setup({ hint = "popup", popup = { position = "top_right" } })
    assert.is_true(report(finding("macro", 30, 5)))
    local cfg = vim.api.nvim_win_get_config(floats()[1])
    assert.same("editor", cfg.relative)
    assert.is_true(cfg.col + cfg.width + 2 <= vim.o.columns + 1)
    assert.is_true(cfg.col > 0)
  end)

  it("closes on InsertEnter, clear() and replacement", function()
    assert.is_true(report(finding("macro", 30, 5)))
    assert.same(1, #floats())
    vim.api.nvim_exec_autocmds("InsertEnter", {})
    assert.same(0, #floats())

    now = now + 100
    assert.is_true(report(finding("global-cmd", 30, 5)))
    hints.clear()
    assert.same(0, #floats())

    now = now + 100
    assert.is_true(report(finding("dup-lines", 30, 5)))
    now = now + 100
    assert.is_true(report(finding("move-lines", 30, 5)))
    assert.same(1, #floats())
  end)
end)
