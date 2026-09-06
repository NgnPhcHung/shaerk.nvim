local helpers = require("tests.helpers")
local request = require("shaerk.request")

--- Fake provider: writes the given content to tmp then exits 0.
--- @param text string|nil nil = writes nothing
--- @param code number|nil exit code, default 0
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

--- Run the request and wait for on_done, up to 5 seconds.
--- @return string state, table|nil res, string|nil detail
local function run_sync(o)
  local done, state, res, detail = false, nil, nil, nil
  local req = request.start(vim.tbl_extend("force", o, {
    on_done = function(s, r, d)
      state, res, detail, done = s, r, d, true
    end,
  }))
  vim.wait(5000, function()
    return done
  end, 20)
  return state, res, detail, req
end

describe("request", function()
  it("parses a successful run", function()
    local tmp = helpers.tmpfile()
    local state, res = run_sync({
      tmp = tmp,
      prov = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal x = 1'),
      build = function()
        return "query"
      end,
    })
    assert.are.equal("parsed", state)
    assert.are.equal("local x = 1", res.body)
  end)

  it("deletes the tmp file when it finishes", function()
    local tmp = helpers.tmpfile()
    run_sync({
      tmp = tmp,
      prov = fake('{"v":1,"status":"ok","lang":"lua"}\n\nlocal x = 1'),
      build = function()
        return "query"
      end,
    })
    assert.are.equal(0, vim.fn.filereadable(tmp))
  end)

  it("reports proc_failed on a non-zero exit", function()
    local tmp = helpers.tmpfile()
    local attempts = 0
    local state = run_sync({
      tmp = tmp,
      prov = fake(nil, 3),
      build = function()
        attempts = attempts + 1
        return "query"
      end,
    })
    assert.are.equal("proc_failed", state)
    assert.are.equal(1, attempts)
  end)

  it("reports proc_failed when the binary does not exist", function()
    local tmp = helpers.tmpfile()
    local state, _, detail, req = run_sync({
      tmp = tmp,
      prov = {
        name = "missing",
        cmd = function()
          return { "this-cmd-does-not-exist-xyz" }
        end,
      },
      build = function()
        return "query"
      end,
    })
    assert.are.equal("proc_failed", state)
    -- `assert.is_not_nil(req)` is trivially true (request.start always returns
    -- a table): assert something that actually depends on the spawn-failure
    -- path having run to completion synchronously instead.
    assert.is_true(req.done)
    -- `assert.are.equal(0, filereadable(tmp))` was trivially true too: _attempt
    -- removes tmp before ever spawning, regardless of what _finish does on
    -- failure. Assert on the real ENOENT detail bubbling through on_done instead.
    assert.is_truthy(detail and detail:find("ENOENT", 1, true))
  end)

  -- C1: self.build(format_err) and self.prov.cmd(...) used to run OUTSIDE the
  -- pcall that guards vim.system, only on the retry path (the first attempt's
  -- build() is also unguarded in the original code, but init.lua's build()
  -- only throws when it reads anchor:range() on a buffer that's already gone,
  -- which can only happen after at least one attempt has round-tripped). A
  -- build() that throws on the retry (e.g. the target buffer was closed while
  -- attempt 1 was in flight) must not escape request.lua uncaught — it has to
  -- land on proc_failed like every other spawn-time failure, not leave on_done
  -- (and therefore init.lua's `active`) unresolved forever.
  it("routes a build() failure on retry to proc_failed instead of throwing (bug C1)", function()
    local tmp = helpers.tmpfile()
    local attempts = 0
    -- If build()'s throw escapes uncaught, on_done never fires: state stays
    -- nil and run_sync's vim.wait times out instead of returning promptly.
    local state = run_sync({
      tmp = tmp,
      -- exits 0 without writing tmp -> "no_file" -> triggers exactly one retry
      prov = fake(nil, 0),
      build = function(format_err)
        attempts = attempts + 1
        if format_err then
          error("simulated: anchor:range() on a deleted buffer")
        end
        return "query"
      end,
    })
    assert.are.equal("proc_failed", state)
    assert.are.equal(2, attempts)
    assert.are.equal(0, vim.fn.filereadable(tmp))
  end)

  it("retries once on no_file then gives up", function()
    local tmp = helpers.tmpfile()
    local seen = {}
    local state = run_sync({
      tmp = tmp,
      prov = fake(nil, 0),
      build = function(format_err)
        table.insert(seen, format_err or "first")
        return "query"
      end,
    })
    assert.are.equal("no_file", state)
    assert.are.same({ "first", "no_file" }, seen)
  end)

  it("retries once on bad_header", function()
    local tmp = helpers.tmpfile()
    local attempts = 0
    local state = run_sync({
      tmp = tmp,
      prov = fake("not json at all"),
      build = function()
        attempts = attempts + 1
        return "query"
      end,
    })
    assert.are.equal("bad_header", state)
    assert.are.equal(2, attempts)
  end)

  it("does not retry a successful parse", function()
    local tmp = helpers.tmpfile()
    local attempts = 0
    run_sync({
      tmp = tmp,
      prov = fake('{"v":1,"status":"no_change","note":"fine"}'),
      build = function()
        attempts = attempts + 1
        return "query"
      end,
    })
    assert.are.equal(1, attempts)
  end)

  it("reports cancelled and cleans up", function()
    local tmp = helpers.tmpfile()
    local done, state = false, nil
    local req = request.start({
      tmp = tmp,
      -- Write tmp before sleeping: otherwise filereadable(tmp) == 0 is true
      -- from the very start and proves nothing about cleanup.
      prov = {
        name = "slow",
        cmd = function(_query, t)
          local script = string.format(
            "mkdir -p %s && cat > %s <<'SHAERK_EOF'\nplaceholder\nSHAERK_EOF\nsleep 5",
            vim.fn.shellescape(vim.fs.dirname(t)),
            vim.fn.shellescape(t)
          )
          return { "sh", "-c", script }
        end,
      },
      build = function()
        return "query"
      end,
      on_done = function(s)
        state, done = s, true
      end,
    })
    -- Wait for the file to actually be written before cancelling, so cleanup has something to clean up.
    vim.wait(2000, function()
      return vim.fn.filereadable(tmp) == 1
    end, 20)
    req:cancel()
    vim.wait(2000, function()
      return done
    end, 20)
    assert.are.equal("cancelled", state)
    assert.are.equal(0, vim.fn.filereadable(tmp))
  end)

  it("calls on_done exactly once", function()
    local tmp = helpers.tmpfile()
    local calls = 0
    local done = false
    local req = request.start({
      tmp = tmp,
      prov = fake('{"v":1,"status":"no_change","note":"fine"}'),
      build = function()
        return "query"
      end,
      on_done = function()
        calls = calls + 1
        done = true
      end,
    })
    vim.wait(5000, function()
      return done
    end, 20)
    req:cancel()
    vim.wait(200)
    assert.are.equal(1, calls)
  end)
end)

describe("provider.claude", function()
  it("builds a read-only command carrying the query", function()
    local provider = require("shaerk.provider")
    local cmd = provider.claude.cmd("my query", "/tmp/x.out")
    assert.are.equal("claude", cmd[1])
    assert.is_truthy(vim.tbl_contains(cmd, "my query"))
    assert.is_truthy(vim.tbl_contains(cmd, "-p"))
  end)
end)
