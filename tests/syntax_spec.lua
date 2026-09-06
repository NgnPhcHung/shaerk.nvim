local helpers = require("tests.helpers")
local contract = require("shaerk.contract")

describe("contract.check_syntax", function()
  it("accepts a valid replacement", function()
    local buf = helpers.buf({ "local function f()", "  return 1", "end" }, "lua")
    assert.is_true(contract.check_syntax(buf, 1, 2, "  return 2"))
  end)

  it("rejects a replacement that breaks the file", function()
    local buf = helpers.buf({ "local function f()", "  return 1", "end" }, "lua")
    assert.is_false(contract.check_syntax(buf, 1, 2, "  return ((("))
  end)

  it("accepts a fragment that only parses in context", function()
    -- 'else' on its own is a syntax error, but between 'if ... then' and 'end'
    -- it's valid. If the gate parses the body standalone instead of splicing it into the buffer, this test goes red.
    local buf = helpers.buf({ "if x then", "  print(1)", "end" }, "lua")
    assert.is_true(contract.check_syntax(buf, 1, 2, "else"))
  end)

  it("accepts an insert into an empty range", function()
    local buf = helpers.buf({ "local a = 1", "local b = 2" }, "lua")
    assert.is_true(contract.check_syntax(buf, 1, 1, "local c = 3"))
  end)

  it("skips the gate when no parser exists for the filetype", function()
    local buf = helpers.buf({ "anything" }, "nosuchfiletype")
    assert.is_true(contract.check_syntax(buf, 0, 1, "!!! not code !!!"))
  end)
end)
