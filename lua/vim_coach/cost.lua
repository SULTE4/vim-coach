-- Every tunable number lives here. Tune these until the rankings feel right.
-- Nothing else in the plugin should hardcode thresholds, timings or costs.
return {
  -- Scoring (design doc section 6)
  HALF_LIFE_DAYS = 14, -- older events decay with this half-life
  MIN_SAVED = 3, -- events that save fewer keystrokes are ignored in scoring

  -- Key-pattern detector
  ring_size = 256, -- preallocated ring of recent normal-mode keys (in memory only)
  run_idle_ms = 700, -- a run of identical commands ends after this much idle time
  min_run = {
    vertical = 4, -- j/k pressed this many times in a row
    horizontal = 4, -- h/l
    word = 3, -- w/b/e/W/B/E
    arrows = 3, -- arrow keys in normal or insert mode
  },
  -- Movement bursts: consecutive j/k (or h/l) presses are judged by where they end up
  fidget_min_keys = 6, -- a burst this long ...
  fidget_min_reversals = 2, -- ... that changes direction at least this often ...
  fidget_max_net = 1, -- ... and ends at most this far from its start is a fidget

  -- Edit-shape detector
  edit_debounce_ms = 600, -- a normal-mode edit span ends after this idle time
  diff_context = 3, -- lines of context kept around a dirty range
  max_lines = 10000, -- buffers larger than this are not watched
  max_span_lines = 200, -- larger spans skip verify and get a modeled event only
  repeat_min = 3, -- same edit shape this many times in a session -> dot/macro
  min_run_edit = {
    x = 3, -- x pressed this many times in one span
    dd = 2, -- dd pressed this many times in one span
    bs = 5, -- <BS> pressed this many times in one insert
  },

  -- Verify
  max_candidates = 8, -- at most this many candidates replayed per span or run
  verify_budget_ms = 4, -- total replay time budget per span or run
  reposition = 2, -- extra keys charged when a candidate must start from the edit start

  -- Modeled naive cost when no keys were observed (design doc 4.2)
  model = {
    char = 1, -- one key per character deleted or retyped
    line_move = 1, -- moving to the next line (j)
    mode_switch = 2, -- entering and leaving insert mode (i ... <Esc>)
  },

  -- Hints
  hint_after = 3, -- same idiom seen this many times in the session before hinting
  hint_big_saving = 20, -- a single finding saving this many keys is hinted immediately
  hint_cooldown_s = 10, -- global minimum gap between hints
  hint_escalation = 2, -- hint at hint_after * hint_escalation^k repeats: 3, 6, 12, 24...
  popup_ttl_ms = 5000, -- popup closes after this long
  hint_ttl_ms = 4000, -- virtual-text hint disappears after this long

  -- Adoption ("learned")
  adopt_uses = 5, -- idiom typed this many times ...
  adopt_days = 2, -- ... across at least this many distinct days

  -- Persistence
  save_debounce_ms = 5000, -- write the stats file at most this often while dirty
  retain_days = 90, -- events older than this are rolled up into weekly buckets
  session_log_max = 200, -- in-memory findings kept for :VimCoach log

  -- Performance gates checked by tests/perf_spec.lua
  perf_key_us = 2, -- average on_key overhead per key, microseconds
  perf_span_ms = 5, -- finalizing a 50-line span including verify, milliseconds
}
