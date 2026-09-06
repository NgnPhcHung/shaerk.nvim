local M = {}

--- A provider is just data: a function that builds a command array.
--- The tmp path already lives in the query (contract.instructions); the tmp
--- parameter here is for a provider that needs its own output flag, and for the fake provider in tests.
M.claude = {
  name = "claude",
  --- @param query string
  --- @param _tmp string
  --- @return string[]
  cmd = function(query, _tmp)
    return {
      "claude",
      "-p",
      "--allowedTools",
      "Read,Grep,Glob,Write",
      query,
    }
  end,
}

M.default = M.claude

return M
