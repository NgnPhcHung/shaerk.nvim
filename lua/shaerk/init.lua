local Anchor = require("shaerk.anchor")
local contract = require("shaerk.contract")
local provider = require("shaerk.provider")
local request = require("shaerk.request")
local target = require("shaerk.target")
local ui = require("shaerk.ui")

local M = {}

M.VERSION = "0.1.0"

local STALE_SECONDS = 3600

--- @type { provider: table, tmp_dir: string }
local config = {
	provider = provider.default,
	tmp_dir = "./.shaerk",
}

--- Every request currently in flight. Concurrent requests are allowed as long
--- as their regions do not overlap: each one owns its own anchor (extmark), so
--- one applying its result just shifts the others' ranges.
--- @type { req: shaerk.Request|nil, anchor: shaerk.Anchor }[]
local inflight = {}

--- Remove orphaned tmp files (nvim crashed mid-request).
--- @param dir string
local function sweep(dir)
	local entries = vim.fn.glob(dir .. "/*.out", true, true)
	local cutoff = os.time() - STALE_SECONDS
	for _, path in ipairs(entries) do
		local stat = vim.uv.fs_stat(path)
		if stat and stat.mtime.sec < cutoff then
			os.remove(path)
		end
	end
end

--- @param opts { provider: table|nil, tmp_dir: string|nil }|nil
function M.setup(opts)
	opts = opts or {}
	config.provider = opts.provider or provider.default
	config.tmp_dir = opts.tmp_dir or "./.shaerk"
	vim.fn.mkdir(config.tmp_dir, "p")
	sweep(config.tmp_dir)
end

--- @return string
local function new_tmp()
	vim.fn.mkdir(config.tmp_dir, "p")
	return string.format("%s/%d-%d.out", config.tmp_dir, vim.uv.os_getpid(), math.random(100000, 999999))
end

--- @param t shaerk.Target
--- @param user_spec string
--- @param tmp string
--- @param format_err string|nil
--- @param srow number 0-indexed, current anchor row (not the stale t.srow)
--- @param erow number 0-indexed, exclusive
--- @return string
local function build_query(t, user_spec, tmp, format_err, srow, erow)
	local lang = vim.bo[t.buf].filetype
	local path = vim.api.nvim_buf_get_name(t.buf)
	local buffer_text = table.concat(vim.api.nvim_buf_get_lines(t.buf, 0, -1, false), "\n")

	local parts = {
		"You are editing exactly one region of one file in Neovim.",
		contract.instructions(tmp),
		string.format('<File path="%s" lang="%s">', path, lang),
		buffer_text,
		"</File>",
		string.format('<Target lines="%d-%d">', srow + 1, erow),
		table.concat(vim.api.nvim_buf_get_lines(t.buf, srow, erow, false), "\n"),
		"</Target>",
		"<Spec>",
		user_spec,
		"</Spec>",
	}

	if format_err then
		table.insert(
			parts,
			string.format(
				"<FormatError>Your previous answer failed with: %s. "
					.. "Re-read <Contract> and write the file again in exactly that shape.</FormatError>",
				format_err
			)
		)
	end

	return table.concat(parts, "\n")
end

--- @param state string
--- @param res shaerk.Result|nil
--- @param detail string|nil
--- @param t shaerk.Target
--- @param anchor shaerk.Anchor
--- @param original_lines string[] lines under the anchor when it was marked
--- @param prov_name string
--- @return string final_state
local function apply_result(state, res, detail, t, anchor, original_lines, prov_name)
	if state == "cancelled" then
		ui.notify("cancelled", "info")
		return state
	end

	if state == "proc_failed" then
		ui.notify(string.format("provider '%s' failed\n%s", prov_name, detail or ""), "error")
		return state
	end

	if state == "no_file" then
		ui.notify("provider wrote no output file", "error")
		return state
	end

	if state == "bad_header" then
		ui.notify("provider output did not match the contract", "error")
		return state
	end

	if res.status == "refused" then
		ui.notify("refused: " .. (res.note or ""), "warn")
		return "refused"
	end

	if res.status == "no_change" then
		local msg = (res.note and res.note ~= "") and ("no change: " .. res.note) or "no change"
		ui.notify(msg, "info")
		return "no_change"
	end

	-- The buffer was actually closed/deleted (not just hidden) while the request
	-- was in flight — anchor:valid() calling nvim_buf_get_extmark_by_id on this buffer would throw.
	if not vim.api.nvim_buf_is_valid(t.buf) then
		ui.notify("the buffer was closed, showing the result instead", "warn")
		-- res is always non-nil here in practice (only a "parsed" state reaches
		-- this point, and request.lua always passes res with that state), but
		-- guard anyway since the buffer being gone is exactly the situation where
		-- assuming too much about upstream state has already bitten this code path once.
		if res and res.body then
			ui.preview(vim.split(res.body, "\n"), res.lang or "", "shaerk: orphaned result")
		end
		return "anchor_lost"
	end

	if not anchor:valid() then
		ui.notify("the target region was deleted, showing the result instead", "warn")
		ui.preview(vim.split(res.body, "\n"), vim.bo[t.buf].filetype, "shaerk: orphaned result")
		return "anchor_lost"
	end

	-- anchor:valid() only knows the extmark still exists and hasn't collapsed to
	-- zero-width — it does NOT know whether the content underneath is still the
	-- original content (e.g. format-on-save, :e!, a big undo replacing the whole
	-- buffer). Diff the text to catch that case instead of silently overwriting content the user no longer recognizes.
	-- An empty anchor has no range to diff (srow == erow always), so compare
	-- the context window captured at mark time instead.
	local srow, erow = anchor:range()
	local changed
	if anchor.empty then
		changed = anchor:context_changed()
	else
		local current_lines = vim.api.nvim_buf_get_lines(t.buf, srow, erow, false)
		changed = not vim.deep_equal(current_lines, original_lines)
	end
	if changed then
		ui.notify("the target region changed underneath, showing the result instead", "warn")
		ui.preview(vim.split(res.body, "\n"), vim.bo[t.buf].filetype, "shaerk: orphaned result")
		return "anchor_lost"
	end

	if not contract.check_syntax(t.buf, srow, erow, res.body) then
		ui.notify("result does not parse, showing it instead of applying", "warn")
		ui.preview(vim.split(res.body, "\n"), vim.bo[t.buf].filetype, "shaerk: invalid syntax")
		return "invalid_syntax"
	end

	anchor:apply(vim.split(res.body, "\n"))
	if res.note and res.note ~= "" then
		ui.notify(res.note, "info")
	end
	return "ok"
