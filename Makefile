NVIM ?= nvim
INIT = tests/minimal_init.lua

.PHONY: test test-file

# Run the whole suite
test:
	$(NVIM) --headless --noplugin -u $(INIT) -c "PlenaryBustedDirectory tests/ {minimal_init = '$(INIT)', sequential = true, timeout = 60000}"

# Run one spec: make test-file FILE=tests/score_spec.lua
test-file:
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua require('plenary.busted').run(vim.fn.fnamemodify('$(FILE)', ':p'))"
