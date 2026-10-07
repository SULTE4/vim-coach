local motions = require("vim_coach.motions")

local function by_keys(cands, keys)
  for _, c in ipairs(cands) do
    if c.keys == keys then
      return c
    end
  end
end

describe("motions", function()
  it("classifies run tokens and maps arrows", function()
    assert.equals(1, motions.RUN["j"])
    assert.equals(2, motions.RUN["l"])
    assert.equals(3, motions.RUN["W"])
    assert.equals(4, motions.RUN["<Down>"])
    assert.is_nil(motions.RUN["x"])
    assert.equals("j", motions.base("<Down>"))
    assert.equals("w", motions.base("w"))
  end)

  it("reads thresholds from cost", function()
    local cost = require("vim_coach.cost")
    assert.equals(cost.min_run.vertical, motions.min_run(1))
    assert.equals(cost.min_run.arrows, motions.min_run(4))
  end)

  it("generates vertical candidates", function()
    local c = motions.candidates("j", 7, { 1, 0 }, { 8, 0 }, { nlines = 30, line = "x" })
    assert.same({ idiom = "count-jk", label = "7j", keys = "7j", cost = 2 }, c[1])
    assert.is_truthy(by_keys(c, "}"))
    assert.is_truthy(by_keys(c, "8G"))
    assert.is_truthy(by_keys(c, vim.keycode("<C-d>")))
    assert.is_nil(by_keys(c, "gg"))
  end)

  it("uses gg, G and {" , function()
    local up = motions.candidates("k", 5, { 9, 0 }, { 1, 0 }, { nlines = 30, line = "" })
    assert.is_truthy(by_keys(up, "gg"))
    assert.is_truthy(by_keys(up, "{"))
    assert.is_truthy(by_keys(up, "5k"))
    assert.is_truthy(by_keys(up, vim.keycode("<C-u>")))
    local down = motions.candidates("j", 5, { 25, 0 }, { 30, 0 }, { nlines = 30, line = "" })
    assert.is_truthy(by_keys(down, "G"))
  end)

  it("generates find-char and line-end candidates for l runs", function()
    local line = "foo(bar, baz)"
    local c = motions.candidates("l", 6, { 1, 0 }, { 1, 3 }, { line = line })
    assert.is_truthy(by_keys(c, "f("))
    assert.is_truthy(by_keys(c, "tb"))
    local end_ = motions.candidates("l", 6, { 1, 0 }, { 1, #line - 1 }, { line = line })
    assert.is_truthy(by_keys(end_, "$"))
    assert.is_truthy(by_keys(end_, "f)"))
  end)

  it("counts repeated target characters", function()
    local c = motions.candidates("l", 6, { 1, 0 }, { 1, 5 }, { line = "a,b,c,d" })
    assert.is_truthy(by_keys(c, "3f,"))
  end)

  it("generates backward find-char and ^ / 0", function()
    local line = "  foo bar"
    local c = motions.candidates("h", 6, { 1, 8 }, { 1, 2 }, { line = line })
    assert.is_truthy(by_keys(c, "Ff"))
    assert.is_truthy(by_keys(c, "^"))
    local z = motions.candidates("h", 6, { 1, 8 }, { 1, 0 }, { line = line })
    assert.is_truthy(by_keys(z, "0"))
  end)

  it("simulates word motions inside a line", function()
    local line = "foo bar.baz qux"
    assert.equals(4, motions.step(line, 0, "w"))
    assert.equals(7, motions.step(line, 4, "w"))
    assert.equals(2, motions.step(line, 0, "e"))
    assert.equals(4, motions.step(line, 7, "b"))
    assert.equals(2, motions.word_count(line, 0, 7, "w"))
    assert.equals(1, motions.word_count(line, 0, 4, "w"))
    assert.is_nil(motions.word_count(line, 12, 14, "w"))
  end)

  it("offers counted word motion for h/l runs and w runs", function()
    local line = "foo bar baz qux"
    local c = motions.candidates("l", 8, { 1, 0 }, { 1, 8 }, { line = line })
    assert.is_truthy(by_keys(c, "2w"))
    local w = motions.candidates("w", 4, { 1, 0 }, { 1, 12 }, { line = line })
    assert.is_truthy(by_keys(w, "4w"))
    assert.equals("word-motion", by_keys(w, "4w").idiom)
    assert.is_truthy(by_keys(w, "f" .. "q"))
  end)

  it("handles multibyte targets", function()
    local line = "ab\u{e9}cd"
    local c = motions.candidates("l", 4, { 1, 0 }, { 1, 2 }, { line = line })
    assert.is_truthy(by_keys(c, "f\u{e9}"))
  end)
end)