end

--- @param t shaerk.Target
--- @param user_spec string
--- @param on_state fun(state: string)|nil
local function start(t, user_spec, on_state)
	local anchor = Anchor.mark(t.buf, t.srow, t.erow)
	local entry = { req = nil, anchor = anchor }
	table.insert(inflight, entry)
	local original_lines = vim.api.nvim_buf_get_lines(t.buf, t.srow, t.erow, false)
	local tmp = new_tmp()
	local spinner = ui.spinner(anchor)
	local prov_name = config.provider.name

	entry.req = request.start({
		tmp = tmp,
		prov = config.provider,
		build = function(format_err)
			local srow, erow = anchor:range()
			return build_query(t, user_spec, tmp, format_err, srow, erow)
		end,
		on_done = function(state, res, detail)
			spinner:stop()
			-- apply_result can throw (e.g. the buffer was actually deleted) — pcall
			-- so cleanup (anchor:clear, dropping the entry, on_state) always runs
			-- instead of getting stuck "running" forever.
			local ok, final = pcall(apply_result, state, res, detail, t, anchor, original_lines, prov_name)
			anchor:clear()
			-- The entry is inserted before request.start(), so this also runs when a
			-- spawn fails synchronously and on_done fires before start() returns.
			for i, e in ipairs(inflight) do
				if e == entry then
					table.remove(inflight, i)
					break
				end
			end
			if on_state then
				on_state(ok and final or "anchor_lost")
			end
		end,
	})
end

--- A request already covers part of this region — two results applied to the
--- same lines would clobber each other.
--- @param t shaerk.Target
--- @return boolean
local function region_busy(t)
	for _, e in ipairs(inflight) do
		if e.anchor.buf == t.buf and vim.api.nvim_buf_is_valid(t.buf) then
			local ok, s, er = pcall(e.anchor.range, e.anchor)
			-- An empty (insertion-point) region covers the single line it sits on.
			if ok and math.max(s, t.srow) < math.min(math.max(er, s + 1), math.max(t.erow, t.srow + 1)) then
				return true
			end
		end
	end
	return false
end

--- @param opts { ask: boolean|nil, visual: boolean|nil, __on_state: fun(state: string)|nil }|nil
local function go(opts)
	opts = opts or {}

	local t = target.resolve({ visual = opts.visual })
	if region_busy(t) then
		ui.notify("a request is already running on this region, cancel it first", "warn")
		return
	end

	if not t.needs_input and not opts.ask then
		start(t, t.spec, opts.__on_state)
		return
	end

	ui.ask("shaerk: ", function(input)
		if not input or vim.trim(input) == "" then
			ui.notify("cancelled", "info")
			if opts.__on_state then
				opts.__on_state("cancelled")
			end
			return
		end
		-- Prompts are non-blocking under dressing/snacks/noice, so several can be
		-- open at once: the region has to be re-checked here, not only in go().
		if region_busy(t) then
			ui.notify("a request is already running on this region, cancel it first", "warn")
			return
		end
		local spec = t.spec ~= "" and (t.spec .. "\n\n" .. input) or input
		start(t, spec, opts.__on_state)
	end)
end

--- @param opts { ask: boolean|nil, __on_state: fun(state: string)|nil }|nil
function M.run(opts)
	go(opts)
end

function M.visual()
	go({ visual = true })
end

--- Cancels every in-flight request.
function M.cancel()
	if #inflight == 0 then
		ui.notify("nothing to cancel", "info")
		return
	end
	-- :cancel() removes the entry from inflight through on_done, so iterate a copy.
	for _, e in ipairs(vim.list_slice(inflight)) do
		if e.req then
			e.req:cancel()
		end
	end
end

return M
