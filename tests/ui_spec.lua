local helpers = require("tests.helpers")
local Anchor = require("shaerk.anchor")
local ui = require("shaerk.ui")

describe("ui.spinner", function()
  it("draws virtual text on the anchor line and removes it on stop", function()
    local buf = helpers.buf({ "a", "b", "c" }, "lua")
    local anchor = Anchor.mark(buf, 1, 2)
    local spinner = ui.spinner(anchor)

    local ns = vim.api.nvim_create_namespace("shaerk.ui")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.is_true(#marks > 0)

    spinner:stop()
    marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.are.equal(0, #marks)
  end)

  it("stop is idempotent", function()
    local buf = helpers.buf({ "a" }, "lua")
    local spinner = ui.spinner(Anchor.mark(buf, 0, 1))
    local timer = spinner.timer

    spinner:stop()
    assert.is_true(timer:is_closing())

    spinner:stop()
    assert.is_true(timer:is_closing())
  end)
end)

describe("ui.preview", function()
  it("opens a scratch buffer with the given lines", function()
    local buf = ui.preview({ "local x = 1" }, "lua", "shaerk: invalid syntax")
    assert.are.same({ "local x = 1" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal("lua", vim.bo[buf].filetype)
    assert.are.equal("nofile", vim.bo[buf].buftype)
    vim.cmd("silent! close")
  end)
end)
