local helpers = require("tests.helpers")
local shaerk = require("shaerk")
local ui = require("shaerk.ui")

local function fake(text, code)
  return {
    name = "fake",
    cmd = function(_query, tmp)
      local script
      if text == nil then
        script = "exit " .. (code or 0)
      else
        script = string.format(
          "mkdir -p %s && cat > %s <<'SHAERK_EOF'\n%s\nSHAERK_EOF\nexit %d",
          vim.fn.shellescape(vim.fs.dirname(tmp)),
          vim.fn.shellescape(tmp),
          text,
          code or 0
        )
      end
      return { "sh", "-c", script }
    end,
  }
end

--- Run the whole flow on a buffer, returning the final state and buffer content.
local function run_on(lines, filetype, cursor_row, provider_text, code)
  local buf = helpers.buf(lines, filetype)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { cursor_row, 0 })

  shaerk.setup({ provider = fake(provider_text, code), tmp_dir = vim.fn.tempname() })

  local state, done = nil, false
  shaerk.run({ __on_state = function(s)
    state, done = s, true
  end })
  vim.wait(5000, function()
    return done
  end, 20)

  return state, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("shaerk.run", function()
  it("replaces the function on ok", function()
    local state, out = run_on(
      { "local function f()", "  return 1", "end" },
      "lua",
      2,
      '{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend'
    )
    assert.are.equal("ok", state)
    assert.are.same({ "local function f()", "  return 2", "end" }, out)
  end)

  it("leaves the buffer untouched on refused", function()
    local before = { "local function f()", "  return 1", "end" }
    local state, out = run_on(
      vim.deepcopy(before),
      "lua",
      2,
      '{"v":1,"status":"refused","note":"needs another file"}'
    )
    assert.are.equal("refused", state)
    assert.are.same(before, out)
  end)

  it("leaves the buffer untouched on no_change", function()
    local before = { "local function f()", "  return 1", "end" }
    local state, out = run_on(
      vim.deepcopy(before),
      "lua",
      2,
      '{"v":1,"status":"no_change","note":"already fine"}'
    )
    assert.are.equal("no_change", state)
    assert.are.same(before, out)
  end)

  it("leaves the buffer untouched on invalid syntax", function()
    local before = { "local function f()", "  return 1", "end" }
    local state, out = run_on(
      vim.deepcopy(before),
      "lua",
      2,
      '{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f((( '
    )
    assert.are.equal("invalid_syntax", state)
    assert.are.same(before, out)
    vim.cmd("silent! close")
  end)

  it("leaves the buffer untouched on proc_failed", function()
    local before = { "local function f()", "  return 1", "end" }
    local state, out = run_on(vim.deepcopy(before), "lua", 2, nil, 3)
    assert.are.equal("proc_failed", state)
    assert.are.same(before, out)
  end)

  it("leaves the buffer untouched on bad_header", function()
    local before = { "local function f()", "  return 1", "end" }
    local state, out = run_on(vim.deepcopy(before), "lua", 2, "not json")
    assert.are.equal("bad_header", state)
    assert.are.same(before, out)
  end)

  it("reports no_file when the provider exits 0 without writing output", function()
    local before = { "local function f()", "  return 1", "end" }
    local state, out = run_on(vim.deepcopy(before), "lua", 2, nil, 0)
    assert.are.equal("no_file", state)
    assert.are.same(before, out)
  end)

  it("cancels an in-flight request via shaerk.cancel()", function()
    local before = { "local function f()", "  return 1", "end" }
    local buf = helpers.buf(vim.deepcopy(before), "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local slow = {
      name = "slow",
      cmd = function(_query, _tmp)
        return { "sh", "-c", "sleep 2; exit 0" }
      end,
    }
    shaerk.setup({ provider = slow, tmp_dir = vim.fn.tempname() })

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })

    shaerk.cancel()
    vim.wait(2000, function()
      return done
    end, 20)

    assert.is_true(done)
    assert.are.equal("cancelled", state)
    assert.are.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("cancels when ui.ask receives empty input, without ever starting a request", function()
    local before = { "local x = 1" }
    local buf = helpers.buf(vim.deepcopy(before), "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local never = {
      name = "never",
      cmd = function()
        error("provider must not be invoked when input is empty")
      end,
    }
    shaerk.setup({ provider = never, tmp_dir = vim.fn.tempname() })

    local orig_ask = ui.ask
    ui.ask = function(_prompt, cb)
      cb("   ")
    end

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })
    ui.ask = orig_ask

    assert.is_true(done)
    assert.are.equal("cancelled", state)
    assert.are.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("refuses a second run() while one is already in flight", function()
    local before = { "local function f()", "  return 1", "end" }
    local buf = helpers.buf(vim.deepcopy(before), "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local calls = 0
    local base = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend')
    local provider = {
      name = "counted",
      cmd = function(query, tmp)
        calls = calls + 1
        return base.cmd(query, tmp)
      end,
    }
    shaerk.setup({ provider = provider, tmp_dir = vim.fn.tempname() })

    local state1, done1 = nil, false
    shaerk.run({ __on_state = function(s)
      state1, done1 = s, true
    end })

    local state2, done2 = nil, false
    shaerk.run({ __on_state = function(s)
      state2, done2 = s, true
    end })

    vim.wait(5000, function()
      return done1
    end, 20)

    assert.are.equal(1, calls)
    assert.are.equal("ok", state1)
    assert.is_false(done2)
    assert.is_nil(state2)
    assert.are.same(
      { "local function f()", "  return 2", "end" },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
  end)

  -- Task-8 finding #1: request.start() can finish SYNCHRONOUSLY (spawn ENOENT
  -- goes through pcall(vim.system,...) failing -> self:_finish() -> on_done
  -- runs before request.start() returns). on_done sets `active = nil`, then
  -- `active = request.start({...})` in start() would silently overwrite that
  -- nil back to the already-finished Request, wedging it there forever and
  -- making every later run() refuse with "already running". Without
  -- init.lua's `if active.done then active = nil end`, this test's second
  -- run() never reaches a terminal state.
  it("regression: a synchronous spawn failure does not permanently wedge active (bug 1)", function()
    local before = { "local function f()", "  return 1", "end" }
    local buf = helpers.buf(vim.deepcopy(before), "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local missing = {
      name = "missing",
      cmd = function()
        return { "this-shaerk-provider-does-not-exist-xyz" }
      end,
    }
    shaerk.setup({ provider = missing, tmp_dir = vim.fn.tempname() })

    local state1, done1 = nil, false
    shaerk.run({ __on_state = function(s)
      state1, done1 = s, true
    end })
    vim.wait(2000, function()
      return done1
    end, 10)
    assert.is_true(done1)
    assert.are.equal("proc_failed", state1)

    local state2, done2 = nil, false
    shaerk.run({ __on_state = function(s)
      state2, done2 = s, true
    end })
    vim.wait(2000, function()
      return done2
    end, 10)

    assert.is_true(done2)
    assert.are.equal("proc_failed", state2)
    assert.are.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  -- Task-8 finding #2: if the buffer is closed/wiped (not just its region
  -- cleared) while a request is in flight, anchor:valid() throws (it calls
  -- nvim_buf_get_extmark_by_id on a dead buffer id). init.lua guards with an
  -- explicit nvim_buf_is_valid check and wraps apply_result in pcall so
  -- cleanup (anchor:clear, active = nil, on_state) always runs.
  it("regression: on_state still fires and a later run is accepted after the buffer is wiped mid-flight (bug 2)", function()
    local buf = helpers.buf({
      "local x = 1",
      "local function f()",
      "  return 1",
      "end",
    }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend'),
      tmp_dir = vim.fn.tempname(),
    })

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })

    vim.api.nvim_buf_delete(buf, { force = true })

    vim.wait(5000, function()
      return done
    end, 20)

    assert.is_true(done)
    assert.are.equal("anchor_lost", state)

    -- a later run must be accepted, not blocked by a stale `active`
    local buf2 = helpers.buf({ "local function g()", "  return 1", "end" }, "lua")
    vim.api.nvim_set_current_buf(buf2)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function g()\n  return 2\nend'),
      tmp_dir = vim.fn.tempname(),
    })

    local state2, done2 = nil, false
    shaerk.run({ __on_state = function(s)
      state2, done2 = s, true
    end })
    vim.wait(5000, function()
      return done2
    end, 20)

    assert.is_true(done2)
    assert.are.equal("ok", state2)
    assert.are.same(
      { "local function g()", "  return 2", "end" },
      vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
    )
  end)

  -- Task-8 finding #3: anchor:valid() only knows the extmark still exists and
  -- is non-degenerate, not whether the text under it is still what the AI
  -- edited. A whole-buffer replace mid-flight (:e!, format-on-save, a big
  -- undo) leaves the extmark valid, so without comparing original_lines vs
  -- current_lines, the AI result would silently clobber the user's new
  -- content while reporting "ok".
  it("regression: a whole-buffer replace mid-flight is detected as anchor_lost (bug 3)", function()
    local buf = helpers.buf({
      "local function f()",
      "  return 1",
      "end",
    }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend'),
      tmp_dir = vim.fn.tempname(),
    })

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })

    local new_content = { "local completely = 'different file'", "print(completely)" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_content)

    vim.wait(5000, function()
      return done
    end, 20)

    assert.is_true(done)
    assert.are.equal("anchor_lost", state)
    assert.are.same(new_content, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd("silent! close")
  end)

  -- Task-8 finding #1: anchor:apply() does not self-check anchor:valid(), and
  -- anchor:range() falls back to (0, 0) when the extmark is gone. If init.lua
  -- does not itself check anchor:valid() before applying, the result would be
  -- inserted at row 0 by mistake when the target region is deleted while the request is running.
  it("does not write at row 0 when the anchor is destroyed mid-flight", function()
    local buf = helpers.buf({
      "local x = 1",
      "local function f()",
      "  return 1",
      "end",
      "local y = 2",
    }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend'),
      tmp_dir = vim.fn.tempname(),
    })

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })

    -- Delete exactly the anchored region (replace with nothing) while the
    -- request is in flight, before on_done runs (on_done is delayed to the
    -- next tick by vim.schedule_wrap) — the same way anchor_spec.lua proves anchor:valid() becomes false.
    vim.api.nvim_buf_set_lines(buf, 1, 4, false, {})

    vim.wait(5000, function()
      return done
    end, 20)

    assert.are.equal("anchor_lost", state)
    assert.are.same({ "local x = 1", "local y = 2" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd("silent! close")
  end)

  -- C2: an empty anchor (free-form insert point) always reports valid() ==
  -- true (it can't be told apart from a deleted zero-width mark) and has no
  -- range to diff (srow == erow), so the mid-flight change guard used for a
  -- real range is a no-op here. Without anchor.lua's captured context window
  -- (the line above and the line at the insertion point), a whole-buffer
  -- replace during a free-form insert is applied anyway and reported "ok".
  it("regression: a whole-buffer replace during a free-form insert is detected as anchor_lost (C2)", function()
    -- Both lines are plain local declarations, not a function/call target, so
    -- target.resolve() falls through to the free-form fallback (needs_input =
    -- true, srow == erow) and Anchor.mark() produces a genuinely empty anchor
    -- -- exercising the context-window path added for C2, not the ranged-anchor
    -- diff that already existed for bug 3.
    local buf = helpers.buf({ "local generated = 1", "local other = 2" }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal inserted = 1'),
      tmp_dir = vim.fn.tempname(),
    })

    local orig_ask = ui.ask
    ui.ask = function(_prompt, cb)
      cb("insert something")
    end

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })
    ui.ask = orig_ask

    -- The line at the insertion point ("local other = 2") is replaced by
    -- something else -- the context captured at mark time no longer matches.
    local new_content = { "local generated = 1", "-- ENTIRELY DIFFERENT CONTENT", "local other = 2" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_content)

    vim.wait(5000, function()
      return done
    end, 20)

    assert.is_true(done)
    assert.are.equal("anchor_lost", state)
    assert.are.same(new_content, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd("silent! close")
  end)

  -- I2: `active` is only assigned once start() actually runs, which for a
  -- free-form spec happens inside ui.ask's callback. vim.ui.input is
  -- non-blocking under dressing.nvim/snacks.nvim/noice/fzf-lua, so a second
  -- run() issued before the first prompt is answered used to sail straight
  -- past the `if active then` guard and open a second prompt.
  it("regression: a second run() is refused while a prompt is still open (I2)", function()
    local buf = helpers.buf({ "local x = 1" }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local calls = 0
    local base = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal x = 2')
    local provider = {
      name = "counted",
      cmd = function(query, tmp)
        calls = calls + 1
        return base.cmd(query, tmp)
      end,
    }
    shaerk.setup({ provider = provider, tmp_dir = vim.fn.tempname() })

    -- Simulate a non-blocking vim.ui.input: cb is stashed, not called.
    local pending = {}
    local orig_ask = ui.ask
    ui.ask = function(_prompt, cb)
      table.insert(pending, cb)
    end

    local done = false
    shaerk.run({ ask = true, __on_state = function()
      done = true
    end })
    shaerk.run({ ask = true })

    ui.ask = orig_ask

    -- The real bug symptom: a second prompt opened before the first answered.
    assert.are.equal(1, #pending)

    for _, cb in ipairs(pending) do
      cb("multiply by 2")
    end
    -- Wait for the request this test actually started to finish, so it
    -- doesn't leak a live `active` into the next test.
    vim.wait(2000, function()
      return done
    end, 20)

    assert.are.equal(1, calls)
  end)

  -- I3: closing the buffer mid-flight used to return "anchor_lost" with no
  -- ui.notify and no ui.preview -- the user waited for the agent and got
  -- nothing. Fix previews the result (using the parsed header's lang) and notifies.
  it("regression: closing the buffer mid-flight previews the result instead of failing silently (I3)", function()
    local buf = helpers.buf({
      "local x = 1",
      "local function f()",
      "  return 1",
      "end",
    }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend'),
      tmp_dir = vim.fn.tempname(),
    })

    local preview_calls = {}
    local orig_preview = ui.preview
    ui.preview = function(lines, ft, title)
      table.insert(preview_calls, { lines = lines, ft = ft, title = title })
      return orig_preview(lines, ft, title)
    end

    local notified = {}
    local orig_notify = ui.notify
    ui.notify = function(msg, level)
      table.insert(notified, msg)
      orig_notify(msg, level)
    end

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })

    vim.api.nvim_buf_delete(buf, { force = true })

    vim.wait(5000, function()
      return done
    end, 20)

    ui.preview = orig_preview
    ui.notify = orig_notify

    assert.is_true(done)
    assert.are.equal("anchor_lost", state)
    assert.are.equal(1, #preview_calls)
    assert.are.same({ "local function f()", "  return 2", "end" }, preview_calls[1].lines)
    assert.are.equal("lua", preview_calls[1].ft)

    local closed_note = false
    for _, msg in ipairs(notified) do
      if msg:find("closed", 1, true) then
        closed_note = true
      end
    end
    assert.is_true(closed_note)

    vim.cmd("silent! close")
  end)

  -- Test gap 1: deleting spinner:stop() from on_done leaves 71/71 passing --
  -- it leaks a repeating 100ms vim.uv timer per request plus a frozen glyph.
  it("regression: the spinner's timer is closed when a request finishes (test gap 1)", function()
    local buf = helpers.buf({ "local function f()", "  return 1", "end" }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend'),
      tmp_dir = vim.fn.tempname(),
    })

    local captured_timer
    local orig_spinner = ui.spinner
    ui.spinner = function(anchor)
      local s = orig_spinner(anchor)
      captured_timer = s.timer
      return s
    end

    local done = false
    shaerk.run({ __on_state = function()
      done = true
    end })
    vim.wait(5000, function()
      return done
    end, 20)

    ui.spinner = orig_spinner

    assert.is_true(done)
    assert.is_not_nil(captured_timer)
    assert.is_true(captured_timer:is_closing())
  end)

  -- Test gap 2: the built query is the entire product. Blanking either the
  -- <File> buffer text or the <Target> region text at build_query() leaves
  -- 71/71 passing without these assertions.
  it("the built query embeds the buffer text and the exact target region text", function()
    local buf = helpers.buf({
      "local x = 1",
      "local function f()",
      "  return 1",
      "end",
    }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    local queries = {}
    local provider = {
      name = "capture",
      cmd = function(query, tmp)
        table.insert(queries, query)
        return fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal function f()\n  return 2\nend').cmd(
          query,
          tmp
        )
      end,
    }
    shaerk.setup({ provider = provider, tmp_dir = vim.fn.tempname() })

    local done = false
    shaerk.run({ __on_state = function()
      done = true
    end })
    vim.wait(5000, function()
      return done
    end, 20)

    assert.are.equal(1, #queries)

    -- Buffer text: "local x = 1" appears only in the <File> section, not the target.
    local file_section = queries[1]:match('<File[^>]*>\n(.-)\n</File>')
    assert.is_truthy(file_section)
    assert.is_truthy(file_section:find("local x = 1", 1, true))

    -- Target text: the exact target region, byte for byte, right after the tag.
    local target_section = queries[1]:match('<Target lines="2%-4">\n(.-)\n</Target>')
    assert.are.equal(
      table.concat({ "local function f()", "  return 1", "end" }, "\n"),
      target_section
    )
  end)

  it("the built query embeds the user's free-form spec", function()
    local buf = helpers.buf({ "local x = 1" }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local queries = {}
    local provider = {
      name = "capture",
      cmd = function(query, tmp)
        table.insert(queries, query)
        return fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal inserted = 1').cmd(query, tmp)
      end,
    }
    shaerk.setup({ provider = provider, tmp_dir = vim.fn.tempname() })

    local orig_ask = ui.ask
    ui.ask = function(_prompt, cb)
      cb("insert a marker constant unique-spec-xyz")
    end

    local done = false
    shaerk.run({ __on_state = function()
      done = true
    end })
    ui.ask = orig_ask

    vim.wait(5000, function()
      return done
    end, 20)

    assert.are.equal(1, #queries)
    local spec_section = queries[1]:match("<Spec>\n(.-)\n</Spec>")
    assert.is_truthy(spec_section)
    assert.is_truthy(spec_section:find("unique-spec-xyz", 1, true))
  end)

  it("appends a FormatError block on a contract-violation retry (test gap 2)", function()
    -- A target on a function (not a free-form insert point) so this doesn't
    -- need a ui.ask stub: needs_input is false and shaerk.run() goes straight
    -- to start() like "the built query embeds the buffer text..." above.
    local buf = helpers.buf({ "local function f()", "  return 1", "end" }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local queries = {}
    local provider = {
      name = "capture-badheader",
      cmd = function(query, tmp)
        table.insert(queries, query)
        return fake("not json at all").cmd(query, tmp)
      end,
    }
    shaerk.setup({ provider = provider, tmp_dir = vim.fn.tempname() })

    local done = false
    shaerk.run({ __on_state = function()
      done = true
    end })
    vim.wait(5000, function()
      return done
    end, 20)

    assert.are.equal(2, #queries)
    assert.is_falsy(queries[1]:find("<FormatError>", 1, true))
    assert.is_truthy(queries[2]:find("<FormatError>", 1, true))
    assert.is_truthy(queries[2]:find("bad_header", 1, true))
  end)

  -- Test gap 3: deleting anchor:clear() from on_done leaves 71/71 passing --
  -- every completed request leaks a live extmark in the shaerk namespace.
  it("regression: the anchor extmark is cleared after a request finishes (test gap 3)", function()
    -- status = "no_change" (not "ok") deliberately: Anchor:apply() clears its
    -- own extmark internally as part of replacing the range, so an "ok" run
    -- would pass this assertion even without on_done's own anchor:clear()
    -- call. A no_change/refused/etc. terminal state never calls apply() --
    -- clearing the extmark there depends entirely on the line under test.
    local buf = helpers.buf({ "local function f()", "  return 1", "end" }, "lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    shaerk.setup({
      provider = fake('{"v":1,"status":"no_change","note":"fine"}'),
      tmp_dir = vim.fn.tempname(),
    })

    local state, done = nil, false
    shaerk.run({ __on_state = function(s)
      state, done = s, true
    end })
    vim.wait(5000, function()
      return done
    end, 20)

    local ns = vim.api.nvim_create_namespace("shaerk")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.are.equal("no_change", state)
    assert.are.equal(0, #marks)
  end)
end)

describe("shaerk.visual", function()
  it("resolves the visual range rather than the cursor region", function()
    local buf = helpers.buf({
      "local x = 1",
      "local function f()",
      "  return 1",
      "end",
      "local y = 2",
    }, "lua")
    vim.api.nvim_set_current_buf(buf)
    -- cursor sits inside the function, but the visual selection covers only
    -- line 1 ("local x = 1") -- if visual() used the cursor region instead,
    -- the function body would be replaced instead of line 1.
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, ">", 1, 0, {})

    shaerk.setup({
      provider = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal x = 100'),
      tmp_dir = vim.fn.tempname(),
    })

    local orig_ask = ui.ask
    ui.ask = function(_prompt, cb)
      cb("multiply by 100")
    end

    -- shaerk.visual() takes no opts (unlike shaerk.run) so there is no
    -- __on_state hook here -- assert on the actual observable: buffer content.
    shaerk.visual()
    ui.ask = orig_ask

    vim.wait(5000, function()
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "local x = 100"
    end, 20)

    assert.are.same({
      "local x = 100",
      "local function f()",
      "  return 1",
      "end",
      "local y = 2",
    }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)

describe("shaerk.setup", function()
  it("sweeps stale tmp files older than an hour", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local old = dir .. "/old.out"
    local fresh = dir .. "/fresh.out"
    helpers.write(old, "x")
    helpers.write(fresh, "x")
    local two_hours_ago = os.time() - 7200
    vim.uv.fs_utime(old, two_hours_ago, two_hours_ago)

    shaerk.setup({ tmp_dir = dir })

    assert.are.equal(0, vim.fn.filereadable(old))
    assert.are.equal(1, vim.fn.filereadable(fresh))
  end)
end)
