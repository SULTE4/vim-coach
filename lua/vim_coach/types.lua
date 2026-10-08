-- Shared contracts between modules (LuaCATS annotations only, no runtime code).
-- Every module codes against these shapes. Change them here first.

---One record per verified finding (design doc 5.1). Persisted. Never holds code text.
---@class VimCoach.Event
---@field edit_id string    random per finding (store.new_id()), dedupes repeats
---@field ts integer        unix seconds (os.time())
---@field idiom string      cheapest verified idiom (catalog id)
---@field alts string[]     other verified idioms for the same finding
---@field ft string         filetype
---@field scale integer     lines or items affected
---@field naive integer     keystrokes without the idiom (measured or modeled)
---@field ideal integer     keystrokes with the idiom
---@field src "edit"|"keys" which detector produced it
---@field measured boolean  true when naive comes from observed keys

---What a detector hands to sink.report(). Only `event` is persisted.
---@class VimCoach.Finding
---@field event VimCoach.Event  edit_id/ts may be omitted; sink fills them
---@field label string          what the hint shows, e.g. "7j", "ci\"", ":m +1"
---@field alt_labels string[]? labels of the verified alternatives, same order as event.alts
---@field was string?           what the user did, no code text, e.g. "j x7", "14 x <BS>"
---@field example {before:string[], after:string[]}?  session-only, never persisted
---@field since number?         vim.uv.now() at span/run start (for claim dedupe)

---A replayable candidate idiom.
---@class VimCoach.Candidate
---@field idiom string          catalog id
---@field label string          shown to the user
---@field keys string?          raw bytes for `normal!` (use vim.keycode for special keys;
---                             inserted text stays literal). Exactly one of keys/ex.
---@field ex string?            Ex command without the leading ':'; line numbers are
---                             relative to the replay buffer (row 1 = span.before[1])
---@field cost integer          ideal keystrokes, excluding text the user types either way
---@field cursor {[1]:integer,[2]:integer}?  start cursor (1-based row in replay
---                             coordinates, 0-based byte col); nil = derive from span

---A finished edit span from the edit-shape detector.
---@class VimCoach.Span
---@field buf integer
---@field ft string
---@field before string[]       region before the edit (hunk + cost.diff_context lines)
---@field after string[]        same region after the edit
---@field first_row integer     1-based buffer row of before[1] and after[1]
---@field cursor_before {[1]:integer,[2]:integer}  real buffer cursor at span start
---                             (1-based row, 0-based col)
---@field keys VimCoach.KeyCounters?  key counter delta during the span (nil = not observed)
---@field measured boolean
---@field since number          vim.uv.now() at span start

---Cumulative typed-key counters from keys.counters(). Detectors diff two snapshots.
---@class VimCoach.KeyCounters
---@field total integer         all typed keys in any mode
---@field printable integer     printable keys typed in insert/replace mode
---@field bs integer            <BS> in insert mode
---@field cw integer            <C-w> in insert mode
---@field cu integer            <C-u> in insert mode
---@field x integer             x in normal mode (no count)
---@field dd integer            dd in normal mode (no count)
---@field arrows integer        arrow keys in any mode
---@field esc integer           <Esc>

---Persisted state view used by score/hints/stats.
---@class VimCoach.State
---@field learned table<string, integer>   idiom -> unix ts adoption was detected
---@field dismissed table<string, boolean> idiom -> true

--[[
Module APIs (who owns what):

verify.lua   (orchestrator)
  verify.busy                                   true while replaying; detectors ignore keys/changes
  verify.budget(ms?) -> fun():boolean           true while time is left (default cost.verify_budget_ms)
  verify.texts(span, cands, budget_ms?) -> boolean[]  one RPC to a child nvim; replays each on
                                                span.before, true when it yields span.after exactly
  verify.text(span, cand) -> boolean            single-candidate wrapper
  verify.warm(), verify.stop()                  start / stop the child process
  verify.cursor(win, from, cand, to) -> boolean replay a motion in the real window (view restored)

session.lua  (orchestrator) in-memory only
  session.push(finding), session.log() -> Finding[], session.example(idiom) -> example?
  session.seen(idiom) -> integer, session.claim(idiom), session.claimed_since(ms) -> set

sink.lua     (orchestrator)
  sink.report(finding) -> boolean               single entry point for detectors
  sink.used(idiom)                              detector saw the user type this idiom

store.lua    (agent A)
  store.setup(path), store.stop()
  store.add(event), store.events() -> Event[], store.rollup() -> table
  store.state() -> VimCoach.State
  store.dismiss(id), store.undismiss(id), store.mark_learned(id, ts?), store.unlearn(id)
  store.record_use(id, now?) -> boolean          true when this use made the idiom learned
  store.save(sync?), store.reset(), store.new_id() -> string, store.path() -> string

score.lua    (agent A)
  score.opportunity(events, now), score.rank(events_by_idiom, catalog, state, now)
  score.next_to_learn(ranked, catalog, state) -> id, because_of?
  score.by_idiom(events) -> table<string, Event[]>
  score.weekly(events, rollup, idiom, now) -> {this={count,saved}, last={count,saved}}

keys.lua     (agent B)  keys.setup(), keys.stop(), keys.counters() -> KeyCounters (copy),
                        keys.total() -> integer (same as counters().total, no allocation)
motions.lua  (agent B)  pure functions used by keys.lua (run -> candidates)
edits.lua    (agent C)  edits.setup(), edits.stop(), edits.attach(buf)
diff.lua, candidates.lua (agent C) pure functions
hints.lua    (agent D)  hints.setup(), hints.offer(finding) -> boolean, hints.clear()
stats.lua    (agent D)  stats.open()
scan.lua     (agent D)  scan.run(buf?)
]]

return {}
