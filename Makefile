test:
	nvim --headless --noplugin -u tests/minimal.vim \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal.vim', sequential = true, timeout = 120000}"

.PHONY: test
