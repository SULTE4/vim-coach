local diff = require("vim_coach.diff")
local candidates = require("vim_coach.candidates")
local verify = require("vim_coach.verify")

local function keys0(t)
  return vim.tbl_extend("force", { total = 0, printable = 0, bs = 0, cw = 0, cu = 0, x = 0, dd = 0, arrows = 0, esc = 0 }, t or {})
end

-- Returns the cheapest verified candidate and the set of verified idioms.
local function run(before, after, opts)
  opts = opts or {}
  local span = {
    buf = vim.api.nvim_get_current_buf(),
    ft = "",
    before = before,
    after = after,
    first_row = 1,
    cursor_before = opts.cursor or { 1, 0 },
    keys = opts.keys,
    measured = opts.keys ~= nil,
    since = 0,
  }
  local shape = diff.classify(before, after)
  local cands = candidates.generate(span, shape)
  assert.is_true(#cands <= require("vim_coach.cost").max_candidates)
  local res = verify.texts(span, cands, 500)
  local best, set = nil, {}
  for i, c in ipairs(cands) do
    if res[i] then
      set[c.idiom] = true
      if not best then
        best = c
      end
    end
  end
  return best, set, cands, shape
end

local function lines(n, f)
  local t = {}
  for i = 1, n do
    t[i] = f(i)
  end
  return t
end

describe("candidates", function()
  before_each(function()
    vim.cmd("enew!")
    vim.bo.shiftwidth = 2
    vim.bo.expandtab = true
    vim.bo.commentstring = "-- %s"
  end)
  after_each(function()
    verify.stop()
  end)

  it("ci\" for string contents replaced", function()
    local best = run({ 'x = "hello world"' }, { 'x = "bye"' }, { cursor = { 1, 6 } })
    assert.equals("ci-quote", best.idiom)
    assert.equals('ci"', best.label)
    assert.equals(3, best.cost)
  end)

  it("di\" for string contents deleted", function()
    local best = run({ 'x = "hello world"' }, { 'x = ""' }, { cursor = { 1, 7 } })
    assert.equals("ci-quote", best.idiom)
    assert.equals('di"', best.label)
  end)

  it("ci( for bracket contents replaced", function()
    local best, set = run({ "call(alpha, beta)" }, { "call(x)" }, { cursor = { 1, 6 } })
    assert.equals("ci-bracket", best.idiom)
    assert.is_true(set["ci-bracket"])
  end)

  it("cit for tag contents", function()
    local best = run({ "<b>some bold text</b>" }, { "<b>new</b>" }, { cursor = { 1, 5 } })
    assert.equals("ci-tag", best.idiom)
  end)

  it("ciw/cw for a word replaced", function()
    local best, set = run({ "local foo = bar" }, { "local baz = bar" }, { cursor = { 1, 6 } })
    assert.equals("ciw", best.idiom)
    assert.is_true(set["ciw"])
  end)

  it("diw for a word deleted", function()
    local best = run({ "one two three" }, { "one three" }, { cursor = { 1, 5 } })
    assert.equals("diw", best.idiom)
  end)

  it("D for tail deleted", function()
    local best = run({ "keep this, drop that" }, { "keep this" }, { cursor = { 1, 9 } })
    assert.equals("delete-eol", best.idiom)
    assert.equals(1, best.cost)
  end)

  it("C for tail replaced", function()
    local best = run({ "keep this, drop that" }, { "keep thing" }, { cursor = { 1, 8 } })
    assert.equals("change-eol", best.idiom)
  end)

  it("dt{c} for up to a char", function()
    local best, set = run({ "foo(first, second)" }, { "foo(second)" }, { cursor = { 1, 4 } })
    assert.is_true(set["dt-char"])
    assert.is_truthy(best)
  end)

  it("cc for the whole line replaced", function()
    vim.bo.autoindent = false
    local best = run({ "    return old_value_here" }, { "totally different" }, { cursor = { 1, 3 } })
    assert.equals("cc-line", best.idiom)
  end)

  it("{N}x for repeated x", function()
    local best = run({ "abcdefgh" }, { "fgh" }, { cursor = { 1, 0 }, keys = keys0({ x = 5, total = 5 }) })
    assert.equals("count-x", best.idiom)
    assert.equals("5x", best.label)
    assert.equals(2, best.cost)
  end)

  it("{N}dd for repeated dd", function()
    local before = { "a", "b", "c", "d", "e", "f" }
    local best = run(before, { "a", "e", "f" }, { cursor = { 1, 0 }, keys = keys0({ dd = 3 }) })
    -- cursor on row 1, deleting rows 2-4
    assert.equals("count-dd", best.idiom)
  end)

  it("<C-w> for many backspaces", function()
    local keys = keys0({ bs = 7, printable = 3 })
    local best, set = run({ "let name = some_value" }, { "let name = other" },
      { cursor = { 1, 20 }, keys = keys })
    assert.is_true(set["insert-ctrl-w"])
    assert.is_truthy(best)
  end)

  it("<C-u> for backspacing to line start", function()
    local keys = keys0({ bs = 9, printable = 3 })
    local best, set = run({ "old text here" }, { "new" }, { cursor = { 1, 12 }, keys = keys })
    assert.is_true(set["insert-ctrl-u"])
    assert.is_truthy(best)
  end)

  it("visual block for a prefix on many lines", function()
    local before = lines(10, function(i) return "item " .. i end)
    local after = lines(10, function(i) return "- item " .. i end)
    local best, set = run(before, after, { cursor = { 1, 0 } })
    assert.is_true(set["visual-block"])
    assert.is_true(set["subst-range"])
    assert.is_true(set["normal-range"])
    assert.equals("visual-block", best.idiom)
  end)

  it("visual block / A for a suffix on many lines", function()
    local before = lines(6, function(i) return "x" .. string.rep("y", i) end)
    local after = lines(6, function(i) return "x" .. string.rep("y", i) .. ";" end)
    local best, set = run(before, after, { cursor = { 1, 0 } })
    assert.is_true(set["visual-block"])
    assert.is_truthy(best)
  end)

  it("subst-range for the same substitution on many lines", function()
    local before = lines(8, function(i) return "call foo(" .. i .. ") end" end)
    local after = lines(8, function(i) return "call bar(" .. i .. ") end" end)
    local best, set = run(before, after, { cursor = { 1, 0 } })
    assert.equals("subst-range", best.idiom)
    assert.is_true(set["subst-range"])
  end)

  it("move-lines for lines moved", function()
    local best, set = run({ "a", "b", "c", "d" }, { "b", "c", "a", "d" }, { cursor = { 1, 0 } })
    assert.is_true(set["move-lines"])
    assert.equals("move-lines", best.idiom)
  end)

  it("ddp for one line moved down", function()
    local best = run({ "a", "b", "c" }, { "b", "a", "c" }, { cursor = { 1, 0 } })
    assert.equals("move-lines", best.idiom)
    assert.equals("ddp", best.label)
  end)

  it("dup-lines for duplicated lines", function()
    local best = run({ "a", "b", "c" }, { "a", "b", "b", "c" }, { cursor = { 2, 0 } })
    assert.equals("dup-lines", best.idiom)
    assert.equals("yyp", best.label)
  end)

  it("indent-block for a block indented", function()
    local before = { "a", "b", "c", "d" }
    local after = { "  a", "  b", "  c", "  d" }
    local best, set = run(before, after, { cursor = { 1, 0 } })
    assert.is_true(set["indent-block"])
    assert.equals("indent-block", best.idiom)
  end)

  it("join-lines for joined lines", function()
    local best = run({ "foo", "bar", "baz" }, { "foo bar", "baz" }, { cursor = { 1, 0 } })
    assert.equals("join-lines", best.idiom)
    assert.equals("J", best.label)
  end)

  it("case-change for case changed", function()
    local best, set = run({ "make this loud" }, { "make THIS loud" }, { cursor = { 1, 5 } })
    assert.is_true(set["case-change"])
    assert.is_truthy(best)
  end)

  it("comment-gc for a comment toggle", function()
    local before = { "local a = 1", "local b = 2", "local c = 3" }
    local after = { "-- local a = 1", "-- local b = 2", "-- local c = 3" }
    local _, set = run(before, after, { cursor = { 1, 0 } })
    assert.is_true(set["comment-gc"])
  end)

  it("returns nothing for unrecognized shapes", function()
    local span = { before = { "a" }, after = { "b", "c", "d" }, first_row = 1, cursor_before = { 1, 0 } }
    assert.same({}, candidates.generate(span, diff.classify(span.before, span.after)))
  end)

  it("models naive cost without keys", function()
    local shape = diff.classify(lines(30, function(i) return "l" .. i end),
      lines(30, function(i) return "- l" .. i end))
    local n = candidates.model_naive(shape)
    assert.is_true(n >= 55 and n <= 65)
  end)
end)
