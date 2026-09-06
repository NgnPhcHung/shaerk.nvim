local helpers = require("tests.helpers")
local target = require("shaerk.target")

-- Neovim ships only its bundled parsers; typescript comes from nvim-treesitter,
-- which CI does not install. Probe the parser file rather than language.add():
-- add() throws on 0.10 and returns nil, err on 0.12, so its result is not portable.
local it_typescript = #vim.api.nvim_get_runtime_file("parser/typescript.so", false) > 0
    and it
  or pending

--- Open a buffer as current, set the cursor, return buf.
--- @param lines string[]
--- @param filetype string
--- @param row number 1-indexed like nvim_win_set_cursor
local function open(lines, filetype, row)
  local buf = helpers.buf(lines, filetype)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  return buf
end

describe("target.resolve", function()
  it("selects the enclosing lua function", function()
    open({
      "local x = 1",
      "local function f()",
      "  return 1",
      "end",
      "local y = 2",
    }, "lua", 3)
    local t = target.resolve({})
    assert.are.equal(1, t.srow)
    assert.are.equal(4, t.erow)
    assert.is_false(t.needs_input)
    assert.is_truthy(t.spec:find("local function f()", 1, true))
  end)

  it("includes the comment block directly above the function", function()
    open({
      "-- step 1: read",
      "-- step 2: parse",
      "local function f()",
      "  return 1",
      "end",
    }, "lua", 4)
    local t = target.resolve({})
    assert.are.equal(0, t.srow)
    assert.are.equal(5, t.erow)
    assert.is_truthy(t.spec:find("step 1", 1, true))
  end)

  it("stops at a blank line between comment and function", function()
    open({
      "-- unrelated note",
      "",
      "local function f()",
      "  return 1",
      "end",
    }, "lua", 4)
    local t = target.resolve({})
    assert.are.equal(2, t.srow)
  end)

  it("selects the comment block when there is no function yet", function()
    open({
      "local x = 1",
      "-- make a function that adds two numbers",
      "-- it must validate both are numbers",
    }, "lua", 2)
    local t = target.resolve({})
    assert.are.equal(1, t.srow)
    assert.are.equal(3, t.erow)
    assert.is_false(t.needs_input)
    assert.is_truthy(t.spec:find("adds two numbers", 1, true))
  end)

  it("falls back to an empty range at the cursor", function()
    open({ "local x = 1", "local y = 2" }, "lua", 2)
    local t = target.resolve({})
    assert.are.equal(1, t.srow)
    assert.are.equal(1, t.erow)
    assert.is_true(t.needs_input)
  end)

  it("falls back cleanly when the filetype has no installed parser", function()
    open({ "hello" }, "text", 1)
    local ok, t = pcall(target.resolve, {})
    assert.is_true(ok)
    assert.are.equal(0, t.srow)
    assert.are.equal(0, t.erow)
    assert.is_true(t.needs_input)
  end)

  it_typescript("selects a typescript method", function()
    open({
      "class A {",
      "  run() {",
      "    return 1;",
      "  }",
      "}",
    }, "typescript", 3)
    local t = target.resolve({})
    assert.are.equal(1, t.srow)
    assert.are.equal(4, t.erow)
  end)

  it("uses the visual marks when visual is set", function()
    local buf = open({ "a", "b", "c", "d" }, "lua", 1)
    vim.api.nvim_buf_set_mark(buf, "<", 2, 0, {})
    vim.api.nvim_buf_set_mark(buf, ">", 3, 0, {})
    local t = target.resolve({ visual = true })
    assert.are.equal(1, t.srow)
    assert.are.equal(3, t.erow)
    assert.is_true(t.needs_input)
  end)
end)
